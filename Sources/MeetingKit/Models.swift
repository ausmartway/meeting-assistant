import Foundation

/// A video-conferencing platform we know how to capture and (best-effort) read
/// the active speaker from.
public enum MeetingProvider: String, Codable, Sendable, CaseIterable {
    case zoom
    case googleMeet
    case microsoftTeams
    case webex

    /// Human-readable name for UI.
    public var displayName: String {
        switch self {
        case .zoom: return "Zoom"
        case .googleMeet: return "Google Meet"
        case .microsoftTeams: return "Microsoft Teams"
        case .webex: return "Webex"
        }
    }

    /// Short label for compact contexts (e.g. an ad-hoc meeting title).
    public var shortName: String {
        switch self {
        case .zoom: return "Zoom"
        case .googleMeet: return "Meet"
        case .microsoftTeams: return "Teams"
        case .webex: return "Webex"
        }
    }

    /// Browser bundle IDs that can host a web meeting (Meet, and Teams/Webex web).
    public static let browserBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",  // Arc
    ]

    /// Bundle IDs of the app(s) that can host a meeting for this provider — the
    /// single source of truth shared by meeting detection and display selection
    /// (so they can't drift). Native clients plus browsers where the provider runs
    /// on the web.
    public var meetingAppBundleIDs: Set<String> {
        switch self {
        case .zoom:
            return ["us.zoom.xos"]
        case .microsoftTeams:
            return Set(["com.microsoft.teams", "com.microsoft.teams2"]).union(Self.browserBundleIDs)
        case .googleMeet:
            return Self.browserBundleIDs
        case .webex:
            return Set(["com.cisco.webexmeetings", "Cisco-Systems.Spark"]).union(
                Self.browserBundleIDs)
        }
    }
}

/// A calendar meeting we may capture. Built from an EKEvent by `CalendarWatcher`,
/// but kept free of EventKit types so it is easy to construct in tests.
public struct Meeting: Identifiable, Codable, Sendable, Equatable {
    public let id: String  // EKEvent.eventIdentifier (or a synthesized id)
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let provider: MeetingProvider?
    public let joinURL: URL?

    public init(
        id: String,
        title: String,
        startDate: Date,
        endDate: Date,
        provider: MeetingProvider?,
        joinURL: URL?
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.provider = provider
        self.joinURL = joinURL
    }

    /// A per-occurrence meeting id. EventKit hands back the *same*
    /// `eventIdentifier` for every occurrence of a recurring event, and the
    /// recording bundle directory is derived from `Meeting.id` — so using the raw
    /// identifier makes next week's occurrence overwrite this week's recording.
    /// Suffixing the occurrence's start time keeps each occurrence's recording in
    /// its own bundle while staying deterministic across calendar refreshes.
    public static func occurrenceID(eventIdentifier: String, startDate: Date) -> String {
        // Whole seconds: EventKit start dates are second-precision, and truncating
        // guards against float jitter minting a "new" occurrence.
        "\(eventIdentifier)#\(Int(startDate.timeIntervalSince1970))"
    }

    /// Build a synthetic meeting for an **ad-hoc** capture — one the user starts
    /// manually with no calendar entry. `id` is supplied by the caller (a UUID)
    /// so this stays pure and testable; the title reflects the detected provider
    /// when known.
    public static func adHoc(
        id: String,
        provider: MeetingProvider?,
        start: Date,
        duration: TimeInterval = 2 * 60 * 60
    ) -> Meeting {
        Meeting(
            id: id,
            title: provider.map { "ad-hoc \($0.shortName)" } ?? "ad-hoc meeting",
            startDate: start,
            endDate: start.addingTimeInterval(duration),
            provider: provider,
            joinURL: nil
        )
    }
}

/// Which audio source a transcript segment came from. The mic-vs-system split is
/// always exact and gives us a reliable "you vs. others" first-level attribution.
public enum AudioChannel: String, Codable, Sendable {
    case microphone  // the local user ("Me")
    case system  // remote participants (mixed)
}

/// One timestamped chunk of recognized speech, before speaker fusion.
public struct TranscriptSegment: Codable, Sendable, Equatable {
    public let start: TimeInterval  // seconds from meeting start
    public let end: TimeInterval
    public let text: String
    public let channel: AudioChannel

    public init(start: TimeInterval, end: TimeInterval, text: String, channel: AudioChannel) {
        self.start = start
        self.end = end
        self.text = text
        self.channel = channel
    }
}

/// A single sample of who appeared to be the active speaker on screen at a moment
/// in time, produced by `SpeakerSampler` roughly every few seconds during capture.
public struct SpeakerSample: Codable, Sendable, Equatable {
    public let timestamp: TimeInterval  // seconds from meeting start
    public let speakerName: String?  // OCR'd name, or nil if none detected

