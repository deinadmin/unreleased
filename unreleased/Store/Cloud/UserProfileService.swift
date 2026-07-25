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
    /// Returns at most `limit` matches, excluding `excludingUID` (typically the caller).
    static func searchUsers(
        prefix rawPrefix: String,
        excludingUID: String?,
        limit: Int = 10
    ) async -> [UserSearchResult] {
        let prefix = rawPrefix
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return [] }

        // Firestore prefix query on the document ID (the lowercased username).
        let end = prefix + "\u{f8ff}"
        let query = CloudPaths.usernamesCollection()
            .order(by: FieldPath.documentID())
            .start(at: [prefix])
            .end(at: [end])
            .limit(to: limit + 1)   // fetch one extra in case we filter ourselves out

        guard let snapshot = try? await query.getDocuments() else { return [] }
        let matches = snapshot.documents.compactMap { doc -> (uid: String, username: String)? in
            guard let uid = doc.data()["uid"] as? String else { return nil }
            if let excludingUID, uid == excludingUID { return nil }
            return (uid, doc.documentID)
        }
        .prefix(limit)
        return await withTaskGroup(of: UserSearchResult.self) { group in
            for match in matches {
                group.addTask {
                    UserSearchResult(
                        id: match.uid,
                        username: match.username,
                        avatarURL: await fetchAvatarURL(forUID: match.uid)
                    )
                }
            }

            var resultsByID: [String: UserSearchResult] = [:]
            for await result in group {
                resultsByID[result.id] = result
            }
            return matches.compactMap { resultsByID[$0.uid] }
        }
    }

    /// Resolves the public profile URL first, then checks the stable Storage
    /// object for photos uploaded by older web builds.
    static func fetchAvatarURL(forUID uid: String) async -> URL? {
        let profile = try? await CloudPaths.userProfileDocument(userID: uid).getDocument()
        if let rawURL = profile?.data()?["avatarURL"] as? String,
           let url = URL(string: rawURL) {
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
}
