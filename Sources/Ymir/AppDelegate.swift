import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let manager = CopilotAPIManager()
    private let account = CopilotAccount()
    private var statusIcon: GatewayStatusIcon?
    private var statusRefreshID = UUID()
    private var statusTimer: Timer?
    private var gatewayAutoStartWorkItem: DispatchWorkItem?

    private let statusMenuItem = NSMenuItem(title: "Gateway: Checking…", action: nil, keyEquivalent: "")
    private let signInMenuItem = NSMenuItem(title: "Sign In to Copilot", action: #selector(authLogin), keyEquivalent: "")
    private let signOutMenuItem = NSMenuItem(title: "Sign Out of Copilot…", action: #selector(authLogout), keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "Start Gateway", action: #selector(startGateway), keyEquivalent: "s")
    private let stopMenuItem = NSMenuItem(title: "Stop Gateway", action: #selector(stopGateway), keyEquivalent: ".")
    private let restartMenuItem = NSMenuItem(title: "Restart Gateway", action: #selector(restartGateway), keyEquivalent: "r")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let startAtLaunchMenuItem = NSMenuItem(title: "Start at Launch", action: #selector(toggleStartAtLaunch), keyEquivalent: "")
    private let modelsMenu = NSMenu(title: "Available Models")
    private lazy var modelsSubmenuItem: NSMenuItem = {
        let item = NSMenuItem(title: "Available Models", action: nil, keyEquivalent: "")
        item.submenu = modelsMenu
        return item
    }()
    private var isLoadingModels = false
    private static let startAtLaunchDefaultsKey = "startAtLaunch"
    private static let gatewayAutoStartDelay: TimeInterval = 2
    private struct AgentSettings {
        let title: String
        let relativePath: String
    }

    private static let agentSettings: [AgentSettings] = [
        AgentSettings(title: "Codex Settings", relativePath: ".codex/config.toml"),
        AgentSettings(title: "Claude Code Settings", relativePath: ".claude/settings.json"),
        AgentSettings(title: "Raycast AI Settings", relativePath: ".config/raycast/ai/providers.yaml")
    ]

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
        if UserDefaults.standard.bool(forKey: Self.startAtLaunchDefaultsKey) {
            let workItem = DispatchWorkItem { [weak self] in
                guard UserDefaults.standard.bool(forKey: Self.startAtLaunchDefaultsKey) else { return }
                self?.manager.requestStart()
                self?.refreshStatus()
            }
            gatewayAutoStartWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.gatewayAutoStartDelay, execute: workItem)
        }
        refreshStatus()
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        statusTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func applicationWillTerminate(_ notification: Notification) {
        gatewayAutoStartWorkItem?.cancel()
        statusTimer?.invalidate()
        manager.requestStop()
    }

    private func configureStatusItem() {
        statusItem.length = NSStatusItem.squareLength
        statusItem.isVisible = true
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.attributedTitle = NSAttributedString()
        if let button = statusItem.button {
            statusIcon = GatewayStatusIcon(button: button)
        }
        statusItem.menu = menu
        NSLog("Ymir status item configured")
    }

    private func configureMenu() {
        menu.delegate = self
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        signInMenuItem.target = self
        signOutMenuItem.target = self
        startMenuItem.target = self
        stopMenuItem.target = self
        restartMenuItem.target = self
        launchAtLoginMenuItem.target = self
        startAtLaunchMenuItem.target = self
        agentSettingsMenuItems.forEach { $0.target = self }

        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(signInMenuItem)
        menu.addItem(signOutMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(restartMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(modelsSubmenuItem)
        menu.addItem(NSMenuItem(title: "Gateway Settings", action: #selector(openCopilotAPIConfig), keyEquivalent: ",", target: self))
        menu.addItem(agentSettingsSubmenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(startAtLaunchMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q", target: self))

        updateLaunchAtLoginState()
        updateStartAtLaunchState()
        account.onChange = { [weak self] in self?.applySignInState() }
        updateSignInState()
        updateConfigMenuItemVisibility()
        updateModelsAvailability(isRunning: false)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateSignInState()
        updateConfigMenuItemVisibility()
        refreshModels()
    }

    @objc private func startGateway() {
        manager.requestStart()
        notify(title: "Ymir", body: "gateway is starting.")
        refreshStatus()
    }

    @objc private func stopGateway() {
        manager.requestStop()
        notify(title: "Ymir", body: "gateway stopped.")
        refreshStatus()
    }

    @objc private func restartGateway() {
        manager.requestRestart()
        notify(title: "Ymir", body: "gateway is restarting.")
        refreshStatus()
    }

    @objc private func authLogin() {
        do {
            try manager.authLogin()
            notify(title: "Ymir", body: "Opening gateway sign-in in Terminal.")
        } catch {
            notify(title: "Ymir could not start sign-in", body: error.localizedDescription)
        }
    }

    @objc private func authLogout() {
        let alert = NSAlert()
        alert.messageText = "Sign Out of Copilot?"
        alert.informativeText = "This will stop the gateway and remove its saved Copilot token. Apps using this gateway will lose access until you sign in and start it again. Your settings will be kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        gatewayAutoStartWorkItem?.cancel()
        gatewayAutoStartWorkItem = nil
        do {
            try manager.authLogout()
            notify(title: "Ymir", body: "Signed out of Copilot.")
        } catch {
            notify(title: "Ymir could not sign out", body: error.localizedDescription)
        }
        updateSignInState()
        refreshStatus()
    }

    @objc private func copyModelID(_ sender: NSMenuItem) {
        guard let modelID = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(modelID, forType: .string)
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

    @objc private func toggleStartAtLaunch() {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: Self.startAtLaunchDefaultsKey), forKey: Self.startAtLaunchDefaultsKey)
        updateStartAtLaunchState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refreshStatus() {
        let refreshID = UUID()
        statusRefreshID = refreshID
        updateGatewayState()
        updateSignInState()
        manager.checkStatus { [weak self] isRunning in
            DispatchQueue.main.async {
                guard let self, self.statusRefreshID == refreshID else { return }
                if let message = self.manager.supervise(isRunning: isRunning) {
                    self.notify(title: "Ymir", body: message)
                }
                self.updateGatewayState()
            }
        }
    }

    private func updateGatewayState() {
        let state = manager.state
        statusMenuItem.title = state.menuTitle
        statusIcon?.update(state)
        startMenuItem.isEnabled = state == .stopped
        stopMenuItem.isEnabled = state != .stopped
        restartMenuItem.isEnabled = state == .running
        updateModelsAvailability(isRunning: state == .running)
    }

    private func refreshModels() {
        guard modelsSubmenuItem.isEnabled, !isLoadingModels else { return }
        isLoadingModels = true
        setModelsMenuMessage("Loading...")
        manager.fetchModels { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoadingModels = false
                switch result {
                case .success(let models):
                    self.modelsSubmenuItem.title = "Available Models (\(models.count))"
                    self.modelsMenu.removeAllItems()
                    if models.isEmpty {
                        self.setModelsMenuMessage("No models available")
                        return
                    }
                    for model in models {
                        let displayName = model.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let title = displayName.flatMap { $0.isEmpty || $0 == model.id ? nil : "\($0) (\(model.id))" } ?? model.id
                        let item = NSMenuItem(title: title, action: #selector(self.copyModelID), keyEquivalent: "")
                        item.representedObject = model.id
                        item.target = self
                        item.toolTip = "Copy \(model.id)"
                        self.modelsMenu.addItem(item)
                    }
                case .failure:
                    self.modelsSubmenuItem.title = "Available Models"
                    self.setModelsMenuMessage("Could not load models")
                }
            }
        }
    }

    private func updateModelsAvailability(isRunning: Bool) {
        modelsSubmenuItem.isEnabled = isRunning
        if !isRunning {
            modelsSubmenuItem.title = "Available Models"
            setModelsMenuMessage("Gateway is not running")
        }
    }

    private func setModelsMenuMessage(_ message: String) {
        modelsMenu.removeAllItems()
        let item = NSMenuItem(title: message, action: nil, keyEquivalent: "")
        item.isEnabled = false
        modelsMenu.addItem(item)
    }

    private func updateLaunchAtLoginState() {
        launchAtLoginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    private func updateStartAtLaunchState() {
        startAtLaunchMenuItem.state = UserDefaults.standard.bool(forKey: Self.startAtLaunchDefaultsKey) ? .on : .off
    }

    private func updateSignInState() {
        account.refresh()
        applySignInState()
    }

    private func applySignInState() {
        signInMenuItem.title = account.menuTitle
        signInMenuItem.isEnabled = !account.isSignedIn
        signOutMenuItem.isEnabled = account.isSignedIn
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

    nonisolated private func notify(title: String, body: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { Self.deliverNotification(title: title, body: body) }
                }
            case .authorized, .provisional:
                Self.deliverNotification(title: title, body: body)
            default:
                NSLog("Ymir: notifications not authorized (status \(settings.authorizationStatus.rawValue)); enable in System Settings > Notifications > Ymir")
            }
        }
    }

    nonisolated private static func deliverNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
