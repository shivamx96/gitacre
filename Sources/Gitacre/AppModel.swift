import AppKit
import Combine
import Foundation
import GitacreCore
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    private static let bundleIdentifier = "com.shivamx96.gitacre"
    private static let legacyBundleIdentifier = "dev.shivam.gitacre"
    private static let legacyDefaultsMigrationKey = "didMigrateDefaultsFromDevBundleIdentifier"

    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var githubSnapshot = GitHubSnapshot(authentication: .cliMissing)
    @Published private(set) var isLoadingRepositories = false
    @Published private(set) var isLoadingGitHub = false
    @Published private(set) var hasLoadedRepositories = false
    @Published private(set) var terminalApplications: [TerminalApplication] = []
    @Published private(set) var lastRepositoryRefresh: Date?
    @Published private(set) var isLaunchAtLoginEnabled: Bool

    @Published var roots: [String] { didSet { save(roots, for: Keys.roots) } }
    @Published var preferredGitHubCLIPath: String { didSet { save(preferredGitHubCLIPath, for: Keys.ghPath) } }
    @Published var preferredTerminalApplicationID: String { didSet { save(preferredTerminalApplicationID, for: Keys.terminalID) } }
    @Published var customTerminalApplicationPath: String { didSet { save(customTerminalApplicationPath, for: Keys.customTerminalPath) } }
    @Published var maximumScanDepth: Int { didSet { save(maximumScanDepth, for: Keys.maximumScanDepth) } }
    @Published var includeWorktrees: Bool { didSet { save(includeWorktrees, for: Keys.includeWorktrees) } }
    @Published var ignoredPathNames: String { didSet { save(ignoredPathNames, for: Keys.ignoredPathNames) } }
    @Published var appearance: GitacreAppearance { didSet { save(appearance.rawValue, for: Keys.appearance) } }
    @Published var menuBarDisplayMode: MenuBarDisplayMode { didSet { save(menuBarDisplayMode.rawValue, for: Keys.menuBarDisplayMode) } }
    @Published var dimIconWhenIdle: Bool { didSet { save(dimIconWhenIdle, for: Keys.dimIconWhenIdle) } }
    @Published var refreshAutomatically: Bool {
        didSet { save(refreshAutomatically, for: Keys.refreshAutomatically); configureTimers() }
    }
    @Published var showReviewRequests: Bool { didSet { save(showReviewRequests, for: Keys.showReviewRequests) } }
    @Published var showAuthoredPullRequests: Bool { didSet { save(showAuthoredPullRequests, for: Keys.showAuthoredPullRequests) } }
    @Published var showDraftPullRequests: Bool { didSet { save(showDraftPullRequests, for: Keys.showDraftPullRequests) } }
    @Published var githubOrganizations: String { didSet { save(githubOrganizations, for: Keys.githubOrganizations) } }
    @Published var pollPullRequests: Bool {
        didSet { save(pollPullRequests, for: Keys.pollPullRequests); configureTimers() }
    }
    @Published var notifyReviewRequests: Bool { didSet { save(notifyReviewRequests, for: Keys.notifyReviewRequests) } }

    private var repositoryRefreshTimer: AnyCancellable?
    private var pullRequestRefreshTimer: AnyCancellable?
    private var knownReviewRequestIDs = Set<String>()

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

        refreshTerminalApplications()
        configureTimers()
        Task { [weak self] in await self?.refreshAll() }
    }

    var pendingRepositories: [Repository] { repositories.filter(\.hasPendingWork) }
    var pendingCount: Int { pendingRepositories.count }
    var reviewCount: Int { visiblePullRequests.filter { $0.kind == .reviewRequested }.count }
    var attentionCount: Int { pendingCount + reviewCount }

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

    func refreshAll() async {
        async let repositories: Void = refreshRepositories()
        async let github: Void = refreshGitHub()
        _ = await (repositories, github)
    }

    func refreshRepositories() async {
        guard !isLoadingRepositories else { return }
        isLoadingRepositories = true
        let scannedRoots = roots
        let depth = maximumScanDepth
        let includesWorktrees = includeWorktrees
        let ignored = ignoredDirectories
        let result = await Task.detached(priority: .utility) {
            RepositoryScanner(
                maximumDepth: depth,
                includeLinkedWorktrees: includesWorktrees,
                ignoredDirectoryNames: ignored
            ).scan(roots: scannedRoots)
        }.value
        repositories = result
        lastRepositoryRefresh = Date()
        isLoadingRepositories = false
        hasLoadedRepositories = true
    }

    func refreshGitHub() async {
        guard !isLoadingGitHub else { return }
        isLoadingGitHub = true
        let preferredPath = preferredGitHubCLIPath.isEmpty ? nil : preferredGitHubCLIPath
        let cacheURL = Self.githubCacheURL()
        let snapshot = await Task.detached(priority: .utility) {
            GitHubCLIService().loadPullRequests(preferredPath: preferredPath, cacheURL: cacheURL)
        }.value

        if notifyReviewRequests, githubSnapshot.fetchedAt != nil {
            notifyAboutNewReviews(in: snapshot.pullRequests)
        }
        knownReviewRequestIDs = Set(snapshot.pullRequests.filter { $0.kind == .reviewRequested }.map(\.id))
        githubSnapshot = snapshot
        isLoadingGitHub = false
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
        Task { await refreshRepositories() }
    }

    func removeRepositoryRoot(_ path: String) {
        roots.removeAll { $0 == path }
        Task { await refreshRepositories() }
    }

    func moveRoots(from source: IndexSet, to destination: Int) {
        roots.move(fromOffsets: source, toOffset: destination)
        Task { await refreshRepositories() }
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

    func copyDiagnostics() {
        let report = [
            applicationVersion,
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Repositories: \(repositories.count)",
            "Roots: \(roots.count)",
            "GitHub: \(githubStatusSummary)",
            "Terminal: \(selectedTerminalApplication?.name ?? "None")"
        ].joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
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
        repositoryRefreshTimer?.cancel()
        pullRequestRefreshTimer?.cancel()
        if refreshAutomatically {
            repositoryRefreshTimer = Timer.publish(every: 60, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in Task { await self?.refreshRepositories() } }
        }
        if pollPullRequests {
            pullRequestRefreshTimer = Timer.publish(every: 300, on: .main, in: .common)
                .autoconnect()
                .sink { [weak self] _ in Task { await self?.refreshGitHub() } }
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
