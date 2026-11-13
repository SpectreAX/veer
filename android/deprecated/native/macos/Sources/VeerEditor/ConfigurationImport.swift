import Foundation

public enum ConfigurationImport {
    public static let maximumBytes = 2 * 1024 * 1024
    public static func verifyExportDestination(_ destination: URL, importedFile: URL?) throws {
        guard let importedFile else { return }
        let source = importedFile.standardizedFileURL.resolvingSymlinksInPath()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let message = "不能覆盖导入的原配置文件。请选择其他文件名或目录导出副本。"
        guard source != target else { throw EditorFailure(message) }
        let keys: Set<URLResourceKey> = [.fileResourceIdentifierKey, .volumeIdentifierKey]
        if let before = try? source.resourceValues(forKeys: keys), let after = try? target.resourceValues(forKeys: keys),
           let sourceID = before.fileResourceIdentifier as? NSObject, let targetID = after.fileResourceIdentifier as? NSObject,
           let sourceVolume = before.volumeIdentifier as? NSObject, let targetVolume = after.volumeIdentifier as? NSObject,
           sourceVolume.isEqual(targetVolume), sourceID.isEqual(targetID) { throw EditorFailure(message) }
    }
    public static func decode(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maximumBytes, let text = String(data: data, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EditorFailure("配置必须是非空 UTF-8 YAML 文件，且不超过 2 MB。")
        }
        return text
    }
    public static func subscriptionURL(_ input: String) throws -> URL {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil else {
            throw EditorFailure("请输入 HTTPS 配置或订阅地址，不支持用户名、密码或片段。")
        }
        return url
    }
    public static func download(_ input: String) async throws -> String {
        let url = try subscriptionURL(input)
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        let session = URLSession(configuration: config, delegate: ImportRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("text/yaml, application/yaml, text/plain", forHTTPHeaderField: "Accept")
        request.setValue("clash.meta/VeerEditor", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw EditorFailure("下载失败。请检查地址、订阅有效期；重定向地址需直接使用最终 HTTPS 链接。") }
            guard response.expectedContentLength <= maximumBytes else { throw EditorFailure("下载配置超过 2 MB。") }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw EditorFailure("下载配置超过 2 MB。") }
                data.append(byte)
            }
            return try decode(data)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as EditorFailure { throw error }
        catch { throw EditorFailure("无法下载配置，请检查网络或订阅地址后重试。") }
    }
}

private final class ImportRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
