import AppKit
import Foundation
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let manager = CopilotAPIManager()
    private var statusTimer: Timer?

    private let statusMenuItem = NSMenuItem(title: "Status: Checking...", action: nil, keyEquivalent: "")
    private let signInMenuItem = NSMenuItem(title: "Sign In", action: #selector(authLogin), keyEquivalent: "")
    private let startMenuItem = NSMenuItem(title: "Start", action: #selector(startGateway), keyEquivalent: "")
    private let stopMenuItem = NSMenuItem(title: "Stop ", action: #selector(stopGateway), keyEquivalent: "")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Start at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let usageViewerMenuItem = NSMenuItem(title: "Open Usage Viewer", action: #selector(openUsageViewer), keyEquivalent: "")

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
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        usageViewerMenuItem.isEnabled = false
        signInMenuItem.target = self
        startMenuItem.target = self
        stopMenuItem.target = self
        launchAtLoginMenuItem.target = self
        usageViewerMenuItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(signInMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(startMenuItem)
        menu.addItem(stopMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(usageViewerMenuItem)
        menu.addItem(NSMenuItem(title: "Open Codex Config", action: #selector(openCodexConfig), keyEquivalent: "", target: self))
        menu.addItem(NSMenuItem(title: "Open Claude Settings", action: #selector(openClaudeSettings), keyEquivalent: "", target: self))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "", target: self))

        updateLaunchAtLoginState()
        updateSignInState()
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

    @objc private func openCodexConfig() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/config.toml"))
    }

    @objc private func openClaudeSettings() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json"))
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
                    statusText = "Status: Running on :4141"
                } else if shouldRun {
                    statusText = "Status: Starting…"
                } else {
                    statusText = "Status: Stopped"
                }
                self.statusMenuItem.title = statusText
                self.statusItem.length = NSStatusItem.variableLength
                self.statusItem.isVisible = true
                self.statusItem.button?.image = nil
                self.statusItem.button?.attributedTitle = NSAttributedString(string: "Ymir", attributes: [.foregroundColor: NSColor.white])
                self.statusItem.button?.toolTip = isRunning ? "Ymir - copilot-api running" : "Ymir - copilot-api stopped"
                self.startMenuItem.isEnabled = !isRunning && !shouldRun
                self.stopMenuItem.isEnabled = isRunning || shouldRun
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
        signInMenuItem.title = signedIn ? "Signed" : "Sign In"
        signInMenuItem.isEnabled = !signedIn
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

private final class CopilotAPIManager {
    private var process: Process?
    private let endpoint = URL(string: "http://localhost:4141/v1/models")!

    /// Whether the user wants the gateway running (drives auto-restart).
    private(set) var shouldBeRunning = false
    private var restartAttempts = 0
    private var nextRestartAt = Date.distantPast
    private var lastKnownRunning = false
    private var didReportGiveUp = false
    private let maxRestartAttempts = 5

    /// User intent: start (and keep) the gateway running. Actual spawning is
    /// done by `supervise(isRunning:)` once a status poll confirms the port is
    /// free, which prevents launching a duplicate gateway.
    func requestStart() {
        shouldBeRunning = true
        restartAttempts = 0
        nextRestartAt = .distantPast
        didReportGiveUp = false
    }

    /// User intent: stop the gateway and stop auto-restarting it.
    func requestStop() {
        shouldBeRunning = false
        restartAttempts = 0
        nextRestartAt = .distantPast
        didReportGiveUp = false
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        // Also kill any gateway process npx spawned (or one started outside
        // Ymir), so Stop/Quit reliably frees port 4141.
        terminateExistingGateway()
    }

    /// Called on the main thread each status-poll tick. Handles auto-restart
    /// with exponential backoff and returns a user-facing message when it acts.
    func supervise(isRunning: Bool) -> String? {
        defer { lastKnownRunning = isRunning }

        if isRunning {
            restartAttempts = 0
            didReportGiveUp = false
            return nil
        }
        guard shouldBeRunning else { return nil }

        // Our process is alive but the port isn't up yet: still starting.
        if process?.isRunning == true { return nil }

        // Give up after too many failures; let the user retry via Start.
        if restartAttempts >= maxRestartAttempts {
            if !didReportGiveUp {
                didReportGiveUp = true
                return "copilot-api failed to stay up after \(maxRestartAttempts) attempts. Click Start to retry."
            }
            return nil
        }

        // Respect the backoff window (2, 4, 8, 16, 30s).
        let now = Date()
        guard now >= nextRestartAt else { return nil }
        restartAttempts += 1
        nextRestartAt = now.addingTimeInterval(min(30, pow(2, Double(restartAttempts))))

        let wasRunning = lastKnownRunning
        do {
            try spawn()
        } catch {
            return "copilot-api restart failed: \(error.localizedDescription)"
        }
        // Only announce unexpected restarts; the initial Start is announced by
        // the menu action itself.
        return wasRunning ? "copilot-api stopped unexpectedly; restarting…" : nil
    }

    private func spawn() throws {
        if process?.isRunning == true { return }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["npx", "@jeffreycao/copilot-api@latest", "start"]
        proc.environment = environment()

        let logURL = logFileURL()
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        logHandle.seekToEndOfFile()
        proc.standardOutput = logHandle
        proc.standardError = logHandle
        proc.terminationHandler = { _ in
            try? logHandle.close()
        }

        try proc.run()
        process = proc
    }

    func authLogin() throws {
        // `auth login` is interactive (device-code flow), so run it in a
        // visible Terminal window instead of headlessly to a log file.
        let script = """
        #!/bin/bash
        export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
        echo "Ymir: signing in to copilot-api…"
        echo
        npx @jeffreycao/copilot-api@latest auth login --provider copilot
        code=$?
        echo
        if [ $code -eq 0 ]; then
          echo "Ymir: sign-in finished. You can close this window."
        else
          echo "Ymir: sign-in exited with status $code."
        fi
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ymir-auth-\(UUID().uuidString).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    func checkStatus(_ completion: @escaping (Bool) -> Void) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { _, response, _ in
            completion((response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    func isSignedIn() -> Bool {
        // copilot-api stores the GitHub token here after `auth login`.
        let tokenURL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/copilot-api/github_token")
        guard let size = try? FileManager.default.attributesOfItem(atPath: tokenURL.path)[.size] as? Int else {
            return false
        }
        return size > 0
    }

    private func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/Users/\(NSUserName())/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
        env["GITHUB_COPILOT_API_KEY"] = env["GITHUB_COPILOT_API_KEY"] ?? "dummy"
        return env
    }

    private func logFileURL() -> URL {
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Ymir", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("copilot-api.log")
    }

    private func terminateExistingGateway() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = ["-f", "@jeffreycao/copilot-api.*start"]
        try? proc.run()
        proc.waitUntilExit()
    }
}

private extension NSMenuItem {
    convenience init(title: String, action: Selector?, keyEquivalent: String, target: AnyObject?) {
        self.init(title: title, action: action, keyEquivalent: keyEquivalent)
        self.target = target
    }
}

@main
enum AppMain {
    static let appDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = appDelegate
        app.run()
    }
}
