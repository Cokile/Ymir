import XCTest
@testable import Ymir

final class CopilotAccountTests: XCTestCase {
    private func makeTokenStore(_ token: String? = nil) throws -> CopilotTokenStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ymir-account-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let store = CopilotTokenStore(tokenURL: directory.appendingPathComponent("github_token"))
        if let token { try token.write(to: store.tokenURL, atomically: true, encoding: .utf8) }
        return store
    }

    @MainActor
    func testSignedOutDoesNotLookUpIdentity() async throws {
        let store = try makeTokenStore()
        let account = CopilotAccount(tokenStore: store) { _ in
            XCTFail("No identity request should be made without a token")
            return "unexpected"
        }
        await account.refresh()?.value
        XCTAssertFalse(account.isSignedIn)
        XCTAssertEqual(account.menuTitle, "Sign In to Copilot")
    }

    @MainActor
    func testIdentityIsLoadedOnceAndCachedUntilTokenChanges() async throws {
        let store = try makeTokenStore("first-token\n")
        var requestedTokens: [String] = []
        let account = CopilotAccount(tokenStore: store) { token in
            requestedTokens.append(token)
            return token == "first-token" ? "octocat" : "second-user"
        }
        let firstLookup = account.refresh()
        XCTAssertTrue(account.isSignedIn)
        XCTAssertTrue(account.isLoading)
        XCTAssertEqual(account.menuTitle, "Copilot Signed In — Loading Account…")
        let duplicateLookup = account.refresh()
        await firstLookup?.value
        await duplicateLookup?.value
        XCTAssertEqual(account.menuTitle, "Signed In as @octocat")
        XCTAssertFalse(account.isLoading)
        await account.refresh()?.value
        XCTAssertEqual(requestedTokens, ["first-token"])

        try "second-token".write(to: store.tokenURL, atomically: true, encoding: .utf8)
        let secondLookup = account.refresh()
        XCTAssertNil(account.login)
        await secondLookup?.value
        XCTAssertEqual(account.menuTitle, "Signed In as @second-user")
        XCTAssertEqual(requestedTokens, ["first-token", "second-token"])
    }

    @MainActor
    func testLookupFailureKeepsSignOutAvailableAndThrottlesRetries() async throws {
        let store = try makeTokenStore("test-token")
        var attempts = 0
        let account = CopilotAccount(tokenStore: store) { _ in
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return "octocat"
        }
        let now = Date()
        await account.refresh(now: now)?.value
        XCTAssertTrue(account.isSignedIn)
        XCTAssertFalse(account.isLoading)
        XCTAssertEqual(account.menuTitle, "Copilot Signed In — Account Unavailable")
        await account.refresh(now: now.addingTimeInterval(5))?.value
        XCTAssertEqual(attempts, 1)
        await account.refresh(now: now.addingTimeInterval(61))?.value
        XCTAssertEqual(account.menuTitle, "Signed In as @octocat")
        XCTAssertEqual(attempts, 2)
    }

    @MainActor
    func testSignOutDiscardsAnInFlightIdentity() async throws {
        let store = try makeTokenStore("test-token")
        let started = expectation(description: "Identity lookup started")
        var continuation: CheckedContinuation<String, Error>?
        let account = CopilotAccount(tokenStore: store) { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        let lookup = account.refresh()
        await fulfillment(of: [started], timeout: 2)
        try store.removeToken()
        account.refresh()
        continuation?.resume(returning: "old-user")
        await lookup?.value
        XCTAssertFalse(account.isSignedIn)
        XCTAssertNil(account.login)
        XCTAssertEqual(account.menuTitle, "Sign In to Copilot")
    }

    @MainActor
    func testAccountChangeOnDiskDiscardsOldResultBeforeNextPoll() async throws {
        let store = try makeTokenStore("first-token")
        let started = expectation(description: "First identity lookup started")
        var continuation: CheckedContinuation<String, Error>?
        let account = CopilotAccount(tokenStore: store) { token in
            if token == "second-token" { return "new-user" }
            return try await withCheckedThrowingContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        var observedTitles: [String] = []
        account.onChange = { [weak account] in
            if let account { observedTitles.append(account.menuTitle) }
        }
        let lookup = account.refresh()
        await fulfillment(of: [started], timeout: 2)
        try "second-token".write(to: store.tokenURL, atomically: true, encoding: .utf8)
        continuation?.resume(returning: "old-user")
        await lookup?.value
        await account.refresh()?.value
        XCTAssertEqual(account.menuTitle, "Signed In as @new-user")
        XCTAssertFalse(observedTitles.contains("Signed In as @old-user"))
    }

    func testIdentityRequestUsesGitHubAndDoesNotPutTokenInURL() {
        let request = GitHubIdentity.request(for: "test-token")
        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 10)
    }

    func testIdentityResponseRequiresSuccessAndNonemptyLogin() throws {
        let url = URL(string: "https://api.github.com/user")!
        let success = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        let unauthorized = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
        let data = Data(#"{"login":"octocat","name":"The Octocat"}"#.utf8)
        XCTAssertEqual(try GitHubIdentity.login(from: data, response: success), "octocat")
        XCTAssertThrowsError(try GitHubIdentity.login(from: data, response: unauthorized))
        XCTAssertThrowsError(try GitHubIdentity.login(from: Data(#"{"login":" "}"#.utf8), response: success))
        XCTAssertThrowsError(try GitHubIdentity.login(from: Data("{}".utf8), response: success))
    }
}
