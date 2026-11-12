#if os(macOS)
import AppKit
#else
import UIKit
#endif
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Turns a file or a pasted image into something a request can carry. AppKit (UIKit on iOS) is here
/// only because `NSAttributedString` is what reads RTF and Word documents; nothing here draws.
public enum AttachmentReader {
    public static let maxFileBytes = 25 * 1024 * 1024
    /// What Claude, GPT and Gemini all take without downscaling it again themselves.
    static let maxImageSide = 1568

    /// What the open panel offers. Anything text-like also works when dragged in.
    public static var offeredTypes: [UTType] {
        // By extension as well: .conf and .list have no system type, so the panel would grey them out.
        [.image, .text, .json, .yaml, .xml, .pdf, .rtf, .rtfd] + documentTypes
            + textExtensions.compactMap { UTType(filenameExtension: $0, conformingTo: .data) }
    }

    #if os(macOS)
    private static var documentTypes: [UTType] { ["doc", "docx", "odt"].compactMap { UTType(filenameExtension: $0) } }
    #else
    /// UIKit's `NSAttributedString` reads RTF but no Word or OpenDocument files, so they are not offered.
    private static var documentTypes: [UTType] { [] }
    #endif
    private static let textExtensions: Set<String> = ["yaml", "yml", "conf", "cfg", "ini", "toml", "list", "log", "md", "markdown",
                                                      "csv", "tsv", "txt", "json", "xml", "html", "htm"]

    public static func read(_ url: URL) throws -> ChatAttachment {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { throw EditorError(String(localized: "不能附加文件夹：\(name)")) }
        guard (values?.fileSize ?? 0) <= maxFileBytes else { throw EditorError(String(localized: "“\(name)”超过 25 MB。")) }
        let type = UTType(filenameExtension: url.pathExtension)

        if type?.conforms(to: .image) == true {
            return try image(from: try Data(contentsOf: url), name: name)
        }
        if type?.conforms(to: .pdf) == true {
            guard let document = PDFDocument(url: url), !document.isLocked else { throw EditorError(String(localized: "无法读取“\(name)”，它可能已加密。")) }
            guard let text = document.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw EditorError(String(localized: "“\(name)”里没有可读的文字，可能是扫描件。可以截图后作为图片发送。"))
            }
            return .file(named: name, text: text)
        }
        if let type, type.conforms(to: .rtf) || type.conforms(to: .rtfd) || documentTypes.contains(type) {
            guard let document = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else {
                throw EditorError(String(localized: "无法读取“\(name)”。"))
            }
            return .file(named: name, text: document.string)
        }
        // By extension as well: .conf and .list have no type of their own.
        guard type?.conforms(to: .text) == true || textExtensions.contains(url.pathExtension.lowercased()) else {
            throw EditorError(String(localized: "不支持“\(name)”。可以发送图片、文本、PDF、RTF 和 Word 文档。"))
        }
        return .file(named: name, text: try text(from: try Data(contentsOf: url), name: name))
    }

    static func text(from data: Data, name: String) throws -> String {
        guard !data.contains(0) else { throw EditorError(String(localized: "“\(name)”不是文本文件。")) }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Logs and configs from Chinese Windows tools are often GB18030.
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        guard let text = String(data: data, encoding: String.Encoding(rawValue: encoding)) else {
            throw EditorError(String(localized: "“\(name)”不是文本文件。"))
        }
        return text
    }

    /// Downscaled and re-encoded, which also leaves its location and other metadata behind.
    public static func image(from data: Data, name: String) throws -> ChatAttachment {
        guard data.count <= maxFileBytes else { throw EditorError(String(localized: "“\(name)”超过 25 MB。")) }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxImageSide]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw EditorError(String(localized: "无法读取图片“\(name)”。"))
        }
        // JPEG has no transparency, and a screenshot's transparent edge would come out black.
        guard let context = CGContext(data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw EditorError(String(localized: "无法读取图片“\(name)”。"))
        }
        let bounds = CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.draw(thumbnail, in: bounds)
        let output = NSMutableData()
        guard let flat = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw EditorError(String(localized: "无法读取图片“\(name)”。"))
        }
        CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw EditorError(String(localized: "无法读取图片“\(name)”。")) }
        return ChatAttachment(info: AttachmentInfo(name: name, kind: .image), image: AIImage(data: output as Data, mediaType: "image/jpeg"))
    }
}
