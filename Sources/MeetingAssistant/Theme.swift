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
    /// document-like touch against the SF Pro UI.
    static let reading = Font.system(.body, design: .serif)

    /// Spacing scale used with deliberate variation (not uniform padding).
    enum Space { static let xs: CGFloat = 6, s: CGFloat = 10, m: CGFloat = 16, l: CGFloat = 24, xl: CGFloat = 36 }
}

/// A quiet section caption — small, medium-weight, secondary. Replaces shouty
/// all-caps headers with something that recedes until you need it.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

/// A soft, rounded speaker chip. Subtly filled normally; accent-filled for "Me".
struct SpeakerChip: View {
    let text: String
    var isMe: Bool = false
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(isMe ? .white : .primary)
            .background(
                Capsule().fill(isMe ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary))
            )
    }
}
