import Foundation
import Testing
@testable import VeerCore

struct DNSWireTests {
    /// A name as DNS writes it: each label after its length, then a zero.
    private func wire(_ name: String) -> [UInt8] {
        name.split(separator: ".").flatMap { [UInt8($0.utf8.count)] + Array($0.utf8) } + [0]
    }

    private func record(_ name: String, type: UInt16, ttl: UInt32 = 300, _ data: [UInt8]) -> [UInt8] {
        wire(name) + [UInt8(type >> 8), UInt8(type & 0xff), 0, 1, UInt8(ttl >> 24), UInt8(ttl >> 16 & 0xff), UInt8(ttl >> 8 & 0xff), UInt8(ttl & 0xff),
                      UInt8(data.count >> 8), UInt8(data.count & 0xff)] + data
    }

    private func message(flags: UInt16, answers: [[UInt8]] = [], authority: [[UInt8]] = [], additional: [[UInt8]] = []) -> [UInt8] {
        let counts: [UInt8] = [0, 1, 0, UInt8(answers.count), 0, UInt8(authority.count), 0, UInt8(additional.count)]
        let header: [UInt8] = [0x12, 0x34, UInt8(flags >> 8), UInt8(flags & 0xff)] + counts
        return header + wire("example.com") + [0, 1, 0, 1] + (answers + authority + additional).flatMap(\.self)
    }

    @Test func aQueryCarriesTheNameTypeAndAnEDNSRecord() {
        let plain = DNSWire.query("example.com", type: .mx, id: 0x1234, dnssec: false)
        #expect(Array(plain[0..<12]) == [0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 1])
        #expect(Array(plain[12..<25]) == wire("example.com"))
        #expect(Array(plain[25..<29]) == [0, 15, 0, 1])
        // OPT, with the DO bit only when signatures are asked for.
        #expect(Array(plain[29...]) == [0, 0, 41, 0x04, 0xd0, 0, 0, 0, 0, 0, 0])
        #expect(DNSWire.query("example.com", type: .ipv4, id: 1, dnssec: true)[36] == 0x80)
    }

    @Test func everySectionAndTheFlagsAreRead() throws {
        // qr rd ra ad, NOERROR.
        let data = message(flags: 0x81a0,
                           answers: [record("example.com", type: 5, wire("edge.example.net")),
                                     record("edge.example.net", type: 1, ttl: 60, [93, 184, 216, 34])],
                           authority: [record("example.net", type: 2, wire("ns1.example.net"))],
                           additional: [record("ns1.example.net", type: 28, [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1])])
        let response = try DNSWire.parse(data)
        #expect(response.id == 0x1234)
        #expect(response.status == "NOERROR")
        #expect(response.flags == ["qr", "rd", "ra", "ad"])
        #expect(response.resolverValidated && !response.truncated)
        #expect(response.records(in: .answer).map(\.data) == ["edge.example.net", "93.184.216.34"])
        #expect(response.records(in: .answer).map(\.ttl) == [300, 60])
        #expect(response.records(in: .answer).map(\.type) == ["CNAME", "A"])
        #expect(response.records(in: .authority).map(\.data) == ["ns1.example.net"])
        #expect(response.records(in: .additional).map(\.data) == ["2001:db8::1"])
        #expect(response.records(in: .answer)[1].address == IPAddr("93.184.216.34"))
        #expect(response.rawText.hasPrefix("12 34 81 a0"))
    }

    @Test func eachOfferedRecordTypeIsReadAsText() throws {
        let soa = wire("ns1.example.com") + wire("hostmaster.example.com") + [0, 0, 0, 7, 0, 0, 0x0e, 0x10, 0, 0, 0x02, 0x58, 0, 0x09, 0x3a, 0x80, 0, 0, 0, 60]
        let https: [UInt8] = [0, 1, 0] + [0, 1, 0, 6, 2, 0x68, 0x33, 2, 0x68, 0x32] + [0, 4, 0, 4, 1, 2, 3, 4] + [0, 3, 0, 2, 0x01, 0xbb]
        struct Row {
            let type: UInt16
            let data: [UInt8]
            let expected: String
            init(_ type: UInt16, _ data: [UInt8], _ expected: String) {
                self.type = type
                self.data = data
                self.expected = expected
            }
        }
        let rows = [
            Row(15, [0, 10] + wire("mail.example.com"), "10 mail.example.com"),
            Row(16, [5] + Array("hello".utf8) + [3] + Array("abc".utf8), "\"hello\" \"abc\""),
            Row(6, soa, "ns1.example.com hostmaster.example.com 7 3600 600 604800 60"),
            Row(12, wire("host.example.com"), "host.example.com"),
            Row(33, [0, 5, 0, 10, 0x01, 0xbb] + wire("sip.example.com"), "5 10 443 sip.example.com"),
            Row(257, [0, 5] + Array("issue".utf8) + Array("letsencrypt.org".utf8), "0 issue \"letsencrypt.org\""),
            Row(65, https, "1 . alpn=h3,h2 ipv4hint=1.2.3.4 port=443"),
            Row(43, [0x30, 0x39, 13, 2, 0xab, 0xcd], "12345 13 2 abcd"),
            Row(48, [1, 1, 3, 13] + [UInt8](repeating: 7, count: 64), "257 3 13 (512-bit key)"),
            Row(99, [1, 2, 3], "\\# 3 010203"),
        ]
        for row in rows {
            let response = try DNSWire.parse(message(flags: 0x8180, answers: [record("example.com", type: row.type, row.data)]))
            #expect(response.records.first?.data == row.expected, "type \(row.type)")
        }
    }

