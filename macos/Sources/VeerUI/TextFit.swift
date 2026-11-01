import AppKit

public extension String {
    /// Cut to fit `width` points in `font`, with an ellipsis. Measured, as characters say little:
    /// a name in capitals runs far wider than the same count in lower case.
    nonisolated func shortened(toFit width: CGFloat, font: NSFont) -> String {
        func measure(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        guard measure(self) > width else { return self }
        var kept = ""
        for character in self {
            guard measure(kept + String(character) + "…") <= width else { break }
            kept.append(character)
        }
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }
}
