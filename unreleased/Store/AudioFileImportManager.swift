import Foundation
import Observation

@Observable
final class AudioFileImportManager {
    /// All files in the current pending batch.
    private(set) var pendingItems: [(url: URL, title: String?)] = []
    private(set) var destinationProjectID: UUID?
    /// Increments whenever a new batch arrives — use as an onChange trigger.
    private(set) var pendingImportToken: UUID?
    /// Direct document URLs can point into another app or file provider and must
    /// never be deleted. Copies delivered inside our own sandbox are safe to clean up.
    private var ownsPendingFiles = false

    // MARK: - Convenience for single-file flows (SaveInSheet / direct open)

    var audioURL: URL? { pendingItems.first?.url }
    var originalTitle: String? { pendingItems.first?.title }

    // MARK: - Loading

    /// Called when the app receives a direct audio URL (e.g. opened from Files).
    func setDirectImport(url: URL) {
        let title = url.deletingPathExtension().lastPathComponent
        pendingItems = [(url: url, title: title.isEmpty ? nil : title)]
        destinationProjectID = nil
        pendingImportToken = UUID()
        let appContainerPath = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        ownsPendingFiles = url.standardizedFileURL.path.hasPrefix(appContainerPath + "/")
    }

    /// Reads any batch staged by the share extension via the App Group.
    func loadPendingImportIfNeeded() {
        guard pendingItems.isEmpty,
              let pending = AudioImportBridge.consumePendingImport()
        else { return }
        pendingItems = pending.items
        destinationProjectID = pending.destinationProjectID
        pendingImportToken = UUID()
        ownsPendingFiles = true
    }

    // MARK: - Cleanup

    func clearPending() {
        let filesToRemove = ownsPendingFiles ? pendingItems.map(\.url) : []
        pendingItems = []
        destinationProjectID = nil
        ownsPendingFiles = false

        guard !filesToRemove.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in filesToRemove {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Clears the destination so the sheet picker is shown as a fallback.
    func clearDestination() {
        destinationProjectID = nil
    }

    /// Legacy alias used by SaveInSheet.
    func clearURL() { clearPending() }
}
