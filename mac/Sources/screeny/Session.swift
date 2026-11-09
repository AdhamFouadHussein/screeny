import CVirtualDisplay
import CoreMedia
import CoreVideo
import Foundation
import Network

/// One connected tablet: owns its capture, encoder and input channel.
///
/// Wire format (big-endian):
///   tablet -> mac  hello:  "SCRN", u32 version, u32 widthPx, u32 heightPx
///   mac -> tablet  packet: u8 type (0 = codec config, 1 = frame), u64 ptsMicros, u32 length, Annex-B bytes
///   tablet -> mac  input:  u8 action, f32 a, f32 b (see InputAction)
final class Session {
    private static let protocolVersion: UInt32 = 1
    private static let helloSize = 16
    private static let maxInFlight = 3

    private let connection: NWConnection
    private let options: Options
    private let displays: DisplayKeeper
    private let onEnd: () -> Void
    private let queue = DispatchQueue(label: "screeny.session")

    private var capture: ScreenCapture?
    private var encoder: H264Encoder?
    private var input: InputInjector?
    private var ended = false

    private let inFlightLock = NSLock()
    private var inFlight = 0

    init(connection: NWConnection, options: Options, displays: DisplayKeeper, onEnd: @escaping () -> Void) {
        self.connection = connection
        self.options = options
        self.displays = displays
        self.onEnd = onEnd
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.queue.async { self?.end() }
            default: break
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: Self.helloSize, maximumLength: Self.helloSize) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data, let hello = Self.parseHello(data) else {
                self.end()
                return
            }
            self.begin(width: hello.width, height: hello.height)
        }
    }

    private static func parseHello(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count == helloSize, data.prefix(4).elementsEqual("SCRN".utf8) else { return nil }
        let bytes = [UInt8](data)
        func u32(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard u32(4) == protocolVersion else { return nil }
        let width = Int(u32(8)) & ~1
        let height = Int(u32(12)) & ~1
        guard (320...7680).contains(width), (240...4320).contains(height) else { return nil }
        return (width, height)
    }

    private func begin(width: Int, height: Int) {
        Task {
            do {
                try await self.run(width: width, height: height)
            } catch {
                print("Could not start the display: \(error)")
                self.queue.async { self.end() }
            }
        }
    }

    private func run(width: Int, height: Int) async throws {
        let scale = options.scale ?? (max(width, height) >= 2400 ? 2 : 1)
        let display = try displays.display(pixelWidth: width, pixelHeight: height, scale: scale, fps: options.fps)
        let encoder = try H264Encoder(width: width, height: height, fps: options.fps, bitrate: options.bitrate) { [weak self] type, pts, payload in
            self?.send(type: type, pts: pts, payload: payload)
        }
        let capture = ScreenCapture()
        capture.onFrame = { [weak self, weak encoder] buffer in
            guard let self, let encoder, self.hasSendCapacity else { return }
            encoder.encode(buffer)
        }
        let input = InputInjector(displayID: display.id)

        queue.async {
            guard !self.ended else { return }
            self.encoder = encoder
            self.capture = capture
            self.input = input
            self.readInput()
        }
        try await capture.start(displayID: display.id, width: width, height: height, fps: options.fps)
        print("Display \(display.id) online: \(width)x\(height) px at \(scale)x")
    }

    private var hasSendCapacity: Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlight < Self.maxInFlight
    }

    private func updateInFlight(by delta: Int) {
        inFlightLock.lock()
        inFlight += delta
        inFlightLock.unlock()
    }

    private func send(type: UInt8, pts: UInt64, payload: Data) {
        var packet = Data(capacity: 13 + payload.count)
        packet.append(type)
        withUnsafeBytes(of: pts.bigEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(payload)

        updateInFlight(by: 1)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            self?.updateInFlight(by: -1)
            if error != nil { self?.queue.async { self?.end() } }
        })
    }

    private func readInput() {
        connection.receive(minimumIncompleteLength: InputInjector.messageSize, maximumLength: InputInjector.messageSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, data.count == InputInjector.messageSize {
                self.input?.handle(data)
            }
            if isComplete || error != nil {
                self.end()
            } else {
                self.readInput()
            }
        }
    }

    private func end() {
        guard !ended else { return }
        ended = true
        input?.releaseButtons()
        connection.cancel()
        let capture = self.capture
        let encoder = self.encoder
        let onEnd = self.onEnd
        Task {
            await capture?.stop()
            encoder?.invalidate()
            print("Tablet disconnected")
            onEnd()
        }
    }
}
