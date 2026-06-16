import Foundation
import Combine
import AppKit
import UserNotifications
import MeetingKit

/// The app coordinator: owns the calendar/detector/capture/processor wiring and
/// the observable state the UI renders. Runs the "calendar AND app detected"
/// auto-start loop, manages a single capture session, and kicks off
/// post-meeting processing.
@MainActor
final class AppState: ObservableObject {
    /// Weak global handle so the app delegate (Dock-click / reopen handling) can
    /// reach the single coordinator without creating a second instance.
    static weak var shared: AppState?

    /// Set by the menu-bar label once SwiftUI's `openWindow` action is available,
    /// so non-view code (a Dock click when the menu-bar icon is hidden) can bring
    /// the main window forward.
    var openMainWindow: (() -> Void)?
    /// The meeting currently being recorded, or nil. Recording is single (one mic
    /// + screen at a time) but runs INDEPENDENTLY of transcription, so a new
    /// recording can start while earlier meetings are still being transcribed.
    @Published private(set) var recording: Meeting?

    /// The serial transcription queue: the meeting being transcribed plus any
    /// waiting behind it. Drains in the background while recording continues.
    @Published private(set) var processing = ProcessingQueue()

    /// One-line, plain-English summary of everything in flight, for the menu bar.
    var statusSummary: String {
        var parts: [String] = []
        if let r = recording { parts.append("Recording: \(r.title)") }
        if let p = processing.current {
            let q = processing.pendingCount
            parts.append("Making transcript: \(p.title)" + (q > 0 ? " (\(q) queued)" : ""))
        }
        return parts.isEmpty ? "Watching for meetings" : parts.joined(separator: " · ")
    }

    /// True while a capture session is active (drives the record/stop control).
    var isRecording: Bool { recording != nil }
    @Published private(set) var upcoming: [Meeting] = []
    @Published private(set) var recordings: [MeetingRecording] = []
    @Published var lastError: String?

    /// Post-meeting progress for the UI: a 0...1 fraction during model download
    /// (nil otherwise) and a stage label ("Downloading model…", "Transcribing…").
    @Published private(set) var progressFraction: Double?
    @Published private(set) var progressPhase: String?

    /// Model readiness — the transcription model is downloaded + loaded at launch,
    /// and processing is gated on it being ready.
    @Published private(set) var modelReady = false
    @Published private(set) var modelPreparing = false
    @Published private(set) var modelDownloadFraction: Double?
    @Published private(set) var modelStatusText: String?
    /// True only after a download/load attempt actually failed — gates the retry UI
    /// so it never shows before the first attempt.
    @Published private(set) var modelFailed = false

    /// True while a voice enrollment is being processed (extracting the voiceprint,
    /// which may trigger a one-time diarization-model download). Drives a "working"
    /// state in the enrollment UI so it isn't silently frozen.
    @Published private(set) var isEnrolling = false

    let settings: AppSettings
    let permissions: Permissions
    private let calendar: CalendarWatcher
    private let detector: MeetingDetector
    private let store: MeetingStore

    private var capture: CaptureSession?
    /// The background task draining the transcription queue, nil when idle.
    private var drainTask: Task<Void, Never>?
    private var pollTimer: Timer?
    private var notifiedMeetingIDs: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []

    /// Set once the main window has been auto-opened at launch, so we only do it
    /// the first time the process runs (not every time the window's task fires).
    var hasAutoOpenedWindow = false

    /// Pure, testable summary of first-run setup, derived from current permissions.
    var setup: SetupState {
        SetupState(statuses: [
            .screenRecording: permissions.screenRecording.setupStatus,
            .microphone: permissions.microphone.setupStatus,
            .calendar: permissions.calendar.setupStatus,
            .accessibility: permissions.accessibility.setupStatus,
            .notifications: permissions.notifications.setupStatus,
        ])
    }

    /// The menu-bar icon: a warning until setup is complete, otherwise reflects
    /// what the app is doing (a filled record dot while recording).
    var menuBarSymbol: String {
        guard setup.isComplete else { return "exclamationmark.triangle.fill" }
        if recording != nil { return "record.circle.fill" }
        if processing.current != nil { return "gearshape.2" }
        return "waveform"
    }

    /// Shared, prepared transcriber reused across all processing so the model is
    /// downloaded/loaded exactly once (at launch) rather than per meeting.
    private var transcriber: Transcribing

