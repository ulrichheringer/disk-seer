import Foundation
import Synchronization
import Testing
@testable import DiskSeerCore

@Suite("Safety policy")
struct SafetyPolicyTests {
    let policy = SafetyPolicy(home: "/Users/tester")

    @Test(arguments: [
        "/", "/System", "/System/Library/Frameworks/AppKit.framework", "/usr/bin/ls", "/Applications", "/Library",
        "/Users/tester", "/Users/tester/Library", "/Users/tester/Documents", "/Users/tester/Library/Keychains/login.keychain-db",
        "/Users/tester/Library/Mail/V10", "/Users/tester/Library/Caches", "/private/var/vm/swapfile0", "/var/db/x",
        "/Applications/Safari.app/Contents/Info.plist", "/Users/tester/Pictures/Photos Library.photoslibrary/originals/a.heic",
        "/System/Volumes/Data/Users/tester", "/Users/tester/.ssh/id_ed25519", "/tmp",
    ])
    func deniesProtectedPaths(_ path: String) {
        #expect(!policy.verdict(forPath: path).isAllowed, "\(path) must be protected")
    }

    @Test(arguments: [
        "/Users/tester/Library/Caches/com.spotify.client", "/Users/tester/Library/Developer/Xcode/DerivedData",
        "/Users/tester/dev/app/node_modules", "/Applications/Slack.app", "/Users/tester/Downloads/installer.dmg",
        "/System/Volumes/Data/Users/tester/Library/Caches/Homebrew", "/Users/tester/.Trash/old.zip",
        "/Users/tester/Pictures/Photos Library.photoslibrary",
    ])
    func allowsUserJunk(_ path: String) {
        #expect(policy.verdict(forPath: path).isAllowed, "\(path) should be removable")
    }

    @Test func allowedRootsOverrideTemporaryFolderProtection() throws {
        let tmp = try TemporaryDirectory()
        #expect(!SafetyPolicy().verdict(forPath: tmp.path + "/x").isAllowed)
        #expect(SafetyPolicy(allowedRoots: [tmp.path]).verdict(forPath: tmp.path + "/x").isAllowed)
    }
}

@Suite("Cleanup engine")
struct CleanupEngineTests {
    @Test func collapsesNestedSelections() {
        let items: [(path: String, size: Int64)] = [("/a/b/c", 1), ("/a/b", 2), ("/a/bc", 3), ("/x", 4), ("/a/b", 2)]
        let collapsed = CleanupEngine.collapseNested(items).map(\.path).sorted()
        #expect(collapsed == ["/a/b", "/a/bc", "/x"])
    }

    @Test func trashesAllowedItemsAndSkipsProtectedOnes() throws {
        let tmp = try TemporaryDirectory()
        let junk = try tmp.write("cache/junk.bin", bytes: 1000)
        let trashed = Mutex<[String]>([])
        let engine = CleanupEngine(policy: SafetyPolicy(allowedRoots: [tmp.path])) { url in
            trashed.withLock { $0.append(url.path) }
            return nil
        }
        let report = engine.moveToTrash([
            (junk.path, 1000),
            ("/System/Library", 10),
            (tmp.path + "/missing", 5),
        ])
        #expect(trashed.withLock { $0 } == [junk.path])
        #expect(report.succeeded.count == 1)
        #expect(report.failed.count == 2)
        #expect(report.freedBytes == 1000)
    }

    @Test func dryRunTouchesNothing() throws {
        let tmp = try TemporaryDirectory()
        let junk = try tmp.write("junk.bin", bytes: 10)
        let engine = CleanupEngine(policy: SafetyPolicy(allowedRoots: [tmp.path])) { _ in
            Issue.record("trash must not be called in a dry run")
            return nil
        }
        let report = engine.moveToTrash([(junk.path, 10)], dryRun: true)
        #expect(report.succeeded.count == 1)
        #expect(FileManager.default.fileExists(atPath: junk.path))
    }

    @Test func realTrashOfProjectOwnedTemporaryFile() throws {
        // Uses the real FileManager.trashItem on a file created by this test, then removes it from the Trash.
        let tmp = try TemporaryDirectory()
        let junk = try tmp.write("diskseer-test-junk-\(UUID().uuidString).bin", bytes: 64)
        let report = CleanupEngine(policy: SafetyPolicy(allowedRoots: [tmp.path])).moveToTrash([(junk.path, 64)])
        #expect(report.succeeded.count == 1)
        #expect(!FileManager.default.fileExists(atPath: junk.path))
        if let trashedURL = report.succeeded.first?.trashedURL {
            #expect(FileManager.default.fileExists(atPath: trashedURL.path))
            try FileManager.default.removeItem(at: trashedURL)
        }
    }

    @Test func commandRunnerCapturesOutput() {
        let output = CommandRunner.run("echo hello; echo oops >&2; exit 3", timeout: 10)
        #expect(output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(output.stderr.contains("oops"))
        #expect(output.status == 3)
        #expect(CommandRunner.which("ls") != nil)
    }
}
