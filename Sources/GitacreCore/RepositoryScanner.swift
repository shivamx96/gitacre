import Foundation

public struct RepositoryScanner: Sendable {
    private let runner: any ProcessRunning
    private let gitExecutable: String
    private let maximumDepth: Int
    private let includeLinkedWorktrees: Bool
    private let ignoredDirectoryNames: Set<String>

    public init(
        runner: any ProcessRunning = ProcessRunner(),
        gitExecutable: String = "/usr/bin/git",
        maximumDepth: Int = 5,
        includeLinkedWorktrees: Bool = true,
        ignoredDirectoryNames: Set<String> = []
    ) {
        self.runner = runner
        self.gitExecutable = gitExecutable
        self.maximumDepth = maximumDepth
        self.includeLinkedWorktrees = includeLinkedWorktrees
        self.ignoredDirectoryNames = ignoredDirectoryNames
    }

    public func scan(roots: [String]) -> [Repository] {
        let checkouts = discoverCheckouts(roots: roots)
        var representatives: [String: String] = [:]

        for checkout in checkouts {
            guard let commonDirectory = commonDirectory(for: checkout) else { continue }
            representatives[commonDirectory] = representatives[commonDirectory] ?? checkout
        }

        return representatives.compactMap { commonDirectory, checkout in
            makeRepository(commonDirectory: commonDirectory, checkout: checkout)
        }
        .sorted {
            if $0.hasPendingWork != $1.hasPendingWork {
                return $0.hasPendingWork
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func discoverCheckouts(roots: [String]) -> [String] {
        let fileManager = FileManager.default
        let defaultIgnoredDirectoryNames: Set<String> = [
            ".build", ".cache", ".git", ".idea", ".swiftpm", "DerivedData",
            "Pods", "node_modules", "vendor"
        ]
        let ignoredDirectoryNames = defaultIgnoredDirectoryNames.union(self.ignoredDirectoryNames)
        var found: Set<String> = []

        for rootPath in roots {
            let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            if isCheckout(rootURL.path) {
                found.insert(rootURL.path)
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            let rootDepth = rootURL.pathComponents.count
            while let item = enumerator.nextObject() as? URL {
                guard let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                      values.isDirectory == true else { continue }

                let depth = item.pathComponents.count - rootDepth
                if depth > maximumDepth || ignoredDirectoryNames.contains(item.lastPathComponent) {
                    enumerator.skipDescendants()
                    continue
                }

                if isCheckout(item.path) {
                    found.insert(item.standardizedFileURL.path)
                    enumerator.skipDescendants()
                }
            }
        }

        return found.sorted()
    }

    private func isCheckout(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(".git").path)
    }

    private func commonDirectory(for checkout: String) -> String? {
        let result = git(
            checkout,
            ["rev-parse", "--path-format=absolute", "--git-common-dir"]
        )
        guard result.succeeded else { return nil }
        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { return nil }
        return URL(fileURLWithPath: output).standardizedFileURL.path
    }

    private func makeRepository(commonDirectory: String, checkout: String) -> Repository? {
        let worktreeResult = git(checkout, ["worktree", "list", "--porcelain", "-z"])
        guard worktreeResult.succeeded else { return nil }

        let discoveredRecords = Self.parseWorktreeList(worktreeResult.standardOutput)
        let records: [WorktreeRecord]
        if includeLinkedWorktrees {
            records = discoveredRecords
        } else {
            records = discoveredRecords.filter {
                URL(fileURLWithPath: $0.path).standardizedFileURL.path
                    == URL(fileURLWithPath: checkout).standardizedFileURL.path
            }
        }
        let worktrees = records.enumerated().compactMap { index, record in
            makeWorktree(record: record, isPrimary: index == 0)
        }
        guard !worktrees.isEmpty else { return nil }

        let originResult = git(checkout, ["config", "--get", "remote.origin.url"])
        let origin = originResult.succeeded
            ? originResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let remoteURL = Self.webURL(forOrigin: origin)
        let name = Self.repositoryName(origin: origin, fallbackPath: worktrees[0].path)

        let stashResult = git(checkout, ["stash", "list", "--format=%gd"])
        let stashCount = stashResult.succeeded
            ? stashResult.standardOutput.split(whereSeparator: \.isNewline).count
            : 0
        let iconPath = worktrees.lazy.compactMap { Self.projectIconPath(in: $0.path) }.first

        return Repository(
            id: commonDirectory,
            name: name,
            commonDirectory: commonDirectory,
            remoteURL: remoteURL,
            worktrees: worktrees,
            stashCount: stashCount,
            iconPath: iconPath
        )
    }

    private func makeWorktree(record: WorktreeRecord, isPrimary: Bool) -> Worktree? {
        guard FileManager.default.fileExists(atPath: record.path) else { return nil }

        let statusResult = git(
            record.path,
            ["--no-optional-locks", "status", "--porcelain=v2", "--branch", "--untracked-files=normal"]
        )
        guard statusResult.succeeded else { return nil }
        let status = Self.parseStatus(statusResult.standardOutput)

        let gitDirectoryResult = git(record.path, ["rev-parse", "--absolute-git-dir"])
        let gitDirectory = gitDirectoryResult.succeeded
            ? gitDirectoryResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let operation = Self.operation(inGitDirectory: gitDirectory)

        let dateResult = git(record.path, ["log", "-1", "--format=%ct"])
        let timestamp = TimeInterval(
            dateResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let branch = status.branch == "(detached)" || status.branch.isEmpty
            ? String(record.head.prefix(8))
            : status.branch

        return Worktree(
            id: record.path,
            path: record.path,
            branch: branch,
            head: record.head,
            isDetached: record.isDetached,
            isPrimary: isPrimary,
            isLocked: record.isLocked,
            staged: status.staged,
            unstaged: status.unstaged,
            untracked: status.untracked,
            conflicted: status.conflicted,
            changedFiles: status.changedFiles,
            ahead: status.ahead,
            behind: status.behind,
            upstream: status.upstream,
            operation: operation,
            lastCommitDate: timestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private func git(_ directory: String, _ arguments: [String]) -> ProcessResult {
        runner.run(executable: gitExecutable, arguments: ["-C", directory] + arguments)
    }

    public static func parseWorktreeList(_ output: String) -> [WorktreeRecord] {
        var records: [WorktreeRecord] = []
        var current: WorktreeRecord?

        for field in output.split(separator: "\0", omittingEmptySubsequences: false) {
            let line = String(field)
            if line.isEmpty {
                if let current {
                    records.append(current)
                }
                current = nil
                continue
            }

            if line.hasPrefix("worktree ") {
                if let current {
                    records.append(current)
                }
                current = WorktreeRecord(path: String(line.dropFirst(9)))
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                current?.branchReference = String(line.dropFirst(7))
            } else if line == "detached" {
                current?.isDetached = true
            } else if line.hasPrefix("locked") {
                current?.isLocked = true
            }
        }

        if let current {
            records.append(current)
        }
        return records
    }

    public static func parseStatus(_ output: String) -> GitStatus {
        var result = GitStatus()

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("# branch.head ") {
                result.branch = String(line.dropFirst(14))
            } else if line.hasPrefix("# branch.upstream ") {
                result.upstream = String(line.dropFirst(18))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.split(separator: " ")
                if parts.count >= 4 {
                    result.ahead = Int(parts[2].dropFirst()) ?? 0
                    result.behind = Int(parts[3].dropFirst()) ?? 0
                }
            } else if line.hasPrefix("? ") {
                result.untracked += 1
                result.changedFiles += 1
            } else if line.hasPrefix("u ") {
                result.conflicted += 1
                result.changedFiles += 1
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2 else { continue }
                let state = Array(parts[1])
                if state.indices.contains(0), state[0] != "." { result.staged += 1 }
                if state.indices.contains(1), state[1] != "." { result.unstaged += 1 }
                result.changedFiles += 1
            }
        }

        return result
    }

    public static func operation(inGitDirectory path: String) -> GitOperation? {
        guard !path.isEmpty else { return nil }
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: path)

        if fileManager.fileExists(atPath: directory.appendingPathComponent("rebase-merge").path)
            || fileManager.fileExists(atPath: directory.appendingPathComponent("rebase-apply").path) {
            return .rebase
        }
        if fileManager.fileExists(atPath: directory.appendingPathComponent("MERGE_HEAD").path) {
            return .merge
        }
        if fileManager.fileExists(atPath: directory.appendingPathComponent("CHERRY_PICK_HEAD").path) {
            return .cherryPick
        }
        if fileManager.fileExists(atPath: directory.appendingPathComponent("REVERT_HEAD").path) {
            return .revert
        }
        if fileManager.fileExists(atPath: directory.appendingPathComponent("BISECT_LOG").path) {
            return .bisect
        }
        return nil
    }

    public static func webURL(forOrigin origin: String) -> URL? {
        let trimmed = origin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var candidate = trimmed
        if let range = candidate.range(of: "://") {
            candidate = String(candidate[range.upperBound...])
            if let at = candidate.firstIndex(of: "@") {
                candidate = String(candidate[candidate.index(after: at)...])
            }
        } else if let separator = candidate.firstIndex(of: ":"), candidate.contains("@") {
            let hostStart = candidate.index(after: candidate.firstIndex(of: "@")!)
            let host = candidate[hostStart..<separator]
            let path = candidate[candidate.index(after: separator)...]
            candidate = "\(host)/\(path)"
        }

        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if candidate.hasSuffix(".git") {
            candidate.removeLast(4)
        }
        return URL(string: "https://\(candidate)")
    }

    public static func repositoryName(origin: String, fallbackPath: String) -> String {
        if let url = webURL(forOrigin: origin), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return URL(fileURLWithPath: fallbackPath).lastPathComponent
    }

    public static func projectIconPath(in repositoryPath: String) -> String? {
        let root = URL(fileURLWithPath: repositoryPath).standardizedFileURL
        let fileManager = FileManager.default
        let exactPaths = [
            "favicon.ico", "favicon.svg", "favicon.png",
            "public/favicon.ico", "public/favicon.svg", "public/favicon.png",
            "static/favicon.ico", "static/favicon.svg", "static/favicon.png",
            "app/favicon.ico", "app/favicon.svg", "app/favicon.png",
            "src/app/favicon.ico", "src/app/favicon.svg", "src/app/favicon.png",
            "assets/favicon.ico", "assets/favicon.svg", "assets/favicon.png",
            "src/assets/favicon.ico", "src/assets/favicon.svg", "src/assets/favicon.png",
            "public/apple-touch-icon.png", "public/apple-touch-icon-precomposed.png"
        ]

        for relativePath in exactPaths {
            let candidate = root.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return candidate.path
            }
        }

        let ignoredDirectories: Set<String> = [
            ".build", ".git", ".next", "Pods", "build", "dist", "node_modules", "vendor"
        ]
        let rankedNames = [
            "favicon.ico": 0,
            "favicon.svg": 1,
            "favicon.png": 2,
            "apple-touch-icon.png": 3,
            "apple-touch-icon-precomposed.png": 4
        ]
        let maximumDepth = 4
        let maximumVisitedItems = 2_500
        var visitedItems = 0
        var matches: [(rank: Int, depth: Int, path: String)] = []

        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        let rootDepth = root.pathComponents.count
        while let item = enumerator.nextObject() as? URL, visitedItems < maximumVisitedItems {
            visitedItems += 1
            let depth = item.pathComponents.count - rootDepth
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])

            if values?.isDirectory == true {
                if depth >= maximumDepth || ignoredDirectories.contains(item.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard depth <= maximumDepth,
                  values?.isRegularFile == true,
                  let rank = rankedNames[item.lastPathComponent.lowercased()] else { continue }
            matches.append((rank, depth, item.standardizedFileURL.path))
        }

        return matches.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            return $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending
        }.first?.path
    }
}

public struct WorktreeRecord: Equatable, Sendable {
    public var path: String
    public var head: String = ""
    public var branchReference: String?
    public var isDetached = false
    public var isLocked = false

    public init(path: String) {
        self.path = path
    }
}

public struct GitStatus: Equatable, Sendable {
    public var branch = ""
    public var upstream: String?
    public var staged = 0
    public var unstaged = 0
    public var untracked = 0
    public var conflicted = 0
    public var changedFiles = 0
    public var ahead = 0
    public var behind = 0

    public init() {}
}
