import Foundation

/// Chromium stores bookmark dates as microseconds since 1601-01-01 00:00:00 UTC
/// (the Windows FILETIME epoch), serialized as decimal strings.
enum ChromeTimestamp {
    /// Seconds between 1601-01-01 and 1970-01-01.
    nonisolated private static let epochOffsetSeconds: Double = 11_644_473_600

    nonisolated static func date(from value: Int64) -> Date {
        Date(timeIntervalSince1970: Double(value) / 1_000_000 - epochOffsetSeconds)
    }

    nonisolated static func date(from string: String) -> Date? {
        Int64(string).map(date(from:))
    }

    nonisolated static func value(from date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + epochOffsetSeconds) * 1_000_000)
    }

    nonisolated static func string(from date: Date) -> String {
        String(value(from: date))
    }
}
