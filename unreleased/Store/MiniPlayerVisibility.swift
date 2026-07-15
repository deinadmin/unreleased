import Observation
import SwiftUI

@Observable
@MainActor
final class MiniPlayerVisibility {
    enum Reason: Hashable {
        case enlargedProfilePhoto
        case deleteTracks
    }

    private(set) var hiddenReasons = Set<Reason>()

    var isHidden: Bool { !hiddenReasons.isEmpty }

    func hide(for reason: Reason) {
        guard !hiddenReasons.contains(reason) else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            hiddenReasons.insert(reason)
        }
    }

    func show(for reason: Reason) {
        guard hiddenReasons.contains(reason) else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            hiddenReasons.remove(reason)
        }
    }
}

private struct AppBottomChromeVisibilityKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var appBottomChromeIsVisible: Bool {
        get { self[AppBottomChromeVisibilityKey.self] }
        set { self[AppBottomChromeVisibilityKey.self] = newValue }
    }
}

private struct BottomChromeAwarePaddingModifier: ViewModifier {
    @Environment(\.appBottomChromeIsVisible) private var isBottomChromeVisible

    let resting: CGFloat
    let visible: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.bottom, isBottomChromeVisible ? visible : resting)
            .animation(.smooth(duration: 0.35), value: isBottomChromeVisible)
    }
}

private struct BottomChromeAwareScrollMarginModifier: ViewModifier {
    @Environment(\.appBottomChromeIsVisible) private var isBottomChromeVisible

    let resting: CGFloat
    let visible: CGFloat

    func body(content: Content) -> some View {
        content
            .contentMargins(
                .bottom,
                isBottomChromeVisible ? visible : resting,
                for: .scrollContent
            )
            .animation(.smooth(duration: 0.35), value: isBottomChromeVisible)
    }
}

extension View {
    func bottomChromeAwarePadding(resting: CGFloat, visible: CGFloat = 100) -> some View {
        modifier(BottomChromeAwarePaddingModifier(resting: resting, visible: visible))
    }

    func bottomChromeAwareScrollMargin(resting: CGFloat = 0, visible: CGFloat = 100) -> some View {
        modifier(BottomChromeAwareScrollMarginModifier(resting: resting, visible: visible))
    }
}
