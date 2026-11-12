import Foundation
import VeerCore

/// What the Agent's "sent to the AI" sheet needs beyond the Mac `AgentStore`: the turn it shows,
/// and the original config next to what the AI received (the Mac builds this in its
/// `PayloadComparisonView`; here it is data for the iPhone view to bind to).
extension AgentStore {
    enum PayloadComparisonResult: Sendable {
        /// Rows of original → sent; `exact` is false when regions were corrected after sending,
        /// so labels may differ slightly from what was actually sent.
        case ready(PayloadComparison, exact: Bool)
        /// The draft the request was made from is gone (the routing changed since).
        case missing
    }

    /// The turn whose payload sheet is open (`payloadTurnID`).
    var payloadTurn: Turn? { payloadTurnID.flatMap { id in current?.turns.first { $0.id == id } } }

    /// Opens the payload sheet for a turn, on the "sent" side.
    func showPayload(of turnID: UUID) {
        payloadComparing = false
        payloadTurnID = turnID
    }

    /// Rebuilds the comparison off the main thread from the draft the payload was made from.
    func payloadComparison(for payload: AIRequestPayload) async -> PayloadComparisonResult {
        guard let session = current else { return .missing }
        return await Task.detached(priority: .userInitiated) { () -> PayloadComparisonResult in
            let regions: (ConfigDocument) -> [String: Region] = { session.regions(for: $0.targets) }
            guard let source = session.sourceDraft(for: payload, regions: regions),
                  let rebuilt = PayloadComparison.rebuild(for: payload, source: source, regions: regions) else { return .missing }
            return .ready(rebuilt.comparison, exact: rebuilt.exact)
        }.value
    }

    /// Sections whose rows contain `query` (original or sent), case-insensitively; all when empty.
    static func filter(_ comparison: PayloadComparison, query: String) -> [PayloadComparison.Section] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return comparison.sections }
        return comparison.sections.compactMap { section in
            let rows = section.rows.filter { $0.original.lowercased().contains(needle) || $0.sent.lowercased().contains(needle) }
            return rows.isEmpty ? nil : PayloadComparison.Section(title: section.title, rows: rows, note: section.note)
        }
    }
}
