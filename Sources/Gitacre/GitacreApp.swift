import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let closeGitacrePanel = Notification.Name("closeGitacrePanel")
    static let openGitacreSettings = Notification.Name("openGitacreSettings")
}

@main
struct GitacreApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: GitacreAppDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        NotificationCenter.default.post(name: .openGitacreSettings, object: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}

@MainActor
final class GitacreAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var globalShortcutMonitor: Any?
    private var localShortcutMonitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = GitacreIconRenderer.applicationIcon()
        configurePopover()
        configureStatusItem()
        configureGlobalShortcut()
        observeModel()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(closePopover),
            name: .closeGitacrePanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsFromNotification),
            name: .openGitacreSettings,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let globalShortcutMonitor { NSEvent.removeMonitor(globalShortcutMonitor) }
        if let localShortcutMonitor { NSEvent.removeMonitor(localShortcutMonitor) }
        NotificationCenter.default.removeObserver(self)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false
        popover.contentSize = NSSize(width: 392, height: 540)
        popover.contentViewController = NSHostingController(
            rootView: GitacrePanel(
                onOpenSettings: { [weak self] in self?.showSettings() },
                onQuit: { NSApp.terminate(nil) }
            )
            .environmentObject(model)
        )
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "gitacre — ⌥⌘G"
        statusItem = item
        updateStatusItem()
    }

    private func observeModel() {
        Publishers.CombineLatest4(model.$repositories, model.$githubSnapshot, model.$menuBarDisplayMode, model.$dimIconWhenIdle)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.updateStatusItem() }
            .store(in: &cancellables)

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)

        model.$appearance
            .receive(on: RunLoop.main)
            .sink { [weak self] appearance in self?.applyAppearance(appearance) }
            .store(in: &cancellables)
    }

    private func applyAppearance(_ appearance: GitacreAppearance) {
        let appAppearance: NSAppearance? = switch appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        popover.appearance = appAppearance
        settingsWindow?.appearance = appAppearance
    }

    private func configureGlobalShortcut() {
        globalShortcutMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isGlobalShortcut(event) else { return }
            Task { @MainActor in self?.showPopover() }
        }
        localShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isGlobalShortcut(event) else { return event }
            self?.showPopover()
            return nil
        }
    }

    private static func isGlobalShortcut(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == "g"
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.option, .command]
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover() }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if model.refreshAutomatically { Task { await model.refreshAll() } }
        }
    }

    @objc private func closePopover() { popover.performClose(nil) }

    private func showSettings() {
        closePopover()
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: GitacreSettingsView().environmentObject(model))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 660, height: 472),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "gitacre Settings"
            window.titlebarSeparatorStyle = .line
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            settingsWindow = window
            applyAppearance(model.appearance)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openSettingsFromNotification() { showSettings() }

    func windowWillClose(_ notification: Notification) {
        NSApp.hide(nil)
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = GitacreIconRenderer.menuBarIcon()
        button.imagePosition = .imageLeft
        button.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        button.title = model.menuBarDisplayMode == .glyphAndCount && model.attentionCount > 0
            ? " \(model.attentionCount)"
            : ""
        button.alphaValue = model.dimIconWhenIdle && model.attentionCount == 0 ? 0.58 : 1
        button.setAccessibilityLabel(menuBarAccessibilityLabel)
    }

    private var menuBarAccessibilityLabel: String {
        model.attentionCount == 0
            ? "gitacre, no pending work"
            : "gitacre, \(model.attentionCount) items need attention"
    }
}

extension GitacreAppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        if settingsWindow?.isVisible != true { NSApp.hide(nil) }
    }
}

enum GitacreIconRenderer {
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            drawBranch(in: rect.insetBy(dx: 2.3, dy: 1.8), color: .labelColor, lineWidth: 1.65)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "gitacre"
        return image
    }

    static func applicationIcon() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 2, dy: 2), xRadius: 115, yRadius: 115)
            NSColor(red: 74 / 255, green: 88 / 255, blue: 196 / 255, alpha: 1).setFill()
            tile.fill()
            NSColor.white.withAlphaComponent(0.04).setStroke()
            tile.lineWidth = 1
            tile.stroke()
            drawBranch(in: rect.insetBy(dx: 128, dy: 122).offsetBy(dx: 0, dy: 6), color: .white, lineWidth: 26)
            return true
        }
    }

    private static func drawBranch(in rect: NSRect, color: NSColor, lineWidth: CGFloat) {
        let trunkX = rect.minX + rect.width * 0.34
        let bottom = rect.minY + rect.height * 0.14
        let middle = rect.minY + rect.height * 0.50
        let top = rect.minY + rect.height * 0.86
        let spurX = rect.minX + rect.width * 0.72

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: trunkX, y: bottom))
        path.line(to: NSPoint(x: trunkX, y: top))
        path.move(to: NSPoint(x: trunkX, y: middle))
        path.curve(
            to: NSPoint(x: spurX, y: top),
            controlPoint1: NSPoint(x: spurX, y: middle),
            controlPoint2: NSPoint(x: spurX, y: top)
        )
        color.setStroke()
        path.stroke()

        let radius = lineWidth * 1.23
        for point in [NSPoint(x: trunkX, y: bottom), NSPoint(x: trunkX, y: top), NSPoint(x: spurX, y: top)] {
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)).fill()
        }
    }
}
