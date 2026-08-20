import SwiftUI

private let selectedSwatchOutline = Color.primary.opacity(0.6)

struct GradientPickerView: View {
    @Binding var selected: GradientTheme
    @Binding var coverImage: UIImage?

    @State private var isShowingPhotoPicker = false

    private let columns = [GridItem(.adaptive(minimum: 60), spacing: 12)]

    private var usesCoverImage: Bool { coverImage != nil }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            Button {
                isShowingPhotoPicker = true
            } label: {
                CoverPhotoSwatch(image: coverImage, isSelected: usesCoverImage)
            }
            .buttonStyle(.scale)

            ForEach(GradientTheme.presets, id: \.colors) { theme in
                Button {
                    withAnimation(.smooth(duration: 0.2)) {
                        coverImage = nil
                        selected = theme
                    }
                } label: {
                    GradientSwatch(theme: theme, isSelected: !usesCoverImage && theme == selected)
                }
                .buttonStyle(.scale)
            }
        }
        .sheet(isPresented: $isShowingPhotoPicker) {
            SquarePhotoPicker { image in
                withAnimation(.smooth(duration: 0.2)) {
                    coverImage = image
                }
            }
            .ignoresSafeArea()
        }
    }
}

private struct CoverPhotoSwatch: View {
    let image: UIImage?
    let isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .frame(width: 60, height: 60)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: 60, height: 60)
                        .scaledToFill()
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selectedSwatchOutline, lineWidth: 3)
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .scaleEffect(isSelected ? 1.05 : 1.0)
            .animation(.smooth(duration: 0.2), value: isSelected)
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
                        .strokeBorder(selectedSwatchOutline, lineWidth: 3)
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
    @Previewable @State var coverImage: UIImage?
    ScrollView {
        GradientPickerView(selected: $selected, coverImage: $coverImage)
            .padding()
    }
}
