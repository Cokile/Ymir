import AppKit
import Foundation
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let manager = CopilotAPIManager()
    private var statusTimer: Timer?

    private let statusMenuItem = NSMenuItem(title: "Gateway: Checking…", action: nil, keyEquivalent: "")
    private let signInMenuItem = NSMenuItem(title: "Sign In to Copilot", action: #selector(authLogin), keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "Start Gateway", action: #selector(startGateway), keyEquivalent: "s")
    private let stopMenuItem = NSMenuItem(title: "Stop Gateway", action: #selector(stopGateway), keyEquivalent: ".")
    private let restartMenuItem = NSMenuItem(title: "Restart Gateway", action: #selector(restartGateway), keyEquivalent: "r")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private struct AgentSettings {
        let title: String
        let relativePath: String
    }

    private static let agentSettings: [AgentSettings] = [
        AgentSettings(title: "Codex Settings", relativePath: ".codex/config.toml"),
        AgentSettings(title: "Claude Code Settings", relativePath: ".claude/settings.json")
    ]

    private let usageViewerMenuItem = NSMenuItem(title: "View Usage", action: #selector(openUsageViewer), keyEquivalent: "u")
    private lazy var agentSettingsMenuItems: [NSMenuItem] = Self.agentSettings.map { settings in
        let item = NSMenuItem(title: settings.title, action: #selector(openAgentSettings), keyEquivalent: "")
        item.representedObject = settings.relativePath
        return item
    }
    private lazy var agentSettingsMenu: NSMenu = {
        let menu = NSMenu(title: "Agent Settings")
        agentSettingsMenuItems.forEach { menu.addItem($0) }
        return menu
    }()
    private lazy var agentSettingsSubmenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Agent Settings", action: nil, keyEquivalent: "")
        item.submenu = agentSettingsMenu
        return item
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        configureStatusItem()
        configureMenu()
        refreshStatus()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        manager.requestStop()
    }

    private func configureStatusItem() {
        statusItem.length = NSStatusItem.variableLength
        statusItem.isVisible = true
        statusItem.button?.image = nil
        statusItem.button?.attributedTitle = NSAttributedString(string: "Ymir", attributes: [.foregroundColor: NSColor.white])
        statusItem.button?.toolTip = "Ymir - copilot-api"
        statusItem.menu = menu
        NSLog("Ymir status item configured")
    }

    private static func menuBarIcon() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()

        NSColor.black.setStroke()
        let circle = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15))
        circle.lineWidth = 1.8
        circle.stroke()

        let mark = NSBezierPath()
        mark.lineWidth = 2.2
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: 5, y: 12.5))
        mark.line(to: NSPoint(x: 9, y: 8.5))
        mark.line(to: NSPoint(x: 13, y: 12.5))
        mark.move(to: NSPoint(x: 9, y: 8.5))
        mark.line(to: NSPoint(x: 9, y: 4.2))
        mark.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        usageViewerMenuItem.isEnabled = false
        signInMenuItem.target = self
        startMenuItem.target = self
        stopMenuItem.target = self
        restartMenuItem.target = self
        launchAtLoginMenuItem.target = self
        usageViewerMenuItem.target = self
        agentSettingsMenuItems.forEach { $0.target = self }

        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(signInMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(restartMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(usageViewerMenuItem)
        menu.addItem(NSMenuItem(title: "Gateway Settings", action: #selector(openCopilotAPIConfig), keyEquivalent: ",", target: self))
        menu.addItem(agentSettingsSubmenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q", target: self))

        updateLaunchAtLoginState()
        updateSignInState()
        updateConfigMenuItemVisibility()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateConfigMenuItemVisibility()
    }

    @objc private func startGateway() {
        manager.requestStart()
        notify(title: "Ymir", body: "copilot-api is starting.")
        refreshStatus()
    }

    @objc private func stopGateway() {
        manager.requestStop()
        notify(title: "Ymir", body: "copilot-api stopped.")
        refreshStatus()
    }

    @objc private func restartGateway() {
        manager.requestRestart()
        notify(title: "Ymir", body: "copilot-api is restarting.")
        refreshStatus()
    }

    @objc private func authLogin() {
        do {
            try manager.authLogin()
            notify(title: "Ymir", body: "Opening copilot-api sign-in in Terminal.")
        } catch {
            notify(title: "Ymir could not start sign-in", body: error.localizedDescription)
        }
    }

    @objc private func openUsageViewer() {
        NSWorkspace.shared.open(URL(string: "http://localhost:4141/usage-viewer?endpoint=http://localhost:4141/usage")!)
    }

    @objc private func openCopilotAPIConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/copilot-api/config.json"))
    }

    @objc private func openAgentSettings(_ sender: NSMenuItem) {
        guard let relativePath = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relativePath))
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            updateLaunchAtLoginState()
        } catch {
            notify(title: "Ymir launch at login failed", body: error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshStatus() {
        manager.checkStatus { [weak self] isRunning in
            DispatchQueue.main.async {
                guard let self else { return }
                let shouldRun = self.manager.shouldBeRunning
                let statusText: String
                if isRunning {
                    statusText = "Gateway: Running on :4141"
                } else if shouldRun {
                    statusText = "Gateway: Starting…"
                } else {
                    statusText = "Gateway: Stopped"
                }
                self.statusMenuItem.title = statusText
                self.statusItem.length = NSStatusItem.variableLength
                self.statusItem.isVisible = true
                self.statusItem.button?.image = nil
                self.statusItem.button?.attributedTitle = NSAttributedString(string: "Ymir", attributes: [.foregroundColor: NSColor.white])
                self.statusItem.button?.toolTip = isRunning ? "Ymir - copilot-api running" : "Ymir - copilot-api stopped"
                let isStarting = shouldRun && !isRunning
                self.startMenuItem.isEnabled = !isRunning && !shouldRun
                self.stopMenuItem.isEnabled = isRunning && !isStarting
                self.restartMenuItem.isEnabled = isRunning && !isStarting
                self.usageViewerMenuItem.isEnabled = isRunning
                self.updateSignInState()
                if let message = self.manager.supervise(isRunning: isRunning) {
                    self.notify(title: "Ymir", body: message)
                }
            }
        }
    }

    private func updateLaunchAtLoginState() {
        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func updateSignInState() {
        let signedIn = manager.isSignedIn()
        signInMenuItem.title = signedIn ? "Copilot Signed In" : "Sign In to Copilot"
        signInMenuItem.isEnabled = !signedIn
    }

    private func updateConfigMenuItemVisibility() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        var hasVisibleAgentSettings = false
        for item in agentSettingsMenuItems {
            guard let relativePath = item.representedObject as? String else {
                item.isHidden = true
                continue
            }
            let configExists = FileManager.default.fileExists(atPath: homeURL.appendingPathComponent(relativePath).path)
            item.isHidden = !configExists
            hasVisibleAgentSettings = hasVisibleAgentSettings || configExists
        }
        agentSettingsSubmenuItem.isHidden = !hasVisibleAgentSettings
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) }
                }
            case .authorized, .provisional:
                center.add(request)
            default:
                NSLog("Ymir: notifications not authorized (status \(settings.authorizationStatus.rawValue)); enable in System Settings > Notifications > Ymir")
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
