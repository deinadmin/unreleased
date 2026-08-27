import FirebaseAuth
import FirebaseAppCheck
import Foundation

/// Minimal client for Firebase callable Cloud Functions.
///
/// The callable protocol is plain HTTPS — `POST { "data": … }` with the caller's
/// Firebase ID token as a bearer credential, answered with `{ "result": … }` or
/// `{ "error": … }`. Speaking it directly keeps the app off the FirebaseFunctions
/// SDK for the one or two calls that need it.
enum CallableFunction {
    private static let region = "us-central1"

    enum CallError: LocalizedError {
        case notSignedIn
        case missingProjectID
        case transport(statusCode: Int)
        case remote(message: String)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .notSignedIn: "You must be signed in."
            case .missingProjectID: "Firebase project id is unavailable."
            case let .transport(statusCode): "Request failed with status \(statusCode)."
            case let .remote(message): message
            case .malformedResponse: "The server returned an unexpected response."
            }
        }
    }

    struct UserMatch: Decodable {
        let id: String
        let username: String
        let avatarURL: String?
    }

    /// Prefix-searches the username directory. See the `searchUsers` function.
    static func searchUsers(prefix: String) async throws -> [UserMatch] {
        struct Payload: Decodable { let results: [UserMatch] }
        let payload: Payload = try await call("searchUsers", data: ["prefix": prefix])
        return payload.results
    }

    // MARK: - Transport

    private static func call<Response: Decodable>(
        _ name: String,
        data: [String: Any]
    ) async throws -> Response {
        guard let user = Auth.auth().currentUser else { throw CallError.notSignedIn }
        guard let projectID = GoogleServiceInfo.string(for: "PROJECT_ID"),
              let url = URL(string: "https://\(region)-\(projectID).cloudfunctions.net/\(name)")
        else { throw CallError.missingProjectID }

        let token = try await user.getIDToken()
        let appCheckToken = try await AppCheck.appCheck().token(forcingRefresh: false).token
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": data])
        request.timeoutInterval = 20

        let (body, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        let envelope = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        if let error = envelope?["error"] as? [String: Any] {
            throw CallError.remote(message: error["message"] as? String ?? "Request failed.")
        }
        guard (200..<300).contains(statusCode) else {
            throw CallError.transport(statusCode: statusCode)
        }
        guard let result = envelope?["result"] else { throw CallError.malformedResponse }

        let resultData = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(Response.self, from: resultData)
    }
}
