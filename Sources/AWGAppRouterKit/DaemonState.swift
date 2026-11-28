import Foundation

/// ЕДИНСТВЕННАЯ модель состояния демона (v13).
///
/// принцип: демон — единственный источник правды. Он вычисляет СНИМОК
/// (immutable value-объект) и пушит его всем GUI-клиентам при любом
/// изменении; GUI не "догадывается" о состоянии сам — он только рендерит
/// снимок. Все индикаторы (точки, текст статуса, трей, кнопки) берут
/// данные отсюда, поэтому рассинхрон между элементами структурно невозможен.
///
/// Толерантность: старый демон присылал DaemonStatus без phase/appRoutes —
/// decode восстанавливает phase из alive, GUI работает с любым демоном.

public enum ServerPhase: String, Codable {
    case off        // выключен (желаемое) — не участвует
    case starting   // включён, прогревается: ядро ещё не закончило пробу
    case up         // включён, urltest live — туннель готов нести трафик
    case down       // включён, но проба не проходит / туннель мёртв
}

/// Состояние одного сервера в снимке демона.
public struct ServerState: Codable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let phase: ServerPhase
    public let endpoint: String       // host:port — тултип

    public init(id: String, name: String, enabled: Bool, phase: ServerPhase,
                endpoint: String = "") {
        self.id = id; self.name = name; self.enabled = enabled
        self.phase = phase; self.endpoint = endpoint
    }

    /// совместимость со старой логикой ожиданий (.alive == true)
    public var alive: Bool? {
        switch phase {
        case .up:     return true
        case .down:   return false
        case .off, .starting: return nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, phase, endpoint
        case alive   // только для чтения старого формата
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        endpoint = (try? c.decode(String.self, forKey: .endpoint)) ?? ""
        if let p = try? c.decode(ServerPhase.self, forKey: .phase) {
            phase = p
        } else {
            // старый формат: только alive Bool?
            let alive = try? c.decode(Bool.self, forKey: .alive)
            switch alive {
            case .some(true):  phase = .up
            case .some(false): phase = .down
            case nil:          phase = enabled ? .starting : .off
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        try c.encode(phase, forKey: .phase)
        try c.encode(endpoint, forKey: .endpoint)
        // alive НЕ кодируем: phase — единственный авторитет
    }
}

/// Куда РЕАЛЬНО ходит приложение сейчас (значение clash-selector'а).
/// Это ответ на «почему всё жёлтое» — видно, куда ядро направило процесс.
public struct AppRouteState: Codable {
    public let name: String
    public let selector: String       // "app-0"
    public let desired: String        // "srv-1" | "block" — желаемое
    public let actual: String         // "srv-1" | "block" | "" — фактическое
    public let carrying: Bool         // actual != block и сервер live
    /// established-сокеты мимо туннеля (локальный адрес ≠ tun): залипшие
    /// direct, пережившие включение защиты — лечится только рестартом приложения
    public let directConns: Int
    /// established-сокеты через tun (локальный адрес = tun IP)
    public let tunConns: Int

    public init(name: String, selector: String, desired: String,
                actual: String, carrying: Bool,
                directConns: Int = 0, tunConns: Int = 0) {
        self.name = name; self.selector = selector
        self.desired = desired; self.actual = actual; self.carrying = carrying
        self.directConns = directConns; self.tunConns = tunConns
    }

    enum CodingKeys: String, CodingKey {
        case name, selector, desired, actual, carrying, directConns, tunConns
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        selector = (try? c.decode(String.self, forKey: .selector)) ?? ""
        desired = (try? c.decode(String.self, forKey: .desired)) ?? "block"
        actual = (try? c.decode(String.self, forKey: .actual)) ?? ""
        carrying = (try? c.decode(Bool.self, forKey: .carrying)) ?? false
        directConns = (try? c.decode(Int.self, forKey: .directConns)) ?? 0
        tunConns = (try? c.decode(Int.self, forKey: .tunConns)) ?? 0
    }
}

/// Полный снимок состояния демона.
public struct DaemonState: Codable {
    public let generation: Int        // растёт на каждый publish; GUI игнорирует старые
    /// идентичность экземпляра демона (pid+время старта): рестарт обнуляет
    /// generation — без bootID GUI отвергал бы все снимки нового демона
    public let bootID: String
    public let mode: TunnelMode
    public let boxRunning: Bool
    public let tunUp: Bool
    public let sealed: Bool           // аварийный pf-блок активен
    public let lastError: String
    public let servers: [ServerState]
    public let appRoutes: [AppRouteState]
    /// рубильник «подключать нужные серверы при старте демона» (Настройки)
    public let autostartConnect: Bool
    /// релизная версия демона (зашита в бинарь; публикует DaemonXPC.status).
    /// пустая — старый демон без версии → GUI считает «устарел»
    public var daemonVersion: String

    public init(generation: Int = 0, bootID: String = "", mode: TunnelMode = .running,
                boxRunning: Bool = false, tunUp: Bool = false, sealed: Bool = false,
                lastError: String = "", servers: [ServerState] = [],
                appRoutes: [AppRouteState] = [], autostartConnect: Bool = false,
                daemonVersion: String = "") {
        self.generation = generation; self.bootID = bootID; self.mode = mode
        self.boxRunning = boxRunning; self.tunUp = tunUp; self.sealed = sealed
        self.lastError = lastError; self.servers = servers; self.appRoutes = appRoutes
        self.autostartConnect = autostartConnect; self.daemonVersion = daemonVersion
    }

    public static let empty = DaemonState()

    enum CodingKeys: String, CodingKey {
        case generation, bootID, mode, boxRunning, tunUp, sealed, lastError, servers, appRoutes
        case autostartConnect, daemonVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generation = (try? c.decode(Int.self, forKey: .generation)) ?? 0
        bootID = (try? c.decode(String.self, forKey: .bootID)) ?? ""
        let raw = (try? c.decode(String.self, forKey: .mode)) ?? "running"
        mode = raw == TunnelMode.off.rawValue ? .off : .running
        boxRunning = (try? c.decode(Bool.self, forKey: .boxRunning)) ?? false
        tunUp = (try? c.decode(Bool.self, forKey: .tunUp)) ?? false
        sealed = (try? c.decode(Bool.self, forKey: .sealed)) ?? false
        lastError = (try? c.decode(String.self, forKey: .lastError)) ?? ""
        servers = (try? c.decode([ServerState].self, forKey: .servers)) ?? []
        appRoutes = (try? c.decode([AppRouteState].self, forKey: .appRoutes)) ?? []
        autostartConnect = (try? c.decode(Bool.self, forKey: .autostartConnect)) ?? false
        daemonVersion = (try? c.decode(String.self, forKey: .daemonVersion)) ?? ""
    }

    /// стабильная строка для сравнения «изменилось ли что-нибудь видимое»
    public var fingerprint: String {
        servers.map { "\($0.id):\($0.phase.rawValue)" }.joined(separator: ",")
            + "|" + appRoutes.map { "\($0.selector)>\($0.actual)/d\($0.directConns)t\($0.tunConns)" }.joined(separator: ",")
            + "|\(mode.rawValue)|tun=\(tunUp)|sealed=\(sealed)|err=\(lastError)"
    }

    public func server(_ id: String) -> ServerState? {
        servers.first { $0.id == id }
    }

    /// сколько приложений реально в туннеле
    public var carryingCount: Int { appRoutes.filter(\.carrying).count }
    /// сколько серверов live
    public var upCount: Int { servers.filter { $0.phase == .up }.count }
    public var enabledCount: Int { servers.filter(\.enabled).count }
    public var anyCarrying: Bool { carryingCount > 0 }
}
