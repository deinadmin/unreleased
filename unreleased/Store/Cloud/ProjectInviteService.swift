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
            "updatedAt": Timestamp(date: Date()),
        ]
        if let hex = project.accentColorHex { data["accentColorHex"] = hex }

        let existing = try? await ref.getDocument()
        if existing?.data()?["linkEnabled"] == nil {
            data["linkEnabled"] = true
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
        return snapshot.documents.compactMap { doc in
            let data = doc.data()
            guard let username = data["username"] as? String,
                  let ts = data["acceptedAt"] as? Timestamp
            else { return nil }
            return InviteeInfo(id: doc.documentID, username: username, acceptedAt: ts.dateValue())
        }
    }

    /// Writes the invitee document, granting read access to the full project.
    static func acceptInvite(
        ownerUID: String,
        projectID: UUID,
        recipientUID: String,
        recipientUsername: String
    ) async throws {
        let ref = CloudPaths.inviteeDocument(ownerID: ownerUID, projectID: projectID, inviteeID: recipientUID)
        try await ref.setData([
            "uid": recipientUID,
            "username": recipientUsername,
            "acceptedAt": Timestamp(date: Date()),
        ])
    }

    /// Removes an invitee document (owner kicks or invitee leaves).
    static func removeInvitee(ownerUID: String, projectID: UUID, inviteeUID: String) async throws {
        let ref = CloudPaths.inviteeDocument(ownerID: ownerUID, projectID: projectID, inviteeID: inviteeUID)
        try await ref.delete()
    }

    // MARK: - Username invites

    /// Invites a user directly by their UID: records a pending invite (so they can join
    /// even when the general link is disabled) and writes an in-app notification to them.
    static func inviteUser(
        recipientUID: String,
        recipientUsername: String,
        project: Project,
        ownerUID: String,
        ownerUsername: String
    ) async throws {
        // Make sure the preview exists so the recipient's invite sheet can load.
        await writePreview(project: project, ownerUID: ownerUID, ownerUsername: ownerUsername)

        let pendingRef = CloudPaths.pendingInviteDocument(
            ownerID: ownerUID, projectID: project.id, inviteeID: recipientUID
        )
        try await pendingRef.setData([
            "uid": recipientUID,
            "username": recipientUsername,
            "invitedAt": Timestamp(date: Date()),
        ])

        // Deliver an in-app notification the recipient can read.
        let noteRef = CloudPaths.notificationsCollection(userID: recipientUID).document()
        try await noteRef.setData([
            "type": AppNotification.Kind.projectInvite.rawValue,
            "fromUID": ownerUID,
            "fromUsername": ownerUsername,
            "projectID": project.id.uuidString,
            "projectName": project.name,
            "createdAt": Timestamp(date: Date()),
            "read": false,
        ])
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

    // MARK: - Private helpers

    private static func decodePreview(
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
            accentColorHex: data["accentColorHex"] as? String,
            // Older preview docs predate this flag; treat them as enabled.
            linkEnabled: data["linkEnabled"] as? Bool ?? true
        )
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
