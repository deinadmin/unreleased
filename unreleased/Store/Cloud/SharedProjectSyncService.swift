import FirebaseFirestore
import Foundation

struct SharedProjectReference: Hashable, Sendable {
    let ownerID: String
    let projectID: UUID
}

/// Manages real-time Firestore listeners for projects shared from other users.
/// Each listener watches a single document at `users/{ownerID}/projects/{projectID}`.
@MainActor
final class SharedProjectSyncService {
    typealias ProjectUpdater = (_ project: Project) -> Void
    typealias ProjectRemover = (_ projectID: UUID) -> Void
    typealias ReferencesUpdater = (_ references: [SharedProjectReference]) -> Void

    private let projectUpdater: ProjectUpdater
    private let projectRemover: ProjectRemover
    private let referencesUpdater: ReferencesUpdater
    private var listeners: [UUID: ListenerRegistration] = [:]
    private var referencesListener: ListenerRegistration?
    private var referencesUserID: String?

    init(
        projectUpdater: @escaping ProjectUpdater,
        projectRemover: @escaping ProjectRemover,
        referencesUpdater: @escaping ReferencesUpdater
    ) {
        self.projectUpdater = projectUpdater
        self.projectRemover = projectRemover
        self.referencesUpdater = referencesUpdater
    }

    // MARK: - Subscription management

    /// Watches the account-level shared-project index used by every client.
    /// Older iOS installs stored shared projects only in local JSON; when the
    /// server index has never existed, seed it once from those local entries.
    func startReferenceSync(
        userID: String,
        seedReferences: [SharedProjectReference]
    ) async {
        referencesListener?.remove()
        referencesListener = nil
        referencesUserID = userID

        let canStartListener = await ProjectInviteService.seedSharedReferencesIfNeeded(
            userID: userID,
            references: seedReferences
        )
        guard referencesUserID == userID, canStartListener else { return }

        let doc = CloudPaths.sharedProjectsDocument(userID: userID)
        referencesListener = doc.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            Task { @MainActor in
                guard self.referencesUserID == userID else { return }
                if let error {
                    print("SharedProjectSyncService: references listener failed — \(error)")
                    return
                }
                self.referencesUpdater(Self.decodeReferences(snapshot?.data()))
            }
        }
    }

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
                    project.selectPublicVersionsForSharedPlayback()
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
        referencesUserID = nil
        referencesListener?.remove()
        referencesListener = nil
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
            project.selectPublicVersionsForSharedPlayback()
            return project
        } catch {
            print("SharedProjectSyncService: fetch failed for \(projectID) — \(error)")
            return nil
        }
    }

    private static func decodeReferences(_ data: [String: Any]?) -> [SharedProjectReference] {
        guard let refs = data?["refs"] as? [String: Any] else { return [] }
        return refs.compactMap { projectID, rawValue in
            guard let id = UUID(uuidString: projectID),
                  let value = rawValue as? [String: Any],
                  let ownerID = value["ownerID"] as? String,
                  !ownerID.isEmpty
            else { return nil }
            return SharedProjectReference(ownerID: ownerID, projectID: id)
        }
    }
}

private extension Project {
    mutating func selectPublicVersionsForSharedPlayback() {
        for index in tracks.indices where !tracks[index].versions.isEmpty {
            let activeIsPublic = tracks[index].versions.contains {
                $0.id == tracks[index].activeVersionID && $0.isPublic
            }
            if !activeIsPublic, let publicVersion = tracks[index].versions.first(where: \.isPublic) {
                tracks[index].selectVersion(id: publicVersion.id)
            }
        }
    }
}
