import AppKit
import Combine
import Foundation
import GitacreCore
import ServiceManagement
import UserNotifications
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    private static let bundleIdentifier = "com.shivamx96.gitacre"
    private static let legacyBundleIdentifier = "dev.shivam.gitacre"
    private static let legacyDefaultsMigrationKey = "didMigrateDefaultsFromDevBundleIdentifier"

    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var discoveryIssues: [RepositoryDiscoveryIssue] = []
    @Published private(set) var githubSnapshot = GitHubSnapshot(authentication: .cliMissing)
    @Published private(set) var isLoadingRepositories = false
    @Published private(set) var isLoadingGitHub = false
    @Published private(set) var hasLoadedRepositories = false
    @Published private(set) var terminalApplications: [TerminalApplication] = []
    @Published private(set) var lastRepositoryRefresh: Date?
    @Published private(set) var isRepositorySnapshotStale = true
    private var watcher: RepositoryWatcher?
    private var discoveryDebounce = DiscoveryDebounce()
    private var pendingDiscovery: Task<Void, Never>?
    private var lastGitHubSuccess: Date?
    private var initialFilesystemPaths = Set<String>()
    private var initialFilesystemRescan = false
    private var watchedPaths: [String] = []
    private var wakeObserver: AnyCancellable?
    private var sleepObserver: AnyCancellable?
    private var discoveryTimer: AnyCancellable?
    private var lastRefreshDuration: TimeInterval = 0
    private var repositoryGeneration = 0
    private var githubGeneration = 0
    private var githubRefreshPending = false
    private var githubActiveRequestID: UInt64?
    /// The earliest refresh queued behind the active one; the follow-up runs under its ID.
    private var githubQueuedContext: DiagnosticContext?
    private var enrichingPRs = Set<String>()
    private var attemptedDetails: [String: Date] = [:]
    @Published var notifyPRTransitions = UserDefaults.standard.bool(forKey: "notifyPRTransitions") {
        didSet { UserDefaults.standard.set(notifyPRTransitions, forKey: "notifyPRTransitions") }
    }
    private var snapshotWriter: Task<Void, Never>?

    private var scanConfiguration: ScanConfiguration {
        ScanConfiguration(roots: roots, maximumDepth: maximumScanDepth,
            includeLinkedWorktrees: includeWorktrees, ignoredDirectoryNames: ignoredDirectories)
    }

    private static var localCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.shivamx96.gitacre/local-snapshot.json")
    }

    private func configurationChanged() {
        repositoryGeneration += 1
        isRepositorySnapshotStale = true
        recordConfiguration()
        Task { await refreshRepositories(trigger: .configuration) }
    }

    private func recordConfiguration() {
        PerformanceDiagnostics.shared.record(DiagnosticEvent(.configuration, count: roots.count,
            automaticRefresh: refreshAutomatically, githubPolling: pollPullRequests))
    }

    @Published private(set) var isLaunchAtLoginEnabled: Bool
    @Published private(set) var isGlobalShortcutRegistered = false

    @Published var roots: [String] { didSet { save(roots, for: Keys.roots); configurationChanged() } }
    @Published var preferredGitHubCLIPath: String { didSet { save(preferredGitHubCLIPath, for: Keys.ghPath); githubConfigurationChanged() } }
    @Published var preferredTerminalApplicationID: String { didSet { save(preferredTerminalApplicationID, for: Keys.terminalID) } }
    @Published var customTerminalApplicationPath: String { didSet { save(customTerminalApplicationPath, for: Keys.customTerminalPath) } }
    @Published var maximumScanDepth: Int { didSet { save(maximumScanDepth, for: Keys.maximumScanDepth); configurationChanged() } }
    @Published var includeWorktrees: Bool { didSet { save(includeWorktrees, for: Keys.includeWorktrees); configurationChanged() } }
    @Published var ignoredPathNames: String { didSet { save(ignoredPathNames, for: Keys.ignoredPathNames); configurationChanged() } }
    @Published var appearance: GitacreAppearance { didSet { save(appearance.rawValue, for: Keys.appearance) } }
    @Published var menuBarDisplayMode: MenuBarDisplayMode { didSet { save(menuBarDisplayMode.rawValue, for: Keys.menuBarDisplayMode) } }
    @Published var dimIconWhenIdle: Bool { didSet { save(dimIconWhenIdle, for: Keys.dimIconWhenIdle) } }
    @Published var refreshAutomatically: Bool {
        didSet { save(refreshAutomatically, for: Keys.refreshAutomatically); configureTimers() }
    }
    @Published var showReviewRequests: Bool { didSet { save(showReviewRequests, for: Keys.showReviewRequests) } }
    @Published var showAuthoredPullRequests: Bool { didSet { save(showAuthoredPullRequests, for: Keys.showAuthoredPullRequests) } }
    @Published var showDraftPullRequests: Bool { didSet { save(showDraftPullRequests, for: Keys.showDraftPullRequests) } }
    @Published var githubOrganizations: String { didSet { save(githubOrganizations, for: Keys.githubOrganizations); githubConfigurationChanged() } }
    @Published var pollPullRequests: Bool {
        didSet { save(pollPullRequests, for: Keys.pollPullRequests); configureTimers() }
    }
    @Published var notifyReviewRequests: Bool { didSet { save(notifyReviewRequests, for: Keys.notifyReviewRequests) } }

    private var repositoryRefreshTimer: AnyCancellable?
    private var pullRequestRefreshTimer: AnyCancellable?
    private var knownReviewRequestIDs = Set<String>()
    private var repositoryRefreshCount = 0
    private let repositoryWorker = RepositoryRefreshWorker()
    private lazy var repositoryRefresh = RefreshCoordinator<RepositoryRefreshRequest, RepositoryRefreshOutcome>(
        coalesce: { $0.coalescing($1) },
        covers: { $0.covers($1) },
        observe: { kind, request, related, count in
            PerformanceDiagnostics.shared.record(DiagnosticEvent(kind, context: request.diagnostics,
                discovery: request.scope.isDiscovery, count: count, relatedRequestID: related?.diagnostics?.id))
        },
        perform: { [repositoryWorker] request in
            await repositoryWorker.run(request)
        }
    )

    private enum Keys {
        static let roots = "repositoryRoots"
        static let ghPath = "preferredGitHubCLIPath"
        static let terminalID = "preferredTerminalApplicationID"
        static let customTerminalPath = "customTerminalApplicationPath"
        static let maximumScanDepth = "maximumScanDepth"
        static let includeWorktrees = "includeWorktrees"
        static let ignoredPathNames = "ignoredPathNames"
        static let appearance = "appearance"
        static let menuBarDisplayMode = "menuBarDisplayMode"
        static let dimIconWhenIdle = "dimIconWhenIdle"
        static let refreshAutomatically = "refreshAutomatically"
        static let showReviewRequests = "showReviewRequests"
        static let showAuthoredPullRequests = "showAuthoredPullRequests"
        static let showDraftPullRequests = "showDraftPullRequests"
        static let githubOrganizations = "githubOrganizations"
        static let pollPullRequests = "pollPullRequests"
        static let notifyReviewRequests = "notifyReviewRequests"
    }

    init() {
        Self.migrateLegacyDefaultsIfNeeded()
        let defaults = UserDefaults.standard
        let savedRoots = defaults.stringArray(forKey: Keys.roots) ?? []
        roots = savedRoots.isEmpty ? Self.defaultRoots() : savedRoots
        preferredGitHubCLIPath = defaults.string(forKey: Keys.ghPath) ?? ""
        preferredTerminalApplicationID = defaults.string(forKey: Keys.terminalID) ?? ""
        customTerminalApplicationPath = defaults.string(forKey: Keys.customTerminalPath) ?? ""
        maximumScanDepth = defaults.object(forKey: Keys.maximumScanDepth) == nil ? 3 : defaults.integer(forKey: Keys.maximumScanDepth)
        includeWorktrees = defaults.object(forKey: Keys.includeWorktrees) == nil ? true : defaults.bool(forKey: Keys.includeWorktrees)
        ignoredPathNames = defaults.string(forKey: Keys.ignoredPathNames) ?? "node_modules, .build, vendor"
        appearance = GitacreAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        menuBarDisplayMode = MenuBarDisplayMode(rawValue: defaults.string(forKey: Keys.menuBarDisplayMode) ?? "") ?? .glyphAndCount
        dimIconWhenIdle = defaults.object(forKey: Keys.dimIconWhenIdle) == nil ? true : defaults.bool(forKey: Keys.dimIconWhenIdle)
        refreshAutomatically = defaults.object(forKey: Keys.refreshAutomatically) == nil ? true : defaults.bool(forKey: Keys.refreshAutomatically)
        showReviewRequests = defaults.object(forKey: Keys.showReviewRequests) == nil ? true : defaults.bool(forKey: Keys.showReviewRequests)
        showAuthoredPullRequests = defaults.object(forKey: Keys.showAuthoredPullRequests) == nil ? true : defaults.bool(forKey: Keys.showAuthoredPullRequests)
        showDraftPullRequests = defaults.object(forKey: Keys.showDraftPullRequests) == nil ? true : defaults.bool(forKey: Keys.showDraftPullRequests)
        githubOrganizations = defaults.string(forKey: Keys.githubOrganizations) ?? ""
        pollPullRequests = defaults.object(forKey: Keys.pollPullRequests) == nil ? true : defaults.bool(forKey: Keys.pollPullRequests)
        notifyReviewRequests = defaults.bool(forKey: Keys.notifyReviewRequests)
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled

        if let cached = LocalSnapshot.read(at: Self.localCacheURL, configuration: scanConfiguration) {
            repositories = cached.repositories
            discoveryIssues = cached.discoveryIssues ?? []
            hasLoadedRepositories = true
            lastRepositoryRefresh = cached.fetchedAt
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.isRepositorySnapshotStale = true
                PerformanceDiagnostics.shared.record(DiagnosticEvent(.wake))
                if self.refreshAutomatically { Task { await self.refreshAll(scope: .status(), trigger: .wake) } }
            }
        sleepObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { _ in PerformanceDiagnostics.shared.record(DiagnosticEvent(.sleep)) }
        refreshTerminalApplications()
        configureTimers()
        Task { [weak self] in await self?.refreshAll(trigger: .startup) }
    }

    var remoteAttentionRepositoryIDs: Set<String> {
        Set(repositories.filter { repository in
            pullRequests(repository: repository).contains { !$0.attentionReasons.isEmpty }
        }.map(\.id))
    }
    var pendingRepositories: [Repository] {
        let remote = remoteAttentionRepositoryIDs
        return repositories.filter { $0.needsAttention || remote.contains($0.id) }
    }
    var pendingCount: Int { pendingRepositories.count + discoveryIssues.count }
    var reviewCount: Int { visiblePullRequests.filter { $0.kind == .reviewRequested }.count }
    var attentionCount: Int {
        pendingCount + visiblePullRequests.filter { request in
            guard !request.attentionReasons.isEmpty else { return false }
            return request.matchingWorktrees(in: repositories).count != 1
        }.count
    }

    var visiblePullRequests: [PullRequest] {
        let organizations = Set(
            githubOrganizations
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        return githubSnapshot.pullRequests.filter { pullRequest in
            if pullRequest.kind == .reviewRequested && !showReviewRequests { return false }
            if pullRequest.kind == .authored && !showAuthoredPullRequests { return false }
            if pullRequest.isDraft && !showDraftPullRequests { return false }
            guard !organizations.isEmpty else { return true }
            let owner = pullRequest.repository.split(separator: "/").first.map(String.init)?.lowercased()
            return owner.map(organizations.contains) ?? false
        }
    }

    var selectedTerminalApplication: TerminalApplication? {
        terminalApplications.first { $0.id == preferredTerminalApplicationID }
            ?? terminalApplications.first { $0.bundleIdentifier == "com.apple.Terminal" }
            ?? terminalApplications.first
    }

    var ignoredDirectories: Set<String> {
        Set(ignoredPathNames.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty })
    }

    var applicationVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "gitacre \(version) (build \(build))"
    }

    /// Refreshes repositories and GitHub together.
    ///
    /// Defaults to discovery so every explicit "refresh" control picks up newly cloned
    /// repositories. Ambient callers that fire on their own — opening the popover —
    /// pass `.status()` to avoid re-walking the monitored roots each time.
    func refreshAll(scope: RepositoryRefreshScope = .discovery, trigger: RefreshTrigger = .manual) async {
        async let repositories: Void = refreshRepositories(scope: scope, trigger: trigger)
        async let github: Void = refreshGitHub(trigger: trigger)
        _ = await (repositories, github)
    }

    /// Discovers repositories under monitored roots, or re-reads status for known ones.
    ///
    /// Overlapping calls coalesce into one follow-up instead of being dropped. A result
    /// is published only when no newer request has superseded it.
    func refreshRepositories(scope: RepositoryRefreshScope = .discovery, trigger: RefreshTrigger = .manual, diagnostics: DiagnosticContext? = nil) async {
        if trigger == .panel && !BackgroundRefreshPolicy.needsPanelRefresh(
            lastSuccess: lastRepositoryRefresh, maximumAge: 30, stale: isRepositorySnapshotStale) { return }
        repositoryGeneration += 1
        let generation = repositoryGeneration
        let started = Date()
        let resolved = resolvedScope(scope)
        if resolved.isDiscovery {
            discoveryDebounce.didStartDiscovery(at: ProcessInfo.processInfo.systemUptime)
            pendingDiscovery?.cancel()
            pendingDiscovery = nil
        }
        let diagnosticContext = diagnostics ?? PerformanceDiagnostics.shared.context(trigger: trigger)
        PerformanceDiagnostics.shared.record(DiagnosticEvent(.requested, context: diagnosticContext, discovery: resolved.isDiscovery))
        repositoryRefreshCount += 1
        isLoadingRepositories = true
        defer {
            repositoryRefreshCount -= 1
            if repositoryRefreshCount == 0 {
                isLoadingRepositories = false
            }
        }

        let request = RepositoryRefreshRequest(
            configuration: ScanConfiguration(
                roots: roots,
                maximumDepth: maximumScanDepth,
                includeLinkedWorktrees: includeWorktrees,
                ignoredDirectoryNames: ignoredDirectories
            ),
            scope: resolved,
            knownRepositories: resolved.isDiscovery ? [] : repositories,
            diagnostics: diagnosticContext
        )
        let outcome = await repositoryRefresh.submit(request)
        guard !Task.isCancelled, generation == repositoryGeneration, request.configuration == scanConfiguration else {
            PerformanceDiagnostics.shared.record(DiagnosticEvent(.publicationSkipped, context: diagnosticContext))
            return
        }
        PerformanceDiagnostics.shared.record(DiagnosticEvent(.published, context: outcome.diagnostics,
            duration: ProcessInfo.processInfo.systemUptime - (outcome.diagnostics?.since ?? diagnosticContext.since),
            count: outcome.repositories.count, changed: repositories != outcome.repositories))

        if outcome.scope.isDiscovery {
            RepositoryIconCache.shared.invalidate()
        }
        repositories = outcome.repositories
        discoveryIssues = outcome.discoveryIssues
        lastRepositoryRefresh = Date()
        hasLoadedRepositories = true
        isRepositorySnapshotStale = false
        lastRefreshDuration = Date().timeIntervalSince(started)
        configureWatcher()
        // Events received while discovery had no baseline must not wait for the
        // discovery cooldown if they affect a repository we have just found.
        if !initialFilesystemPaths.isEmpty || initialFilesystemRescan {
            let batch = BackgroundRefreshPolicy.batch(paths: initialFilesystemPaths,
                rescan: initialFilesystemRescan, repositories: repositories)
            initialFilesystemPaths.removeAll()
            initialFilesystemRescan = false
            if let scope = batch.statusScope {
                Task { await self.refreshRepositories(scope: scope, trigger: .filesystem) }
            }
        }
        let cacheURL = Self.localCacheURL
        let snapshot = LocalSnapshot(configuration: scanConfiguration, repositories: repositories, fetchedAt: lastRepositoryRefresh!, discoveryIssues: discoveryIssues)
        let previousWriter = snapshotWriter
        snapshotWriter = Task.detached(priority: .utility) {
            await previousWriter?.value
            snapshot.write(to: cacheURL)
        }
    }

    /// Status refreshes have nothing to work from until the first discovery finishes.
    private func resolvedScope(_ scope: RepositoryRefreshScope) -> RepositoryRefreshScope {
        if case .status = scope, !hasLoadedRepositories {
            return .discovery
        }
        return scope
    }

    private func githubConfigurationChanged() {
        githubGeneration += 1
        lastGitHubSuccess = nil
        githubSnapshot = GitHubSnapshot(authentication: .cliMissing)
        attemptedDetails.removeAll()
        Task { await refreshGitHub(trigger: .configuration) }
    }

    /// Loads pull requests through the GitHub CLI.
    ///
    /// Only one load runs at a time. Calls that arrive while one is active collapse into a
    /// single follow-up, recorded as `githubQueued`; that follow-up runs under the earliest
    /// queued request's ID so its latency counts from the first caller.
    func refreshGitHub(trigger: RefreshTrigger = .manual) async {
        if trigger == .panel && !BackgroundRefreshPolicy.needsPanelRefresh(lastSuccess: lastGitHubSuccess, maximumAge: 120) { return }
        let diagnostics = PerformanceDiagnostics.shared
        if isLoadingGitHub {
            let context = diagnostics.context(trigger: trigger)
            diagnostics.record(DiagnosticEvent(.githubQueued, context: context, relatedRequestID: githubActiveRequestID))
            if githubQueuedContext == nil { githubQueuedContext = context }
            githubRefreshPending = true
            return
        }
        isLoadingGitHub = true
        defer { isLoadingGitHub = false; githubActiveRequestID = nil; githubQueuedContext = nil }
        var context = diagnostics.context(trigger: trigger)
        diagnostics.record(DiagnosticEvent(.githubRequested, context: context))
        repeat {
            if let queued = githubQueuedContext { context = queued; githubQueuedContext = nil }
            githubRefreshPending = false
            githubActiveRequestID = context.id
            let generation = githubGeneration
            let preferredPath = preferredGitHubCLIPath.isEmpty ? nil : preferredGitHubCLIPath
            let cacheURL = Self.githubCacheURL()
            let organizations = githubOrganizations.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let local = repositories
            let started = ProcessInfo.processInfo.systemUptime
            let counter = DiagnosticCommandCounter()
            let input = context
            let snapshot: GitHubSnapshot = await Task.detached(priority: .utility) {
                DiagnosticContext.$current.withValue(input) {
                    DiagnosticCommandCounter.$current.withValue(counter) {
                        GitHubCLIService().loadPullRequests(preferredPath: preferredPath, cacheURL: cacheURL,
                            organizations: organizations, localRepositories: local)
                    }
                }
            }.value
            diagnostics.record(DiagnosticEvent(.githubCompleted, context: context,
                duration: ProcessInfo.processInfo.systemUptime - started, count: snapshot.pullRequests.count,
                failed: snapshot.errorMessage != nil || snapshot.authentication.login == nil, commandCount: counter.count))
            guard generation == githubGeneration, !Task.isCancelled else {
                diagnostics.record(DiagnosticEvent(.githubSkipped, context: context))
                continue
            }
            let sameAccount = githubSnapshot.authentication.login == snapshot.authentication.login
            if sameAccount, snapshot.errorMessage == nil {
                if notifyReviewRequests, githubSnapshot.fetchedAt != nil { notifyAboutNewReviews(in: snapshot.pullRequests) }
                if notifyPRTransitions { notifyTransitions(from: githubSnapshot.pullRequests, to: snapshot.pullRequests) }
            }
            knownReviewRequestIDs = Set(snapshot.pullRequests.filter { $0.kind == .reviewRequested }.map(\.id))
            diagnostics.record(DiagnosticEvent(.githubPublished, context: context,
                duration: ProcessInfo.processInfo.systemUptime - context.since, count: snapshot.pullRequests.count,
                changed: !sameAccount || githubSnapshot.pullRequests != snapshot.pullRequests))
            githubSnapshot = snapshot
            if snapshot.errorMessage == nil, snapshot.authentication.login != nil {
                lastGitHubSuccess = Date()
            }
        } while githubRefreshPending && !Task.isCancelled
    }

    func enrichVisiblePullRequest(_ request: PullRequest) async {
        guard request.details == nil || request.detailsAreStale,
              let executable = githubSnapshot.authentication.executable,
              !enrichingPRs.contains(request.id), enrichingPRs.count < 4,
              Date().timeIntervalSince(attemptedDetails[request.id] ?? .distantPast) > 300 else { return }
        let generation = githubGeneration
        let login = githubSnapshot.authentication.login
        enrichingPRs.insert(request.id)
        attemptedDetails[request.id] = Date()
        defer { enrichingPRs.remove(request.id) }
        let context = PerformanceDiagnostics.shared.context(trigger: .detail)
        let details = await Task.detached(priority: .utility) {
            DiagnosticContext.$current.withValue(context) { GitHubCLIService().loadDetails(for: request, executable: executable) }
        }.value
        guard generation == githubGeneration, login == githubSnapshot.authentication.login,
              let details, !Task.isCancelled,
              let index = githubSnapshot.pullRequests.firstIndex(where: { $0.id == request.id && $0.updatedAt == request.updatedAt }) else { return }
        var rows = githubSnapshot.pullRequests
        rows[index].details = details
        rows[index].detailsFetchedAt = Date()
        githubSnapshot = GitHubSnapshot(authentication: githubSnapshot.authentication, pullRequests: rows,
            fetchedAt: githubSnapshot.fetchedAt, errorMessage: githubSnapshot.errorMessage)
    }

    func pullRequests(repository: Repository, worktree: Worktree? = nil) -> [PullRequest] {
        githubSnapshot.pullRequests.filter { request in
            let matches = request.matchingWorktrees(in: repositories)
            return matches.count == 1 && matches.contains { match in
                worktree.map { $0.id == match.id } ?? repository.worktrees.contains { $0.id == match.id }
            }
        }
    }

    func requestTransitionNotifications(_ enabled: Bool) {
        notifyPRTransitions = enabled
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            if !granted { Task { @MainActor in self?.notifyPRTransitions = false } }
        }
    }

    private func notifyTransitions(from old: [PullRequest], to new: [PullRequest]) {
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for request in new {
            guard let prior = previous[request.id], prior.details != nil,
                  !request.detailsAreStale, request.details != nil else { continue }
            let changes = Set(request.attentionReasons).subtracting(prior.attentionReasons)
                .intersection(["Checks failing", "Changes requested", "Ready to merge"])
            guard !changes.isEmpty else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(request.repository) #\(request.number)"
            content.body = changes.sorted().joined(separator: " · ")
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "transition:" + request.id, content: content, trigger: nil))
        }
    }

    func addRepositoryRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose folders containing Git repositories"
        panel.prompt = "Monitor"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK else { return }
        addRepositoryRoots(panel.urls.map { $0.standardizedFileURL.path })
    }

    func addRepositoryRoots(_ paths: [String]) {
        let additions = paths.compactMap { path -> String? in
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            return url.path
        }
        guard !additions.isEmpty else { return }
        roots = Array(Set(roots + additions)).sorted()
        Task { await refreshRepositories(trigger: .configuration) }
    }

    func removeRepositoryRoot(_ path: String) {
        roots.removeAll { $0 == path }
        Task { await refreshRepositories(trigger: .configuration) }
    }

    func moveRoots(from source: IndexSet, to destination: Int) {
        roots.move(fromOffsets: source, toOffset: destination)
        Task { await refreshRepositories(trigger: .configuration) }
    }

    func chooseGitHubCLI() {
        let panel = NSOpenPanel()
        panel.title = "Choose the GitHub CLI executable"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return }
        preferredGitHubCLIPath = panel.url?.path ?? ""
        Task { await refreshGitHub() }
    }

    func resetGitHubCLIPath() {
        preferredGitHubCLIPath = ""
        Task { await refreshGitHub() }
    }

    func selectTerminalApplication(_ id: String) {
        guard terminalApplications.contains(where: { $0.id == id }) else { return }
        preferredTerminalApplicationID = id
    }

    func refreshTerminalApplications() {
        terminalApplications = TerminalApplicationDiscovery.discover(customApplicationPath: customTerminalApplicationPath)
    }

    func chooseTerminalApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose a terminal application"
        panel.prompt = "Use Terminal"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, url.pathExtension.lowercased() == "app" else { return }
        customTerminalApplicationPath = url.standardizedFileURL.path
        refreshTerminalApplications()
        if let application = terminalApplications.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            preferredTerminalApplicationID = application.id
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSSound.beep()
        }
        isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setGlobalShortcutRegistered(_ registered: Bool) {
        isGlobalShortcutRegistered = registered
    }

    func requestReviewNotifications(_ enabled: Bool) {
        notifyReviewRequests = enabled
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted {
                Task { @MainActor [weak self] in self?.notifyReviewRequests = false }
            }
        }
    }

    func clearRepositoryCache() {
        guard let url = Self.githubCacheURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func copyDiagnostics(updateSummary: String = "Update state unavailable") {
        let report = [
            applicationVersion,
            ProcessDiagnostics.shared.summary,
            updateSummary,
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Repositories: \(repositories.count)",
            "Roots: \(roots.count)",
            "Local snapshot stale: \(isRepositorySnapshotStale)",
            "Last refresh duration: \(String(format: "%.2fs", lastRefreshDuration))",
            "Discovery issues: \(discoveryIssues.count)",
            "Repositories with scan failures: \(repositories.filter { $0.scanFailure != nil }.count)",
            "Shortcut registered: \(isGlobalShortcutRegistered)",
            "GitHub cached/error: \(githubSnapshot.errorMessage != nil)",
            "GitHub refresh age: \(githubSnapshot.fetchedAt.map { String(Int(Date().timeIntervalSince($0))) + "s" } ?? "never")",
            "GitHub: \(githubStatusSummary)",
            "Terminal: \(selectedTerminalApplication?.name ?? "None")"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    func exportPerformanceDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "gitacre-performance.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PerformanceDiagnostics.shared.exportJSON().write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openTerminal(at path: String) {
        if let selectedTerminalApplication {
            selectedTerminalApplication.open(directory: path)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }

    func copyAndOpenTerminal(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        openTerminal(at: FileManager.default.homeDirectoryForCurrentUser.path)
    }

    var githubStatusSummary: String {
        switch githubSnapshot.authentication {
        case .cliMissing: "gh not found"
        case .signedOut: "not authenticated"
        case let .signedIn(_, login): "connected as \(login)"
        case .unavailable: "temporarily unavailable"
        }
    }

    private func configureTimers() {
        recordConfiguration()
        repositoryRefreshTimer?.cancel()
        discoveryTimer?.cancel()
        configureWatcher()
        pullRequestRefreshTimer?.cancel()
        if refreshAutomatically {
            repositoryRefreshTimer = Timer.publish(every: 60, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in
                    guard let self, self.watcher?.isActive != true else { return }
                    self.configureWatcher()
                    Task { await self.refreshRepositories(scope: .status(), trigger: .statusTimer) }
                }
            discoveryTimer = Timer.publish(every: 900, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in Task { await self?.refreshRepositories(trigger: .discoveryTimer) } }
        }
        if pollPullRequests {
            pullRequestRefreshTimer = Timer.publish(every: 300, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in Task { await self?.refreshGitHub(trigger: .githubTimer) } }
        }
    }

    private func configureWatcher() {
        let paths = refreshAutomatically ? Array(Set(roots + repositories.flatMap { [$0.commonDirectory] + $0.worktrees.map(\.path) })).sorted() : []
        if !refreshAutomatically { pendingDiscovery?.cancel(); pendingDiscovery = nil }
        guard paths != watchedPaths || watcher?.isActive != true else { return }
        watchedPaths = paths
        watcher = RepositoryWatcher(paths: paths) { [weak self] paths, rescan in
            let context = PerformanceDiagnostics.shared.context(trigger: .filesystem)
            Task { @MainActor in
                guard let self else { return }
                guard self.refreshAutomatically else { return }
                let batch = BackgroundRefreshPolicy.batch(paths: paths, rescan: rescan, repositories: self.repositories)
                RepositoryIconCache.shared.invalidate(paths: batch.paths)
                let insideGitDirectory = paths.filter { $0.contains("/.git/") || $0.hasSuffix("/.git") }.count
                PerformanceDiagnostics.shared.record(DiagnosticEvent(.filesystem, context: context,
                    discovery: batch.needsDiscovery, count: paths.count, insideGitDirectory: insideGitDirectory,
                    rescan: rescan, unmatched: batch.unmatched, ignored: batch.ignored,
                    refreshed: batch.statusScope != nil))
                if batch.needsDiscovery { self.scheduleFilesystemDiscovery() }
                if !self.hasLoadedRepositories {
                    self.initialFilesystemPaths.formUnion(batch.paths)
                    self.initialFilesystemRescan = self.initialFilesystemRescan || rescan
                } else if let scope = batch.statusScope {
                    await self.refreshRepositories(scope: scope, trigger: .filesystem, diagnostics: context)
                }
            }
        }
    }

    private func scheduleFilesystemDiscovery() {
        guard pendingDiscovery == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let due = discoveryDebounce.request(at: now)
        pendingDiscovery = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, due - now))) } catch { return }
            guard let self, self.refreshAutomatically else { return }
            self.pendingDiscovery = nil
            await self.refreshRepositories(trigger: .filesystem)
        }
    }

    private func notifyAboutNewReviews(in pullRequests: [PullRequest]) {
        for pullRequest in pullRequests where pullRequest.kind == .reviewRequested && !knownReviewRequestIDs.contains(pullRequest.id) {
            let content = UNMutableNotificationContent()
            content.title = "Review requested in \(pullRequest.repository)"
            content.body = pullRequest.title
            content.sound = .default
            let request = UNNotificationRequest(identifier: pullRequest.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func save(_ value: Any, for key: String) { UserDefaults.standard.set(value, forKey: key) }

    private static func migrateLegacyDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyDefaultsMigrationKey) else { return }

        if let legacyDefaults = defaults.persistentDomain(forName: legacyBundleIdentifier) {
            for (key, value) in legacyDefaults where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        defaults.set(true, forKey: legacyDefaultsMigrationKey)
    }

    private static func defaultRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Developer", "Projects", "IdeaProjects"]
            .map { home.appendingPathComponent($0).path }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    static func githubCacheURL() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("pull-requests.json")
    }
}
