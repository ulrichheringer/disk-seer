import Foundation

/// Assigns a `FileCategory` to every node of a scanned tree and explains individual items.
///
/// Classification is layered, from most to least certain:
/// 1. Knowledge base: exact locations, path patterns and context rules
///    (a `target` folder next to `Cargo.toml` is Rust build output).
/// 2. Location: items inherit the meaning of strongly classified ancestors.
/// 3. File type: extension based rules.
/// 4. Contents: folders are labelled by what makes up most of their bytes.
/// 5. Predictive model: a Naive Bayes model, self-trained on this disk,
///    guesses the purpose of anything still unknown from its name and location.
public final class TreeClassifier: @unchecked Sendable {
    public let engine: RuleEngine
    public let model: PredictiveModel
    /// Minimum probability for accepting a prediction.
    public var predictionThreshold = 0.6

    private var samplesPerCategory: [FileCategory: Int] = [:]
    private let maxSamplesPerCategory = 1500

    public init(engine: RuleEngine = .shared, model: PredictiveModel = PredictiveModel()) {
        self.engine = engine
        self.model = model
    }

    private struct Context {
        var strong: Signature?
        var weak: FileCategory?
    }

    // MARK: - Whole tree

    /// Classify every node below `root` (inclusive).
    public func classify(root: FileNode) {
        let rootKey = engine.keyPath(forAbsolutePath: root.path)
        let rootContext = inheritedContext(forAncestorsOf: root)
        _ = visit(root, key: rootKey, context: rootContext)
        // Second pass: predictive model for whatever is still unknown.
        _ = predictUnknown(root, key: rootKey)
    }

    /// Context from ancestors that are not part of the scanned tree (when scanning a sub-folder).
    private func inheritedContext(forAncestorsOf root: FileNode) -> Context {
        var context = Context()
        var prefixes: [String] = []
        var current = (ScanLocation.canonicalPath(root.path) as NSString).deletingLastPathComponent
        while current != "/" && !current.isEmpty {
            prefixes.append(current)
            current = (current as NSString).deletingLastPathComponent
        }
        for absolute in prefixes.reversed() {
            let key = engine.keyPath(forAbsolutePath: absolute)
            let probe = FileNode(name: (absolute as NSString).lastPathComponent, kind: .directory)
            guard let sig = engine.match(node: probe, key: key, includeFileTypes: false) else { continue }
            switch sig.inheritance {
            case .strong: context.strong = sig
            case .weak: context.strong = nil; context.weak = sig.category
            case .none: break
            }
        }
        return context
    }

    @discardableResult
    private func visit(_ node: FileNode, key: String, context: Context) -> FileCategory {
        let match = engine.match(node: node, key: key, includeFileTypes: context.strong == nil)
        var childContext = context
        var category: FileCategory?

        if let match {
            category = match.category
            switch match.inheritance {
            case .strong: childContext.strong = match
            case .weak: childContext.strong = nil; childContext.weak = match.category
            case .none: break
            }
            if node.isContainer || node.size > 1_000_000 { recordSample(node: node, key: key, category: match.category) }
        } else if let strong = context.strong {
            category = strong.category
        }

        if node.isContainer && !node.children.isEmpty {
            var bytesByCategory: [FileCategory: Int64] = [:]
            for child in node.children {
                let childKey = engine.childKeyPath(parent: key, name: child.name)
                let childCategory = visit(child, key: childKey, context: childContext)
                bytesByCategory[childCategory, default: 0] += max(child.size, 1)
            }
            if category == nil {
                category = TreeClassifier.dominantCategory(bytesByCategory, total: max(node.size, 1)) ?? context.weak
            }
        }

        let resolved = category ?? context.weak ?? .other
        node.setCategory(resolved)
        return resolved
    }

    /// Category that makes up most of a folder, if it is clearly dominant.
    static func dominantCategory(_ bytes: [FileCategory: Int64], total: Int64) -> FileCategory? {
        let relevant = bytes.filter { $0.key != .other }
        guard let best = relevant.max(by: { $0.value < $1.value }) else { return nil }
        let sum = max(bytes.values.reduce(0, +), total)
        return Double(best.value) / Double(sum) >= 0.6 ? best.key : nil
    }

    private func recordSample(node: FileNode, key: String, category: FileCategory) {
        let count = samplesPerCategory[category, default: 0]
        guard count < maxSamplesPerCategory else { return }
        samplesPerCategory[category] = count + 1
        model.train(tokens: PathTokenizer.tokens(keyPath: key, isDirectory: node.isContainer, size: node.size), category: category)
    }

