import Foundation
import Observation

@Observable
final class AudioFileImportManager {
    /// All files in the current pending batch.
    private(set) var pendingItems: [(url: URL, title: String?)] = []
    private(set) var destinationProjectID: UUID?
    /// Increments whenever a new batch arrives — use as an onChange trigger.
    private(set) var pendingImportToken: UUID?

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
    }

    /// Reads any batch staged by the share extension via the App Group.
    func loadPendingImportIfNeeded() {
        guard pendingItems.isEmpty,
              let pending = AudioImportBridge.consumePendingImport()
        else { return }
        pendingItems = pending.items
        destinationProjectID = pending.destinationProjectID
        pendingImportToken = UUID()
    }

    // MARK: - Cleanup

    func clearPending() {
        for item in pendingItems {
            try? FileManager.default.removeItem(at: item.url)
        }
        pendingItems = []
        destinationProjectID = nil
    }

    /// Clears the destination so the sheet picker is shown as a fallback.
    func clearDestination() {
        destinationProjectID = nil
    }

    /// Legacy alias used by SaveInSheet.
    func clearURL() { clearPending() }
}
