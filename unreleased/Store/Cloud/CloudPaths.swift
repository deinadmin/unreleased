import FirebaseFirestore
import FirebaseStorage
import Foundation

enum CloudPaths {
    // MARK: - User documents

    static func userDocument(userID: String) -> DocumentReference {
        Firestore.firestore()
            .collection("users")
            .document(userID)
    }

    /// App-writable user profile doc: `userProfiles/{userID}` (contains `username`).
    static func userProfileDocument(userID: String) -> DocumentReference {
        Firestore.firestore()
            .collection("userProfiles")
            .document(userID)
    }

    /// Username uniqueness index: `usernames/{username}` → `{uid}`.
    static func usernamesCollection() -> CollectionReference {
        Firestore.firestore().collection("usernames")
    }

    static func usernameDocument(username: String) -> DocumentReference {
        usernamesCollection().document(username.lowercased())
    }

    /// Private per-user data the user can read/write but others cannot
    /// (e.g. the FCM push token). `users/{userID}/private/{docID}`.
    static func userPrivateDocument(userID: String, docID: String) -> DocumentReference {
        userDocument(userID: userID).collection("private").document(docID)
    }

    // MARK: - Notifications

    /// In-app notifications addressed to a user: `users/{userID}/notifications`.
    static func notificationsCollection(userID: String) -> CollectionReference {
        userDocument(userID: userID).collection("notifications")
    }

    static func notificationDocument(userID: String, notificationID: String) -> DocumentReference {
        notificationsCollection(userID: userID).document(notificationID)
    }

    // MARK: - Projects

    static func projectsCollection(userID: String) -> CollectionReference {
        userDocument(userID: userID).collection("projects")
    }

    static func projectDocument(userID: String, projectID: UUID) -> DocumentReference {
        projectsCollection(userID: userID).document(projectID.uuidString)
    }

    // MARK: - Invite previews

    /// Small publicly-readable preview used to show invite prompts before acceptance.
    /// `users/{ownerID}/projectPreviews/{projectID}`
    static func projectPreviewDocument(ownerID: String, projectID: UUID) -> DocumentReference {
        userDocument(userID: ownerID)
            .collection("projectPreviews")
            .document(projectID.uuidString)
    }

    // MARK: - Invitees

    /// Subcollection of users who accepted a project invite.
    /// `users/{ownerID}/projects/{projectID}/invitees`
    static func inviteesCollection(ownerID: String, projectID: UUID) -> CollectionReference {
        projectDocument(userID: ownerID, projectID: projectID)
            .collection("invitees")
    }

    static func inviteeDocument(ownerID: String, projectID: UUID, inviteeID: String) -> DocumentReference {
        inviteesCollection(ownerID: ownerID, projectID: projectID).document(inviteeID)
    }

    /// Subcollection of users explicitly invited by username. Lets them join even
    /// when the general share link is disabled.
    /// `users/{ownerID}/projects/{projectID}/pendingInvites`
    static func pendingInvitesCollection(ownerID: String, projectID: UUID) -> CollectionReference {
        projectDocument(userID: ownerID, projectID: projectID)
            .collection("pendingInvites")
    }

    static func pendingInviteDocument(ownerID: String, projectID: UUID, inviteeID: String) -> DocumentReference {
        pendingInvitesCollection(ownerID: ownerID, projectID: projectID).document(inviteeID)
    }

    // MARK: - Storage

    static func audioStoragePath(userID: String, trackID: UUID, fileExtension: String) -> String {
        "users/\(userID)/audio/\(trackID.uuidString.lowercased()).\(fileExtension)"
    }

    static func coverStoragePath(userID: String, fileName: String) -> String {
        "users/\(userID)/covers/\(fileName)"
    }

    static func storageReference(storagePath: String) -> StorageReference {
        Storage.storage().reference(withPath: storagePath)
    }

    static func audioReference(storagePath: String) -> StorageReference {
        storageReference(storagePath: storagePath)
    }
}
