import FirebaseFirestore
import FirebaseStorage
import Foundation

enum CloudPaths {
    static func projectsCollection(userID: String) -> CollectionReference {
        Firestore.firestore()
            .collection("users")
            .document(userID)
            .collection("projects")
    }

    static func projectDocument(userID: String, projectID: UUID) -> DocumentReference {
        projectsCollection(userID: userID).document(projectID.uuidString)
    }

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
