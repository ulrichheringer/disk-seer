import Foundation

/// Docker engine usage reported by `docker system df`.
public struct DockerUsage: Sendable, Hashable {
    public struct Row: Sendable, Hashable, Identifiable {
        public var id: String { type }
        public let type: String
        public let total: String
        public let active: String
        public let size: String
        public let reclaimable: String
    }

    public let rows: [Row]
    public let context: String?

    /// Parse the output of `docker system df --format '{{json .}}'`.
    public static func parse(jsonLines: String, context: String? = nil) -> DockerUsage? {
        var rows: [Row] = []
        for line in jsonLines.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            func field(_ key: String) -> String {
                if let s = object[key] as? String { return s }
                if let n = object[key] as? NSNumber { return n.stringValue }
                return ""
            }
            rows.append(Row(type: field("Type"), total: field("TotalCount"), active: field("Active"),
                            size: field("Size"), reclaimable: field("Reclaimable")))
        }
        return rows.isEmpty ? nil : DockerUsage(rows: rows, context: context)
    }

    /// Query the local Docker engine (Docker Desktop, OrbStack, Colima…). Read-only.
    public static func query(timeout: TimeInterval = 8) -> DockerUsage? {
        guard CommandRunner.which("docker") != nil else { return nil }
        let output = CommandRunner.run("docker system df --format '{{json .}}'", timeout: timeout)
        guard output.succeeded else { return nil }
        let context = CommandRunner.run("docker context show", timeout: 3).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return parse(jsonLines: output.stdout, context: context.isEmpty ? nil : context)
    }
}

/// Known virtual machine / container disk images on this Mac, independent of the scan.
public struct VirtualDisk: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let product: String
    public let allocated: Int64
    public let logical: Int64
    public let pruneCommand: String?
}

public enum VirtualizationInspector {
    static var knownLocations: [(String, String, String?)] {
        let h = NSHomeDirectory()
        return [
            (h + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", "Docker Desktop", "docker system prune -a --volumes"),
            (h + "/Library/Containers/com.docker.docker/Data/vms/0/Docker.raw", "Docker Desktop", "docker system prune -a --volumes"),
            (h + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2", "Docker Desktop", "docker system prune -a"),
            (h + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack/data/data.img", "OrbStack", "docker system prune -a"),
            (h + "/.colima/_lima/_disks/colima/datadisk", "Colima", "docker system prune -a"),
            (h + "/.local/share/containers/podman/machine/applehv/podman-machine-default-arm64.raw", "Podman", "podman system prune -a"),
            (h + "/Library/Application Support/rancher-desktop/lima/0/diffdisk", "Rancher Desktop", "nerdctl system prune -a"),
        ]
    }

    /// Disk images found at well-known locations plus any VM disk found in the scanned tree.
    public static func discover(in tree: FileNode?) -> [VirtualDisk] {
        var result: [String: VirtualDisk] = [:]
        for (path, product, command) in knownLocations {
            var st = stat()
            if lstat(path, &st) == 0 {
                result[path] = VirtualDisk(path: path, product: product, allocated: Int64(st.st_blocks) * 512,
                                           logical: Int64(st.st_size), pruneCommand: command)
            }
        }
        if let tree {
            let exts: Set<String> = ["vhdx", "vhd", "vmdk", "vdi", "qcow2", "hdd", "raw", "img"]
            tree.walk { node in
                if node.kind == .file && node.size > 500_000_000 && exts.contains(node.fileExtension) && node.category == .virtualMachines {
                    let path = ScanLocation.canonicalPath(node.path)
                    if result[path] == nil {
                        result[path] = VirtualDisk(path: path, product: productName(for: path), allocated: node.size,
                                                   logical: node.logicalSize, pruneCommand: nil)
                    }
                }
                return node.isContainer
            }
        }
        return result.values.sorted { $0.allocated > $1.allocated }
    }

    static func productName(for path: String) -> String {
        let lower = path.lowercased()
        if lower.contains("/.android/avd") { return "Android Emulator" }
        if lower.contains("docker") { return "Docker" }
        if lower.contains("orbstack") { return "OrbStack" }
        if lower.contains("utm") { return "UTM" }
        if lower.contains("parallels") { return "Parallels" }
        if lower.contains("vmware") { return "VMware" }
        if lower.contains("virtualbox") { return "VirtualBox" }
        if lower.hasSuffix(".vhdx") || lower.hasSuffix(".vhd") { return "Hyper-V / WSL disk" }
        return "Virtual disk"
    }
}

/// Time Machine local snapshots (read-only).
public enum TimeMachineInsights {
    public static func localSnapshots() -> [String] {
        let output = CommandRunner.run("tmutil listlocalsnapshots /", timeout: 10)
        guard output.succeeded else { return [] }
        return output.stdout.split(separator: "\n").map(String.init).filter { $0.contains("com.apple") }
    }
}
