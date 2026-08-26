import SwiftUI

/// Bottom bar shown in place of the mini player while search is active.
struct PlayerSearchBar: View {
    @Environment(AppSearchState.self) private var searchState
    @Environment(ProjectStore.self) private var store
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

    private var inputTint: Color {
        guard case let .project(projectID) = searchState.scope,
              let project = store.projects.first(where: { $0.id == projectID })
        else { return Color("AccentColor") }
        return store.accentColor(for: project)
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
            .tint(inputTint)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($isFocused)
            .submitLabel(.search)
            .onSubmit(submitSearch)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, endCapRadius + closeSize / 2 + 6)
        .frame(height: barHeight)
        .frame(maxWidth: .infinity)
        // Inside the glass so the close button stretches/wiggles with the bar.
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
            .buttonStyle(.scale)
            .accessibilityLabel("Close search")
            .padding(.trailing, closeTrailingInset)
        }
        .glassEffect(.regular.interactive().tint(surfaceFill), in: Capsule())
        .geometryGroup()
        .shadow(
            color: .black.opacity(isDark ? 0.35 : 0.12),
            radius: isDark ? 18 : 10,
            x: 0,
            y: isDark ? 6 : 4
        )
        .padding(.horizontal, sideMargin)
        .padding(.bottom, 8)
        .onAppear { focusField() }
        .onChange(of: isFocused) { _, focused in
            searchState.setFieldFocused(focused)
        }
        .onChange(of: searchState.focusRequest) { _, _ in
            focusField()
        }
        .onChange(of: searchState.blurRequest) { _, _ in
            isFocused = false
        }
    }

    private func focusField() {
        // Next run loop — TextField must be in the hierarchy before focus sticks.
        DispatchQueue.main.async {
            isFocused = true
        }
    }

    private func submitSearch() {
        guard searchState.text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        closeSearch()
    }

    private func closeSearch() {
        isFocused = false
        searchState.deactivate(dismissKeyboard: true)
    }
}

#Preview {
    @Previewable @State var searchState = AppSearchState()
    @Previewable @State var store = ProjectStore()
    ZStack(alignment: .bottom) {
        Color(.systemGroupedBackground).ignoresSafeArea()
        PlayerSearchBar()
    }
    .environment(searchState)
    .environment(store)
    .onAppear {
        searchState.activate(scope: .library, placeholder: "Search your library")
    }
}
