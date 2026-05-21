import SwiftUI
import UIKit

/// Bottom bar shown in place of the mini player while search is active.
struct PlayerSearchBar: View {
    @Environment(AppSearchState.self) private var searchState
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isFocused: Bool

    private let barHeight: CGFloat = 50
    private let sideMargin: CGFloat = 12
    private let closeSize: CGFloat = 28
    private let leadingInset: CGFloat = 14

    /// Capsule end-cap radius; close circle center aligns with this point on the trailing edge.
    private var endCapRadius: CGFloat { barHeight / 2 }
    private var closeTrailingInset: CGFloat { endCapRadius - closeSize / 2 }

    private var isDark: Bool { colorScheme == .dark }

    private var surfaceFill: Color {
        isDark ? PlayerChrome.surfaceBackground : .white
    }

    private var primaryInk: Color {
        isDark ? .white : .black
    }

    private var secondaryInk: Color {
        isDark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)
    }

    private var closeButtonFill: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.08)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(secondaryInk)

            TextField(
                "",
                text: Bindable(searchState).text,
                prompt: Text(searchState.placeholder)
                    .foregroundStyle(secondaryInk)
            )
            .font(.system(size: 16))
            .foregroundStyle(primaryInk)
            .tint(primaryInk)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isFocused)
            .submitLabel(.search)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, endCapRadius + closeSize / 2 + 6)
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        .background(surfaceFill, in: Capsule())
        .overlay(alignment: .trailing) {
            Button(action: closeSearch) {
                ZStack {
                    Circle()
                        .fill(closeButtonFill)
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(secondaryInk)
                }
                .frame(width: closeSize, height: closeSize)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
            .padding(.trailing, closeTrailingInset)
        }
        .shadow(
            color: .black.opacity(isDark ? 0.35 : 0.12),
            radius: isDark ? 18 : 10,
            x: 0,
            y: isDark ? 6 : 4
        )
        .padding(.horizontal, sideMargin)
        .padding(.bottom, 8)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isFocused = true
            }
        }
    }

    private func closeSearch() {
        isFocused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            searchState.deactivate(dismissKeyboard: false)
        }
    }
}

#Preview {
    @Previewable @State var searchState = AppSearchState()
    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        PlayerSearchBar()
    }
    .environment(searchState)
    .onAppear {
        searchState.activate(scope: .library, placeholder: "Search your library")
    }
}
