import Foundation
import Testing
@testable import DiskSeerCore

private let home = "/Users/tester"

private func homeTree(_ children: [FileNode]) -> FileNode {
    // Build /Users/tester as a root node.
    dir(home, children)
}

@Suite("Classification")
struct ClassifierTests {
    let engine = RuleEngine(home: home)

    @Test func knownLocationsAndInheritance() {
        let derived = dir("DerivedData", [dir("App-abc", [file("Build.o", 5_000_000)])])
        let root = homeTree([dir("Library", [dir("Developer", [dir("Xcode", [derived])])])])
        let classifier = TreeClassifier(engine: engine)
        classifier.classify(root: root)
        #expect(derived.category == .buildArtifacts)
        let objectFile = derived.descendant(atRelativePath: "App-abc/Build.o")!
        #expect(objectFile.category == .buildArtifacts, "strong inheritance beats file type")
        let explanation = classifier.explain(objectFile)
        #expect(explanation.source == .inherited)
        #expect(explanation.advice?.safety == .safe)
    }

    @Test func contextRulesNeedTheirMarkers() {
        let rustTarget = dir("target", [file("app", 9_000_000)])
        let rust = dir("rusty", [file("Cargo.toml", 100), rustTarget])
        let plainTarget = dir("target", [file("notes.txt", 1000)])
        let plain = dir("plain", [plainTarget])
        let root = homeTree([dir("dev", [rust, plain])])
        TreeClassifier(engine: engine).classify(root: root)
        #expect(rustTarget.category == .buildArtifacts)
        #expect(plainTarget.category != .buildArtifacts)
        #expect(engine.match(node: rustTarget, key: "~/dev/rusty/target")?.id == "proj.cargo")
        #expect(engine.match(node: plainTarget, key: "~/dev/plain/target") == nil)
    }

    @Test func dotnetBinNeedsProjectFile() {
        let bin = dir("bin", [file("App.dll", 2_000_000)])
        let project = dir("Api", [file("Api.csproj", 1000), bin])
        _ = homeTree([dir("RiderProjects", [project])])
        #expect(engine.match(node: bin, key: "~/RiderProjects/Api/bin")?.id == "proj.dotnetbin")
    }

    @Test func virtualEnvironmentDetectedByContents() {
        let venv = dir(".venv", [file("pyvenv.cfg", 100), dir("lib", [file("x.py", 10)])])
        _ = dir("proj", [venv])
        #expect(engine.match(node: venv, key: "~/proj/.venv")?.id == "proj.venv")
        let fake = dir(".venv", [file("readme.md", 10)])
        _ = dir("proj2", [fake])
        #expect(engine.match(node: fake, key: "~/proj2/.venv") == nil)
    }

    @Test func dockerAndVirtualDisks() {
        let raw = file("Docker.raw", 60_000_000_000)
        let vhdx = file("data.vhdx", 20_000_000_000)
        #expect(engine.match(node: raw, key: "~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")?.category == .virtualMachines)
        let vhdSig = engine.match(node: vhdx, key: "~/Downloads/data.vhdx")
        #expect(vhdSig?.category == .virtualMachines)
        #expect(vhdSig?.advice?.safety == .caution)
    }

    @Test func cachesGlobAndExactPrecedence() {
        let homebrew = dir("Homebrew", [file("x.tar.gz", 1_000_000)])
        let spotify = dir("com.spotify.client", [file("data", 1_000_000)])
        let apple = dir("com.apple.Safari", [file("db", 10)])
        #expect(engine.match(node: homebrew, key: "~/Library/Caches/Homebrew")?.id == "pkg.homebrew")
        #expect(engine.match(node: spotify, key: "~/Library/Caches/com.spotify.client")?.id == "sys.usercaches.item")
        #expect(engine.match(node: apple, key: "~/Library/Caches/com.apple.Safari")?.id == "app.safaricache")
        let appleOther = dir("com.apple.nsurlsessiond", [])
        #expect(engine.match(node: appleOther, key: "~/Library/Caches/com.apple.nsurlsessiond")?.id == "sys.usercaches.apple")
    }

