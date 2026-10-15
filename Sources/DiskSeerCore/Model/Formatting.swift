import Foundation

public enum ByteFormat {
    /// Human readable size using decimal units (like Finder): 1 KB = 1000 bytes.
    public static func string(_ bytes: Int64) -> String {
        if bytes < 0 { return "-" + string(-bytes) }
        if bytes < 1000 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = -1
        while value >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = value >= 100 ? 0 : (value >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f %@", value, units[unit])
    }

    public static func percent(_ part: Int64, of whole: Int64) -> String {
        guard whole > 0 else { return "0%" }
        let p = Double(part) / Double(whole) * 100
        if p > 0 && p < 0.1 { return "<0.1%" }
        return String(format: p >= 10 ? "%.0f%%" : "%.1f%%", p)
    }
}

public enum AgeFormat {
    /// "3 days ago", "2 years ago" ... for an epoch timestamp.
    public static func relative(_ timestamp: TimeInterval, now: Date = Date()) -> String {
        guard timestamp > 0 else { return "unknown" }
        let seconds = now.timeIntervalSince1970 - timestamp
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if minutes < 60 { return plural(Int(minutes), "minute") }
        if hours < 24 { return plural(Int(hours), "hour") }
        if days < 31 { return plural(Int(days), "day") }
        if days < 365 { return plural(Int(days / 30.4), "month") }
        return plural(Int(days / 365.25), "year")
    }

    /// Compact form for tables: "5m", "3h", "12d", "4mo", "2y".
    public static func short(_ timestamp: TimeInterval, now: Date = Date()) -> String {
        guard timestamp > 0 else { return "–" }
        let seconds = max(now.timeIntervalSince1970 - timestamp, 0)
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(Int(minutes)) min ago" }
        if hours < 24 { return "\(Int(hours)) h ago" }
        if days < 31 { return "\(Int(days)) d ago" }
        if days < 365 { return "\(Int(days / 30.4)) mo ago" }
        return "\(Int(days / 365.25)) y ago"
    }

    public static func days(since timestamp: TimeInterval, now: Date = Date()) -> Double {
        guard timestamp > 0 else { return .infinity }
        return (now.timeIntervalSince1970 - timestamp) / 86_400
    }

    private static func plural(_ n: Int, _ unit: String) -> String {
        let value = max(n, 1)
        return "\(value) \(unit)\(value == 1 ? "" : "s") ago"
    }
}

public extension String {
    /// Replace the home directory prefix with "~" for display.
    var abbreviatingHome: String {
        let home = NSHomeDirectory()
        if self == home { return "~" }
        if hasPrefix(home + "/") { return "~" + dropFirst(home.count) }
        return self
    }

}
