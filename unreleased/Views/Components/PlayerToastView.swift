import SwiftUI

enum PlayerChrome {
    /// Mini player bar, toast banner, and scrub time pill.
    static let surfaceBackground = Color(white: 0.13)
}

@Observable
@MainActor
final class PlayerToastCenter {
    struct Toast: Equatable {
        let id = UUID()
        let message: String
        let systemImage: String
    }

    private(set) var toast: Toast?
    private var hideTask: Task<Void, Never>?

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

    func show(message: String, systemImage: String) {
        hideTask?.cancel()
        withAnimation(.spring(response: 0.4, dampingFraction: 0.86)) {
            toast = Toast(message: message, systemImage: systemImage)
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            await hideAnimated()
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
            Image(systemName: toast.systemImage)
                .font(.system(size: 14, weight: .semibold))

            Text(toast.message)
                .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(PlayerChrome.surfaceBackground, in: Capsule())
    }
}
