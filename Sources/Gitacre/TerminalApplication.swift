import AppKit
import Foundation

struct TerminalApplication: Identifiable, Equatable {
    enum LaunchStyle: Equatable {
        case openDirectory
        case ghostty
        case alacritty
        case kitty
        case wezTerm
    }

    let id: String
    let name: String
    let bundleIdentifier: String?
    let url: URL
    let launchStyle: LaunchStyle

    var abbreviatedPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    func open(directory: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")

        switch launchStyle {
        case .openDirectory:
            if let bundleIdentifier {
                process.arguments = ["-b", bundleIdentifier, directory]
            } else {
                process.arguments = ["-a", url.path, directory]
            }
        case .ghostty:
            process.arguments = ["-na", url.path, "--args", "--working-directory=\(directory)"]
        case .alacritty:
            process.arguments = ["-na", url.path, "--args", "--working-directory", directory]
        case .kitty:
            process.arguments = ["-na", url.path, "--args", "--directory", directory]
        case .wezTerm:
            process.arguments = ["-na", url.path, "--args", "start", "--cwd", directory]
        }

        do {
            try process.run()
        } catch {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }
}

enum TerminalApplicationDiscovery {
    private struct Candidate {
        let name: String
        let bundleIdentifiers: [String]
        let applicationNames: [String]
        let explicitPaths: [String]
        let launchStyle: TerminalApplication.LaunchStyle
    }

    private static let candidates: [Candidate] = [
        Candidate(
            name: "Terminal",
            bundleIdentifiers: ["com.apple.Terminal"],
            applicationNames: ["Terminal"],
            explicitPaths: ["/System/Applications/Utilities/Terminal.app"],
            launchStyle: .openDirectory
        ),
        Candidate(
            name: "iTerm2",
            bundleIdentifiers: ["com.googlecode.iterm2"],
            applicationNames: ["iTerm", "iTerm2"],
            explicitPaths: [],
            launchStyle: .openDirectory
        ),
        Candidate(
            name: "Ghostty",
            bundleIdentifiers: ["com.mitchellh.ghostty"],
            applicationNames: ["Ghostty"],
            explicitPaths: [],
            launchStyle: .ghostty
        ),
        Candidate(
            name: "Warp",
            bundleIdentifiers: ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview"],
            applicationNames: ["Warp", "Warp Preview"],
            explicitPaths: [],
            launchStyle: .openDirectory
        ),
        Candidate(
            name: "Alacritty",
            bundleIdentifiers: ["org.alacritty"],
            applicationNames: ["Alacritty"],
            explicitPaths: [],
            launchStyle: .alacritty
        ),
        Candidate(
            name: "kitty",
            bundleIdentifiers: ["net.kovidgoyal.kitty"],
            applicationNames: ["kitty"],
            explicitPaths: [],
            launchStyle: .kitty
        ),
        Candidate(
            name: "WezTerm",
            bundleIdentifiers: ["com.github.wez.wezterm"],
            applicationNames: ["WezTerm"],
            explicitPaths: [],
            launchStyle: .wezTerm
        ),
        Candidate(
            name: "Rio",
            bundleIdentifiers: ["com.raphaelamorim.rio"],
            applicationNames: ["Rio"],
            explicitPaths: [],
            launchStyle: .openDirectory
        ),
        Candidate(
            name: "Hyper",
            bundleIdentifiers: ["co.zeit.hyper"],
            applicationNames: ["Hyper"],
            explicitPaths: [],
            launchStyle: .openDirectory
        ),
        Candidate(
            name: "Tabby",
            bundleIdentifiers: ["org.tabby"],
            applicationNames: ["Tabby"],
            explicitPaths: [],
            launchStyle: .openDirectory
        ),
        Candidate(
            name: "Wave Terminal",
            bundleIdentifiers: ["dev.waveterm", "dev.commandline.waveterm"],
            applicationNames: ["Wave", "Wave Terminal"],
            explicitPaths: [],
            launchStyle: .openDirectory
        )
    ]

    static func discover(customApplicationPath: String?) -> [TerminalApplication] {
        var applications: [TerminalApplication] = []
        var discoveredPaths = Set<String>()

        for candidate in candidates {
            guard let url = locate(candidate) else { continue }
            let standardizedPath = url.standardizedFileURL.path
            guard discoveredPaths.insert(standardizedPath).inserted else { continue }
            let bundle = Bundle(url: url)
            applications.append(
                TerminalApplication(
                    id: bundle?.bundleIdentifier ?? candidate.bundleIdentifiers.first ?? standardizedPath,
                    name: displayName(for: url, fallback: candidate.name),
                    bundleIdentifier: bundle?.bundleIdentifier ?? candidate.bundleIdentifiers.first,
                    url: url,
                    launchStyle: candidate.launchStyle
                )
            )
        }

        if let customApplicationPath, !customApplicationPath.isEmpty {
            let url = URL(fileURLWithPath: customApplicationPath).standardizedFileURL
            if FileManager.default.fileExists(atPath: url.path), discoveredPaths.insert(url.path).inserted {
                let bundle = Bundle(url: url)
                applications.append(
                    TerminalApplication(
                        id: bundle?.bundleIdentifier ?? url.path,
                        name: displayName(for: url, fallback: url.deletingPathExtension().lastPathComponent),
                        bundleIdentifier: bundle?.bundleIdentifier,
                        url: url,
                        launchStyle: .openDirectory
                    )
                )
            }
        }

        return applications
    }

    private static func locate(_ candidate: Candidate) -> URL? {
        for bundleIdentifier in candidate.bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
                return url.standardizedFileURL
            }
        }

        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        let applicationDirectories = [URL(fileURLWithPath: "/Applications"), homeApplications]
        let possiblePaths = candidate.explicitPaths.map(URL.init(fileURLWithPath:)) + applicationDirectories.flatMap { directory in
            candidate.applicationNames.map { directory.appendingPathComponent("\($0).app") }
        }

        return possiblePaths.first { FileManager.default.fileExists(atPath: $0.path) }?.standardizedFileURL
    }

    private static func displayName(for url: URL, fallback: String) -> String {
        guard let bundle = Bundle(url: url) else { return fallback }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? fallback
    }
}
