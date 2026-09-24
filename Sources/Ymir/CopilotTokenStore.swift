import Foundation

struct CopilotTokenStore {
    // copilot-api stores the GitHub token here after `auth login`.
    let tokenURL: URL

    init(tokenURL: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".local/share/copilot-api/github_token")) {
        self.tokenURL = tokenURL
    }

    var isSignedIn: Bool {
        token != nil
    }

    var token: String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: tokenURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let contents = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            return nil
        }
        let token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    func removeToken() throws {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: tokenURL.path)
            // Never recursively remove a directory if the token path is malformed.
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw NSError(domain: "Ymir", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "The saved Copilot token is not a regular file. It was not removed."
                ])
            }
            try FileManager.default.removeItem(at: tokenURL)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            // Signing out is already complete if another process removed it.
        }
    }
}
