import Foundation
import Combine
import AppKit
import UserNotifications
import MeetingKit

/// What the app is currently doing, surfaced in the menu bar.
enum CaptureStatus: Equatable {
    case idle
    case recording(Meeting)
    case processing(Meeting)

    /// Friendly, plain-English status — "Idle" reads as "off" for an app that is
    /// actively watching the calendar, so the idle state says what it's doing.
    var label: String {
        switch self {
        case .idle: return "Watching for meetings"
        case .recording(let m): return "Recording: \(m.title)"
        case .processing(let m): return "Making transcript: \(m.title)"
        }
    }
}

/// The app coordinator: owns the calendar/detector/capture/processor wiring and
/// the observable state the UI renders. Runs the "calendar AND app detected"
/// auto-start loop, manages a single capture session, and kicks off
/// post-meeting processing.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var status: CaptureStatus = .idle
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

    let settings: AppSettings
    let permissions: Permissions
    private let calendar: CalendarWatcher
    private let detector: MeetingDetector
    private let store: MeetingStore

    private var capture: CaptureSession?
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
        switch status {
        case .idle: return "waveform"
        case .recording: return "record.circle.fill"
        case .processing: return "gearshape.2"
        }
    }

    /// Shared, prepared transcriber reused across all processing so the model is
    /// downloaded/loaded exactly once (at launch) rather than per meeting.
    private var transcriber: Transcribing

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
        // Re-publish permission changes so onboarding/menu views observing AppState
        // update live as the user grants each capability.
        permissions.objectWillChange
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
        guard case .idle = status else { return }
        for meeting in upcoming where detector.shouldAutoStart(meeting) {
            notifyAndStart(meeting)
            break
        }
    }

    func refreshUpcoming() {
        guard permissions.calendar == .granted else { return }
        upcoming = calendar.upcomingMeetings()
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
        guard case .idle = status else { return }
        let provider = detector.firstRunningProvider()
        let meeting = Meeting.adHoc(id: "adhoc-\(UUID().uuidString)", provider: provider, start: Date())
        await startCapture(for: meeting)
    }

    /// Start capturing a meeting (also the manual Start action).
    func startCapture(for meeting: Meeting) async {
        guard case .idle = status else { return }
        lastError = nil
        let session = CaptureSession(meeting: meeting, store: store)
        do {
            try await session.start()
            capture = session
            status = .recording(meeting)
        } catch {
            lastError = userFacingMessage(for: .startRecording, error: error)
        }
    }

    /// Stop the active capture and run post-processing.
    func stopCapture() async {
        guard case .recording(let meeting) = status, let session = capture else { return }
        do {
            try await session.stop()
            capture = nil
            status = .processing(meeting)
            await process(meeting)
        } catch {
            lastError = userFacingMessage(for: .stopRecording, error: error)
            status = .idle
        }
        recordings = store.allRecordings()
    }

    // MARK: - Post-processing

    private func process(_ meeting: Meeting) async {
        guard let recording = store.allRecordings().first(where: { $0.meeting.id == meeting.id }) else {
            status = .idle
            return
        }
        let processor = MeetingProcessor(store: store, transcriber: transcriber)
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
        progressFraction = nil
        progressPhase = nil
        status = .idle
        recordings = store.allRecordings()
    }

    /// Re-run the transcription pipeline for a saved recording. Recovers a meeting
    /// whose processing failed — the audio + speaker timeline are already on disk.
    func reprocess(_ recording: MeetingRecording) async {
        guard case .idle = status else { return }
        lastError = nil
        status = .processing(recording.meeting)
        await process(recording.meeting)
        recordings = store.allRecordings()
    }

    func transcript(for recording: MeetingRecording) -> String? {
        store.transcript(for: recording.meeting.id)
    }

    /// On-disk transcript file, for "Reveal in Finder".
    func transcriptURL(for recording: MeetingRecording) -> URL {
        store.transcriptURL(for: recording.meeting.id)
    }

    /// The meeting currently being recorded or processed, if any.
    private var activeMeetingID: String? {
        switch status {
        case .recording(let m), .processing(let m): return m.id
        case .idle: return nil
        }
    }

    /// Delete a saved meeting (audio + metadata + transcript). Refuses to delete
    /// the meeting that's currently recording or processing.
    func deleteRecording(_ recording: MeetingRecording) {
        guard activeMeetingID != recording.meeting.id else { return }
        try? store.delete(meetingID: recording.meeting.id)
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
