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

/// Keeps the display alive between connections, so a reconnecting tablet gets the same
/// screen back. It is only replaced when the requested size changes.
final class DisplayKeeper {
    private struct Key: Equatable {
        let width: Int
        let height: Int
        let scale: Int
    }

    private let lock = NSLock()
    private var key: Key?
    private var display: VirtualDisplay?

    func display(pixelWidth: Int, pixelHeight: Int, scale: Int, fps: Int) throws -> VirtualDisplay {
        lock.lock()
        defer { lock.unlock() }

        let requested = Key(width: pixelWidth, height: pixelHeight, scale: scale)
        if requested == key, let display {
            return display
        }
        // Release the old display first: both would share the same vendor and serial.
        display = nil
        key = nil
        let created = try VirtualDisplay(pixelWidth: pixelWidth, pixelHeight: pixelHeight, scale: scale, fps: fps)
        display = created
        key = requested
        return created
    }
}
