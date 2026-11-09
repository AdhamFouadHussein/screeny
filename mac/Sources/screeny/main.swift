import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct Options {
    var port: UInt16 = 7878
    var bitrate = 20_000_000
    var fps = 60
    var scale: Int?
}

func parseOptions() -> Options {
    var options = Options()
    var args = CommandLine.arguments.dropFirst().makeIterator()
    func usage() -> Never {
        print("usage: screeny [--port N] [--mbps N] [--fps N] [--scale 1|2]")
        exit(2)
    }
    while let arg = args.next() {
        guard let value = args.next().flatMap({ Int($0) }), value > 0 else { usage() }
        switch arg {
        case "--port":
            guard let port = UInt16(exactly: value) else { usage() }
            options.port = port
        case "--mbps": options.bitrate = value * 1_000_000
        case "--fps": options.fps = value
        case "--scale":
            guard value == 1 || value == 2 else { usage() }
            options.scale = value
        default: usage()
        }
    }
    return options
}

let options = parseOptions()

// ScreenCaptureKit needs a connection to the window server, which a bare CLI doesn't have.
_ = NSApplication.shared

if !CGPreflightScreenCaptureAccess() {
    CGRequestScreenCaptureAccess()
    print("Grant Screen Recording to your terminal in System Settings > Privacy & Security, then run screeny again.")
    exit(1)
}

let axPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
if !AXIsProcessTrustedWithOptions([axPrompt: true] as CFDictionary) {
    print("Touch input is off until your terminal has Accessibility access in System Settings > Privacy & Security.")
}

let server = Server(options: options)
do {
    try server.start()
} catch {
    print("Could not listen on port \(options.port): \(error)")
    exit(1)
}
dispatchMain()
