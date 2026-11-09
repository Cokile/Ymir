import Foundation

/// Keeps Codex's model picker available without a successful startup HTTP request.
/// Refresh state is confined to the main queue used by the gateway status poll.
final class CodexModelCatalog {
    static let fileURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/Application Support/Ymir", isDirectory: true)
        .appendingPathComponent("codex-models.json")

    private var isRefreshing = false
    private var isGatewayRunning = false
    private var nextRefreshAt = Date.distantPast

    func refreshIfNeeded(isRunning: Bool) {
        isGatewayRunning = isRunning
        guard isRunning else {
            nextRefreshAt = .distantPast
            return
        }
        guard !isRefreshing, Date() >= nextRefreshAt else { return }
        isRefreshing = true

        // 0.160 is the gateway's minimum client version for the modern
        // model_messages schema. The User-Agent selects its Codex catalog route.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:4141/models?client_version=0.160.0")!)
        request.setValue("codex_ymir", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let result = Result {
                if let error { throw error }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data else {
                    throw URLError(.badServerResponse)
                }
                return try Self.save(data, to: Self.fileURL)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                let delay: TimeInterval
                switch result {
                case .success:
                    delay = 300
                case .failure(let error):
                    delay = 30
                    NSLog("Ymir: keeping the last Codex model catalog: %@", error.localizedDescription)
                }
                self.nextRefreshAt = self.isGatewayRunning ? Date().addingTimeInterval(delay) : .distantPast
            }
        }.resume()
    }

    /// Validate before replacing the last good copy; retain metadata verbatim.
    @discardableResult
    static func save(_ data: Data, to destination: URL) throws -> Bool {
        guard data.count <= 1024 * 1024,
              let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = catalog["models"] as? [[String: Any]], !models.isEmpty else {
            throw invalidCatalog()
        }
        let slugs = models.compactMap { $0["slug"] as? String }
        guard slugs.count == models.count,
              slugs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(slugs).count == slugs.count,
              models.contains(where: { $0["visibility"] as? String != "hide" }) else {
            throw invalidCatalog()
        }
        if (try? Data(contentsOf: destination)) == data { return false }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return true
    }

    private static func invalidCatalog() -> NSError {
        NSError(domain: "Ymir", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "The Codex model catalog is empty, invalid, or exceeds 1 MiB."
        ])
    }
}
