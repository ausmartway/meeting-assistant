import CoreGraphics
import Foundation

/// A captured on-screen window, adapted from `SCWindow` so the selection logic is
/// pure and testable without ScreenCaptureKit.
public struct ScreenWindow: Equatable, Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let bundleID: String?
    public let pid: pid_t
    /// The window's title, when the source (`SCWindow`) exposes one. Used to tell
    /// the actual meeting window apart from the app's other windows.
    public let title: String?

    public init(
        windowID: CGWindowID = 0, frame: CGRect, bundleID: String?, pid: pid_t,
        title: String? = nil
    ) {
        self.windowID = windowID
        self.frame = frame
        self.bundleID = bundleID
        self.pid = pid
        self.title = title
    }

    /// Pixel area; used to prefer the largest candidate window.
    public var area: CGFloat { frame.width * frame.height }
}

/// A display, adapted from `SCDisplay`.
public struct ScreenDisplay: Equatable, Sendable {
    public let id: CGDirectDisplayID
    public let frame: CGRect

    public init(id: CGDirectDisplayID, frame: CGRect) {
        self.id = id
        self.frame = frame
    }
}

/// Pure logic that decides which display is showing the meeting. See N13 design.
public enum DisplaySelector {
    /// Pick the meeting window. Among windows owned by a preferred (conferencing-app)
    /// bundle ID, prefer the largest whose title contains the meeting's calendar
    /// subject — that is the actual meeting window; the app's *main* window (or a big
    /// browser window, since browsers are preferred for Teams/Meet/Webex) is often
    /// larger but shows no participant names, so raw size alone picks the wrong
    /// window. Falls back to: largest preferred window → largest window of the
    /// frontmost app → nil. The single shared selection rule for both window capture
    /// and display selection.
    public static func pickWindow(
        windows: [ScreenWindow],
        preferredBundleIDs: Set<String>,
        frontmostPID: pid_t?,
        meetingTitle: String? = nil
    ) -> ScreenWindow? {
        let preferred = windows.filter { w in
            guard let b = w.bundleID else { return false }
            return preferredBundleIDs.contains(b)
        }
        if let subject = foldedTitle(meetingTitle) {
            let titled = preferred.filter { w in
                guard let t = foldedTitle(w.title) else { return false }
                return t.contains(subject)
            }
            if let best = largest(titled) { return best }
        }
        if let best = largest(preferred) { return best }
        if let pid = frontmostPID, let best = largest(windows.filter { $0.pid == pid }) {
            return best
        }
        return nil
    }

    /// Case/diacritic-folded, trimmed title for matching; nil when blank.
    private static func foldedTitle(_ s: String?) -> String? {
        guard
            let folded = s?.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil),
            !folded.isEmpty
        else { return nil }
        return folded
    }

    /// Pick the display showing the meeting: the meeting window's display, or nil
    /// (caller keeps the default display).
    public static func pickDisplay(
        windows: [ScreenWindow],
        displays: [ScreenDisplay],
        preferredBundleIDs: Set<String>,
        frontmostPID: pid_t?
    ) -> CGDirectDisplayID? {
        guard
            let window = pickWindow(
                windows: windows, preferredBundleIDs: preferredBundleIDs,
                frontmostPID: frontmostPID)
        else { return nil }
        return displayID(forWindow: window.frame, in: displays)
    }

    /// The display whose frame overlaps `windowFrame` the most; nil if none overlap.
    public static func displayID(
        forWindow windowFrame: CGRect,
        in displays: [ScreenDisplay]
    ) -> CGDirectDisplayID? {
        var bestID: CGDirectDisplayID?
        var bestArea: CGFloat = 0
        for d in displays {
            let overlap = d.frame.intersection(windowFrame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                bestID = d.id
            }
        }
        return bestID
    }

    private static func largest(_ windows: [ScreenWindow]) -> ScreenWindow? {
        windows.max(by: { $0.area < $1.area })
    }
}