    /// Shared on-device diarizer, warmed up alongside the transcriber so in-room
    /// speaker separation doesn't pay the model load cost on the first meeting.
    private var diarizer: Diarizing

    init() {
        let calendar = CalendarWatcher()
        self.calendar = calendar
        self.detector = MeetingDetector()
        let settings = AppSettings()
        self.settings = settings
        self.permissions = Permissions(calendarWatcher: calendar)
        // A failure here is unrecoverable (no place to store data); surface loudly.
        self.store = try! MeetingStore()
        self.recordings = store.allRecordings()
        self.transcriber = Backends.makeTranscriber(
            model: settings.transcriptionModel,
            workers: settings.transcriptionWorkers
        )
        self.diarizer = Backends.makeDiarizer()
        // Re-publish permission changes so onboarding/menu views observing AppState
        // update live as the user grants each capability.
        permissions.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Same for settings: views observe AppState, not the nested AppSettings
        // object, so without this a Settings toggle (e.g. "Identify multiple
        // in-room speakers") would write through but never visually update.
        settings.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Screen Recording / Accessibility are granted in System Settings, outside
        // the app. Re-check permissions whenever the user switches back so the
        // onboarding checklist updates the moment they return.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.permissions.refresh()
                    self?.refreshUpcoming()
                }
            }
            .store(in: &cancellables)

        Self.shared = self
    }

    /// Request a single capability (the onboarding checklist drives this), then
    /// refresh anything that depends on it.
    func grant(_ capability: SetupCapability) async {
        switch capability {
        case .screenRecording: permissions.requestScreenRecording()
        case .microphone:       await permissions.requestMicrophone()
        case .calendar:         await permissions.requestCalendar(); refreshUpcoming()
        case .accessibility:    permissions.requestAccessibility()
        case .notifications:    await permissions.requestNotifications()
        }
    }

    // MARK: - Lifecycle

    /// Begin background polling: refresh the calendar and check auto-start every
    /// 30 seconds. Cheap — it only lists events and checks running apps.
    func start() {
        applyDockIconSetting()
        refreshUpcoming()
        Task { await prepareModel() }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Download + load the transcription model up front (at launch, or after the
    /// user changes the model in Settings). Processing waits for this to finish.
    func prepareModel() async {
        lastError = nil
        modelPreparing = true
        modelReady = false
        modelFailed = false
        modelStatusText = "Preparing model…"
        transcriber = Backends.makeTranscriber(
            model: settings.transcriptionModel,
            workers: settings.transcriptionWorkers
        )
        let tHandler: TranscribeProgressHandler = { [weak self] p in
            Task { @MainActor in
                self?.modelDownloadFraction = p.fraction
                self?.modelStatusText = p.phase
            }
        }
        do {
            try await transcriber.prepare(progress: tHandler)
            // Best-effort: warm up the diarizer too when in-room identification is
            // enabled, so the first meeting doesn't pay the model load cost. A
            // failure here must not block transcription, which works without it.
            if settings.identifyInRoomSpeakers {
                try? await diarizer.prepare(progress: tHandler)
            }
            modelReady = true
            modelStatusText = "Model ready"
        } catch {
            modelFailed = true
            modelStatusText = "Download failed — tap to retry"
            lastError = userFacingMessage(for: .modelDownload, error: error)
        }
        modelPreparing = false
        modelDownloadFraction = nil
    }

    private func tick() {
        refreshUpcoming()
        // Auto-start only gates on whether we're already recording — transcription
        // of a previous meeting runs independently and must not block a new one.
        guard recording == nil else { return }
        for meeting in upcoming where detector.shouldAutoStart(meeting) {
            notifyAndStart(meeting)
            break
        }
    }

    func refreshUpcoming() {
        guard permissions.calendar == .granted else { return }
        upcoming = calendar.upcomingMeetings()
    }

    /// Show or hide the Dock icon per the user's preference. A Dock icon is an
    /// always-visible way in when the menu-bar icon is hidden for lack of space.
    func applyDockIconSetting() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
    }

    /// Quit and reopen the app. Some permissions — notably Screen & Audio
    /// Recording — only take effect on a fresh launch, so onboarding offers this.
    /// Spawns a tiny detached shell that waits for this instance to exit, then
    /// relaunches the bundle. (The app is intentionally non-sandboxed, so this is
    /// allowed.)
    func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: - Capture control

    /// Auto-start path: notify the user that recording began, then start.
    private func notifyAndStart(_ meeting: Meeting) {
        guard !notifiedMeetingIDs.contains(meeting.id) else { return }
        notifiedMeetingIDs.insert(meeting.id)
        postNotification(
            title: "Recording started",
            body: "Meeting Assistant is transcribing “\(meeting.title)”."
        )
        Task { await startCapture(for: meeting) }
    }

    /// Start an ad-hoc capture with no calendar entry — the user clicked "Start"
    /// for a meeting that isn't (or isn't yet) on their calendar. Labels it with
    /// the detected provider when a native client is running.
    func startAdHocCapture() async {
        guard recording == nil else { return }
        let provider = detector.firstRunningProvider()
        let meeting = Meeting.adHoc(id: "adhoc-\(UUID().uuidString)", provider: provider, start: Date())
        await startCapture(for: meeting)
    }

    /// Start capturing a meeting (also the manual Start action).
    func startCapture(for meeting: Meeting) async {
        guard recording == nil else { return }
        lastError = nil
        let session = CaptureSession(meeting: meeting, store: store)
        do {
            try await session.start()
            capture = session
            recording = meeting
        } catch {
            lastError = userFacingMessage(for: .startRecording, error: error)
        }
    }

    /// Stop the active capture and hand the meeting to the transcription queue.
    /// Returns immediately so the user can start recording again right away;
    /// transcription drains serially in the background.
    func stopCapture() async {
        guard let meeting = recording, let session = capture else { return }
        do {
            try await session.stop()
            capture = nil
            recording = nil
            processing.enqueue(meeting)
            recordings = store.allRecordings()
            drainProcessingQueue()
        } catch {
            lastError = userFacingMessage(for: .stopRecording, error: error)
            capture = nil
            recording = nil
        }
    }

    // MARK: - Post-processing

    /// Drain the transcription queue serially in the background. Idempotent: if a
    /// drain task is already running it just returns, and the running loop picks up
    /// anything enqueued since. Recording continues independently throughout.
    private func drainProcessingQueue() {
        guard drainTask == nil else { return }
        drainTask = Task { @MainActor in
            while let meeting = processing.startNext() {
                await process(meeting)
                processing.finishCurrent()
                progressFraction = nil
                progressPhase = nil
            }
            drainTask = nil
        }
    }

    private func process(_ meeting: Meeting) async {
        guard let recording = store.allRecordings().first(where: { $0.meeting.id == meeting.id }) else {
            return
        }
        // Diarization requires the user to have enrolled their voice — otherwise
        // their own mic audio would be split off as "Speaker 2" instead of "Me",
        // a worse result than today's blanket "Me". Without enrollment we fall back
        // to the stub (blanket "Me"), matching pre-feature behavior.
        let useDiar = settings.identifyInRoomSpeakers && settings.speakerLibrary.me != nil
        let processor = MeetingProcessor(
            store: store,
            transcriber: transcriber,
            diarizer: useDiar ? diarizer : StubDiarizer(),
            knownSpeakers: useDiar ? settings.speakerLibrary.all() : []
        )
        let progress: MeetingProcessor.ProcessProgress = { [weak self] fraction, phase in
            Task { @MainActor in
                self?.progressFraction = fraction
                self?.progressPhase = phase
            }
        }
        do {
            _ = try await processor.process(recording, progress: progress)
            postNotification(title: "Transcript ready", body: "The transcript for “\(meeting.title)” is ready.")
        } catch {
            lastError = userFacingMessage(for: .transcribing, error: error)
        }
        // Progress reset + advancing the queue is handled by the drain loop.
        recordings = store.allRecordings()
    }

    /// Re-run the transcription pipeline for a saved recording. Recovers a meeting
    /// whose processing failed — the audio + speaker timeline are already on disk.
    func reprocess(_ recording: MeetingRecording) async {
        // Enqueue behind anything already transcribing (dedup if already queued).
        guard !processing.contains(recording.meeting.id) else { return }
        lastError = nil
        processing.enqueue(recording.meeting)
        drainProcessingQueue()
    }

    func transcript(for recording: MeetingRecording) -> String? {
        store.transcript(for: recording.meeting.id)
    }

    /// Rename a speaker in a saved transcript. Rewrites the transcript text and,
    /// when the meeting has a persisted speaker map, teaches the shared library the
    /// new name for that cluster's voiceprint so the person is recognized in future
    /// meetings. Best-effort: a missing map just rewrites the text.
    @MainActor
    func renameSpeaker(in recording: MeetingRecording, from oldLabel: String, to newName: String) {
        let meetingID = recording.meeting.id
        let map = store.speakerMap(for: meetingID)

        // 1. Rewrite the rendered transcript's labels.
        guard let current = store.transcript(for: meetingID) else { return }
        let updated = TranscriptRelabeler.rename(in: current, from: oldLabel, to: newName)
        try? store.saveTranscript(updated, for: meetingID)

        // 2. If we have a speaker map, learn the voiceprint under the new name and
        //    update the map's label so a later rename starts from the right place.
        if var map, let embedding = map.relabel(from: oldLabel, to: newName) {
            // Preserve the existing speaker's `isMe` flag: renaming a cluster to an
            // existing name (e.g. "Me") must not demote it to a regular speaker and
            // silently disable enrollment.
            let isMe = KnownSpeaker.preservedIsMe(forName: newName, in: settings.speakerLibrary.all())
            try? settings.speakerLibrary.upsert(name: newName, embedding: embedding, isMe: isMe)
            try? store.saveSpeakerMap(map, for: meetingID)
        }

        // Transcripts are read on demand via `transcript(for:)`, so a generic
        // change notification is enough to refresh any view showing one.
        objectWillChange.send()
    }

    /// On-disk transcript file, for "Reveal in Finder".
    func transcriptURL(for recording: MeetingRecording) -> URL {
        store.transcriptURL(for: recording.meeting.id)
    }

    // MARK: - Speakers

    /// Distinct speaker labels detected in a meeting (from its persisted speaker
    /// map), sorted for stable display. Empty if the meeting wasn't diarized.
    func meetingSpeakers(for recording: MeetingRecording) -> [String] {
        guard let map = store.speakerMap(for: recording.meeting.id) else { return [] }
        return Array(Set(map.labelByCluster.values)).sorted()
    }

    /// The known speakers in the shared library (for Settings management).
    func knownSpeakers() -> [KnownSpeaker] { settings.speakerLibrary.all() }

    /// Rename a known speaker in the library (Settings). Does not rewrite past
    /// transcripts — only affects future recognition and the library listing.
    func renameKnownSpeaker(id: UUID, to newName: String) {
        try? settings.speakerLibrary.rename(id: id, to: newName)
        objectWillChange.send()
    }

    /// Remove a known speaker from the library (Settings).
    func deleteKnownSpeaker(id: UUID) {
        try? settings.speakerLibrary.delete(id: id)
        objectWillChange.send()
    }

    /// Enroll (or re-enroll) the local user "Me" from a clip of them reading the
    /// enrollment script: extract the voiceprint and store it in the library.
    /// Returns true on success. Best-effort: returns false if no voice was found.
    func enrollMe(audioFile: URL) async -> Bool {
        isEnrolling = true
        defer { isEnrolling = false }
        do {
            // Warm the model with progress first: the very first enrollment may pull
            // a multi-hundred-MB CoreML model, which would otherwise freeze the UI
            // with no feedback.
            let onProgress: TranscribeProgressHandler = { [weak self] p in
                Task { @MainActor in self?.modelStatusText = p.phase }
            }
            try await diarizer.prepare(progress: onProgress)
            guard let embedding = try await diarizer.enrollmentEmbedding(audioFile: audioFile) else {
                return false
            }
            try settings.speakerLibrary.upsert(name: "Me", embedding: embedding, isMe: true)
            objectWillChange.send()
            return true
        } catch {
            lastError = userFacingMessage(for: .transcribing, error: error)
            return false
        }
    }

    /// Delete a saved meeting (audio + metadata + transcript). Refuses to delete a
    /// meeting that's currently recording, transcribing, or queued for it.
    func deleteRecording(_ recording: MeetingRecording) {
        let id = recording.meeting.id
        guard self.recording?.id != id, !processing.contains(id) else { return }
        try? store.delete(meetingID: id)
        recordings = store.allRecordings()
    }

    /// Clear the current error banner (user tapped it, or it auto-dismissed).
    func dismissError() { lastError = nil }

    // MARK: - Notifications

    private func postNotification(title: String, body: String) {
        guard permissions.notifications == .granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
