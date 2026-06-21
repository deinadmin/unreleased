import FirebaseFirestore
import Foundation

/// Server-reported storage usage and quota state, maintained by the
/// `enforceAudioStorageLimit` Cloud Function. This is the authoritative quota
/// view — a tampered client cannot fake it because the document is read-only.
struct StorageEnforcementState {
    /// Bytes the server currently counts against the user's audio quota.
    let usedBytes: Int64
    /// Plan limit in bytes; nil means unlimited.
    let limitBytes: Int64?
    /// True when the server considers the user over their limit.
    let overLimit: Bool
    /// Timestamp of the most recent upload the server rejected for being over quota.
    let lastBlockedAt: Date?
    /// Track id of the most recently rejected upload, if any.
    let lastBlockedTrackID: String?
}

/// Listens to `users/{userID}/storage/state` and reports server-side quota
/// rejections so the client can surface an upsell when an upload was blocked
/// (the backstop for a modified app that ignored the local capacity checks).
final class StorageEnforcementService {
    private var listener: ListenerRegistration?
    private var userID: String?

    /// `onRejection` fires once per *new* server rejection (deduplicated across
    /// launches via UserDefaults so the user isn't nagged repeatedly).
    func start(
        userID: String,
        onState: @escaping @MainActor (StorageEnforcementState) -> Void,
        onRejection: @escaping @MainActor () -> Void
    ) {
        stop()
        self.userID = userID
        let ref = CloudPaths.storageStateDocument(userID: userID)
        listener = ref.addSnapshotListener { [weak self] snapshot, error in
            guard let self else { return }
            if let error {
                print("StorageEnforcementService: listener error — \(error)")
                return
            }
            guard let state = Self.decode(snapshot: snapshot) else { return }

            let isNewRejection = self.consumeRejectionIfNew(state.lastBlockedAt, userID: userID)
            Task { @MainActor in
                onState(state)
                if isNewRejection { onRejection() }
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        userID = nil
    }

    // MARK: - Rejection dedup

    private func rejectionDefaultsKey(_ userID: String) -> String {
        "storageEnforcement.lastBlockedAt.\(userID)"
    }

    /// Returns true when `blockedAt` is newer than the last rejection we surfaced
    /// for this user, persisting the new high-water mark so we only prompt once.
    private func consumeRejectionIfNew(_ blockedAt: Date?, userID: String) -> Bool {
        guard let blockedAt else { return false }
        let key = rejectionDefaultsKey(userID)
        let previous = UserDefaults.standard.double(forKey: key)
        let timestamp = blockedAt.timeIntervalSince1970
        guard timestamp > previous + 0.5 else { return false }
        UserDefaults.standard.set(timestamp, forKey: key)
        return true
    }

    // MARK: - Decoding

    private static func decode(snapshot: DocumentSnapshot?) -> StorageEnforcementState? {
        guard let data = snapshot?.data() else { return nil }

        let usedBytes = (data["usedBytes"] as? NSNumber)?.int64Value ?? 0
        let limitBytes = (data["limitBytes"] as? NSNumber)?.int64Value
        let overLimit = data["overLimit"] as? Bool ?? false
        let lastBlockedAt = (data["lastBlockedAt"] as? Timestamp)?.dateValue()
        let lastBlockedTrackID = data["lastBlockedTrackId"] as? String

        return StorageEnforcementState(
            usedBytes: usedBytes,
            limitBytes: limitBytes,
            overLimit: overLimit,
            lastBlockedAt: lastBlockedAt,
            lastBlockedTrackID: lastBlockedTrackID
        )
    }
}
