import FirebaseFirestore
import FirebaseStorage
import Foundation

/// Manages the current user's profile (username) and provides lookup helpers.
///
/// - Listens to `userProfiles/{userID}` for real-time username updates.
/// - Atomically claims usernames via a Firestore transaction on `usernames/{username}`.
final class UserProfileService {
    private var listener: ListenerRegistration?

    // MARK: - Lifecycle

    func start(userID: String, onUpdate: @escaping @MainActor (String?) -> Void) {
        stop()
        let ref = CloudPaths.userProfileDocument(userID: userID)
        listener = ref.addSnapshotListener { snapshot, error in
            if let error {
                print("UserProfileService: listener error — \(error)")
                return
            }
            let username = snapshot?.data()?["username"] as? String
            Task { @MainActor in onUpdate(username) }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    // MARK: - Claim username

    /// Atomically checks availability and claims `username` for `userID`.
    /// Throws if the username is already taken or the transaction fails.
    func setUsername(_ username: String, forUserID userID: String) async throws {
        let db = Firestore.firestore()
        let usernameRef = CloudPaths.usernameDocument(username: username.lowercased())
        let profileRef = CloudPaths.userProfileDocument(userID: userID)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            db.runTransaction({ transaction, errorPointer in
                let usernameDoc: DocumentSnapshot
                do {
                    usernameDoc = try transaction.getDocument(usernameRef)
                } catch let fetchError as NSError {
                    errorPointer?.pointee = fetchError
                    return nil
                }

                if usernameDoc.exists {
                    errorPointer?.pointee = NSError(
                        domain: "UserProfileService",
                        code: 409,
                        userInfo: [NSLocalizedDescriptionKey: "@\(username) is already taken."]
                    )
                    return nil
                }

                transaction.setData(["uid": userID], forDocument: usernameRef)
                transaction.setData(["username": username], forDocument: profileRef, merge: true)
                return nil
            }) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Lookup helpers

    /// Fetches the username for an arbitrary UID (for displaying project owners).
    static func fetchUsername(forUID uid: String) async -> String? {
        let ref = CloudPaths.userProfileDocument(userID: uid)
        let snapshot = try? await ref.getDocument()
        return snapshot?.data()?["username"] as? String
    }

    /// Returns true when the username is not yet claimed.
    /// Always reads from the server so a cached "not found" can't give a false positive.
    /// Throws on network or permission errors.
    static func isAvailable(_ username: String) async throws -> Bool {
        let ref = CloudPaths.usernameDocument(username: username.lowercased())
        let snapshot = try await ref.getDocument(source: .server)
        return !snapshot.exists
    }

    /// Prefix-searches the username index for invite suggestions.
    /// Returns at most `limit` matches, excluding the caller.
    ///
    /// The query runs in the `searchUsers` Cloud Function rather than here.
    /// Doing it client-side required `list` permission on `usernames`, and that
    /// collection is the uid directory for the whole app — with it, anyone
    /// could enumerate every user, then every project id they own, which makes
    /// share-link UUIDs guessable. Clients now only get exact-key reads.
    static func searchUsers(
        prefix rawPrefix: String,
        excludingUID: String?,
        limit: Int = 10
    ) async -> [UserSearchResult] {
        let prefix = rawPrefix
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        // The function applies the same floor; short prefixes match too much of
        // the directory to be a search rather than a dump.
        guard prefix.count >= 2 else { return [] }

        do {
            let matches = try await CallableFunction.searchUsers(prefix: prefix)
            return matches
                .filter { $0.id != excludingUID }
                .prefix(limit)
                .map { match in
                    UserSearchResult(
                        id: match.id,
                        username: match.username,
                        avatarURL: match.avatarURL.flatMap(URL.init(string:))
                    )
                }
        } catch {
            print("UserProfileService: user search failed — \(error)")
            return []
        }
    }

    /// Resolves the public profile URL first, then checks the stable Storage
    /// object for photos uploaded by older web builds.
    static func fetchAvatarURL(forUID uid: String) async -> URL? {
        let profile = try? await CloudPaths.userProfileDocument(userID: uid).getDocument()
        if let rawURL = profile?.data()?["avatarURL"] as? String,
           let url = canonicalAvatarURL(rawURL, forUID: uid) {
            return url
        }

        let reference = CloudPaths.profilePhotoReference(userID: uid)
        do {
            async let url = reference.downloadURL()
            async let metadata = reference.getMetadata()
            let (downloadURL, objectMetadata) = try await (url, metadata)
            guard let updated = objectMetadata.updated else { return downloadURL }

            var components = URLComponents(url: downloadURL, resolvingAgainstBaseURL: false)
            var queryItems = components?.queryItems ?? []
            queryItems.removeAll { $0.name == "v" }
            queryItems.append(URLQueryItem(
                name: "v",
                value: String(Int(updated.timeIntervalSince1970 * 1_000))
            ))
            components?.queryItems = queryItems
            return components?.url ?? downloadURL
        } catch {
            return nil
        }
    }

    static func canonicalAvatarURL(_ rawValue: String, forUID uid: String) -> URL? {
        guard let url = URL(string: rawValue),
              url.scheme == "https",
              url.host == "firebasestorage.googleapis.com"
        else { return nil }
        let decodedPath = url.path.removingPercentEncoding ?? url.path
        guard decodedPath.hasSuffix("/o/users/\(uid)/profile/avatar.jpg") else { return nil }
        return url
    }
}
