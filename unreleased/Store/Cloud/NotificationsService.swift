import FirebaseFirestore
import Foundation

/// Listens to the signed-in user's in-app notifications and exposes static
/// helpers to mark them read or delete them.
///
/// Notifications live at `users/{userID}/notifications/{notificationID}`.
final class NotificationsService {
    private var listener: ListenerRegistration?

    // MARK: - Lifecycle

    func start(userID: String, onUpdate: @escaping @MainActor ([AppNotification]) -> Void) {
        stop()
        let query = CloudPaths.notificationsCollection(userID: userID)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)

        listener = query.addSnapshotListener { snapshot, error in
            if let error {
                print("NotificationsService: listener error — \(error)")
                return
            }
            let items = snapshot?.documents.compactMap(Self.decode) ?? []
            Task { @MainActor in onUpdate(items) }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
    }

    // MARK: - Mutations

    static func markRead(userID: String, notificationID: String) async {
        let ref = CloudPaths.notificationDocument(userID: userID, notificationID: notificationID)
        try? await ref.setData(["read": true], merge: true)
    }

    static func markAllRead(userID: String, ids: [String]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await markRead(userID: userID, notificationID: id) }
            }
        }
    }

    static func delete(userID: String, notificationID: String) async {
        let ref = CloudPaths.notificationDocument(userID: userID, notificationID: notificationID)
        try? await ref.delete()
    }

    // MARK: - Decoding

    private nonisolated static func decode(_ doc: QueryDocumentSnapshot) -> AppNotification? {
        let data = doc.data()
        guard let typeRaw = data["type"] as? String,
              let fromUID = data["fromUID"] as? String,
              let projectIDString = data["projectID"] as? String,
              let projectID = UUID(uuidString: projectIDString)
        else { return nil }

        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue() ?? Date()
        return AppNotification(
            id: doc.documentID,
            kind: AppNotification.Kind(raw: typeRaw),
            fromUID: fromUID,
            fromUsername: data["fromUsername"] as? String ?? "",
            projectID: projectID,
            projectName: data["projectName"] as? String ?? "a project",
            createdAt: createdAt,
            read: data["read"] as? Bool ?? false
        )
    }
}

// MARK: - Async DocumentReference helpers

private extension DocumentReference {
    func setData(_ documentData: [String: Any], merge: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setData(documentData, merge: merge) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func delete() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delete { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
