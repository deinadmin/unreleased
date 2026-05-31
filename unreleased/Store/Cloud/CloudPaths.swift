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
    static func usernameDocument(username: String) -> DocumentReference {
        Firestore.firestore()
            .collection("usernames")
            .document(username.lowercased())
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
