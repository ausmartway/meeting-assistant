import SwiftUI

/// The app's visual language: a calm, native-macOS aesthetic. SF Pro for UI, a
/// single restrained indigo accent (tied to the app icon), system semantic
/// neutrals so light and dark both feel native, and gentle depth. Centralised so
/// every surface stays consistent.
enum Theme {
    /// The one accent — the indigo from the app icon. Used sparingly: selection,
    /// the primary action, the live-recording dot.
    static let accent = Color(red: 0.36, green: 0.30, blue: 0.86)

    /// A serif (New York) reading face for transcript bodies — the one expressive,
    /// document-like touch against the SF Pro UI. Sized via a semantic text style
    /// (not a fixed point size) so it follows the user's system text-size setting;
    /// `.title3` (15 pt regular by default) over `.body` (13 pt) because sustained
    /// document reading wants a larger face than UI chrome — cf. Books / Safari
    /// Reader defaults.
    static let reading = Font.system(.title3, design: .serif)

    /// Spacing scale used with deliberate variation (not uniform padding).
    enum Space {
        static let xs: CGFloat = 6, s: CGFloat = 10, m: CGFloat = 16, l: CGFloat = 24,
            xl: CGFloat = 36
    }

    /// A small palette of muted, dark- and light-mode-safe colors for telling
    /// speakers apart in the transcript. The local user always gets the one accent.
    private static let speakerPalette: [Color] = [
        Color(red: 0.20, green: 0.58, blue: 0.62),  // teal
        Color(red: 0.80, green: 0.52, blue: 0.25),  // amber
        Color(red: 0.78, green: 0.42, blue: 0.55),  // rose
        Color(red: 0.45, green: 0.62, blue: 0.35),  // moss
        Color(red: 0.55, green: 0.50, blue: 0.80),  // periwinkle
        Color(red: 0.35, green: 0.56, blue: 0.80),  // blue
    ]

    /// A stable color for a speaker label: the accent for the local user ("Me" or
    /// their chosen name), otherwise a deterministic pick from the muted palette so
    /// the same speaker keeps one color throughout a transcript.
    static func speakerColor(for speaker: String, localUserName: String) -> Color {
        if speaker == localUserName || speaker == "Me" { return accent }
        var hash: UInt64 = 5381
        for byte in speaker.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
        return speakerPalette[Int(hash % UInt64(speakerPalette.count))]
    }
}

/// A quiet section caption — small, medium-weight, secondary. Replaces shouty
/// all-caps headers with something that recedes until you need it.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}
