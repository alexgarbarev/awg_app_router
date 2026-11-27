import Foundation
import AWGAppRouterKit

/// XPC-фасад демона. v13: держим набор живых соединений — снимки состояния
/// пушится каждому клиенту, экспортирующему AWGAppRouterObserver (GUI).
/// Транспорт — mach-сервис NSXPC: события доставляются через ядро асинхронно,
/// без пайпов и общей памяти; сорванный клиент отваливается по errorHandler.
final class DaemonXPC: NSObject, NSXPCListenerDelegate, AWGAppRouterDaemon {
    static let shared = DaemonXPC()

    private let clientsLock = NSLock()
    private var clients: [NSXPCConnection] = []

    private override init() {
        super.init()
        // единственный канал доставки снимков: Supervisor → все GUI
        Supervisor.shared.onPublish = { [weak self] state in
            self?.broadcast(state)
        }
    }

    private func broadcast(_ state: DaemonState) {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        clientsLock.lock()
        let targets = clients
        clientsLock.unlock()
        for conn in targets {
            let observer = conn.remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.remove(conn)
            } as? AWGAppRouterObserver
            observer?.stateChanged(json)
        }
    }

    private func remove(_ conn: NSXPCConnection) {
        clientsLock.lock(); clients.removeAll { $0 === conn }; clientsLock.unlock()
    }

    // NSXPCListenerDelegate
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: AWGAppRouterDaemon.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self] in
            // GUI умер — демон и не заметил: состояние живёт в /etc/awgapprouter
            self?.remove(newConnection)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.remove(newConnection)
        }
        clientsLock.lock(); clients.append(newConnection); clientsLock.unlock()
        newConnection.resume()
        // новичку — текущий снимок сразу, чтобы UI не стартовал «вслепую»
        let s = Supervisor.shared.lastState
        if let data = try? JSONEncoder().encode(s),
           let json = String(data: data, encoding: .utf8) {
            let observer = newConnection.remoteObjectProxyWithErrorHandler { _ in }
                as? AWGAppRouterObserver
            observer?.stateChanged(json)
        }
        return true
    }

    // MARK: - AWGAppRouterDaemon (XPC)

    func sync(_ serversJSON: String, appsJSON: String, mode: String,
              reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let m = TunnelMode(rawValue: mode) else {
                reply(false, "неизвестный режим: \(mode)")
                return
            }
            let msg = Supervisor.shared.sync(serversJSON: serversJSON, appsJSON: appsJSON,
                                              newMode: m)
            reply(true, msg)
        }
    }

    func setServer(_ id: String, enabled: Bool, reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let msg = Supervisor.shared.setServer(id: id, enabled: enabled)
            reply(true, msg)
        }
    }

    func setAutoConnect(_ on: Bool, reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let msg = Supervisor.shared.setAutoConnect(on: on)
            reply(true, msg)
        }
    }

    func powerOff(_ reply: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let msg = Supervisor.shared.powerOff()
            reply(msg == "ok", msg)
        }
    }

    func status(_ reply: @escaping (String) -> Void) {
        let s = Supervisor.shared.status()
        let data = (try? JSONEncoder().encode(s)) ?? Data()
        reply(String(data: data, encoding: .utf8) ?? "{}")
    }

    func version(_ reply: @escaping (String) -> Void) {
        reply(Supervisor.shared.version())
    }
}
