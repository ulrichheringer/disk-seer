import Foundation
import NaturalLanguage

/// Turns a path into features for the predictive model.
public enum PathTokenizer {
    /// Tokens for a key path (e.g. "~/Library/Application Support/Foo/ModelWeights").
    public static func tokens(keyPath: String, isDirectory: Bool, size: Int64) -> [String] {
        var result: [String] = []
        let components = keyPath.split(separator: "/").map(String.init)
        let tail = components.suffix(6)
        for (offset, component) in tail.enumerated() {
            let isLast = offset == tail.count - 1
            for word in words(in: component) where !stopwords.contains(word) {
                result.append(word)
                if isLast { result.append("n:" + word) }
            }
        }
        if !isDirectory, let last = components.last, let dot = last.lastIndex(of: "."), dot != last.startIndex {
            result.append("ext:" + last[last.index(after: dot)...].lowercased())
        }
        result.append(isDirectory ? "kind:dir" : "kind:file")
        if size > 0 {
            result.append("size:\(Int(log10(Double(size))))")
        }
        return result
    }

    /// Lowercased words of a single path component, splitting on punctuation and camelCase.
    public static func words(in component: String) -> [String] {
        var words: [String] = []
        var current = ""
        var previousWasLower = false
        func flush() {
            if current.count >= 2 { words.append(normalize(current.lowercased())) }
            current = ""
        }
        for scalar in component.unicodeScalars {
            let isLetter = CharacterSet.letters.contains(scalar)
            let isDigit = CharacterSet.decimalDigits.contains(scalar)
            if !(isLetter || isDigit) {
                flush(); previousWasLower = false; continue
            }
            let isUpper = CharacterSet.uppercaseLetters.contains(scalar)
            if isUpper && previousWasLower { flush() }
            current.unicodeScalars.append(scalar)
            previousWasLower = CharacterSet.lowercaseLetters.contains(scalar) || isDigit
        }
        flush()
        return words
    }

    /// Path boilerplate that says nothing about an item's purpose.
    static let stopwords: Set<String> = [
        "library", "application", "support", "users", "user", "container", "data", "group", "com", "org", "net", "io",
        "app", "someapp", "vendor", "file", "content", "resource", "the", "and", "of", "for", "default", "local", "share",
        "<num>", "<hex>", "v1", "v2", "v3",
    ]

    private static func normalize(_ word: String) -> String {
        if word.allSatisfy(\.isNumber) { return "<num>" }
        if word.count >= 16 && word.allSatisfy(\.isHexDigit) { return "<hex>" }
        // Light stemming: plural "s" (caches -> cache, projects -> project, logs -> log).
        if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us") {
            return String(word.dropLast())
        }
        return word
    }
}

/// Multinomial Naive Bayes classifier over path tokens.
///
/// It starts from a built-in corpus of labelled paths and is then
/// self-trained on the items of the user's own disk that the knowledge base
/// recognised with certainty. Words never seen during training are mapped to
/// their nearest known neighbour with Apple's on-device word embeddings, so
/// "thumbnails" can borrow evidence from "cache" and "checkpoints" from "models".
public final class PredictiveModel: @unchecked Sendable {
    private var tokenCounts: [FileCategory: [String: Int]] = [:]
    private var totalTokens: [FileCategory: Int] = [:]
    private var documentCounts: [FileCategory: Int] = [:]
    private var vocabulary: Set<String> = []
    private var documents = 0
    private let lock = NSLock()
    private var neighbourCache: [String: String?] = [:]
    private lazy var embedding: NLEmbedding? = NLEmbedding.wordEmbedding(for: .english)

    public struct Prediction: Sendable {
        public let category: FileCategory
        public let probability: Double
        public let topTokens: [String]
        public let substitutions: [String: String]
    }

    public init(includeBuiltInCorpus: Bool = true) {
        if includeBuiltInCorpus {
            for (path, category) in PredictiveModel.builtInCorpus {
                let isDir = !path.contains(".") || path.hasSuffix("/")
                train(tokens: PathTokenizer.tokens(keyPath: path, isDirectory: isDir, size: 0), category: category)
            }
        }
    }

    public var trainingDocumentCount: Int { lock.withLock { documents } }
    public var vocabularySize: Int { lock.withLock { vocabulary.count } }

