import Foundation
import XCTest
@testable import GitacreCore

final class RepositoryRefreshTests: XCTestCase {
    func testDiscoveryWinsOverStatusAndKeepsTheLatestConfiguration() {
        let first = RepositoryRefreshRequest(
            configuration: configuration(roots: ["/old"], depth: 2),
            scope: .status(paths: ["/old/example"])
        )
        let second = RepositoryRefreshRequest(
            configuration: configuration(roots: ["/new"], depth: 4),
            scope: .discovery,
            knownRepositories: [makeRepository(id: "example")]
        )

        let coalesced = first.coalescing(second)
        XCTAssertEqual(coalesced.configuration.roots, ["/new"])
        XCTAssertEqual(coalesced.configuration.maximumDepth, 4)
        XCTAssertEqual(coalesced.scope, .discovery)
        XCTAssertEqual(coalesced.knownRepositories.map(\.id), ["example"])
    }

    func testQueuedDiscoveryKeepsItsConfigurationWhenAStatusRefreshArrives() {
        let discovery = RepositoryRefreshRequest(
            configuration: configuration(roots: ["/new"], depth: 4),
            scope: .discovery
        )
        let status = RepositoryRefreshRequest(
            configuration: configuration(roots: ["/old"], depth: 2),
            scope: .status()
        )

        let coalesced = discovery.coalescing(status)
        XCTAssertEqual(coalesced.configuration.roots, ["/new"])
        XCTAssertEqual(coalesced.configuration.maximumDepth, 4)
        XCTAssertEqual(coalesced.scope, .discovery)
    }

    func testStatusPathsUnionUnlessEitherRequestRefreshesEverything() {
        let left = RepositoryRefreshRequest(
            configuration: configuration(),
            scope: .status(paths: ["/a"])
        )
        let right = RepositoryRefreshRequest(
            configuration: configuration(),
            scope: .status(paths: ["/b"])
        )
        let everything = RepositoryRefreshRequest(
            configuration: configuration(),
            scope: .status()
        )

        XCTAssertEqual(left.scope.merging(right.scope), .status(paths: ["/a", "/b"]))
        XCTAssertEqual(left.scope.merging(everything.scope), .status(paths: nil))
        XCTAssertEqual(everything.scope.merging(right.scope), .status(paths: nil))
    }

    func testDiscoveryCoversStatusOnlyWhenTheConfigurationMatches() {
        let discovery = RepositoryRefreshRequest(
            configuration: configuration(roots: ["/tmp"], depth: 3),
            scope: .discovery
        )
        let status = RepositoryRefreshRequest(
            configuration: configuration(roots: ["/tmp"], depth: 3),
            scope: .status()
        )
        let otherRoots = RepositoryRefreshRequest(
            configuration: configuration(roots: ["/other"], depth: 3),
            scope: .status()
        )

        XCTAssertTrue(discovery.covers(status))
        XCTAssertFalse(status.covers(discovery))
        XCTAssertFalse(discovery.covers(otherRoots))
        XCTAssertTrue(
            discovery.covers(discovery),
            "a running discovery must absorb an identical one instead of restarting it"
        )
    }

    func testStatusRefreshUpdatesMatchingRepositoriesWithoutDiscoveringNewOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let alpha = root.appendingPathComponent("alpha", isDirectory: true)
        let beta = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = ProcessRunner()
        for checkout in [alpha, beta] {
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", checkout.path, "init", "-q"]).succeeded)
        }

        let scanner = RepositoryScanner()
        let initial = scanner.scan(roots: [root.path])
        XCTAssertEqual(Set(initial.map(\.name)), ["alpha", "beta"])
        XCTAssertTrue(initial.allSatisfy { $0.totalChangedFiles == 0 })

        try Data("dirty\n".utf8).write(to: alpha.appendingPathComponent("pending.txt"))
        try Data("dirty\n".utf8).write(to: beta.appendingPathComponent("pending.txt"))

