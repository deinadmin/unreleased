import SwiftUI
import UIKit

/// Presents the photo library with a mandatory 1:1 square crop (UIImagePicker editing).
struct SquarePhotoPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    var onImagePicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePicked: onImagePicked, dismiss: dismiss)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onImagePicked: (UIImage) -> Void
        let dismiss: DismissAction

        init(onImagePicked: @escaping (UIImage) -> Void, dismiss: DismissAction) {
            self.onImagePicked = onImagePicked
            self.dismiss = dismiss
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let cropped = info[.editedImage] as? UIImage {
                onImagePicked(cropped.opaqueSquareCropped())
            } else if let original = info[.originalImage] as? UIImage {
                onImagePicked(original.opaqueSquareCropped())
            }
            dismiss()
        }
    }
}

private extension UIImage {
    /// Center-crops, normalizes orientation, caps decode size, and removes alpha
    /// before the image is cached, encoded as JPEG, or used as Now Playing art.
    func opaqueSquareCropped(maxPixelDimension: CGFloat = 1_200) -> UIImage {
        let side = min(size.width, size.height)
        let outputSide = min(side, maxPixelDimension)
        let outputSize = CGSize(width: outputSide, height: outputSide)
        let outputScale = outputSide / side
        let scaledSize = CGSize(width: size.width * outputScale, height: size.height * outputScale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))
            draw(in: CGRect(
                x: -(scaledSize.width - outputSide) / 2,
                y: -(scaledSize.height - outputSide) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            ))
        }
    }
}
