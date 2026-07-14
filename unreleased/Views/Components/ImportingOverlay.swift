import SwiftUI

/// A non-dismissable, alert-styled overlay shown while audio files are importing.
/// It dims and blocks all interaction underneath so the import can't be interrupted.
private struct ImportingOverlay: View {
    var body: some View {
        ZStack {
            // Full-screen scrim that swallows every touch (nothing can be tapped
            // underneath, and there is no way to dismiss it).
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 16) {
                TwoToneCircleSpinner(diameter: 30, lineWidth: 2.5)
                Text("Importing audio files…")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(minWidth: 240)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        }
        .transition(.opacity)
    }
}

private struct ImportingOverlayModifier: ViewModifier {
    let isPresented: Bool
    /// Keep the overlay on screen for at least this long once shown, so a fast
    /// import doesn't make it flash for a fraction of a second (it also has to
    /// wait out the document-picker dismissal before it becomes visible).
    var minimumDuration: TimeInterval = 0.8

    @State private var isVisible = false
    @State private var shownAt: Date?
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay {
                // Present directly from the source value on the first update.
                // `isVisible` keeps it around long enough during dismissal.
                if isPresented || isVisible {
                    ImportingOverlay()
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isVisible)
            .onChange(of: isPresented) { _, presenting in
                if presenting {
                    hideTask?.cancel()
                    hideTask = nil
                    shownAt = Date()
                    isVisible = true
                } else {
                    let elapsed = shownAt.map { Date().timeIntervalSince($0) } ?? minimumDuration
                    let remaining = max(0, minimumDuration - elapsed)
                    hideTask?.cancel()
                    hideTask = Task {
                        if remaining > 0 {
                            try? await Task.sleep(for: .seconds(remaining))
                        }
                        guard !Task.isCancelled else { return }
                        isVisible = false
                    }
                }
            }
    }
}

extension View {
    /// Presents an unclosable "Importing audio files…" alert-style overlay while `isPresented` is true.
    func importingOverlay(isPresented: Bool) -> some View {
        modifier(ImportingOverlayModifier(isPresented: isPresented))
    }
}
