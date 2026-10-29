import Foundation

/// Where a node says it exits, read offline from its name: a flag emoji first, then country and
/// city names in Chinese or English, then country codes. Never a measured location.
public enum NodeLocator {
    /// A country or region Veer can place on the map.
    public struct Place: Sendable, Hashable, Identifiable {
        /// ISO 3166-1 alpha-2, upper case.
        public let code: String
        /// A representative point (where nodes usually are), for the map.
        public let latitude: Double
        public let longitude: Double
        public var id: String { code }

        /// The region's name in the interface language, from the system's own list.
        public var name: String {
            let language = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
            return Locale(identifier: language).localizedString(forRegionCode: code) ?? code
        }

        public var flag: String {
            String(String.UnicodeScalarView(code.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 - 0x41 + $0.value) }))
        }
    }

    /// The ISO code of the place `name` points at, or nil when it says nothing recognisable.
    /// Memoized: big subscriptions ask for hundreds of names on every draw.
    public static func locate(_ name: String) -> String? {
        if let cached = cache.get(name) { return cached.value }
        let code = flag(in: name) ?? earliest(in: name, entries: chinese) ?? earliest(in: name, entries: english) ?? earliest(in: name, entries: codes)
        cache.set(name, Cached(value: code))
        return code
    }

    public static func place(_ code: String) -> Place? { placesByCode[code.uppercased()] }

    /// Whether the name already carries a flag Veer knows, so none needs adding.
    public static func hasFlag(_ name: String) -> Bool { flag(in: name) != nil }

    public static var places: [Place] { table.map(\.place) }

    // MARK: Matching

    /// The first pair of regional indicators, if it names a place Veer knows.
    static func flag(in name: String) -> String? {
        let scalars = Array(name.unicodeScalars)
        for index in scalars.indices.dropLast() {
            let first = scalars[index].value, second = scalars[index + 1].value
            guard (0x1F1E6...0x1F1FF).contains(first), (0x1F1E6...0x1F1FF).contains(second) else { continue }
            let code = String(UnicodeScalar(first - 0x1F1E6 + 0x41)!) + String(UnicodeScalar(second - 0x1F1E6 + 0x41)!)
            if placesByCode[code] != nil { return code }
        }
        return nil
    }

    /// The match that starts earliest in the name; a relay like "香港-日本" exits where it says
    /// first, which is how subscriptions name them. Ties go to the longer match.
    private static func earliest(in name: String, entries: [(NSRegularExpression, String)]) -> String? {
        let range = NSRange(name.startIndex..., in: name)
        var best: (location: Int, length: Int, code: String)?
        for (regex, code) in entries {
            guard let match = regex.firstMatch(in: name, range: range) else { continue }
            let found = match.range
            if best == nil || found.location < best!.location || (found.location == best!.location && found.length > best!.length) {
                best = (found.location, found.length, code)
            }
        }
        return best?.code
    }

    private static func alternatives(_ words: [String]) -> String {
        words.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    }

    private static let chinese: [(NSRegularExpression, String)] = table.compactMap { entry in
        guard !entry.chinese.isEmpty else { return nil }
        return (try! NSRegularExpression(pattern: alternatives(entry.chinese)), entry.place.code)
    }

    /// Whole words only: "us" must not match "russia" or "status".
    private static let english: [(NSRegularExpression, String)] = table.compactMap { entry in
        guard !entry.english.isEmpty else { return nil }
        return (try! NSRegularExpression(pattern: #"(?<![A-Za-z])(?:"# + alternatives(entry.english) + #")(?![A-Za-z])"#, options: .caseInsensitive), entry.place.code)
    }

    /// Upper case and standing alone ("[A]HK 01", "JP-02"); lower-case "us" or "in" are words.
    private static let codes: [(NSRegularExpression, String)] = table.compactMap { entry in
        guard !entry.codes.isEmpty else { return nil }
        return (try! NSRegularExpression(pattern: #"(?<![A-Za-z])(?:"# + alternatives(entry.codes) + #")(?![A-Za-z])"#), entry.place.code)
    }

    private struct Cached { let value: String? }

    private final class Cache: @unchecked Sendable {
        private var values: [String: Cached] = [:]
        private let lock = NSLock()
        func get(_ name: String) -> Cached? { lock.withLock { values[name] } }
        func set(_ name: String, _ value: Cached) {
            lock.withLock {
                if values.count > 20_000 { values.removeAll() }
                values[name] = value
            }
        }
    }

    private static let cache = Cache()

    // MARK: Table

    private struct Entry {
        let place: Place
        let chinese: [String]
        let english: [String]
        /// Codes matched when written in capitals. Only places whose codes rarely collide with
        /// other words in node names ("AI", "IS" or "NO" would).
        let codes: [String]

        init(_ code: String, _ latitude: Double, _ longitude: Double, zh: [String], en: [String], codes: [String] = []) {
            place = Place(code: code, latitude: latitude, longitude: longitude)
            chinese = zh
            english = en
            self.codes = codes
        }
    }

    private static let placesByCode = Dictionary(uniqueKeysWithValues: table.map { ($0.place.code, $0.place) })

    // Mainland Chinese cities are left out on purpose: in relay names ("沪日", "广港 IPLC") they
    // are the entry, not the exit. So is a bare "中国", which starts "中国香港" and "中国台湾".
    private static let table: [Entry] = [
        Entry("HK", 22.32, 114.17, zh: ["香港"], en: ["hong kong", "hongkong"], codes: ["HK", "HKG"]),
        Entry("TW", 25.03, 121.56, zh: ["台湾", "台灣", "臺灣", "台北", "臺北", "新北", "台中", "彰化", "高雄"], en: ["taiwan", "taipei"], codes: ["TW", "TWN"]),
        Entry("MO", 22.20, 113.55, zh: ["澳门", "澳門"], en: ["macau", "macao"], codes: ["MO", "MAC"]),
        Entry("JP", 35.68, 139.69, zh: ["日本", "东京", "東京", "大阪", "埼玉", "名古屋", "福冈", "福岡"], en: ["japan", "tokyo", "osaka", "saitama"], codes: ["JP", "JPN"]),
        Entry("KR", 37.57, 126.98, zh: ["韩国", "韓國", "首尔", "首爾", "春川"], en: ["korea", "seoul", "chuncheon"], codes: ["KR", "KOR"]),
        Entry("SG", 1.35, 103.82, zh: ["新加坡", "狮城", "獅城"], en: ["singapore"], codes: ["SG", "SGP"]),
        Entry("US", 39.5, -98.35, zh: ["美国", "美國", "洛杉矶", "洛杉磯", "圣何塞", "聖何塞", "硅谷", "矽谷", "纽约", "紐約", "西雅图", "西雅圖", "芝加哥", "达拉斯", "達拉斯", "凤凰城", "鳳凰城", "旧金山", "舊金山", "波特兰", "弗吉尼亚", "维吉尼亚", "迈阿密", "亚特兰大", "阿什本", "拉斯维加斯"],
              en: ["united states", "america", "los angeles", "san jose", "silicon valley", "new york", "seattle", "chicago", "dallas", "phoenix", "san francisco", "portland", "virginia", "miami", "atlanta", "ashburn", "las vegas"], codes: ["US", "USA"]),
        Entry("CA", 49.0, -96.0, zh: ["加拿大", "多伦多", "多倫多", "温哥华", "溫哥華", "蒙特利尔"], en: ["canada", "toronto", "vancouver", "montreal"], codes: ["CA", "CAN"]),
        Entry("MX", 19.43, -99.13, zh: ["墨西哥"], en: ["mexico"], codes: ["MX", "MEX"]),
        Entry("BR", -23.55, -46.63, zh: ["巴西", "圣保罗", "聖保羅"], en: ["brazil", "sao paulo", "são paulo"], codes: ["BR", "BRA"]),
        Entry("AR", -34.60, -58.38, zh: ["阿根廷"], en: ["argentina", "buenos aires"], codes: ["AR", "ARG"]),
        Entry("CL", -33.45, -70.67, zh: ["智利"], en: ["chile", "santiago"], codes: ["CL", "CHL"]),
        Entry("CO", 4.71, -74.07, zh: ["哥伦比亚", "哥倫比亞"], en: ["colombia", "bogota"]),
        Entry("PE", -12.05, -77.04, zh: ["秘鲁", "秘魯"], en: ["peru", "lima"]),
        Entry("GB", 51.51, -0.13, zh: ["英国", "英國", "伦敦", "倫敦", "曼彻斯特"], en: ["united kingdom", "britain", "england", "london", "manchester"], codes: ["UK", "GBR"]),
        Entry("IE", 53.35, -6.26, zh: ["爱尔兰", "愛爾蘭", "都柏林"], en: ["ireland", "dublin"], codes: ["IE", "IRL"]),
        Entry("FR", 48.86, 2.35, zh: ["法国", "法國", "巴黎", "马赛", "馬賽"], en: ["france", "paris", "marseille"], codes: ["FR", "FRA"]),
        Entry("DE", 50.11, 8.68, zh: ["德国", "德國", "法兰克福", "法蘭克福", "柏林", "杜塞尔多夫", "慕尼黑"], en: ["germany", "frankfurt", "berlin", "dusseldorf", "munich"], codes: ["DE", "DEU", "GER"]),
        Entry("NL", 52.37, 4.90, zh: ["荷兰", "荷蘭", "阿姆斯特丹"], en: ["netherlands", "holland", "amsterdam"], codes: ["NL", "NLD"]),
        Entry("BE", 50.85, 4.35, zh: ["比利时", "比利時", "布鲁塞尔"], en: ["belgium", "brussels"]),
        Entry("LU", 49.61, 6.13, zh: ["卢森堡", "盧森堡"], en: ["luxembourg"]),
        Entry("CH", 47.38, 8.54, zh: ["瑞士", "苏黎世", "蘇黎世"], en: ["switzerland", "zurich"], codes: ["CH", "CHE"]),
        Entry("AT", 48.21, 16.37, zh: ["奥地利", "奧地利", "维也纳", "維也納"], en: ["austria", "vienna"], codes: ["AT", "AUT"]),
        Entry("IT", 45.46, 9.19, zh: ["意大利", "義大利", "米兰", "米蘭", "罗马"], en: ["italy", "milan", "rome"], codes: ["IT", "ITA"]),
        Entry("ES", 40.42, -3.70, zh: ["西班牙", "马德里", "馬德里"], en: ["spain", "madrid"], codes: ["ES", "ESP"]),
        Entry("PT", 38.72, -9.14, zh: ["葡萄牙", "里斯本"], en: ["portugal", "lisbon"], codes: ["PT", "PRT"]),
        Entry("SE", 59.33, 18.07, zh: ["瑞典", "斯德哥尔摩"], en: ["sweden", "stockholm"], codes: ["SE", "SWE"]),
        Entry("NO", 59.91, 10.75, zh: ["挪威", "奥斯陆"], en: ["norway", "oslo"]),
        Entry("DK", 55.68, 12.57, zh: ["丹麦", "丹麥", "哥本哈根"], en: ["denmark", "copenhagen"]),
        Entry("FI", 60.17, 24.94, zh: ["芬兰", "芬蘭", "赫尔辛基"], en: ["finland", "helsinki"], codes: ["FI", "FIN"]),
        Entry("IS", 64.15, -21.94, zh: ["冰岛", "冰島"], en: ["iceland", "reykjavik"]),
        Entry("PL", 52.23, 21.01, zh: ["波兰", "波蘭", "华沙", "華沙"], en: ["poland", "warsaw"], codes: ["PL", "POL"]),
        Entry("CZ", 50.08, 14.44, zh: ["捷克", "布拉格"], en: ["czech", "czechia", "prague"]),
        Entry("HU", 47.50, 19.04, zh: ["匈牙利", "布达佩斯"], en: ["hungary", "budapest"]),
        Entry("RO", 44.43, 26.10, zh: ["罗马尼亚", "羅馬尼亞"], en: ["romania", "bucharest"]),
        Entry("BG", 42.70, 23.32, zh: ["保加利亚", "保加利亞"], en: ["bulgaria", "sofia"]),
        Entry("GR", 37.98, 23.73, zh: ["希腊", "希臘", "雅典"], en: ["greece", "athens"]),
        Entry("RS", 44.79, 20.45, zh: ["塞尔维亚", "塞爾維亞"], en: ["serbia", "belgrade"]),
        Entry("HR", 45.81, 15.98, zh: ["克罗地亚", "克羅地亞"], en: ["croatia", "zagreb"]),
        Entry("EE", 59.44, 24.75, zh: ["爱沙尼亚", "愛沙尼亞"], en: ["estonia", "tallinn"]),
        Entry("LV", 56.95, 24.11, zh: ["拉脱维亚", "拉脫維亞"], en: ["latvia", "riga"]),
        Entry("LT", 54.69, 25.28, zh: ["立陶宛"], en: ["lithuania", "vilnius"]),
        Entry("MD", 47.01, 28.86, zh: ["摩尔多瓦", "摩爾多瓦"], en: ["moldova"]),
        Entry("UA", 50.45, 30.52, zh: ["乌克兰", "烏克蘭", "基辅"], en: ["ukraine", "kyiv", "kiev"], codes: ["UA", "UKR"]),
        Entry("RU", 55.76, 37.62, zh: ["俄罗斯", "俄羅斯", "莫斯科", "圣彼得堡", "伯力", "新西伯利亚"], en: ["russia", "moscow", "khabarovsk", "novosibirsk"], codes: ["RU", "RUS"]),
        Entry("TR", 41.01, 28.98, zh: ["土耳其", "伊斯坦布尔", "伊斯坦堡"], en: ["turkey", "türkiye", "turkiye", "istanbul"], codes: ["TR", "TUR"]),
        Entry("GE", 41.72, 44.79, zh: ["格鲁吉亚", "喬治亞"], en: ["georgia", "tbilisi"]),
        Entry("AM", 40.18, 44.51, zh: ["亚美尼亚", "亞美尼亞"], en: ["armenia", "yerevan"]),
        Entry("AZ", 40.41, 49.87, zh: ["阿塞拜疆", "亞塞拜然"], en: ["azerbaijan", "baku"]),
        Entry("IL", 32.09, 34.78, zh: ["以色列"], en: ["israel", "tel aviv"], codes: ["IL", "ISR"]),
        Entry("AE", 25.20, 55.27, zh: ["阿联酋", "阿聯酋", "迪拜", "杜拜"], en: ["united arab emirates", "emirates", "uae", "dubai"], codes: ["AE", "UAE", "ARE"]),
        Entry("SA", 24.71, 46.68, zh: ["沙特", "沙地阿拉伯"], en: ["saudi"]),
        Entry("QA", 25.29, 51.53, zh: ["卡塔尔", "卡達"], en: ["qatar", "doha"]),
        Entry("BH", 26.23, 50.59, zh: ["巴林"], en: ["bahrain"]),
        Entry("KW", 29.38, 47.99, zh: ["科威特"], en: ["kuwait"]),
        Entry("OM", 23.59, 58.41, zh: ["阿曼"], en: ["oman"]),
        Entry("IR", 35.69, 51.39, zh: ["伊朗"], en: ["iran", "tehran"]),
        Entry("IQ", 33.32, 44.37, zh: ["伊拉克"], en: ["iraq", "baghdad"]),
        Entry("EG", 30.04, 31.24, zh: ["埃及", "开罗"], en: ["egypt", "cairo"]),
        Entry("NG", 6.52, 3.38, zh: ["尼日利亚", "奈及利亞"], en: ["nigeria", "lagos"]),
        Entry("KE", -1.29, 36.82, zh: ["肯尼亚", "肯亞"], en: ["kenya", "nairobi"]),
        Entry("ZA", -26.20, 28.05, zh: ["南非", "约翰内斯堡"], en: ["south africa", "johannesburg"], codes: ["ZA", "ZAF"]),
        Entry("IN", 19.08, 72.88, zh: ["印度", "孟买", "孟買", "新德里", "班加罗尔"], en: ["india", "mumbai", "delhi", "bangalore"], codes: ["IN", "IND"]),
        Entry("PK", 24.86, 67.01, zh: ["巴基斯坦"], en: ["pakistan", "karachi"]),
        Entry("BD", 23.81, 90.41, zh: ["孟加拉"], en: ["bangladesh", "dhaka"]),
        Entry("NP", 27.72, 85.32, zh: ["尼泊尔", "尼泊爾"], en: ["nepal"]),
        Entry("LK", 6.93, 79.85, zh: ["斯里兰卡", "斯里蘭卡"], en: ["sri lanka"]),
        Entry("TH", 13.76, 100.50, zh: ["泰国", "泰國", "曼谷"], en: ["thailand", "bangkok"], codes: ["TH", "THA"]),
        Entry("VN", 10.82, 106.63, zh: ["越南", "胡志明", "河内", "河內"], en: ["vietnam", "viet nam", "hanoi", "ho chi minh"], codes: ["VN", "VNM"]),
        Entry("KH", 11.56, 104.93, zh: ["柬埔寨", "金边", "金邊"], en: ["cambodia", "phnom penh"]),
        Entry("LA", 17.97, 102.63, zh: ["老挝", "寮國"], en: ["laos"]),
        Entry("MM", 16.87, 96.20, zh: ["缅甸", "緬甸"], en: ["myanmar"]),
        Entry("MY", 3.14, 101.69, zh: ["马来西亚", "馬來西亞", "吉隆坡", "大马"], en: ["malaysia", "kuala lumpur"], codes: ["MY", "MYS"]),
        Entry("ID", -6.21, 106.85, zh: ["印尼", "印度尼西亚", "印度尼西亞", "雅加达", "雅加達"], en: ["indonesia", "jakarta"], codes: ["ID", "IDN"]),
        Entry("PH", 14.60, 120.98, zh: ["菲律宾", "菲律賓", "马尼拉", "馬尼拉"], en: ["philippines", "manila"], codes: ["PH", "PHL"]),
        Entry("BN", 4.90, 114.94, zh: ["文莱", "汶萊"], en: ["brunei"]),
        Entry("MN", 47.89, 106.91, zh: ["蒙古"], en: ["mongolia", "ulaanbaatar"]),
        Entry("KZ", 43.24, 76.89, zh: ["哈萨克斯坦", "哈薩克"], en: ["kazakhstan", "almaty"]),
        Entry("UZ", 41.30, 69.24, zh: ["乌兹别克斯坦", "烏茲別克"], en: ["uzbekistan", "tashkent"]),
        Entry("KP", 39.02, 125.75, zh: ["朝鲜", "北韩"], en: ["north korea"]),
        Entry("CN", 35.86, 104.20, zh: ["中国大陆", "中國大陸", "回国", "回國"], en: ["mainland china"], codes: ["CN", "CHN"]),
        Entry("AU", -33.87, 151.21, zh: ["澳大利亚", "澳大利亞", "澳洲", "悉尼", "雪梨", "墨尔本", "墨爾本"], en: ["australia", "sydney", "melbourne"], codes: ["AU", "AUS"]),
        Entry("NZ", -36.85, 174.76, zh: ["新西兰", "紐西蘭", "奥克兰"], en: ["new zealand", "auckland"], codes: ["NZ", "NZL"]),
    ]
}