    public func train(tokens: [String], category: FileCategory) {
        lock.withLock {
            documents += 1
            documentCounts[category, default: 0] += 1
            var counts = tokenCounts[category] ?? [:]
            for token in tokens {
                counts[token, default: 0] += 1
                vocabulary.insert(token)
            }
            tokenCounts[category] = counts
            totalTokens[category, default: 0] += tokens.count
        }
    }

    /// Predict the category of a path. Returns nil if the model has no data.
    public func predict(tokens rawTokens: [String], useEmbeddings: Bool = false) -> Prediction? {
        var substitutions: [String: String] = [:]
        var tokens: [String] = []
        let vocab = lock.withLock { vocabulary }
        for token in rawTokens {
            if vocab.contains(token) {
                tokens.append(token)
            } else if useEmbeddings, !token.contains(":"), let neighbour = nearestKnownWord(token, vocabulary: vocab) {
                tokens.append(neighbour)
                substitutions[token] = neighbour
            }
        }
        let informative = tokens.filter { !$0.hasPrefix("kind:") && !$0.hasPrefix("size:") }
        guard !informative.isEmpty else { return nil }

        return lock.withLock { () -> Prediction? in
            guard documents > 0 else { return nil }
            let vocabCount = Double(vocabulary.count)
            var logScores: [(FileCategory, Double)] = []
            for (category, docCount) in documentCounts {
                let counts = tokenCounts[category] ?? [:]
                let total = Double(totalTokens[category] ?? 0)
                var score = log(Double(docCount) / Double(documents))
                for token in tokens {
                    score += log((Double(counts[token] ?? 0) + 1) / (total + vocabCount))
                }
                logScores.append((category, score))
            }
            guard let best = logScores.max(by: { $0.1 < $1.1 }) else { return nil }
            // Softmax for a calibrated-ish probability.
            let denominator = logScores.reduce(0.0) { $0 + exp($1.1 - best.1) }
            let probability = 1 / denominator

            let counts = tokenCounts[best.0] ?? [:]
            let top = informative
                .sorted { (counts[$0] ?? 0) > (counts[$1] ?? 0) }
                .prefix(3)
                .map { $0.replacingOccurrences(of: "n:", with: "").replacingOccurrences(of: "ext:", with: ".") }
            var unique: [String] = []
            for t in top where !unique.contains(t) { unique.append(t) }
            return Prediction(category: best.0, probability: probability, topTokens: unique, substitutions: substitutions)
        }
    }

    private func nearestKnownWord(_ word: String, vocabulary: Set<String>) -> String? {
        let bare = word.hasPrefix("n:") ? String(word.dropFirst(2)) : word
        if let cached = lock.withLock({ neighbourCache[bare] }) { return cached.map { word.hasPrefix("n:") ? "n:" + $0 : $0 } }
        var found: String?
        if bare.count >= 3, let embedding = lock.withLock({ embedding }) {
            for (candidate, distance) in embedding.neighbors(for: bare, maximumCount: 12) where distance < 1.1 {
                if vocabulary.contains(candidate) { found = candidate; break }
            }
        }
        lock.withLock { neighbourCache[bare] = found }
        return found.map { word.hasPrefix("n:") ? "n:" + $0 : $0 }
    }

