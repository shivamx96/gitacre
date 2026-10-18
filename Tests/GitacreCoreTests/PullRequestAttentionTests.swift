import XCTest
@testable import GitacreCore

final class PullRequestAttentionTests: XCTestCase {
    func testCanonicalIdentityIncludesOwnerAndHost() {
        XCTAssertEqual(identity("https://github.com/Owner/Repo.git"), identity("https://github.com/owner/repo"))
        XCTAssertNotEqual(identity("https://github.com/one/repo"), identity("https://github.com/two/repo"))
        XCTAssertNotEqual(identity("https://github.com/one/repo"), identity("https://git.example.com/one/repo"))
        XCTAssertEqual(identity(RepositoryScanner.webURL(forOrigin: "git@github.com:Owner/Repo.git")!.absoluteString), identity("https://github.com/owner/repo"))
    }

    func testReadyRequiresApprovalGreenChecksAndCleanMergeState() throws {
        var request = pr()
        request.details = try details()
        XCTAssertEqual(request.attentionReasons, ["Ready to merge"])
        request.details = try details(mergeState: "BLOCKED")
        XCTAssertFalse(request.attentionReasons.contains("Ready to merge"))
        request.details = try details(checks: "[]")
        XCTAssertFalse(request.attentionReasons.contains("Ready to merge"))
        request.details = try details(checks: #"[{"status":"IN_PROGRESS","conclusion":null}]"#)
        XCTAssertEqual(request.attentionReasons, ["Checks pending"])
        request.details = try details(review: "CHANGES_REQUESTED", checks: #"[{"state":"FAILURE"}]"#)
        XCTAssertEqual(request.attentionReasons, ["Checks failing", "Changes requested"])
    }

    func testForkBranchNeverMatchesBaseRepositoryByNameAlone() throws {
        var request = pr()
        request.details = try details(head: "fork/project")
        let base = repository(owner: "base", sha: "other")
        let fork = repository(owner: "fork", sha: "other")
        XCTAssertTrue(request.matchingWorktrees(in: [base]).isEmpty)
        XCTAssertEqual(request.matchingWorktrees(in: [base, fork]).map(\.id), ["fork"])
    }

    func testSHAMatchingPreservesAmbiguity() throws {
        var request = pr()
        request.details = try details(head: "fork/project")
        let matches = request.matchingWorktrees(in: [repository(owner: "base"), repository(owner: "fork")])
        XCTAssertEqual(matches.count, 2)
        XCTAssertTrue(request.matchingWorktrees(in: [repository(owner: "unrelated")]).isEmpty)
    }

    func testDetailsBecomeStaleWhenPRChanges() throws {
        var request = pr()
        request.details = try details()
        request.detailsFetchedAt = Date(timeIntervalSince1970: 1)
        XCTAssertTrue(request.detailsAreStale)
        XCTAssertTrue(request.attentionSummary.contains("cached"))
    }

    private func identity(_ value: String) -> RepositoryIdentity? { RepositoryIdentity(url: URL(string: value)) }
    private func pr() -> PullRequest {
        PullRequest(id: "1", number: 1, title: "Test", url: URL(string: "https://github.com/base/project/pull/1")!, repository: "base/project", author: "me", isDraft: false, updatedAt: Date(), comments: 0, kind: .authored)
    }
    private func details(head: String = "base/project", review: String = "APPROVED", mergeState: String = "CLEAN", checks: String = #"[{"status":"COMPLETED","conclusion":"SUCCESS"}]"#) throws -> PullRequestDetails {
        let json = """
        {"headRefName":"feature","headRefOid":"abc","headRepository":{"nameWithOwner":"\(head)"},"baseRefName":"main","reviewDecision":"\(review)","mergeStateStatus":"\(mergeState)","mergeable":"MERGEABLE","statusCheckRollup":\(checks)}
        """
        return try JSONDecoder().decode(PullRequestDetails.self, from: Data(json.utf8))
    }
    private func repository(owner: String, sha: String = "abc") -> Repository {
        Repository(id: owner, name: "project", commonDirectory: "/\(owner)/.git", remoteURL: URL(string: "https://github.com/\(owner)/project"), worktrees: [Worktree(id: owner, path: "/\(owner)", branch: "feature", head: sha, isDetached: false, isPrimary: true, isLocked: false, staged: 0, unstaged: 0, untracked: 0, conflicted: 0, changedFiles: 0, ahead: 0, behind: 0, upstream: nil, operation: nil, lastCommitDate: nil)], stashCount: 0)
    }
}
