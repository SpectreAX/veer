import Foundation
import SwiftUI

enum Format {
    /// Bytes per second as `1.2 MB/s`.
    static func rate(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary) + "/s"
    }

    static func delay(_ delay: Int?) -> String {
        switch delay {
        case nil: "—"
        case 0: String(localized: "超时")
        case let value?: "\(value) ms"
        }
    }

    /// Delay meaning in words, paired with color wherever a delay is shown: good under 200 ms,
    /// fair up to 500 ms.
    static func delayKind(_ delay: Int?) -> StatusKind {
        switch delay {
        case nil: .neutral
        case 0: .failure
        case let value? where value < 200: .success
        case let value? where value <= 500: .warning
        default: .failure
        }
    }

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}

extension ProxyStore.Phase {
    var kind: StatusKind {
        switch self {
        case .stopped: .neutral
        case .starting: .info
        case .running: .success
        case .failed: .failure
        }
    }

    var title: String {
        switch self {
        case .stopped: String(localized: "已停止")
        case .starting: String(localized: "正在启动")
        case .running: String(localized: "运行中")
        case .failed: String(localized: "启动失败")
        }
    }
}
