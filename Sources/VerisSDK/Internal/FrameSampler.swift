import Foundation
import CoreImage
import CoreVideo

/// FrameSampler — renders a crop of a camera frame into a small grayscale byte array.
///
/// All pixel-level analysis (quality gate, LBP liveness) runs on tiny downscales
/// (16–64px), so a CIContext render per analysed frame is cheap. The frame is
/// oriented `.leftMirrored` to match the orientation handed to Vision, so Vision's
/// normalised rects (y-up, origin bottom-left) map directly onto the CIImage extent.
final class FrameSampler {

    private let context = CIContext(options: [.workingColorSpace: NSNull()])
    private let graySpace = CGColorSpaceCreateDeviceGray()

    /// - Parameters:
    ///   - normRect: crop in Vision normalised coordinates (y-up). Pass the unit rect
    ///     for the full frame.
    /// - Returns: `width*height` grayscale bytes, or nil when the crop is degenerate.
    func gray(from pixelBuffer: CVPixelBuffer, normRect: CGRect, width: Int, height: Int) -> [UInt8]? {
        var image = CIImage(cvPixelBuffer: pixelBuffer).oriented(.leftMirrored)
        let extent = image.extent
        let crop = CGRect(
            x: extent.minX + normRect.minX * extent.width,
            y: extent.minY + normRect.minY * extent.height,
            width: normRect.width * extent.width,
            height: normRect.height * extent.height
        ).intersection(extent)
        guard crop.width >= 1, crop.height >= 1 else { return nil }

        image = image
            .cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / crop.width,
                                               y: CGFloat(height) / crop.height))

        var bytes = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeMutableBytes { buf in
            context.render(
                image,
                toBitmap: buf.baseAddress!,
                rowBytes: width,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .L8,
                colorSpace: graySpace
            )
        }
        return bytes
    }
}
