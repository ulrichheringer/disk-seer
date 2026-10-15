import Foundation

/// Capacity information about a mounted volume.
public struct VolumeInfo: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let format: String
    public let totalCapacity: Int64
    /// Free space right now.
    public let availableCapacity: Int64
    /// Free space including purgeable data macOS can reclaim on demand.
    public let availableForImportantUsage: Int64
    public let isInternal: Bool
    public let isRoot: Bool

    public var usedCapacity: Int64 { max(totalCapacity - availableCapacity, 0) }
    public var purgeable: Int64 { max(availableForImportantUsage - availableCapacity, 0) }
    public var usedFraction: Double {
        totalCapacity > 0 ? Double(usedCapacity) / Double(totalCapacity) : 0
    }

    public init(path: String, name: String, format: String, totalCapacity: Int64, availableCapacity: Int64,
                availableForImportantUsage: Int64, isInternal: Bool, isRoot: Bool) {
        self.path = path
        self.name = name
        self.format = format
        self.totalCapacity = totalCapacity
        self.availableCapacity = availableCapacity
        self.availableForImportantUsage = availableForImportantUsage
        self.isInternal = isInternal
        self.isRoot = isRoot
    }

    public static func forPath(_ path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeURLKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? available
        return VolumeInfo(
            path: values.volume?.path ?? path,
            name: values.volumeName ?? "Disk",
            format: values.volumeLocalizedFormatDescription ?? "",
            totalCapacity: total,
            availableCapacity: available,
            availableForImportantUsage: max(important, available),
            isInternal: values.volumeIsInternal ?? false,
            isRoot: values.volumeIsRootFileSystem ?? false
        )
    }

    /// All user-visible mounted volumes.
    public static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                         options: [.skipHiddenVolumes]) ?? []
        var seen = Set<String>()
        return urls.compactMap { url in
            guard let info = forPath(url.path), seen.insert(info.path).inserted else { return nil }
            return info
        }
    }
}

/// Well known scan locations.
public enum ScanLocation {
    /// The APFS data volume holds every user writable file (Users, Applications, Library...).
    public static let dataVolume = "/System/Volumes/Data"
    public static var home: String { NSHomeDirectory() }

    /// Best root for an "entire disk" scan on this Mac.
    public static var entireDisk: String {
        FileManager.default.fileExists(atPath: dataVolume) ? dataVolume : "/"
    }

    /// Converts a path below the data volume into its familiar firmlinked form.
    public static func displayPath(_ path: String) -> String {
        if path == dataVolume { return "Macintosh HD" }
        if path.hasPrefix(dataVolume + "/") { return String(path.dropFirst(dataVolume.count)) }
        return path
    }

    /// The canonical path (as most tools refer to it) for a path inside the data volume.
    public static func canonicalPath(_ path: String) -> String {
        if path.hasPrefix(dataVolume + "/") { return String(path.dropFirst(dataVolume.count)) }
        return path
    }
}
