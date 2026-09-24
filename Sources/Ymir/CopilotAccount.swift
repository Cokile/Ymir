import Foundation

/// UI-owned account state. Credentials and identity are cached only in memory.
@MainActor
final class CopilotAccount {
    private let tokenStore: CopilotTokenStore
    private let fetchLogin: (String) async throws -> String
    private var currentToken: String?
    private var lookup: Task<Void, Never>?
    private var nextRetryAt = Date.distantPast
    private(set) var login: String?
    private(set) var isLoading = false
    var onChange: (() -> Void)?

    init(
        tokenStore: CopilotTokenStore = CopilotTokenStore(),
        fetchLogin: @escaping (String) async throws -> String = GitHubIdentity.fetchLogin
    ) {
        self.tokenStore = tokenStore
        self.fetchLogin = fetchLogin
    }

    deinit {
        lookup?.cancel()
    }

    var isSignedIn: Bool { currentToken != nil }

    var menuTitle: String {
        guard isSignedIn else { return "Sign In to Copilot" }
        if let login { return "Signed In as @\(login)" }
        return isLoading ? "Copilot Signed In — Loading Account…" : "Copilot Signed In — Account Unavailable"
    }

    @discardableResult
    func refresh(now: Date = Date()) -> Task<Void, Never>? {
        let token = tokenStore.token
        if token != currentToken {
            lookup?.cancel()
            lookup = nil
            currentToken = token
            login = nil
            isLoading = false
            nextRetryAt = .distantPast
            onChange?()
        }
        guard let token, login == nil, now >= nextRetryAt else { return nil }
        if let lookup { return lookup }

        isLoading = true
        onChange?()
        lookup = Task { [weak self] in
            // Read the UI-owned dependency before suspending for the request.
            guard let fetchLogin = self?.fetchLogin else { return }
            let login = try? await fetchLogin(token)
            guard !Task.isCancelled, let self else { return }
            // Re-read disk too: sign-out/account switching may precede the next poll.
            guard self.tokenStore.token == token else {
                self.refresh()
                return
            }
            self.lookup = nil
            self.isLoading = false
            self.login = login
            self.nextRetryAt = now.addingTimeInterval(60)
            self.onChange?()
        }
        return lookup
    }
}

enum GitHubIdentity {
    private struct User: Decodable {
        let login: String
    }

    static func request(for token: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Ymir", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func login(from data: Data, response: URLResponse) throws -> String {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let login = try JSONDecoder().decode(User.self, from: data).login
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty else { throw URLError(.cannotParseResponse) }
        return login
    }

    static func fetchLogin(token: String) async throws -> String {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request(for: token))
        return try login(from: data, response: response)
    }
}
