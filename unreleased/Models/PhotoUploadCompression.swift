import UIKit

struct CompressedPhoto {
    let image: UIImage
    let data: Data
}

/// Shared upload policy for project covers and profile photos.
///
/// Originals are center-cropped, orientation-normalized, rendered without
/// alpha, and encoded with adaptive JPEG quality. A dimension fallback keeps
/// even unusually noisy images within the target byte budget.
enum PhotoUploadCompression {
    static func cover(_ image: UIImage) -> CompressedPhoto? {
        compressSquare(
            image,
            maxPixelDimension: 1_200,
            initialQuality: 0.82,
            minimumQuality: 0.62,
            maxBytes: 1_500_000
        )
    }

    static func profile(_ image: UIImage) -> CompressedPhoto? {
        compressSquare(
            image,
            maxPixelDimension: 512,
            initialQuality: 0.82,
            minimumQuality: 0.62,
            maxBytes: 500_000
        )
    }

    private static func compressSquare(
        _ source: UIImage,
        maxPixelDimension: CGFloat,
        initialQuality: CGFloat,
        minimumQuality: CGFloat,
        maxBytes: Int
    ) -> CompressedPhoto? {
        let sourcePixelSide = min(
            source.size.width * source.scale,
            source.size.height * source.scale
        )
        var pixelDimension = max(1, min(maxPixelDimension, sourcePixelSide))

        while pixelDimension >= 128 {
            let rendered = renderOpaqueSquare(source, pixelDimension: pixelDimension)
            var quality = initialQuality

            while true {
                guard let data = rendered.jpegData(compressionQuality: quality) else {
                    return nil
                }
                if data.count <= maxBytes {
                    return CompressedPhoto(image: rendered, data: data)
                }
                if quality <= minimumQuality {
                    break
                }
                quality = max(minimumQuality, quality - 0.06)
            }

            // Extremely detailed/noisy images may not meet the byte target
            // through quality alone. Reduce dimensions and try again.
            pixelDimension = floor(pixelDimension * 0.82)
        }

        return nil
    }

    private static func renderOpaqueSquare(
        _ source: UIImage,
        pixelDimension: CGFloat
    ) -> UIImage {
        let sourceSide = min(source.size.width, source.size.height)
        let outputSize = CGSize(width: pixelDimension, height: pixelDimension)
        let scale = pixelDimension / sourceSide
        let scaledSize = CGSize(
            width: source.size.width * scale,
            height: source.size.height * scale
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: outputSize))
            source.draw(in: CGRect(
                x: -(scaledSize.width - pixelDimension) / 2,
                y: -(scaledSize.height - pixelDimension) / 2,
                width: scaledSize.width,
                height: scaledSize.height
            ))
        }
    }
}