    @discardableResult
    private func predictUnknown(_ node: FileNode, key: String) -> FileCategory {
        if node.category != .other && !node.isContainer { return node.category }
        var bytesByCategory: [FileCategory: Int64] = [:]
        var changed = false
        if node.isContainer {
            for child in node.children where child.isContainer || child.category == .other {
                let before = child.category
                let after = predictUnknown(child, key: engine.childKeyPath(parent: key, name: child.name))
                if before != after { changed = true }
            }
            if node.category == .other {
                for child in node.children { bytesByCategory[child.category, default: 0] += max(child.size, 1) }
            }
        }
        guard node.category == .other else { return node.category }
        if changed, let dominant = TreeClassifier.dominantCategory(bytesByCategory, total: node.size) {
            node.setCategory(dominant)
            return dominant
        }
        // Only predict for items big enough to matter (keeps huge scans fast).
        guard node.size >= 256 * 1024 else { return .other }
        let tokens = PathTokenizer.tokens(keyPath: key, isDirectory: node.isContainer, size: node.size)
        if let prediction = model.predict(tokens: tokens, useEmbeddings: node.size >= 100_000_000),
           prediction.probability >= predictionThreshold {
            node.setCategory(prediction.category)
            return prediction.category
        }
        return .other
    }

    // MARK: - Single item explanation

    /// Full reasoning about a single node, used by the inspector.
    public func explain(_ node: FileNode) -> Classification {
        let key = engine.keyPath(forAbsolutePath: node.path)
        var evidence: [String] = []

        // Direct knowledge base hit.
        if let sig = engine.match(node: node, key: key) {
            evidence.append(evidenceText(for: sig, node: node))
            if let ancestor = strongAncestor(of: node), ancestor.signature.id != sig.id, sig.inheritance == .none {
                evidence.append("Lives inside \u{201C}\(ancestor.signature.label)\u{201D} (\(ancestor.node.name)).")
                return Classification(category: ancestor.signature.category, label: "\(sig.label) in \(ancestor.signature.label)",
                                      explanation: ancestor.signature.explanation, confidence: 0.9, source: .inherited,
                                      advice: ancestor.signature.advice, evidence: evidence, signatureID: ancestor.signature.id)
            }
            let source: Classification.Source
            switch sig.matcher {
            case .directoryWithSibling, .directoryContaining: source = .context
            case .fileExtension: source = .fileType
            default: source = .knowledgeBase
            }
            var confidence: Double = source == .fileType ? 0.8 : (source == .context ? 0.95 : 0.98)
            if case .glob = sig.matcher, sig.inheritance == .weak { confidence = 0.6 } // generic pattern, e.g. ~/.*
            return Classification(category: sig.category, label: sig.label, explanation: sig.explanation,
                                  confidence: confidence, source: source, advice: sig.advice, evidence: evidence, signatureID: sig.id)
        }

        // Inherited from a strongly classified ancestor.
        if let ancestor = strongAncestor(of: node) {
            evidence.append("Inside \u{201C}\(ancestor.signature.label)\u{201D} at \(ScanLocation.canonicalPath(ancestor.node.path).abbreviatingHome).")
            evidence.append(ancestor.signature.explanation)
            return Classification(category: ancestor.signature.category, label: "Part of \(ancestor.signature.label)",
                                  explanation: ancestor.signature.explanation, confidence: 0.9, source: .inherited,
                                  advice: ancestor.signature.advice, evidence: evidence,
                                  signatureID: ancestor.signature.id)
        }

        // Contents analysis for folders.
        if node.isContainer && !node.children.isEmpty {
            var bytes: [FileCategory: Int64] = [:]
            for child in node.children { bytes[child.category, default: 0] += child.size }
            let total = max(node.size, 1)
            let ranked = bytes.filter { $0.key != .other && $0.value > 0 }.sorted { $0.value > $1.value }
            if let top = ranked.first {
                let share = Double(top.value) / Double(total)
                let breakdown = ranked.prefix(3).map { "\($0.key.displayName) \(ByteFormat.percent($0.value, of: total))" }
                    .joined(separator: ", ")
                evidence.append("Contents: \(breakdown).")
                if share >= 0.6 {
                    let projectHint = projectKind(of: node)
                    if let projectHint { evidence.append(projectHint) }
                    return Classification(category: top.key, label: projectHint == nil ? "Mostly \(top.key.displayName.lowercased())" : "Software project",
                                          explanation: "Most of this folder (\(ByteFormat.percent(top.value, of: total))) is \(top.key.displayName.lowercased()).",
                                          confidence: min(0.5 + share / 2, 0.92), source: .contents, evidence: evidence)
                }
            }
        }

        // Predictive model.
        let tokens = PathTokenizer.tokens(keyPath: key, isDirectory: node.isContainer, size: node.size)
        if let prediction = model.predict(tokens: tokens, useEmbeddings: true) {
            var reasons = "Name/location words: \(prediction.topTokens.joined(separator: ", "))"
            if !prediction.substitutions.isEmpty {
                let subs = prediction.substitutions
                    .map { "\u{201C}\($0.key.replacingOccurrences(of: "n:", with: ""))\u{201D}≈\u{201C}\($0.value.replacingOccurrences(of: "n:", with: ""))\u{201D}" }
                    .sorted().prefix(3).joined(separator: ", ")
                reasons += " (semantic matches: \(subs))"
            }
            evidence.append(reasons + ".")
            evidence.append("Model trained on \(model.trainingDocumentCount) labelled paths, \(model.vocabularySize) known words.")
            if prediction.probability >= 0.45 {
                return Classification(category: prediction.category, label: "Likely \(prediction.category.displayName.lowercased())",
                                      explanation: "Predicted from the item's name and location.",
                                      confidence: prediction.probability, source: .predictive,
                                      advice: predictiveAdvice(for: prediction.category), evidence: evidence)
            }
        }

        if let weak = weakAncestorCategory(of: node) {
            evidence.append("Located in a \(weak.displayName.lowercased()) folder.")
            return Classification(category: weak, label: weak.displayName, explanation: "Classified by its location.",
                                  confidence: 0.5, source: .inherited, evidence: evidence)
        }

        let fallback = node.category
        return Classification(category: fallback, label: fallback == .other ? "Unrecognised item" : fallback.displayName,
                              explanation: "No rule matched; nothing in its name or contents reveals its purpose.",
                              confidence: fallback == .other ? 0.2 : 0.5, source: .unknown, evidence: evidence)
    }

