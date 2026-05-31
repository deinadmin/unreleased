import FirebaseFirestore
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
}
