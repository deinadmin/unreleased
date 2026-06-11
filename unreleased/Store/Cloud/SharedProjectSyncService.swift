import FirebaseFirestore
import Foundation

/// Manages real-time Firestore listeners for projects shared from other users.
/// Each listener watches a single document at `users/{ownerID}/projects/{projectID}`.
@MainActor
final class SharedProjectSyncService {
    typealias ProjectUpdater = (_ project: Project) -> Void
    typealias ProjectRemover = (_ projectID: UUID) -> Void

    private let projectUpdater: ProjectUpdater
    private let projectRemover: ProjectRemover
    private var listeners: [UUID: ListenerRegistration] = [:]

    init(
        projectUpdater: @escaping ProjectUpdater,
        projectRemover: @escaping ProjectRemover
    ) {
        self.projectUpdater = projectUpdater
        self.projectRemover = projectRemover
    }

    // MARK: - Subscription management

    func subscribe(ownerID: String, projectID: UUID) {
        guard listeners[projectID] == nil else { return }

        let doc = Firestore.firestore()
            .collection("users").document(ownerID)
            .collection("projects").document(projectID.uuidString)

        let registration = doc.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            Task { @MainActor in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == FirestoreErrorDomain,
                       nsError.code == FirestoreErrorCode.permissionDenied.rawValue {
                        // Owner revoked access (deleted the invitee document).
                        // Treat it the same as the project being deleted.
                        self.projectRemover(projectID)
                    } else {
                        print("SharedProjectSyncService: listener error for \(projectID) — \(error)")
                    }
                    return
                }
                if let snapshot, snapshot.exists, var project = FirestoreProjectCodec.decode(snapshot) {
                    project.ownerID = ownerID
                    self.projectUpdater(project)
                } else if error == nil {
                    // Document removed — owner deleted the project.
                    self.projectRemover(projectID)
                }
            }
        }
        listeners[projectID] = registration
    }

    func unsubscribe(projectID: UUID) {
        listeners[projectID]?.remove()
        listeners.removeValue(forKey: projectID)
    }

    func stop() {
        listeners.values.forEach { $0.remove() }
        listeners.removeAll()
    }

    // MARK: - One-shot fetch

    func fetchProject(ownerID: String, projectID: UUID) async -> Project? {
        let doc = Firestore.firestore()
            .collection("users").document(ownerID)
            .collection("projects").document(projectID.uuidString)

        do {
            let snapshot = try await doc.getDocument()
            guard snapshot.exists, var project = FirestoreProjectCodec.decode(snapshot) else { return nil }
            project.ownerID = ownerID
            return project
        } catch {
            print("SharedProjectSyncService: fetch failed for \(projectID) — \(error)")
            return nil
        }
    }
}
