import FirebaseFirestore
import Foundation

/// Listens to the signed-in user's in-app notifications and exposes static
/// helpers to mark them read or delete them.
///
/// Notifications live at `users/{userID}/notifications/{notificationID}`.
final class NotificationsService {
    private var listener: ListenerRegistration?
    private var previewListeners: [ProjectKey: ListenerRegistration] = [:]
    private var previews: [ProjectKey: ProjectPreview] = [:]
    private var items: [AppNotification] = []
    private var onUpdate: (@MainActor ([AppNotification]) -> Void)?

    private struct ProjectKey: Hashable {
        let ownerUID: String
        let projectID: UUID
    }

    // MARK: - Lifecycle

    func start(userID: String, onUpdate: @escaping @MainActor ([AppNotification]) -> Void) {
        stop()
        self.onUpdate = onUpdate
        let query = CloudPaths.notificationsCollection(userID: userID)
            .order(by: "createdAt", descending: true)
            .limit(to: 50)

        listener = query.addSnapshotListener { snapshot, error in
            if let error {
                print("NotificationsService: listener error — \(error)")
                return
            }
            self.items = snapshot?.documents.compactMap(Self.decode) ?? []
            self.reconcilePreviewListeners()
            self.publish()
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        previewListeners.values.forEach { $0.remove() }
        previewListeners.removeAll()
        previews.removeAll()
        items.removeAll()
        onUpdate = nil
    }

    // MARK: - Live project previews

    private func reconcilePreviewListeners() {
        let wanted = Set(items.compactMap { notification -> ProjectKey? in
            guard notification.kind == .projectInvite else { return nil }
            return ProjectKey(ownerUID: notification.fromUID, projectID: notification.projectID)
        })

        for (key, listener) in previewListeners where !wanted.contains(key) {
            listener.remove()
            previewListeners.removeValue(forKey: key)
            previews.removeValue(forKey: key)
        }

        for key in wanted where previewListeners[key] == nil {
            let ref = CloudPaths.projectPreviewDocument(
                ownerID: key.ownerUID,
                projectID: key.projectID
            )
            previewListeners[key] = ref.addSnapshotListener { [weak self] snapshot, error in
                guard let self else { return }
                if let error {
                    print("NotificationsService: project preview listener error — \(error)")
                    return
                }
                if let data = snapshot?.data(),
                   let preview = ProjectInviteService.decodePreview(
                       data,
                       ownerUID: key.ownerUID,
                       projectID: key.projectID
                   ) {
                    self.previews[key] = preview
                } else {
                    self.previews.removeValue(forKey: key)
                }
                self.publish()
            }
        }
    }

    private func publish() {
        let resolved = items.map { notification in
            let key = ProjectKey(
                ownerUID: notification.fromUID,
                projectID: notification.projectID
            )
            guard notification.kind == .projectInvite, let preview = previews[key] else {
                return notification
            }
            return AppNotification(
                id: notification.id,
                kind: notification.kind,
                fromUID: notification.fromUID,
                fromUsername: notification.fromUsername,
                projectID: notification.projectID,
                projectName: preview.projectName,
                projectGradient: preview.gradient,
                coverStoragePath: preview.coverStoragePath,
                createdAt: notification.createdAt,
                read: notification.read
            )
        }
        guard let onUpdate else { return }
        Task { @MainActor in onUpdate(resolved) }
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
        let projectGradient = (data["projectGradient"] as? [String: Any]).flatMap(decodeGradient)
        return AppNotification(
            id: doc.documentID,
            kind: AppNotification.Kind(raw: typeRaw),
            fromUID: fromUID,
            fromUsername: data["fromUsername"] as? String ?? "",
            projectID: projectID,
            projectName: data["projectName"] as? String ?? "a project",
            projectGradient: projectGradient,
            coverStoragePath: data["coverStoragePath"] as? String,
            createdAt: createdAt,
            read: data["read"] as? Bool ?? false
        )
    }

    private nonisolated static func decodeGradient(_ data: [String: Any]) -> GradientTheme? {
        guard let colors = data["colors"] as? [String],
              let startX = data["startX"] as? Double,
              let startY = data["startY"] as? Double,
              let endX = data["endX"] as? Double,
              let endY = data["endY"] as? Double
        else { return nil }
        return GradientTheme(
            colors: colors,
            startX: startX,
            startY: startY,
            endX: endX,
            endY: endY
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
