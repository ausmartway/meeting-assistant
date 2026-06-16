import Foundation

/// Pure voice-embedding comparison. Smaller distance = more similar. Lives in
/// MeetingKit (no FluidAudio dependency) so recognition logic is unit-testable.
public enum VoiceMatch {
    /// Cosine distance in [0, 2]; `.infinity` for empty/zero-magnitude/length-
    /// mismatched inputs (treated as "cannot match").
    public static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return .infinity }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        guard na > 0, nb > 0 else { return .infinity }
        let sim = dot / (na.squareRoot() * nb.squareRoot())
        return 1 - max(-1, min(1, sim))
    }
}
