import AppKit
import Testing
@testable import VeerUI

struct TextFitTests {
    private let font = NSFont.systemFont(ofSize: 10)

    private func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }

    @Test func aNameThatFitsIsLeftAlone() {
        #expect("我的机场".shortened(toFit: 90, font: font) == "我的机场")
        #expect("".shortened(toFit: 90, font: font).isEmpty)
    }

    @Test(arguments: ["一二三四五六七八九十甲乙丙丁", "MOMENTUM NETWORK M", "HONG KONG PREMIUM", "WWWWWWWWWWWWWWWWWWWWWW"])
    func aLongNameEndsWithinTheWidth(name: String) {
        let short = name.shortened(toFit: 90, font: font)
        #expect(short.hasSuffix("…"))
        #expect(short.count > 1)
        #expect(width(short) <= 90)
    }

    @Test func lowerCaseKeepsMoreCharactersThanCapitals() {
        let lower = String(repeating: "i", count: 40).shortened(toFit: 90, font: font)
        let upper = String(repeating: "W", count: 40).shortened(toFit: 90, font: font)
        #expect(lower.count > upper.count)
    }

    @Test func noSpaceBeforeTheEllipsis() {
        let name = "一二三四五六七 八九十甲乙丙丁戊己庚"
        let short = name.shortened(toFit: width("一二三四五六七 …"), font: font)
        #expect(short == "一二三四五六七…")
    }
}
