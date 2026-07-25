import FirebaseFirestore
import Foundation

/// Keeps the account's custom EQ presets in sync. The current curve and enabled
/// state remain device-local in UserDefaults.
@MainActor
final class EqualizerSyncService {
    struct State: Equatable, Sendable {
        var customPresets: [CustomEqualizerPreset]
    }

    private var listener: ListenerRegistration?
    private var uploadTask: Task<Void, Never>?
    private var document: DocumentReference?
    private var latestState: State?
    private var onRemoteUpdate: ((State) -> Void)?
    private var hasReceivedInitialSnapshot = false
    private var changedBeforeInitialSnapshot = false
    private var localRevision = 0
    private var finishedRevision = 0

    deinit {
        listener?.remove()
        uploadTask?.cancel()
    }

    func start(
        userID: String,
        localState: State,
        onRemoteUpdate: @escaping (State) -> Void
    ) {
        stop()

        let document = CloudPaths.equalizerPresetsDocument(userID: userID)
        self.document = document
        self.latestState = localState
        self.onRemoteUpdate = onRemoteUpdate

        listener = document.addSnapshotListener { [weak self] snapshot, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    print("EqualizerSyncService: listener error — \(error)")
                    return
                }
                self.receive(snapshot)
            }
        }
    }

    func stop() {
        listener?.remove()
        listener = nil
        uploadTask?.cancel()
        uploadTask = nil
        document = nil
        latestState = nil
        onRemoteUpdate = nil
        hasReceivedInitialSnapshot = false
        changedBeforeInitialSnapshot = false
        localRevision = 0
        finishedRevision = 0
    }

    func stateDidChange(_ state: State) {
        latestState = state
        localRevision &+= 1

        guard hasReceivedInitialSnapshot else {
            changedBeforeInitialSnapshot = true
            return
        }
        scheduleUpload()
    }

    private var hasPendingLocalChange: Bool {
        localRevision > finishedRevision
    }

    private func receive(_ snapshot: DocumentSnapshot?) {
        guard let snapshot else { return }
        let remoteState = Self.decode(snapshot.data())

        if !hasReceivedInitialSnapshot {
            hasReceivedInitialSnapshot = true

            if let remoteState {
                if changedBeforeInitialSnapshot {
                    scheduleUpload()
                } else {
                    acceptRemote(remoteState)
                }
            } else if snapshot.exists {
                // Repair an invalid document with the known-good local cache.
                scheduleUpload()
            } else {
                createDocumentIfMissing()
            }
            return
        }

        guard let remoteState else { return }

        // A remote snapshot can race a local save/rename/delete. Keep the
        // explicit local preset action; its write becomes the shared state.
        if hasPendingLocalChange, remoteState != latestState {
            return
        }
        acceptRemote(remoteState)
    }

    private func acceptRemote(_ state: State) {
        latestState = state
        localRevision = 0
        finishedRevision = 0
        onRemoteUpdate?(state)
    }

    private func scheduleUpload() {
        uploadTask?.cancel()
        uploadTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await self?.uploadLatestState()
        }
    }

    private func uploadLatestState() async {
        guard let document, let state = latestState else { return }
        let revision = localRevision

        do {
            try await document.setData(Self.encode(state))
            if localRevision == revision {
                finishedRevision = revision
            }
        } catch {
            print("EqualizerSyncService: upload failed — \(error)")
        }
    }

    /// Uses a transaction so two devices migrating their local state at the
    /// same time cannot overwrite an EQ document that already exists.
    private func createDocumentIfMissing() {
        guard let document, let state = latestState else { return }
        let database = Firestore.firestore()

        database.runTransaction({ transaction, errorPointer in
            do {
                let snapshot = try transaction.getDocument(document)
                if !snapshot.exists {
                    transaction.setData(Self.encode(state), forDocument: document)
                }
            } catch let transactionError as NSError {
                errorPointer?.pointee = transactionError
            }
            return nil
        }) { _, error in
            if let error {
                print("EqualizerSyncService: initial upload failed — \(error)")
            }
        }
    }

    private static func encode(_ state: State) -> [String: Any] {
        [
            "schemaVersion": 1,
            "customPresets": state.customPresets.map { preset in
                [
                    "id": preset.id.uuidString.lowercased(),
                    "title": preset.title,
                    "gains": preset.gains.map(Double.init),
                ]
            },
            "updatedAt": FieldValue.serverTimestamp(),
        ]
    }

    private static func decode(_ data: [String: Any]?) -> State? {
        guard let data else { return nil }

        let presetData = data["customPresets"] as? [[String: Any]] ?? []
        let customPresets = presetData.compactMap { item -> CustomEqualizerPreset? in
            guard let idString = item["id"] as? String,
                  let id = UUID(uuidString: idString),
                  let rawTitle = item["title"] as? String,
                  let presetGains = decodeGains(item["gains"])
            else { return nil }

            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
            return CustomEqualizerPreset(id: id, title: title, gains: presetGains)
        }

        return State(customPresets: customPresets)
    }

    private static func decodeGains(_ value: Any?) -> [Float]? {
        guard let numbers = value as? [NSNumber],
              numbers.count == EqualizerBand.all.count
        else { return nil }

        let gains = numbers.map(\.floatValue)
        guard gains.allSatisfy(\.isFinite) else { return nil }
        return gains.map { min(max($0, -12), 12) }
    }
}
