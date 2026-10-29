import Foundation
import SwiftUI

enum Format {
    /// Bytes per second as `1.2 MB/s`, with the same English units in every language (the
    /// system's would read "字节/s" in Chinese).
    static func rate(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, bytes)), unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = unit == 0 || value >= 100 ? String(Int(value.rounded())) : String(format: "%.1f", value)
        return "\(number) \(units[unit])/s"
    }

    /// A byte count as `3.2 MB`, with the same English units as speeds.
    static func bytes(_ bytes: Int64) -> String {
        String(rate(bytes).dropLast(2))
    }

    /// How long ago `start` was, as `42s`, `3m`, `1h 5m`.
    static func duration(since start: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \(seconds % 3600 / 60)m"
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
