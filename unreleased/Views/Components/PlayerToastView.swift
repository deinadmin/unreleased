import SwiftUI

enum PlayerChrome {
    /// Mini player bar, toast banner, and scrub time pill.
    static let surfaceBackground = Color(white: 0.13)
}

@Observable
@MainActor
final class PlayerToastCenter {
    struct Toast: Equatable {
        enum Icon: Equatable {
            case system(String)
            case spinner
        }

        let id: UUID
        let message: String
        let icon: Icon
    }

    private(set) var toast: Toast?
    private var hideTask: Task<Void, Never>?
    private var activeImports: [UUID: Int] = [:]

    func showTrackQueued() {
        show(
            message: "Added to queue",
            systemImage: "text.line.first.and.arrowtriangle.forward"
        )
    }

    func showTrackDeleted() {
        show(message: "Track deleted", systemImage: "trash")
    }

    func showTrackMoved(to projectName: String) {
        show(message: "Moved to \(projectName)", systemImage: "arrow.right.square")
    }

    func showTrackAdded(to projectName: String) {
        show(message: "Added to \(projectName)", systemImage: "plus.circle")
    }

    /// Shows a persistent import status and returns the identifier needed to
    /// dismiss this exact toast when its background work completes.
    @discardableResult
    func showImporting(fileCount: Int) -> UUID {
        hideTask?.cancel()
        let id = UUID()
        activeImports[id] = max(fileCount, 1)
        updateImportToast()
        return id
    }

    func finishImporting(id: UUID) {
        guard activeImports.removeValue(forKey: id) != nil else { return }
        if activeImports.isEmpty {
            guard toast?.icon == .spinner else { return }
            hideAnimated()
        } else {
            updateImportToast()
        }
    }

    private func updateImportToast() {
        let fileCount = activeImports.values.reduce(0, +)
        let message = fileCount == 1 ? "Importing track…" : "Importing tracks…"
        let toastID = toast?.icon == .spinner ? toast?.id ?? UUID() : UUID()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            toast = Toast(id: toastID, message: message, icon: .spinner)
        }
    }

    func show(message: String, systemImage: String) {
        // Import status is persistent and has priority until every active batch
        // has completed.
        guard activeImports.isEmpty else { return }
        hideTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            toast = Toast(id: UUID(), message: message, icon: .system(systemImage))
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            hideAnimated()
        }
    }

    private func hideAnimated() {
        withAnimation(.easeOut(duration: 0.28)) {
            toast = nil
        }
    }
}

struct PlayerToastBanner: View {
    let toast: PlayerToastCenter.Toast

    var body: some View {
        HStack(spacing: 8) {
            switch toast.icon {
            case .system(let systemImage):
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
            case .spinner:
                TwoToneCircleSpinner(diameter: 14, lineWidth: 1.5)
                    .environment(\.colorScheme, .dark)
            }

            Text(toast.message)
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PlayerChrome.surfaceBackground, in: Capsule())
    }
}
