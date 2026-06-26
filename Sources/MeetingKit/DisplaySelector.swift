import CoreGraphics
import Foundation

/// A captured on-screen window, adapted from `SCWindow` so the selection logic is
/// pure and testable without ScreenCaptureKit.
public struct ScreenWindow: Equatable, Sendable {
    public let windowID: CGWindowID
    public let frame: CGRect
    public let bundleID: String?
    public let pid: pid_t

    public init(windowID: CGWindowID = 0, frame: CGRect, bundleID: String?, pid: pid_t) {
        self.windowID = windowID
        self.frame = frame
        self.bundleID = bundleID
        self.pid = pid
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
    /// Pick the meeting window: the largest window owned by a preferred
    /// (conferencing-app) bundle ID; else the largest window owned by the frontmost
    /// app; else nil. The single shared selection rule for both window capture and
    /// display selection.
    public static func pickWindow(
        windows: [ScreenWindow],
        preferredBundleIDs: Set<String>,
        frontmostPID: pid_t?
    ) -> ScreenWindow? {
        let preferred = windows.filter { w in
            guard let b = w.bundleID else { return false }
            return preferredBundleIDs.contains(b)
        }
        if let best = largest(preferred) { return best }
        if let pid = frontmostPID, let best = largest(windows.filter { $0.pid == pid }) {
            return best
        }
        return nil
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
