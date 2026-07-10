import AppKit
import Foundation

final class CopilotAPIManager {
    struct GatewayModel: Decodable {
        let id: String
        let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }

    private struct ModelsResponse: Decodable {
        let data: [GatewayModel]
    }

    private var process: Process?
    private let endpoint = URL(string: "http://localhost:4141/v1/models")!

    /// Whether the user wants the gateway running (drives auto-restart).
    private(set) var shouldBeRunning = false
    private var restartAttempts = 0
    private var nextRestartAt = Date.distantPast
    private var lastKnownRunning = false
    private var didReportGiveUp = false
    private let maxRestartAttempts = 5
    /// When true, a Restart is in progress and spawning is blocked until port
    /// 4141 is released by the previous gateway.
    private var awaitingRestart = false
    /// After this instant, force-kill a gateway that ignored SIGTERM during a restart.
    private var restartKillDeadline = Date.distantPast

    /// User intent: start (and keep) the gateway running. Actual spawning is
    /// done by `supervise(isRunning:)` once a status poll confirms the port is
    /// free, which prevents launching a duplicate gateway.
    func requestStart() {
        shouldBeRunning = true
        restartAttempts = 0
        nextRestartAt = .distantPast
        didReportGiveUp = false
        awaitingRestart = false
    }

    /// User intent: stop the gateway and stop auto-restarting it.
    func requestStop() {
        shouldBeRunning = false
        restartAttempts = 0
        nextRestartAt = .distantPast
        didReportGiveUp = false
        awaitingRestart = false
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        // Also kill any gateway process npx spawned (or one started outside
        // Ymir), so Stop/Quit reliably frees port 4141.
        terminateExistingGateway()
    }

    /// User intent: restart the gateway. Stops the current instance immediately,
    /// then defers spawning to `supervise(isRunning:)` until port 4141 is free,
    /// so the new process doesn't fail to bind an already-held port.
    func requestRestart() {
        shouldBeRunning = true
        restartAttempts = 0
        nextRestartAt = .distantPast
        didReportGiveUp = false
        awaitingRestart = true
        restartKillDeadline = Date().addingTimeInterval(8)
        if process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        terminateExistingGateway()
    }

    /// Called on the main thread each status-poll tick. Handles auto-restart
    /// with exponential backoff and returns a user-facing message when it acts.
    func supervise(isRunning: Bool) -> String? {
        defer { lastKnownRunning = isRunning }

        // Deterministic restart: after Restart we stopped the old gateway and
        // must wait until port 4141 is released before spawning, or the new
        // process fails to bind. Force-kill the old one if it ignores SIGTERM
        // past the deadline.
        if awaitingRestart {
            if isRunning || isPortBusy() {
                if Date() >= restartKillDeadline {
                    terminateExistingGateway(force: true)
                }
                return nil
            }
            awaitingRestart = false
            // The restart was already announced; avoid a misleading
            // "stopped unexpectedly" message when we spawn below.
            lastKnownRunning = false
        }

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
                return "Gateway failed to stay up after \(maxRestartAttempts) attempts. Click Start to retry."
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
            return "Gateway restart failed: \(error.localizedDescription)"
        }
        // Only announce unexpected restarts; the initial Start is announced by
        // the menu action itself.
        return wasRunning ? "Gateway stopped unexpectedly; restarting…" : nil
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
        echo "Ymir: signing in to gateway…"
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

    func fetchModels(_ completion: @escaping (Result<[GatewayModel], Error>) -> Void) {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  let data else {
                completion(.failure(URLError(.badServerResponse)))
                return
            }
            do {
                let models = try JSONDecoder().decode(ModelsResponse.self, from: data).data
                    .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
                completion(.success(models))
            } catch {
                completion(.failure(error))
            }
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

    private func terminateExistingGateway(force: Bool = false) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        proc.arguments = (force ? ["-9"] : []) + ["-f", "@jeffreycao/copilot-api.*start"]
        try? proc.run()
        proc.waitUntilExit()
    }

    /// Whether something is still listening on the gateway port. Used to gate a
    /// restart until the previous process has fully released the socket.
    private func isPortBusy() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        proc.arguments = ["-nP", "-iTCP:4141", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            // Can't check; assume free so a restart never deadlocks.
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return !data.isEmpty
    }
}
