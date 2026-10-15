import Foundation

/// High level semantic category of a file or folder.
public enum FileCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case applications
    case system
    case developer
    case buildArtifacts
    case dependencies
    case packageCaches
    case caches
    case logs
    case virtualMachines
    case photos
    case videos
    case audio
    case documents
    case code
    case archives
    case installers
    case cloudStorage
    case communication
    case backups
    case games
    case aiModels
    case trash
    case other

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .applications: "Applications"
        case .system: "System & Library"
        case .developer: "Developer Tools"
        case .buildArtifacts: "Build Artifacts"
        case .dependencies: "Project Dependencies"
        case .packageCaches: "Package Manager Caches"
        case .caches: "Caches"
        case .logs: "Logs & Diagnostics"
        case .virtualMachines: "Docker & Virtual Machines"
        case .photos: "Photos & Images"
        case .videos: "Videos"
        case .audio: "Music & Audio"
        case .documents: "Documents"
        case .code: "Source Code"
        case .archives: "Archives"
        case .installers: "Installers & Disk Images"
        case .cloudStorage: "Cloud Storage"
        case .communication: "Mail & Messages"
        case .backups: "Backups"
        case .games: "Games"
        case .aiModels: "AI Models"
        case .trash: "Trash"
        case .other: "Other"
        }
    }

    /// SF Symbol name.
    public var symbol: String {
        switch self {
        case .applications: "app.badge"
        case .system: "gearshape.2"
        case .developer: "hammer"
        case .buildArtifacts: "shippingbox"
        case .dependencies: "cube.box"
        case .packageCaches: "archivebox"
        case .caches: "bolt.horizontal.circle"
        case .logs: "doc.text.magnifyingglass"
        case .virtualMachines: "server.rack"
        case .photos: "photo.on.rectangle"
        case .videos: "film"
        case .audio: "music.note"
        case .documents: "doc.richtext"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archives: "doc.zipper"
        case .installers: "opticaldiscdrive"
        case .cloudStorage: "icloud"
        case .communication: "envelope"
        case .backups: "clock.arrow.circlepath"
        case .games: "gamecontroller"
        case .aiModels: "brain"
        case .trash: "trash"
        case .other: "questionmark.folder"
        }
    }

    /// Base color as RGB components (0...1), shared by every UI.
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .applications: (0.27, 0.52, 0.96)
        case .system: (0.50, 0.53, 0.60)
        case .developer: (0.55, 0.36, 0.90)
        case .buildArtifacts: (0.93, 0.47, 0.20)
        case .dependencies: (0.96, 0.62, 0.18)
        case .packageCaches: (0.86, 0.66, 0.26)
        case .caches: (0.98, 0.78, 0.22)
        case .logs: (0.70, 0.62, 0.45)
        case .virtualMachines: (0.10, 0.62, 0.78)
        case .photos: (0.95, 0.36, 0.55)
        case .videos: (0.86, 0.22, 0.32)
        case .audio: (0.98, 0.42, 0.42)
        case .documents: (0.24, 0.72, 0.52)
        case .code: (0.42, 0.66, 0.30)
        case .archives: (0.66, 0.48, 0.34)
        case .installers: (0.80, 0.40, 0.62)
        case .cloudStorage: (0.38, 0.75, 0.96)
        case .communication: (0.30, 0.60, 0.70)
        case .backups: (0.55, 0.60, 0.30)
        case .games: (0.62, 0.30, 0.70)
        case .aiModels: (0.20, 0.80, 0.70)
        case .trash: (0.60, 0.35, 0.30)
        case .other: (0.58, 0.62, 0.68)
        }
    }
}
