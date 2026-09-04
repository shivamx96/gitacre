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
        guard result.succeeded else {
            return .signedOut(executable: executable)
        }

        guard let data = result.standardOutput.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AuthEnvelope.self, from: data),
              let account = envelope.hosts["github.com"]?.first(where: { $0.active && $0.state == "success" }),
              !account.login.isEmpty else {
            return .unavailable(executable: executable, message: "Could not read the active GitHub account")
        }

        return .signedIn(executable: executable, login: account.login)
    }

    public func loadPullRequests(
        preferredPath: String? = nil,
        cacheURL: URL? = nil
    ) -> GitHubSnapshot {
        let authentication = authentication(preferredPath: preferredPath)
        guard case let .signedIn(executable, login) = authentication else {
            return GitHubSnapshot(authentication: authentication)
        }

        let fields = "number,title,url,repository,author,isDraft,updatedAt,commentsCount"
        let authored = runner.run(
            executable: executable,
            arguments: [
                "search", "prs", "--author=@me", "--state=open", "--limit", "50",
                "--json", fields
            ]
        )
        let reviews = runner.run(
            executable: executable,
            arguments: [
                "search", "prs", "--review-requested=@me", "--state=open", "--limit", "50",
                "--json", fields
            ]
        )

        guard authored.succeeded, reviews.succeeded,
              let authoredRows = decodePullRequests(authored.standardOutput, kind: .authored),
              let reviewRows = decodePullRequests(reviews.standardOutput, kind: .reviewRequested) else {
            let message = firstUsefulError(authored.standardError, reviews.standardError)
                ?? "GitHub could not be reached"
            if let cache = readCache(at: cacheURL) {
                return GitHubSnapshot(
                    authentication: authentication,
                    pullRequests: cache.pullRequests,
                    fetchedAt: cache.fetchedAt,
                    errorMessage: message
                )
            }
            return GitHubSnapshot(authentication: authentication, errorMessage: message)
        }

        let pullRequests = (reviewRows.filter { $0.author.caseInsensitiveCompare(login) != .orderedSame }
            + authoredRows)
            .sorted { $0.updatedAt > $1.updatedAt }
        let fetchedAt = Date()
        writeCache(CachePayload(fetchedAt: fetchedAt, pullRequests: pullRequests), to: cacheURL)

        return GitHubSnapshot(
            authentication: authentication,
            pullRequests: pullRequests,
            fetchedAt: fetchedAt
        )
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
    let fetchedAt: Date
    let pullRequests: [PullRequest]
}
