import CoreGraphics
import Testing
@testable import VeerUI

@MainActor struct ColumnFitTests {
    private let columns = [ColumnFit.Column("host", ideal: 100), .init("rule", ideal: 50), .init("chain", ideal: 50)]
    private let order = ["rule", "chain"]
    /// 100 + 50 + 50 and three lots of spacing.
    private var all: CGFloat { 200 + 3 * ColumnFit.spacing }

    @Test func everythingStaysWhenItFits() {
        #expect(ColumnFit.hidden(in: all, columns: columns, givingUp: order).isEmpty)
        #expect(ColumnFit.hidden(in: all + 500, columns: columns, givingUp: order).isEmpty)
    }

    @Test func columnsGoInOrderUntilTheRestFit() {
        #expect(ColumnFit.hidden(in: all - 1, columns: columns, givingUp: order) == ["rule"])
        #expect(ColumnFit.hidden(in: all - 50 - ColumnFit.spacing - 1, columns: columns, givingUp: order) == ["rule", "chain"])
    }

    @Test func aColumnNotOfferedAlwaysStays() {
        #expect(ColumnFit.hidden(in: 1, columns: columns, givingUp: order) == ["rule", "chain"])
    }

    @Test func aNameNotInTheTableIsSkipped() {
        #expect(ColumnFit.hidden(in: all - 1, columns: columns, givingUp: ["speed", "rule"]) == ["rule"])
    }
}