    /// Generic examples teaching the model common naming conventions.
    static let builtInCorpus: [(String, FileCategory)] = [
        ("~/Library/Application Support/SomeApp/Cache", .caches),
        ("~/Library/Application Support/SomeApp/Code Cache", .caches),
        ("~/Library/Application Support/SomeApp/GPUCache", .caches),
        ("~/Library/Application Support/SomeApp/ShaderCache", .caches),
        ("~/Library/Application Support/SomeApp/DawnCache", .caches),
        ("~/Library/Application Support/SomeApp/thumbnails", .caches),
        ("~/Library/Application Support/SomeApp/thumbs", .caches),
        ("~/Library/Application Support/SomeApp/previews", .caches),
        ("~/Library/Application Support/SomeApp/tmp", .caches),
        ("~/Library/Application Support/SomeApp/temp", .caches),
        ("~/Library/Application Support/SomeApp/blob_storage", .caches),
        ("~/Library/Application Support/SomeApp/IndexedDB", .caches),
        ("~/Library/Application Support/SomeApp/Service Worker/CacheStorage", .caches),
        ("~/Library/Application Support/SomeApp/Crashpad/completed", .logs),
        ("~/Library/Application Support/SomeApp/logs", .logs),
        ("~/Library/Application Support/SomeApp/log", .logs),
        ("~/Library/Application Support/SomeApp/crash reports", .logs),
        ("~/Library/Application Support/SomeApp/diagnostics", .logs),
        ("~/Library/Application Support/SomeApp/telemetry", .logs),
        ("~/Library/Application Support/SomeApp/backups", .backups),
        ("~/Library/Application Support/SomeApp/backup", .backups),
        ("~/Library/Application Support/SomeApp/snapshots", .backups),
        ("~/Library/Application Support/SomeApp/archive", .backups),
        ("~/Library/Application Support/SomeApp/models", .aiModels),
        ("~/Library/Application Support/SomeApp/model weights", .aiModels),
        ("~/Library/Application Support/SomeApp/checkpoints", .aiModels),
        ("~/Library/Application Support/SomeApp/embeddings", .aiModels),
        ("~/Library/Application Support/SomeApp/llm", .aiModels),
        ("~/Library/Application Support/SomeApp/neural", .aiModels),
        ("~/Library/Application Support/SomeApp/vm", .virtualMachines),
        ("~/Library/Application Support/SomeApp/vms", .virtualMachines),
        ("~/Library/Application Support/SomeApp/virtual machine", .virtualMachines),
        ("~/Library/Application Support/SomeApp/disk images", .virtualMachines),
        ("~/Library/Application Support/SomeApp/rootfs", .virtualMachines),
        ("~/Library/Application Support/SomeApp/containers", .virtualMachines),
        ("~/Library/Application Support/SomeApp/docker", .virtualMachines),
        ("~/Library/Application Support/SomeApp/kernel", .virtualMachines),
        ("~/Library/Application Support/SomeApp/updates", .installers),
        ("~/Library/Application Support/SomeApp/updater", .installers),
        ("~/Library/Application Support/SomeApp/installer", .installers),
        ("~/Library/Application Support/SomeApp/downloads", .installers),
        ("~/Library/Application Support/SomeApp/ShipIt", .installers),
        ("~/Library/Application Support/SomeApp/media", .videos),
        ("~/Library/Application Support/SomeApp/videos", .videos),
        ("~/Library/Application Support/SomeApp/recordings", .videos),
        ("~/Library/Application Support/SomeApp/clips", .videos),
        ("~/Library/Application Support/SomeApp/footage", .videos),
        ("~/Library/Application Support/SomeApp/photos", .photos),
        ("~/Library/Application Support/SomeApp/images", .photos),
        ("~/Library/Application Support/SomeApp/pictures", .photos),
        ("~/Library/Application Support/SomeApp/wallpapers", .photos),
        ("~/Library/Application Support/SomeApp/screenshots", .photos),
        ("~/Library/Application Support/SomeApp/artwork", .photos),
        ("~/Library/Application Support/SomeApp/music", .audio),
        ("~/Library/Application Support/SomeApp/sounds", .audio),
        ("~/Library/Application Support/SomeApp/samples", .audio),
        ("~/Library/Application Support/SomeApp/podcasts", .audio),
        ("~/Library/Application Support/SomeApp/audio", .audio),
        ("~/Library/Application Support/SomeApp/voice", .audio),
        ("~/Library/Application Support/SomeApp/games", .games),
        ("~/Library/Application Support/SomeApp/saves", .games),
        ("~/Library/Application Support/SomeApp/steamapps", .games),
        ("~/Library/Application Support/SomeApp/levels", .games),
        ("~/Library/Application Support/SomeApp/mail", .communication),
        ("~/Library/Application Support/SomeApp/messages", .communication),
        ("~/Library/Application Support/SomeApp/chats", .communication),
        ("~/Library/Application Support/SomeApp/attachments", .communication),
        ("~/Library/Application Support/SomeApp/conversations", .communication),
        ("~/Library/Application Support/SomeApp/sync", .cloudStorage),
        ("~/Library/Application Support/SomeApp/cloud", .cloudStorage),
        ("~/Library/Application Support/SomeApp/drive", .cloudStorage),
        ("~/Library/Application Support/SomeApp/plugins", .applications),
        ("~/Library/Application Support/SomeApp/extensions", .applications),
        ("~/Library/Application Support/SomeApp/frameworks", .applications),
        ("~/Library/Application Support/SomeApp/bin", .applications),
        ("~/Library/Application Support/SomeApp/runtime", .applications),
        ("~/Library/Application Support/SomeApp/versions", .applications),
        ("~/Library/Application Support/SomeApp/database", .documents),
        ("~/Library/Application Support/SomeApp/documents", .documents),
        ("~/Library/Application Support/SomeApp/library", .documents),
        ("~/Library/Application Support/SomeApp/notes", .documents),
        ("~/Library/Application Support/SomeApp/reports", .documents),
        ("~/Library/Application Support/SomeApp/books", .documents),
        ("~/Library/Application Support/SomeApp/fonts", .documents),
        ("~/projects/app/build", .buildArtifacts),
        ("~/projects/app/out", .buildArtifacts),
        ("~/projects/app/dist", .buildArtifacts),
        ("~/projects/app/release", .buildArtifacts),
        ("~/projects/app/debug", .buildArtifacts),
        ("~/projects/app/obj", .buildArtifacts),
        ("~/projects/app/target", .buildArtifacts),
        ("~/projects/app/intermediates", .buildArtifacts),
        ("~/projects/app/artifacts", .buildArtifacts),
        ("~/projects/app/compiled", .buildArtifacts),
        ("~/projects/app/coverage", .buildArtifacts),
        ("~/projects/app/vendor", .dependencies),
        ("~/projects/app/packages", .dependencies),
        ("~/projects/app/deps", .dependencies),
        ("~/projects/app/third_party", .dependencies),
        ("~/projects/app/external", .dependencies),
        ("~/projects/app/site-packages", .dependencies),
        ("~/projects/app/lib/python3/site-packages", .dependencies),
        ("~/projects/app/src", .code),
        ("~/projects/app/source", .code),
        ("~/projects/app/tests", .code),
        ("~/projects/app/scripts", .code),
        ("~/projects/app/repo", .code),
        ("~/projects/app/git", .code),
        ("~/projects/app/sdk", .developer),
        ("~/projects/app/toolchain", .developer),
        ("~/projects/app/toolchains", .developer),
        ("~/projects/app/emulator", .developer),
        ("~/projects/app/simulator", .developer),
        ("~/projects/app/ide", .developer),
        ("~/projects/app/compiler", .developer),
        ("~/Documents/Work/invoices", .documents),
        ("~/Documents/Work/contracts", .documents),
        ("~/Documents/Work/presentations", .documents),
        ("~/Documents/Work/spreadsheets", .documents),
        ("~/Documents/University/thesis", .documents),
        ("~/Documents/scans", .documents),
        ("~/Documents/Taxes", .documents),
        ("~/Documents/Finance", .documents),
        ("~/Desktop/Screenshots", .photos),
        ("~/Desktop/Screen Recordings", .videos),
        ("~/Movies/exports", .videos),
        ("~/Movies/renders", .videos),
        ("~/Movies/Projects/Render Files", .videos),
        ("~/Movies/Projects/Proxy Media", .videos),
        ("~/Pictures/Lightroom", .photos),
        ("~/Pictures/Camera Roll", .photos),
        ("~/Pictures/RAW", .photos),
        ("~/Pictures/Exports", .photos),
        ("~/Music/Loops", .audio),
        ("~/Music/Stems", .audio),
        ("~/Downloads/installers", .installers),
        ("~/Downloads/setup", .installers),
        ("~/Datasets/imagenet", .aiModels),
        ("~/datasets/train", .aiModels),
        ("~/models/llama", .aiModels),
        ("~/models/stable-diffusion", .aiModels),
        ("~/models/lora", .aiModels),
        ("~/Time Machine Backups", .backups),
        ("~/Backups/old laptop", .backups),
        ("~/Old Mac", .backups),
        ("~/Archive", .archives),
        ("~/Archives", .archives),
        ("~/Games/Minecraft", .games),
        ("~/Games/emulators/roms", .games),
        ("~/VMs/ubuntu", .virtualMachines),
        ("~/VMs/windows11", .virtualMachines),
        ("~/wsl/data.vhdx", .virtualMachines),
        ("~/Library/Caches/SomeApp", .caches),
        ("~/Library/Logs/SomeApp", .logs),
        ("~/Library/Containers/com.vendor.app/Data/Library/Caches", .caches),
    ]
}
