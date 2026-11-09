import Foundation
import Network

/// Listens on loopback only. The tablet reaches it through `adb reverse`, so the
/// unencrypted stream and the input channel are never exposed to the local network.
final class Server {
    private let options: Options
    private let queue = DispatchQueue(label: "screeny.server")
    private var listener: NWListener?
    private var session: Session?

    init(options: Options) {
        self.options = options
    }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: options.port)!)

        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [options] state in
            switch state {
            case .ready: print("Waiting for tablet on 127.0.0.1:\(options.port)")
            case .failed(let error):
                print("Listener failed: \(error)")
                exit(1)
            default: break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        guard session == nil else {
            connection.cancel()
            return
        }
        let session = Session(connection: connection, options: options) { [weak self] in
            self?.queue.async { self?.session = nil }
        }
        self.session = session
        session.start()
    }
}