    @Test func statusesIncludeTheExtendedCodeFromEDNS() throws {
        #expect(try DNSWire.parse(message(flags: 0x8183)).status == "NXDOMAIN")
        #expect(try DNSWire.parse(message(flags: 0x8182)).status == "SERVFAIL")
        #expect(try DNSWire.parse(message(flags: 0x8185)).status == "REFUSED")
        #expect(try DNSWire.parse(message(flags: 0x8380)).truncated)
        // The OPT record is not listed, and its TTL's top byte extends the code: 1 << 4 is BADVERS.
        let opt: [UInt8] = [0, 0, 41, 0x04, 0xd0, 1, 0, 0, 0, 0, 0]
        let extended = try DNSWire.parse(message(flags: 0x8180, additional: [opt]))
        #expect(extended.status == "BADVERS" && extended.records.isEmpty)
        #expect(throws: EditorError.self) { try DNSWire.parse([1, 2, 3]) }
        let cut = Array(message(flags: 0x8180, answers: [record("example.com", type: 1, [1, 2, 3, 4])]).dropLast(2))
        #expect(throws: EditorError.self) { try DNSWire.parse(cut) }
    }

    @Test func namesAreMadeASCIIAndAddressesReversed() throws {
        #expect(try DNSWire.queryName(" WWW.Example.com. ", type: .ipv4) == "www.example.com")
        #expect(try DNSWire.punycode("bücher") == "bcher-kva")
        #expect(try DNSWire.queryName("bücher.example", type: .ipv4) == "xn--bcher-kva.example")
        #expect(try DNSWire.queryName("例え.jp", type: .ipv4) == "xn--r8jz45g.jp")
        #expect(try DNSWire.queryName("8.8.4.4", type: .ptr) == "4.4.8.8.in-addr.arpa")
        #expect(try DNSWire.queryName("2001:db8::1", type: .ptr) == "1.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.8.b.d.0.1.0.0.2.ip6.arpa")
        #expect(throws: EditorError.self) { try DNSWire.queryName("8.8.8.8", type: .ipv4) }
        #expect(throws: EditorError.self) { try DNSWire.queryName("a..b", type: .ipv4) }
        #expect(throws: EditorError.self) { try DNSWire.queryName(String(repeating: "a", count: 64) + ".com", type: .ipv4) }
    }

    @Test func serverAddressesNameTheirTransport() {
        #expect(DNSEndpoint("223.5.5.5") == DNSEndpoint(transport: .udp, host: "223.5.5.5", port: 53))
        #expect(DNSEndpoint("udp://1.1.1.1:5353") == DNSEndpoint(transport: .udp, host: "1.1.1.1", port: 5353))
        #expect(DNSEndpoint("tcp://8.8.8.8") == DNSEndpoint(transport: .tcp, host: "8.8.8.8", port: 53))
        #expect(DNSEndpoint("tls://dns.google") == DNSEndpoint(transport: .tls, host: "dns.google", port: 853))
        #expect(DNSEndpoint("tls://[2606:4700:4700::1111]:853")?.host == "2606:4700:4700::1111")
        #expect(DNSEndpoint("https://dns.google/dns-query")?.transport == .https)
        #expect(DNSEndpoint("https://dns.google/dns-query")?.label == "https://dns.google/dns-query")
        #expect(DNSEndpoint("tls://dns.google")?.label == "dns.google")
        // Not implemented, so not accepted.
        #expect(DNSEndpoint("quic://dns.adguard.com") == nil)
        #expect(DNSEndpoint("dhcp://en0") == nil)
        #expect(DNSEndpoint("") == nil)
    }
}