        let targeted = scanner.refreshStatus(of: initial, matching: [alpha.path])
        let refreshedAlpha = try XCTUnwrap(targeted.first { $0.name == "alpha" })
        let untouchedBeta = try XCTUnwrap(targeted.first { $0.name == "beta" })
        XCTAssertEqual(refreshedAlpha.totalChangedFiles, 1)
        XCTAssertEqual(untouchedBeta.totalChangedFiles, 0, "unmatched repositories must keep their previous status")

        let gamma = root.appendingPathComponent("gamma", isDirectory: true)
        try FileManager.default.createDirectory(at: gamma, withIntermediateDirectories: true)
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", gamma.path, "init", "-q"]).succeeded)

        let statusOnly = scanner.refreshStatus(of: targeted)
        XCTAssertEqual(Set(statusOnly.map(\.name)), ["alpha", "beta"])
        XCTAssertEqual(Set(scanner.scan(roots: [root.path]).map(\.name)), ["alpha", "beta", "gamma"])
    }

    func testStatusRefreshDropsRepositoriesThatNoLongerExist() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let alpha = root.appendingPathComponent("alpha", isDirectory: true)
        let beta = root.appendingPathComponent("beta", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = ProcessRunner()
        for checkout in [alpha, beta] {
            try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
            XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", checkout.path, "init", "-q"]).succeeded)
        }

        let scanner = RepositoryScanner()
        let initial = scanner.scan(roots: [root.path])
        XCTAssertEqual(Set(initial.map(\.name)), ["alpha", "beta"])

        try FileManager.default.removeItem(at: alpha)

        let refreshed = scanner.refreshStatus(of: initial)
        XCTAssertEqual(refreshed.map(\.name), ["beta"])
        XCTAssertTrue(
            refreshed.allSatisfy { $0.scanFailure == nil },
            "a deleted repository must disappear rather than become a scan failure"
        )
    }

    func testStatusRefreshPreservesDiscoveredIconPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let checkout = root.appendingPathComponent("example", isDirectory: true)
        let publicDirectory = checkout.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = ProcessRunner()
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", checkout.path, "init", "-q"]).succeeded)
        let icon = publicDirectory.appendingPathComponent("favicon.png")
        try Data("icon".utf8).write(to: icon)

        let scanner = RepositoryScanner()
        let initial = scanner.scan(roots: [root.path])
        XCTAssertEqual(initial.first?.iconPath, icon.path)

        try FileManager.default.removeItem(at: icon)
        let status = scanner.refreshStatus(of: initial)
        XCTAssertEqual(status.first?.iconPath, icon.path, "status refresh must not walk for icons")

        let rediscovered = scanner.scan(roots: [root.path])
        XCTAssertNil(rediscovered.first?.iconPath)
    }

    func testRepositoryScannerRunHonoursRefreshScope() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let checkout = root.appendingPathComponent("example", isDirectory: true)
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = ProcessRunner()
        XCTAssertTrue(runner.run(executable: "/usr/bin/git", arguments: ["-C", checkout.path, "init", "-q"]).succeeded)

        let configuration = ScanConfiguration(
            roots: [root.path],
            maximumDepth: 5,
            includeLinkedWorktrees: true,
            ignoredDirectoryNames: []
        )
        let discovered = RepositoryScanner.run(
            RepositoryRefreshRequest(configuration: configuration, scope: .discovery)
        )
        XCTAssertEqual(discovered.map(\.name), ["example"])

        try Data("dirty\n".utf8).write(to: checkout.appendingPathComponent("pending.txt"))
        let status = RepositoryScanner.run(
            RepositoryRefreshRequest(
                configuration: configuration,
                scope: .status(),
                knownRepositories: discovered
            )
        )
        XCTAssertEqual(status.first?.totalChangedFiles, 1)
    }

    private func configuration(
        roots: [String] = ["/tmp"],
        depth: Int = 3
    ) -> ScanConfiguration {
        ScanConfiguration(
            roots: roots,
            maximumDepth: depth,
            includeLinkedWorktrees: true,
            ignoredDirectoryNames: []
        )
    }

    private func makeRepository(id: String) -> Repository {
        Repository(
            id: id,
            name: id,
            commonDirectory: "/tmp/\(id)/.git",
            remoteURL: nil,
            worktrees: [],
            stashCount: 0
        )
    }
}