    private func evidenceText(for sig: Signature, node: FileNode) -> String {
        switch sig.matcher {
        case let .path(p): "Known location \(p.isEmpty ? "Macintosh HD" : p)."
        case let .glob(p): "Matches known pattern \(p)."
        case let .directoryName(n): "Folder named \u{201C}\(n)\u{201D}."
        case let .directoryWithSibling(n, markers): "Folder \u{201C}\(n)\u{201D} next to \(markers.filter { m in node.parent?.children.contains { RuleEngine.marker(m, matches: $0.name) } ?? false }.first ?? markers[0])."
        case let .directoryContaining(n, markers): "Folder \u{201C}\(n)\u{201D} containing \(markers[0])."
        case let .fileName(n): "File named \u{201C}\(n)\u{201D}."
        case .fileExtension: "File type .\(node.fileExtension)."
        case .packageExtension: "Bundle type .\(node.fileExtension)."
        }
    }

    private func strongAncestor(of node: FileNode) -> (node: FileNode, signature: Signature)? {
        var cursor = node.parent
        var best: (FileNode, Signature)?
        while let current = cursor {
            let key = engine.keyPath(forAbsolutePath: current.path)
            if let sig = engine.match(node: current, key: key, includeFileTypes: false) {
                if sig.inheritance == .strong { best = (current, sig); break }
                if sig.inheritance == .weak { break }
            }
            cursor = current.parent
        }
        if best == nil {
            let ctx = inheritedContext(forAncestorsOf: node.root)
            if let strong = ctx.strong, node.root !== node {
                return (node.root, strong)
            }
        }
        return best
    }

    private func weakAncestorCategory(of node: FileNode) -> FileCategory? {
        var cursor = node.parent
        while let current = cursor {
            let key = engine.keyPath(forAbsolutePath: current.path)
            if let sig = engine.match(node: current, key: key, includeFileTypes: false), sig.inheritance == .weak {
                return sig.category
            }
            cursor = current.parent
        }
        return nil
    }

    private func predictiveAdvice(for category: FileCategory) -> CleanupAdvice? {
        switch category {
        case .caches: CleanupAdvice(.review, "Looks like a cache. Caches are usually safe to remove, but this one was identified by prediction only.", regenerable: true)
        case .logs: CleanupAdvice(.review, "Looks like logs or diagnostics, usually safe to remove.", regenerable: true)
        case .buildArtifacts: CleanupAdvice(.review, "Looks like build output that can be regenerated.", regenerable: true)
        case .installers: CleanupAdvice(.review, "Looks like downloaded installers or updates.")
        default: nil
        }
    }

    /// Detects common project types from marker files.
    func projectKind(of node: FileNode) -> String? {
        let names = Set(node.children.map(\.name))
        let markers: [(String, String)] = [
            ("package.json", "JavaScript/Node.js project"), ("Cargo.toml", "Rust project"), ("Package.swift", "Swift package"),
            ("go.mod", "Go module"), ("pom.xml", "Maven project"), ("build.gradle", "Gradle project"),
            ("build.gradle.kts", "Gradle project"), ("pyproject.toml", "Python project"), ("requirements.txt", "Python project"),
            ("Gemfile", "Ruby project"), ("composer.json", "PHP project"), ("pubspec.yaml", "Flutter/Dart project"),
            ("CMakeLists.txt", "C/C++ project"), ("Makefile", "Make-based project"), ("Podfile", "CocoaPods project"),
        ]
        for (marker, kind) in markers where names.contains(marker) { return "Detected \(kind) (\(marker))." }
        if node.children.contains(where: { $0.fileExtension == "xcodeproj" || $0.fileExtension == "xcworkspace" }) {
            return "Detected Xcode project."
        }
        if node.children.contains(where: { $0.fileExtension == "sln" || $0.fileExtension == "csproj" }) {
            return "Detected .NET solution."
        }
        if names.contains(".git") { return "Detected Git repository." }
        return nil
    }
}