    @Test func fileTypesAndExecutables() {
        let movie = file("holiday.MOV", 1_000_000)
        #expect(engine.match(node: movie, key: "~/Movies/holiday.MOV")?.category == .videos)
        let tool = file("ripgrep", 5_000_000)
        let bin = dir("bin", [tool])
        #expect(bin.children.count == 1)
        #expect(engine.match(node: tool, key: "~/.cargo/bin/ripgrep")?.category == .developer)
    }

    @Test func foldersAreLabelledByDominantContents() {
        let shoot = dir("Shoot 2023", (0..<10).map { file("IMG_\($0).CR3", 30_000_000) } + [file("notes.txt", 1000)])
        let root = homeTree([dir("Stuff", [shoot])])
        TreeClassifier(engine: engine).classify(root: root)
        #expect(shoot.category == .photos)
        #expect(TreeClassifier.dominantCategory([.photos: 90, .documents: 10], total: 100) == .photos)
        #expect(TreeClassifier.dominantCategory([.photos: 50, .documents: 50], total: 100) == nil)
    }

    @Test func keyPathsAreCanonical() {
        #expect(engine.keyPath(forAbsolutePath: home) == "~")
        #expect(engine.keyPath(forAbsolutePath: home + "/Library") == "~/Library")
        #expect(engine.keyPath(forAbsolutePath: "/System/Volumes/Data" + home + "/x") == "~/x")
        #expect(engine.keyPath(forAbsolutePath: "/System/Volumes/Data") == "")
        #expect(engine.childKeyPath(parent: "", name: "Users") == "/Users")
        #expect(engine.childKeyPath(parent: "/Users", name: "tester") == "~")
    }

    @Test func explainsHomeFolder() {
        let root = homeTree([file("a", 1)])
        let c = TreeClassifier(engine: engine).explain(root)
        #expect(c.label == "Your home folder")
    }
}

@Suite("Predictive model")
struct PredictiveModelTests {
    @Test func tokenizerSplitsCamelCaseAndPunctuation() {
        #expect(PathTokenizer.words(in: "GPUCache") == ["gpucache"] || PathTokenizer.words(in: "GPUCache").contains("cache"))
        #expect(PathTokenizer.words(in: "modelWeights_v2") == ["model", "weight", "v2"])
        #expect(PathTokenizer.words(in: "com.spotify.client") == ["com", "spotify", "client"])
        #expect(PathTokenizer.words(in: "2024") == ["<num>"])
        let tokens = PathTokenizer.tokens(keyPath: "~/Downloads/movie.mkv", isDirectory: false, size: 2_000_000_000)
        #expect(tokens.contains("ext:mkv"))
        #expect(tokens.contains("kind:file"))
        #expect(tokens.contains("size:9"))
    }

    @Test func builtInCorpusGeneralises() {
        let model = PredictiveModel()
        func predict(_ path: String) -> FileCategory? {
            model.predict(tokens: PathTokenizer.tokens(keyPath: path, isDirectory: true, size: 0))?.category
        }
        #expect(predict("~/Library/Application Support/Unknown Vendor/Cache") == .caches)
        #expect(predict("~/Library/Application Support/Foo/logs") == .logs)
        #expect(predict("~/Library/Application Support/Foo/models") == .aiModels)
        #expect(predict("~/work/project/build") == .buildArtifacts)
    }

    @Test func selfTrainingLearnsNewVocabulary() {
        let model = PredictiveModel(includeBuiltInCorpus: false)
        for i in 0..<20 {
            model.train(tokens: PathTokenizer.tokens(keyPath: "~/x/zorblax\(i)/quuxcache", isDirectory: true, size: 0), category: .caches)
            model.train(tokens: PathTokenizer.tokens(keyPath: "~/x/vid\(i)/footage", isDirectory: true, size: 0), category: .videos)
        }
        let p = model.predict(tokens: PathTokenizer.tokens(keyPath: "~/other/quuxcache", isDirectory: true, size: 0))
        #expect(p?.category == .caches)
        #expect((p?.probability ?? 0) > 0.6)
        #expect(model.predict(tokens: ["kind:dir"]) == nil, "no informative tokens means no prediction")
    }
}
