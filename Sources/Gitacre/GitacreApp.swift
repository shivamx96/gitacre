import GitacreCore
import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    static let closeGitacrePanel = Notification.Name("closeGitacrePanel")
}

@main
enum GitacreApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = GitacreAppDelegate()
        // AppKit owns all windows. A placeholder SwiftUI Settings scene can
        // otherwise surface an empty window when the menu-bar app activates.
        application.setActivationPolicy(.accessory)
        application.delegate = delegate
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class GitacreAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let updates = UpdateController()

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var globalShortcut: GlobalShortcutRegistrar?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = GitacreIconRenderer.applicationIcon()
        configureApplicationMenu()
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        globalShortcut?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "gitacre")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)

        applicationMenu.addItem(withTitle: "About gitacre", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        let settingsItem = applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        NSApp.servicesMenu = servicesMenu
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Hide gitacre", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = applicationMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        applicationMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit gitacre", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Keep standard text-editing shortcuts in the hosted SwiftUI views.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
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
            .environmentObject(updates)
        )
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "gitacre"
        statusItem = item
        updateStatusItem()
    }

    private func observeModel() {
        updates.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
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
        globalShortcut = GlobalShortcutRegistrar(definition: .showGitacre) { [weak self] in
            self?.showPopover()
        }
        model.setGlobalShortcutRegistered(globalShortcut != nil)
        updateStatusItem()
    }

    @objc private func togglePopover() {
        if popover.isShown { closePopover() }
        else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            PerformanceDiagnostics.shared.record(DiagnosticEvent(.panelOpened))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if model.refreshAutomatically { Task { await model.refreshAll(scope: .status(), trigger: .panel) } }
        }
    }

    @objc private func closePopover() { popover.performClose(nil) }

    @objc private func showSettings() {
        closePopover()
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: GitacreSettingsView().environmentObject(model).environmentObject(updates))
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
        let updateAvailable = updates.state.release != nil
        if updateAvailable { button.title += " ↑" }
        button.alphaValue = model.dimIconWhenIdle && model.attentionCount == 0 && !updateAvailable ? 0.58 : 1
        button.toolTip = model.isGlobalShortcutRegistered
            ? "gitacre — \(GlobalShortcutDefinition.showGitacre.label)"
            : "gitacre"
        if updateAvailable { button.toolTip = (button.toolTip ?? "gitacre") + " — Update available" }
        button.setAccessibilityLabel(menuBarAccessibilityLabel + (updateAvailable ? ", update available" : ""))
    }

    private var menuBarAccessibilityLabel: String {
        model.attentionCount == 0
            ? "gitacre, no pending work"
            : "gitacre, \(model.attentionCount) items need attention"
    }
}

extension GitacreAppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        PerformanceDiagnostics.shared.record(DiagnosticEvent(.panelClosed))
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
