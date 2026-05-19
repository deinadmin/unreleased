import SwiftUI

struct GradientPickerView: View {
    @Binding var selected: GradientTheme

    private let columns = [GridItem(.adaptive(minimum: 60), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(GradientTheme.presets, id: \.colors) { theme in
                GradientSwatch(theme: theme, isSelected: theme == selected)
                    .onTapGesture {
                        withAnimation(.smooth(duration: 0.2)) {
                            selected = theme
                        }
                    }
            }
        }
    }
}

private struct GradientSwatch: View {
    let theme: GradientTheme
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.gradient)
            .frame(width: 60, height: 60)
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white, lineWidth: 3)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .animation(.smooth(duration: 0.2), value: isSelected)
    }
}

#Preview {
    @Previewable @State var selected = GradientTheme.presets[0]
    ScrollView {
        GradientPickerView(selected: $selected)
            .padding()
    }
}
