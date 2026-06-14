import Foundation
import AppKit
import UserNotifications
import MeetingKit

/// What the app is currently doing, surfaced in the menu bar.
enum CaptureStatus: Equatable {
    case idle
    case recording(Meeting)
    case processing(Meeting)

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .recording(let m): return "Recording: \(m.title)"
        case .processing(let m): return "Processing: \(m.title)"
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

    let settings: AppSettings
    let permissions: Permissions
    private let calendar: CalendarWatcher
    private let detector: MeetingDetector
    private let store: MeetingStore

    private var capture: CaptureSession?
    private var pollTimer: Timer?
    private var notifiedMeetingIDs: Set<String> = []

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
        self.transcriber = Backends.makeTranscriber(model: settings.transcriptionModel)
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
        modelPreparing = true
        modelReady = false
        modelStatusText = "Preparing model…"
        transcriber = Backends.makeTranscriber(model: settings.transcriptionModel)
        let handler: TranscribeProgressHandler = { [weak self] p in
            Task { @MainActor in
                self?.modelDownloadFraction = p.fraction
                self?.modelStatusText = p.phase
            }
        }
        do {
            try await transcriber.prepare(progress: handler)
            modelReady = true
            modelStatusText = "Model ready"
        } catch {
            modelStatusText = "Model download failed — retry in Settings"
            lastError = "Model preparation failed: \(error.localizedDescription)"
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
        let session = CaptureSession(meeting: meeting, store: store)
        do {
            try await session.start()
            capture = session
            status = .recording(meeting)
        } catch {
            lastError = "Failed to start capture: \(error.localizedDescription)"
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
            lastError = "Failed to stop capture: \(error.localizedDescription)"
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
        let processor = MeetingProcessor(
            store: store,
            transcriber: transcriber,
            summarizer: settings.makeSummarizer()
        )
        let progress: MeetingProcessor.ProcessProgress = { [weak self] fraction, phase in
            Task { @MainActor in
                self?.progressFraction = fraction
                self?.progressPhase = phase
            }
        }
        do {
            _ = try await processor.process(recording, progress: progress)
            postNotification(title: "Meeting ready", body: "Transcript and summary for “\(meeting.title)” are ready.")
        } catch {
            lastError = "Processing failed: \(error.localizedDescription)"
        }
        progressFraction = nil
        progressPhase = nil
        status = .idle
        recordings = store.allRecordings()
    }

    /// Re-run the full pipeline (transcribe → fuse → summarize) for a saved
    /// recording. Recovers a meeting whose processing failed (e.g. a missing
    /// model) — the audio + speaker timeline are already on disk.
    func reprocess(_ recording: MeetingRecording) async {
        guard case .idle = status else { return }
        lastError = nil
        status = .processing(recording.meeting)
        await process(recording.meeting)
        recordings = store.allRecordings()
    }

    /// Re-run the summary for a saved meeting (e.g. via Claude) on demand.
    func resummarize(_ recording: MeetingRecording) async {
        let processor = MeetingProcessor(
            store: store,
            transcriber: transcriber,
            summarizer: settings.makeSummarizer()
        )
        // Reuse the existing transcript instead of re-transcribing the audio.
        guard let transcriptBody = store.transcript(for: recording.meeting.id) else { return }
        do {
            let summary = try await settings.makeSummarizer()
                .summarize(transcript: transcriptBody, meetingTitle: recording.meeting.title)
            try store.saveSummary(summary.markdown(), for: recording.meeting.id)
            recordings = store.allRecordings()
        } catch {
            lastError = "Re-summarize failed: \(error.localizedDescription)"
        }
        _ = processor // silence unused in case future flows need it
    }

    func transcript(for recording: MeetingRecording) -> String? {
        store.transcript(for: recording.meeting.id)
    }

    func summary(for recording: MeetingRecording) -> String? {
        store.summary(for: recording.meeting.id)
    }

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
