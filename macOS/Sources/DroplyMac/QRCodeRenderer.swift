import CoreImage
import CoreImage.CIFilterBuiltins
import AppKit
import SwiftUI

enum QRCodeRenderer {
    private static let context = CIContext()

    static func renderImage(from text: String, size: CGFloat = 240) -> NSImage? {
        guard let data = text.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }
        let scaleX = size / outputImage.extent.width
        let scaleY = size / outputImage.extent.height
        let transformed = outputImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: size, height: size))
    }
}
