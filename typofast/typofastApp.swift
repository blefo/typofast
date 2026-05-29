import SwiftUI
import AppKit

@main
struct typofastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

/// Borderless panels return `false` from `canBecomeKey` by default, which prevents text fields
/// (the personalization editor) from receiving keyboard focus. Forcing it lets the settings UI
/// be edited while keeping the panel non-activating during normal inline-suggestion use.
final class SettingsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private lazy var globalController = GlobalSuggestionController(appState: appState)
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            globalController.start()
        }
        setupStatusItem()
        setupPanel()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "text.cursor", accessibilityDescription: "Typofast")
            button.action = #selector(togglePanel)
            button.target = self
        }
        statusItem = item
    }

    private func setupPanel() {
        let hostingView = NSHostingView(rootView: ContentView(appState: appState))
        let panelSize = NSSize(width: 320, height: 460)
        let panel = SettingsPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.collectionBehavior = [.transient, .canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.contentView = hostingView
        self.panel = panel
    }

    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            return
        }
        positionPanel(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        panel?.orderOut(nil)
    }
}

extension AppDelegate {
    private func positionPanel(_ panel: NSPanel) {
        guard let button = statusItem?.button else { return }
        guard let buttonWindow = button.window else {
            positionPanelOnMainScreen(panel)
            return
        }
        let buttonRect = buttonWindow.convertToScreen(button.frame)
        let panelSize = panel.frame.size
        let targetScreen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? .zero
        let menuBarBottom = visibleFrame.maxY
        let origin = NSPoint(
            x: buttonRect.midX - (panelSize.width / 2),
            y: menuBarBottom - panelSize.height
        )
        panel.setFrameOrigin(origin)
    }

    private func positionPanelOnMainScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - (panelSize.width / 2),
            y: visibleFrame.maxY - panelSize.height
        )
        panel.setFrameOrigin(origin)
    }
}
