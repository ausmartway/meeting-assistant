import Foundation

/// Produces a distinguishing sidebar label for meetings that share a generic
/// default title (e.g. "Microsoft Teams meeting", "ad-hoc meeting"), by appending
/// the most prominent named remote speaker. For DISPLAY only — it never changes the
/// stored meeting title (rename still works). Pure and unit-tested.
public enum MeetingDisplayTitle {

    public static func sidebarTitle(
        title: String,
        providerDisplayName: String?,
        providerShortName: String?,
        speakers: [String],
        localUserName: String
    ) -> String {
        guard
            isGeneric(
                title, providerDisplayName: providerDisplayName,
                providerShortName: providerShortName)
        else { return title }

        let named = speakers.first { s in
            !s.isEmpty && s != localUserName && s != "Me" && !isAnonymous(s)
        }
        guard let named else { return title }
        return "\(title) · \(named)"
    }

    private static func isGeneric(
        _ title: String, providerDisplayName: String?, providerShortName: String?
    ) -> Bool {
        var defaults: Set<String> = ["ad-hoc meeting", "Untitled meeting", "Meeting"]
        if let d = providerDisplayName { defaults.insert("\(d) meeting") }
        if let s = providerShortName { defaults.insert("ad-hoc \(s)") }
        return defaults.contains(title)
    }

    /// An anonymous "Speaker" / "Speaker N" label (not a real name).
    private static func isAnonymous(_ s: String) -> Bool {
        s == "Speaker" || s.hasPrefix("Speaker ")
    }
}
