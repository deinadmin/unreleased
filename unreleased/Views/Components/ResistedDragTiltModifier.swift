import SwiftUI

private struct ResistedDragTiltModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var dragTranslation = CGSize.zero

    let isInverted: Bool

    private let maximumTilt = 10.0
    private let dragResistance = 140.0

    private var direction: Double {
        isInverted ? -1 : 1
    }

    private var horizontalTilt: Double {
        direction * rubberBandTilt(for: dragTranslation.width)
    }

    private var verticalTilt: Double {
        direction * rubberBandTilt(for: -dragTranslation.height)
    }

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : verticalTilt),
                axis: (x: 1, y: 0, z: 0),
                perspective: 0.65
            )
            .rotation3DEffect(
                .degrees(reduceMotion ? 0 : horizontalTilt),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.65
            )
            .contentShape(.rect)
            .gesture(dragGesture)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragTranslation = value.translation
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) {
                    dragTranslation = .zero
                }
            }
    }

    private func rubberBandTilt(for distance: CGFloat) -> Double {
        maximumTilt * tanh(Double(distance) / dragResistance)
    }
}

extension View {
    func resistedDragTilt(inverted: Bool = false) -> some View {
        modifier(ResistedDragTiltModifier(isInverted: inverted))
    }
}
