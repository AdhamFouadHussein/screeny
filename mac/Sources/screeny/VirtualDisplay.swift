import CVirtualDisplay
import CoreGraphics
import Foundation

struct DisplayError: Error, CustomStringConvertible {
    let description: String
}

/// A real extended display as far as macOS is concerned. It disappears when released.
final class VirtualDisplay {
    private let display: CGVirtualDisplay

    var id: CGDirectDisplayID { display.displayID }

    init(pixelWidth: Int, pixelHeight: Int, scale: Int, fps: Int) throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.dispatchQueue = DispatchQueue.main
        descriptor.name = "Screeny"
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        let pixelsPerMillimeter = Double(scale) * 110 / 25.4
        descriptor.sizeInMillimeters = CGSize(
            width: Double(pixelWidth) / pixelsPerMillimeter,
            height: Double(pixelHeight) / pixelsPerMillimeter
        )
        // Stable IDs let macOS remember where the display was arranged last time.
        descriptor.vendorID = 0x5343
        descriptor.productID = 0x5259
        descriptor.serialNum = 1

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = scale > 1 ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt(pixelWidth / scale), height: UInt(pixelHeight / scale), refreshRate: Double(fps))
        ]

        display = CGVirtualDisplay(descriptor: descriptor)
        guard display.displayID != 0, display.apply(settings) else {
            throw DisplayError(description: "macOS refused to create the virtual display")
        }
    }
}
