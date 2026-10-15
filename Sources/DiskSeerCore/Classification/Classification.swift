import Foundation

/// How risky it is to remove an item.
public enum CleanupSafety: Int, Codable, Sendable, Comparable, CaseIterable {
    /// Regenerable data (caches, build output). Removing it has no lasting effect.
    case safe = 0
    /// Probably disposable, but the user should take a look first.
    case review = 1
    /// Contains user data or state that cannot be recreated automatically.
    case caution = 2
    /// Never remove from DiskSeer (system data, libraries managed by apps...).
    case protected = 3

    public static func < (lhs: CleanupSafety, rhs: CleanupSafety) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .safe: "Safe to remove"
        case .review: "Review first"
        case .caution: "Caution"
        case .protected: "Protected"
        }
    }

    public var symbol: String {
        switch self {
        case .safe: "checkmark.shield"
        case .review: "eye"
        case .caution: "exclamationmark.triangle"
        case .protected: "lock"
        }
    }
}

/// What to do about an item and why.
public struct CleanupAdvice: Sendable, Hashable {
    public var safety: CleanupSafety
    public var summary: String
    /// Optional shell command that performs a proper cleanup (e.g. `brew cleanup`).
    public var command: String?
    /// The data is recreated automatically when needed.
    public var regenerable: Bool

    public init(_ safety: CleanupSafety, _ summary: String, command: String? = nil, regenerable: Bool? = nil) {
        self.safety = safety
        self.summary = summary
        self.command = command
        self.regenerable = regenerable ?? (safety == .safe)
    }
}

/// How strongly a matched signature propagates to the matched folder's content.
public enum Inheritance: Sendable {
    /// Everything below is the same thing (e.g. every file below DerivedData is a build artifact).
    case strong
    /// Default for descendants without better evidence (e.g. ~/Pictures).
    case weak
    /// Applies to the matched item only.
    case none
}

/// Result of classifying a file or folder.
public struct Classification: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable {
        case knowledgeBase = "Knowledge base"
        case context = "Context rule"
        case fileType = "File type"
        case inherited = "Location"
        case contents = "Contents analysis"
        case predictive = "Predictive model"
        case unknown = "Unknown"
    }

    public var category: FileCategory
    public var label: String
    public var explanation: String
    public var confidence: Double
    public var source: Source
    public var advice: CleanupAdvice?
    /// Human readable reasoning steps that led to this classification.
    public var evidence: [String]
    public var signatureID: String?

    public init(category: FileCategory, label: String, explanation: String, confidence: Double,
                source: Source, advice: CleanupAdvice? = nil, evidence: [String] = [], signatureID: String? = nil) {
        self.category = category
        self.label = label
        self.explanation = explanation
        self.confidence = confidence
        self.source = source
        self.advice = advice
        self.evidence = evidence
        self.signatureID = signatureID
    }
}

/// A known kind of file or folder.
public struct Signature: Sendable, Identifiable {
    public enum Matcher: Sendable {
        /// Exact path; "~" is the home folder. Example: "~/Library/Developer/Xcode/DerivedData".
        case path(String)
        /// Path pattern where "*" matches exactly one component. Example: "~/Library/Caches/*".
        case glob(String)
        /// A directory with this exact name anywhere.
        case directoryName(String)
        /// A directory with this name that has a sibling matching one of the markers ("Cargo.toml", "*.csproj").
        case directoryWithSibling(String, [String])
        /// A directory with this name that contains one of the markers.
        case directoryContaining(String, [String])
        /// A file with this exact name.
        case fileName(String)
        /// A file with one of these extensions (lowercase, no dot).
        case fileExtension([String])
        /// A package/directory with one of these extensions (e.g. "app", "photoslibrary").
        case packageExtension([String])
    }

    public let id: String
    public let matcher: Matcher
    public let category: FileCategory
    public let label: String
    public let explanation: String
    public let advice: CleanupAdvice?
    public let inheritance: Inheritance
    /// Report this item in Smart Clean (requires `advice`).
    public let reportable: Bool

    public init(_ id: String, _ matcher: Matcher, _ category: FileCategory, _ label: String, _ explanation: String,
                advice: CleanupAdvice? = nil, inheritance: Inheritance = .strong, reportable: Bool = true) {
        self.id = id
        self.matcher = matcher
        self.category = category
        self.label = label
        self.explanation = explanation
        self.advice = advice
        self.inheritance = inheritance
        self.reportable = reportable && advice != nil
    }

    var isContextual: Bool {
        switch matcher {
        case .directoryWithSibling, .directoryContaining: true
        default: false
        }
    }
}
