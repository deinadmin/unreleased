import SwiftUI

enum PlayerChrome {
    /// Mini player bar, toast banner, and scrub time pill.
    static let surfaceBackground = Color(white: 0.13)
}

@Observable
@MainActor
final class PlayerToastCenter {
    struct Toast: Equatable, Identifiable {
        enum Icon: Equatable {
            case system(String)
            case spinner
        }

        let id: UUID
        let message: String
        let icon: Icon
    }

    private(set) var toasts: [Toast] = []
    private var hideTasks: [UUID: Task<Void, Never>] = [:]
    private var activeImports: [UUID: Int] = [:]

    private static let maximumVisibleToastCount = 3

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
        let id = UUID()
        activeImports[id] = max(fileCount, 1)
        updateImportToast()
        return id
    }

    func finishImporting(id: UUID) {
        guard activeImports.removeValue(forKey: id) != nil else { return }
        if activeImports.isEmpty {
            guard let toast = toasts.first(where: { $0.icon == .spinner }) else { return }
            hideAnimated(id: toast.id)
        } else {
            updateImportToast()
        }
    }

    private func updateImportToast() {
        let fileCount = activeImports.values.reduce(0, +)
        let message = fileCount == 1 ? "Importing track…" : "Importing tracks…"

        if let index = toasts.firstIndex(where: { $0.icon == .spinner }) {
            let toastID = toasts[index].id
            withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
                toasts[index] = Toast(id: toastID, message: message, icon: .spinner)
            }
        } else {
            push(Toast(id: UUID(), message: message, icon: .spinner))
        }
    }

    func show(message: String, systemImage: String) {
        let toast = Toast(id: UUID(), message: message, icon: .system(systemImage))
        push(toast)

        hideTasks[toast.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            self?.hideAnimated(id: toast.id)
        }
    }

    private func push(_ toast: Toast) {
        var evictedToastID: UUID?

        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            if toasts.count == Self.maximumVisibleToastCount {
                evictedToastID = toasts.removeFirst().id
            }
            toasts.append(toast)
        }

        if let evictedToastID {
            hideTasks.removeValue(forKey: evictedToastID)?.cancel()
        }
    }

    private func hideAnimated(id: UUID) {
        hideTasks.removeValue(forKey: id)?.cancel()
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }

        withAnimation(.easeOut(duration: 0.28)) {
            _ = toasts.remove(at: index)
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
        .glassEffect(
            .regular.interactive().tint(PlayerChrome.surfaceBackground),
            in: .capsule
        )
    }
}
