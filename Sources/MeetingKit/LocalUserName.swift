import Foundation

/// Picks the display name for the local user ("me"). Pure so the system lookup
/// (`NSFullUserName()`) stays out of the testable logic — the caller passes it in.
public enum LocalUserName {
    /// A non-empty trimmed `override` wins; else a non-empty trimmed `accountName`;
    /// else the generic "Me".
    public static func resolve(override: String, accountName: String) -> String {
        let o = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !o.isEmpty { return o }
        let a = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !a.isEmpty { return a }
        return "Me"
    }
}
