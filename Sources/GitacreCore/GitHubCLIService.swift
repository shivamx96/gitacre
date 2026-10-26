import Foundation

public struct GitHubCLIService: Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) {
        self.runner = runner
    }

    public func locateExecutable(preferredPath: String? = nil) -> String? {
        var candidates: [String] = []
        if let preferredPath, !preferredPath.isEmpty {
            candidates.append(preferredPath)
        }

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/gh" })
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/opt/local/bin/gh"
        ])

        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func authentication(preferredPath: String? = nil) -> GitHubAuthentication {
        guard let executable = locateExecutable(preferredPath: preferredPath) else {
            return .cliMissing
        }

        let result = runner.run(
            executable: executable,
            arguments: ["auth", "status", "--active", "--hostname", "github.com", "--json", "hosts"]
        )
        // In JSON mode gh reports account issues in the payload; a nonzero exit can
        // instead be a timeout, launch failure, or transport error. Do not send users
        // through login again when the account could not be checked.
        guard result.succeeded else {
            if result.terminationStatus == 1,
               result.standardError.lowercased().contains("not logged into any github hosts") {
                return .signedOut(executable: executable)
            }
            return .unavailable(executable: executable, message: "Could not verify your GitHub account. Check your connection and retry.")
        }

        guard let data = result.standardOutput.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: data) else {
            return .unavailable(executable: executable, message: "Could not read the active GitHub account")
        }
        guard let accounts = envelope.hosts["github.com"], !accounts.isEmpty else {
            return .signedOut(executable: executable)
        }
        guard let account = accounts.first(where: { $0.active && $0.state == "success" }),
              !account.login.isEmpty else {
            return .unavailable(executable: executable, message: "Could not verify the active GitHub account. Check gh auth status and retry.")
        }

        return .signedIn(executable: executable, login: account.login)
    }

    public func loadPullRequests(
        preferredPath: String? = nil,
        cacheURL: URL? = nil,
        organizations: [String] = [],
        localRepositories: [Repository] = []
    ) -> GitHubSnapshot {
        let authentication = authentication(preferredPath: preferredPath)
        guard case let .signedIn(executable, login) = authentication else {
            // Do not show another account's cached private data when identity is unknown.
            return GitHubSnapshot(authentication: authentication)
        }
        let scope = organizations.map { $0.lowercased() }.sorted()
        let cache = readCache(at: cacheURL).flatMap { $0.login == login && $0.organizations == scope ? $0 : nil }
        let fields = "number,title,url,repository,author,isDraft,updatedAt,commentsCount"
        var rows: [PullRequest] = []
        var warnings: [String] = []
        var failedKinds = Set<PullRequest.Kind>()
        for kind in [PullRequest.Kind.reviewRequested, .authored] {
            var arguments = ["search", "prs", kind == .authored ? "--author=@me" : "--review-requested=@me",
                             "--state=open", "--limit", "1000", "--json", fields]
            for owner in scope { arguments += ["--owner", owner] }
            let result = runner.run(executable: executable, arguments: arguments)
            if result.succeeded, let decoded = decodePullRequests(result.standardOutput, kind: kind) {
                rows += decoded
                if decoded.count >= 1000 { warnings.append("Search reached GitHub's 1,000-result limit; narrow the organization filter.") }
            } else {
                failedKinds.insert(kind)
                warnings.append("Some pull requests could not be refreshed; cached results are shown where available.")
                rows += cache?.pullRequests.filter { $0.kind == kind } ?? []
            }
        }
        var seen = Set<String>()
        rows = rows.filter { !($0.kind == .reviewRequested && $0.author.caseInsensitiveCompare(login) == .orderedSame) }
            .filter { seen.insert($0.url.absoluteString).inserted }
            .sorted { $0.updatedAt > $1.updatedAt }
        let cachedRows = Dictionary((cache?.pullRequests ?? []).map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        for index in rows.indices {
            if let old = cachedRows[rows[index].url] {
                rows[index].details = old.details
                rows[index].detailsFetchedAt = old.detailsFetchedAt
            }
        }
        let identities = Set(localRepositories.compactMap { RepositoryIdentity(url: $0.remoteURL) })
        // Bound work to 24 details per poll. Visible rows can request details on demand.
        let candidates = rows.indices.filter { !failedKinds.contains(rows[$0].kind) && (rows[$0].details == nil || rows[$0].detailsAreStale) }
            .sorted {
                let left = rows[$0].repositoryIdentity.map(identities.contains) ?? false
                let right = rows[$1].repositoryIdentity.map(identities.contains) ?? false
                if left != right { return left }
                return (rows[$0].detailsFetchedAt ?? .distantPast) < (rows[$1].detailsFetchedAt ?? .distantPast)
            }.prefix(24)
        let detailIndices = Array(candidates)
        let enrichmentStarted = Date()
        for start in stride(from: 0, to: detailIndices.count, by: 4) {
            if Date().timeIntervalSince(enrichmentStarted) > 20 { break }
            let batch = detailIndices[start..<min(start + 4, detailIndices.count)].map { ($0, rows[$0]) }
            let results = RepositoryScanner.concurrentMap(batch) { item in
                (item.0, loadDetails(for: item.1, executable: executable))
            }
            for (index, details) in results {
                if let details {
                    rows[index].details = details
                    rows[index].detailsFetchedAt = Date()
                } else {
                    warnings.append("Some PR checks and reviews could not be refreshed.")
                }
            }
        }
        let currentAccount = self.authentication(preferredPath: preferredPath)
        guard currentAccount == authentication else {
            return GitHubSnapshot(authentication: currentAccount, errorMessage: "GitHub account changed during refresh. Refresh again to load its pull requests.")
        }
        let fetchedAt = failedKinds.isEmpty ? Date() : cache?.fetchedAt
        // Failed refreshes never advance the freshness of cached lists.
        writeCache(CachePayload(login: login, organizations: scope, fetchedAt: fetchedAt, pullRequests: rows), to: cacheURL)
        return GitHubSnapshot(authentication: authentication, pullRequests: rows, fetchedAt: fetchedAt,
            errorMessage: warnings.isEmpty ? nil : Array(Set(warnings)).sorted().joined(separator: " "))
    }

    public func loadDetails(for pullRequest: PullRequest, executable: String) -> PullRequestDetails? {
        guard pullRequest.url.scheme == "https", pullRequest.url.host == "github.com" else { return nil }
        let result = runner.run(executable: executable, arguments: ["pr", "view", pullRequest.url.absoluteString,
            "--json", "headRefName,headRefOid,headRepository,baseRefName,reviewDecision,mergeStateStatus,mergeable,statusCheckRollup"])
        guard result.succeeded, let data = result.standardOutput.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PullRequestDetails.self, from: data)
    }

    private func decodePullRequests(_ output: String, kind: PullRequest.Kind) -> [PullRequest]? {
        guard let data = output.data(using: .utf8),
              let rows = try? JSONDecoder().decode([RawPullRequest].self, from: data) else {
            return nil
        }

        return rows.compactMap { row in
            guard let url = URL(string: row.url),
                  let updatedAt = Self.date(from: row.updatedAt) else {
                return nil
            }
            let repository = row.repository.nameWithOwner ?? row.repository.name ?? "Repository"
            return PullRequest(
                id: "\(kind.rawValue):\(repository):\(row.number)",
                number: row.number,
                title: row.title,
                url: url,
                repository: repository,
                author: row.author?.login ?? "",
                isDraft: row.isDraft,
                updatedAt: updatedAt,
                comments: row.commentsCount,
                kind: kind
            )
        }
    }

    private func firstUsefulError(_ errors: String...) -> String? {
        errors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .map { $0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0 }
    }

    private func readCache(at url: URL?) -> CachePayload? {
        guard let url,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CachePayload.self, from: data)
    }

    private func writeCache(_ payload: CachePayload, to url: URL?) {
        guard let url, let data = try? JSONEncoder().encode(payload) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
    }

    private static func date(from value: String) -> Date? {
        fractionalDateFormatter.date(from: value) ?? dateFormatter.date(from: value)
    }

    private static let dateFormatter = ISO8601DateFormatter()

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private struct AuthEnvelope: Decodable {
    let hosts: [String: [AuthAccount]]
}

private struct AuthAccount: Decodable {
    let state: String
    let active: Bool
    let login: String
}

private struct RawPullRequest: Decodable {
    struct Repository: Decodable {
        let nameWithOwner: String?
        let name: String?
    }

    struct Author: Decodable {
        let login: String
    }

    let number: Int
    let title: String
    let url: String
    let repository: Repository
    let author: Author?
    let isDraft: Bool
    let updatedAt: String
    let commentsCount: Int
}

private struct CachePayload: Codable {
    let login: String
    let organizations: [String]
    let fetchedAt: Date?
    let pullRequests: [PullRequest]
}