    public init(timestamp: TimeInterval, speakerName: String?) {
        self.timestamp = timestamp
        self.speakerName = speakerName
    }
}

/// The ordered series of on-screen active-speaker samples for a meeting.
public struct SpeakerTimeline: Codable, Sendable, Equatable {
    public let samples: [SpeakerSample]

    public init(samples: [SpeakerSample]) {
        // Keep samples sorted by time so lookups can assume ordering.
        self.samples = samples.sorted { $0.timestamp < $1.timestamp }
    }
}

/// A transcript segment after speaker fusion: it now carries a resolved label.
public struct LabeledSegment: Codable, Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let speaker: String  // "Me", an OCR'd name, or "Speaker N"
    /// Which audio file this segment came from — lets the UI play the exact
    /// clip back (`segments.json`). Nil for segments saved before this existed.
    public let channel: AudioChannel?

    public init(
        start: TimeInterval, end: TimeInterval, text: String, speaker: String,
        channel: AudioChannel? = nil
    ) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
        self.channel = channel
    }
}

/// Metadata persisted alongside a captured meeting's audio + timeline on disk.
public struct MeetingRecording: Codable, Sendable, Equatable {
    public let meeting: Meeting
    public let recordedAt: Date
    public let micAudioFile: String  // filename within the bundle
    public let systemAudioFile: String
    public let timeline: SpeakerTimeline

    public init(
        meeting: Meeting,
        recordedAt: Date,
        micAudioFile: String,
        systemAudioFile: String,
        timeline: SpeakerTimeline
    ) {
        self.meeting = meeting
        self.recordedAt = recordedAt
        self.micAudioFile = micAudioFile
        self.systemAudioFile = systemAudioFile
        self.timeline = timeline
    }
}

/// The diarization result persisted per meeting so speakers can be renamed later
/// without re-diarizing: each cluster's voiceprint and its resolved display label.
public struct MeetingSpeakerMap: Codable, Sendable, Equatable {
    public var labelByCluster: [String: String]
    public var embeddingByCluster: [String: [Float]]
    /// Seconds of speech behind each cluster's voiceprint. Empty for maps saved
    /// before durations existed (treated as trustworthy — see
    /// `learnableVoiceprint`).
    public var durationByCluster: [String: TimeInterval]

    public init(
        labelByCluster: [String: String],
        embeddingByCluster: [String: [Float]],
        durationByCluster: [String: TimeInterval] = [:]
    ) {
        self.labelByCluster = labelByCluster
        self.embeddingByCluster = embeddingByCluster
        self.durationByCluster = durationByCluster
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        labelByCluster = try c.decode([String: String].self, forKey: .labelByCluster)
        embeddingByCluster = try c.decode([String: [Float]].self, forKey: .embeddingByCluster)
        // Absent in maps saved before durations were recorded.
        durationByCluster =
            try c.decodeIfPresent([String: TimeInterval].self, forKey: .durationByCluster) ?? [:]
    }

    /// Relabel the cluster currently shown as `oldLabel` to `newLabel`, returning
    /// that cluster's voiceprint so the caller can teach it to the speaker library.
    /// Returns nil (and changes nothing) if no cluster carries `oldLabel`. Pure, so
    /// the rename → relearn flow is unit-testable without `AppState`.
    public mutating func relabel(from oldLabel: String, to newLabel: String) -> [Float]? {
        guard let cluster = labelByCluster.first(where: { $0.value == oldLabel })?.key else {
            return nil
        }
        labelByCluster[cluster] = newLabel
        return embeddingByCluster[cluster]
    }

    /// The voiceprint to teach the library when the user renames `label` — or nil
    /// when the cluster has too little speech to be a trustworthy voiceprint
    /// (renaming a junk cluster must not contaminate the library; the transcript
    /// rename itself is not gated). Legacy maps without recorded durations keep
    /// the old always-learn behavior.
    public func learnableVoiceprint(
        forLabel label: String,
        minDuration: TimeInterval = SpeakerRecognizer.minSpeechDuration
    ) -> [Float]? {
        guard let cluster = labelByCluster.first(where: { $0.value == label })?.key else {
            return nil
        }
        if let duration = durationByCluster[cluster], duration < minDuration { return nil }
        return embeddingByCluster[cluster]
    }

    /// Seconds of speech behind the cluster currently labeled `label`, or nil
    /// for unknown labels / maps saved before durations were recorded.
    public func duration(forLabel label: String) -> TimeInterval? {
        guard let cluster = labelByCluster.first(where: { $0.value == label })?.key else {
            return nil
        }
        return durationByCluster[cluster]
    }
}
