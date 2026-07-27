import FirebaseFirestore
import Foundation

/// Handles project invite previews and the invitees subcollection.
///
/// - Writes `users/{ownerID}/projectPreviews/{projectID}` when an owner shares a project.
/// - Reads the same preview for recipients to see the invite prompt.
/// - Manages `users/{ownerID}/projects/{projectID}/invitees/{inviteeUID}` documents.
enum ProjectInviteService {

    // MARK: - Invite preview

    /// Writes (or refreshes) the invite preview so recipients can see project info
    /// before accepting. Called when the owner opens the share sheet.
    ///
    /// Uses a merge write and only seeds `linkEnabled` when the doc doesn't have it
    /// yet, so a previously-disabled link stays disabled when the sheet is reopened.
    static func writePreview(
        project: Project,
        ownerUID: String,
        ownerUsername: String
    ) async {
        let ref = CloudPaths.projectPreviewDocument(ownerID: ownerUID, projectID: project.id)
        var data: [String: Any] = [
            "name": project.name,
            "ownerUID": ownerUID,
            "ownerUsername": ownerUsername,
            "gradient": encodeGradient(project.gradient),
            "coverStoragePath": project.coverStoragePath ?? FieldValue.delete(),
            "updatedAt": Timestamp(date: Date()),
        ]
        if let hex = project.accentColorHex { data["accentColorHex"] = hex }

        let existing = try? await ref.getDocument()
        if existing?.data()?["linkEnabled"] == nil {
            data["linkEnabled"] = true
        }
        try? await ref.setData(data, merge: true)
    }

    /// Refreshes an existing invite preview after project metadata changes.
    ///
    /// Unlike `writePreview`, this never creates a preview for a project that has
    /// not been shared. Notification rows observe this document so their cover
    /// follows later project edits instead of remaining an invite-time snapshot.
    static func refreshPreviewIfExists(
        project: Project,
        ownerUID: String,
        ownerUsername: String?
    ) async {
        let ref = CloudPaths.projectPreviewDocument(ownerID: ownerUID, projectID: project.id)
        guard let snapshot = try? await ref.getDocument(), snapshot.exists else { return }

        var data: [String: Any] = [
            "name": project.name,
            "gradient": encodeGradient(project.gradient),
            "coverStoragePath": project.coverStoragePath ?? FieldValue.delete(),
            "accentColorHex": project.accentColorHex ?? FieldValue.delete(),
            "updatedAt": Timestamp(date: Date()),
        ]
        if let ownerUsername {
            data["ownerUsername"] = ownerUsername
        }
        try? await ref.setData(data, merge: true)
    }

    /// Enables or disables the general share link. Existing listeners keep their access.
    static func setLinkEnabled(_ enabled: Bool, ownerUID: String, projectID: UUID) async throws {
        let ref = CloudPaths.projectPreviewDocument(ownerID: ownerUID, projectID: projectID)
        try await ref.setData(["linkEnabled": enabled], merge: true)
    }

    /// Fetches the publicly-readable invite preview (no invitee status required).
    static func fetchPreview(ownerUID: String, projectID: UUID) async -> ProjectPreview? {
        let ref = CloudPaths.projectPreviewDocument(ownerID: ownerUID, projectID: projectID)
        guard let data = try? await ref.getDocument().data() else { return nil }
        return decodePreview(data, ownerUID: ownerUID, projectID: projectID)
    }

    // MARK: - Invitees

    /// Returns all users who have accepted the invite (owner-only read).
    static func fetchInvitees(ownerUID: String, projectID: UUID) async -> [InviteeInfo] {
        let ref = CloudPaths.inviteesCollection(ownerID: ownerUID, projectID: projectID)
        guard let snapshot = try? await ref.getDocuments() else { return [] }
        return decodeInvitees(snapshot)
    }

    /// Keeps the owner's accepted-listener view synchronized across iOS and web.
    static func observeInvitees(
        ownerUID: String,
        projectID: UUID,
        onChange: @escaping ([InviteeInfo]) -> Void
    ) -> ListenerRegistration {
        CloudPaths.inviteesCollection(ownerID: ownerUID, projectID: projectID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("ProjectInviteService: invitees listener failed — \(error)")
                    return
                }
                guard let snapshot else { return }
                onChange(decodeInvitees(snapshot))
            }
    }

    /// Writes the invitee document, granting read access to the full project.
    static func acceptInvite(
        ownerUID: String,
        projectID: UUID,
        recipientUID: String,
        recipientUsername: String
    ) async throws {
        let inviteeRef = CloudPaths.inviteeDocument(
            ownerID: ownerUID,
            projectID: projectID,
            inviteeID: recipientUID
        )
        let sharedProjectsRef = CloudPaths.sharedProjectsDocument(userID: recipientUID)
        let pendingRef = CloudPaths.pendingInviteDocument(
            ownerID: ownerUID,
            projectID: projectID,
            inviteeID: recipientUID
        )
        let pendingSnapshot = try? await pendingRef.getDocument()
        let notificationID = pendingSnapshot?.data()?["notificationID"] as? String
        let batch = Firestore.firestore().batch()
        batch.setData([
            "uid": recipientUID,
            "username": recipientUsername,
            "acceptedAt": Timestamp(date: Date()),
        ], forDocument: inviteeRef)
        batch.setData([
            "refs": [
                projectID.uuidString: [
                    "ownerID": ownerUID,
                    "addedAt": Timestamp(date: Date()),
                ],
            ],
        ], forDocument: sharedProjectsRef, merge: true)
        batch.deleteDocument(pendingRef)
        if let notificationID {
            batch.deleteDocument(
                CloudPaths.notificationDocument(
                    userID: recipientUID,
                    notificationID: notificationID
                )
            )
        }
        try await batch.commit()
    }

    /// Removes an invitee document (owner kicks or invitee leaves).
    static func removeInvitee(ownerUID: String, projectID: UUID, inviteeUID: String) async throws {
        let ref = CloudPaths.inviteeDocument(ownerID: ownerUID, projectID: projectID, inviteeID: inviteeUID)
        try await ref.delete()
    }

    /// Leaves a shared project everywhere by atomically removing both library
    /// membership and the read-access grant owned by this account.
    static func leaveSharedProject(
        ownerUID: String,
        projectID: UUID,
        userID: String
    ) async throws {
        let sharedProjectsRef = CloudPaths.sharedProjectsDocument(userID: userID)
        let inviteeRef = CloudPaths.inviteeDocument(
            ownerID: ownerUID,
            projectID: projectID,
            inviteeID: userID
        )
        let pendingRef = CloudPaths.pendingInviteDocument(
            ownerID: ownerUID,
            projectID: projectID,
            inviteeID: userID
        )
        let batch = Firestore.firestore().batch()
        batch.setData([
            "refs": [
                projectID.uuidString: FieldValue.delete(),
            ],
        ], forDocument: sharedProjectsRef, merge: true)
        batch.deleteDocument(inviteeRef)
        batch.deleteDocument(pendingRef)
        try await batch.commit()
    }

    /// Cleans a stale library reference after the owner deletes a project or
    /// revokes this account's access.
    static func removeSharedReference(userID: String, projectID: UUID) async {
        let ref = CloudPaths.sharedProjectsDocument(userID: userID)
        try? await ref.setData([
            "refs": [
                projectID.uuidString: FieldValue.delete(),
            ],
        ], merge: true)
    }

    /// One-time migration for iOS builds that predate the account-level shared
    /// project index. An existing server document always wins, including an
    /// intentionally empty one after the user left every shared project.
    static func seedSharedReferencesIfNeeded(
        userID: String,
        references: [SharedProjectReference]
    ) async -> Bool {
        guard !references.isEmpty else { return true }
        let ref = CloudPaths.sharedProjectsDocument(userID: userID)
        do {
            let snapshot = try await ref.getDocument(source: .server)
            guard !snapshot.exists else { return true }
            let values = Dictionary(uniqueKeysWithValues: references.map {
                (
                    $0.projectID.uuidString,
                    [
                        "ownerID": $0.ownerID,
                        "addedAt": Timestamp(date: Date()),
                    ] as [String: Any]
                )
            })
            try await ref.setData(["refs": values], merge: true)
            return true
        } catch {
            print("ProjectInviteService: shared-reference migration failed — \(error)")
            // Keep legacy local projects intact while offline. A future signed-in
            // session will retry the migration before treating the cloud index
            // as authoritative.
            return false
        }
    }

    // MARK: - Username invites

    /// Invites a user directly by their UID: records a pending invite (so they can join
    /// even when the general link is disabled) and writes an in-app notification to them.
    ///
    /// Returns the ID of the notification document so the caller can delete it if the
    /// invite is later cancelled.
    @discardableResult
    static func inviteUser(
        recipientUID: String,
        recipientUsername: String,
        project: Project,
        ownerUID: String,
        ownerUsername: String
    ) async throws -> String {
        // Make sure the preview exists so the recipient's invite sheet can load.
        await writePreview(project: project, ownerUID: ownerUID, ownerUsername: ownerUsername)

        // A stable ID makes re-inviting idempotent across iOS and web and
        // guarantees there is only one notification to withdraw.
        let notificationID = inviteNotificationID(ownerUID: ownerUID, projectID: project.id)
        let noteRef = CloudPaths.notificationDocument(
            userID: recipientUID,
            notificationID: notificationID
        )
        let pendingRef = CloudPaths.pendingInviteDocument(
            ownerID: ownerUID, projectID: project.id, inviteeID: recipientUID
        )
        let now = Timestamp(date: Date())
        let batch = Firestore.firestore().batch()
        var notificationData: [String: Any] = [
            "type": AppNotification.Kind.projectInvite.rawValue,
            "fromUID": ownerUID,
            "fromUsername": ownerUsername,
            "projectID": project.id.uuidString,
            "projectName": project.name,
            "projectGradient": encodeGradient(project.gradient),
            "recipientUsername": recipientUsername,
            "createdAt": now,
            "read": false,
        ]
        if let coverStoragePath = project.coverStoragePath {
            notificationData["coverStoragePath"] = coverStoragePath
        }
        batch.setData(notificationData, forDocument: noteRef)
        batch.setData([
            "uid": recipientUID,
            "username": recipientUsername,
            "invitedAt": now,
            "notificationID": notificationID,
        ], forDocument: pendingRef)
        try await batch.commit()

        return notificationID
    }

    /// True when an explicit username invite is still pending for this user.
    static func hasPendingInvite(ownerUID: String, projectID: UUID, inviteeUID: String) async -> Bool {
        let ref = CloudPaths.pendingInviteDocument(ownerID: ownerUID, projectID: projectID, inviteeID: inviteeUID)
        return (try? await ref.getDocument().exists) ?? false
    }

    /// Removes a pending invite (after acceptance, or when leaving a project).
    static func clearPendingInvite(ownerUID: String, projectID: UUID, inviteeUID: String) async {
        let ref = CloudPaths.pendingInviteDocument(ownerID: ownerUID, projectID: projectID, inviteeID: inviteeUID)
        try? await ref.delete()
    }

    /// Returns all users who have a pending (not-yet-accepted) username invite (owner-only read).
    static func fetchPendingInvites(ownerUID: String, projectID: UUID) async -> [PendingInviteInfo] {
        let ref = CloudPaths.pendingInvitesCollection(ownerID: ownerUID, projectID: projectID)
        guard let snapshot = try? await ref.getDocuments() else { return [] }
        return decodePendingInvites(snapshot)
    }

    /// Keeps the owner's pending list live. This also lets server-side repair of
    /// legacy orphan notifications appear without closing and reopening the sheet.
    static func observePendingInvites(
        ownerUID: String,
        projectID: UUID,
        onChange: @escaping ([PendingInviteInfo]) -> Void
    ) -> ListenerRegistration {
        CloudPaths.pendingInvitesCollection(ownerID: ownerUID, projectID: projectID)
            .addSnapshotListener { snapshot, error in
                if let error {
                    print("ProjectInviteService: pending-invites listener failed — \(error)")
                    return
                }
                guard let snapshot else { return }
                onChange(decodePendingInvites(snapshot))
            }
    }

    /// Cancels a pending username invite: deletes the recipient's in-app notification
    /// (best-effort) and removes the pending invite document.
    static func cancelInvite(
        ownerUID: String,
        projectID: UUID,
        inviteeUID: String,
        notificationID: String?
    ) async throws {
        let pendingRef = CloudPaths.pendingInviteDocument(
            ownerID: ownerUID,
            projectID: projectID,
            inviteeID: inviteeUID
        )
        let batch = Firestore.firestore().batch()
        if let notificationID {
            let noteRef = CloudPaths.notificationDocument(
                userID: inviteeUID, notificationID: notificationID
            )
            batch.deleteDocument(noteRef)
        }
        batch.deleteDocument(pendingRef)
        do {
            try await batch.commit()
        } catch {
            // The recipient may already have deleted their notification. In
            // that case its sender cannot authorize deleting a missing doc, but
            // revoking the pending grant must still succeed. The delete trigger
            // performs authoritative notification cleanup.
            try await pendingRef.delete()
        }
    }

    // MARK: - Private helpers

    static func decodePreview(
        _ data: [String: Any],
        ownerUID: String,
        projectID: UUID
    ) -> ProjectPreview? {
        guard let name = data["name"] as? String,
              let ownerUsername = data["ownerUsername"] as? String,
              let gradientData = data["gradient"] as? [String: Any],
              let gradient = decodeGradient(gradientData)
        else { return nil }

        return ProjectPreview(
            projectID: projectID,
            ownerUID: ownerUID,
            ownerUsername: ownerUsername,
            projectName: name,
            gradient: gradient,
            coverStoragePath: data["coverStoragePath"] as? String,
            accentColorHex: data["accentColorHex"] as? String,
            // Older preview docs predate this flag; treat them as enabled.
            linkEnabled: data["linkEnabled"] as? Bool ?? true
        )
    }

    private static func inviteNotificationID(ownerUID: String, projectID: UUID) -> String {
        "projectInvite-\(ownerUID)-\(projectID.uuidString)"
    }

    private static func decodeInvitees(_ snapshot: QuerySnapshot) -> [InviteeInfo] {
        snapshot.documents.compactMap { doc in
            let data = doc.data()
            guard let username = data["username"] as? String,
                  let ts = data["acceptedAt"] as? Timestamp
            else { return nil }
            return InviteeInfo(id: doc.documentID, username: username, acceptedAt: ts.dateValue())
        }
        .sorted { $0.acceptedAt < $1.acceptedAt }
    }

    private static func decodePendingInvites(_ snapshot: QuerySnapshot) -> [PendingInviteInfo] {
        snapshot.documents.compactMap { doc in
            let data = doc.data()
            guard let username = data["username"] as? String,
                  let ts = data["invitedAt"] as? Timestamp
            else { return nil }
            return PendingInviteInfo(
                id: doc.documentID,
                username: username,
                invitedAt: ts.dateValue(),
                notificationID: data["notificationID"] as? String
            )
        }
        .sorted { $0.invitedAt < $1.invitedAt }
    }

    private static func encodeGradient(_ gradient: GradientTheme) -> [String: Any] {
        [
            "colors": gradient.colors,
            "startX": gradient.startX,
            "startY": gradient.startY,
            "endX": gradient.endX,
            "endY": gradient.endY,
        ]
    }

    private static func decodeGradient(_ data: [String: Any]) -> GradientTheme? {
        guard let colors = data["colors"] as? [String],
              let startX = data["startX"] as? Double,
              let startY = data["startY"] as? Double,
              let endX = data["endX"] as? Double,
              let endY = data["endY"] as? Double
        else { return nil }
        return GradientTheme(colors: colors, startX: startX, startY: startY, endX: endX, endY: endY)
    }
}

// MARK: - Async DocumentReference helpers (mirrors ProjectSyncService)

private extension DocumentReference {
    func setData(_ documentData: [String: Any]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setData(documentData) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

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
