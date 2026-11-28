import Foundation
import AWGAppRouterKit

/// Супервизор ядра v13. Ядро ЖИВЁТ ВСЕГДА (кроме явного off с паролем).
///
/// Матрица применения (главное отличие от v12 — тумблы без рестарта):
///   • вкл/выкл сервера, выбор сервера приложением → clash PUT selector'ов,
///     ядро НЕ перезапускается, первый сервер НЕ переподключается;
///   • добавить/убрать сервер или приложение, смена IP/конфа → структурное
///     изменение конфига → рестарт ядра (неизбежно: состав endpoints);
///   • ядро рестартует → desired-выбор записан в default конфигa и
///     дополнительно перекалывается PUT'ом как только controllers поднимутся;
///   • tun мёртв (любой режим) → quick-блок WAN + рестарт box, автоснятие.
///
/// Состояние: единое хранилище снимков DaemonState — каждый тик сравниваем
/// fingerprint и при отличии пушим всем GUI (onPublish → DaemonXPC).
final class Supervisor {
    static let shared = Supervisor()

    private let lock = NSLock()
    private var box: Process?
    /// pid ядра, о котором известно: свой spawn или подобранный на boot осиротевший.
    /// Тик супервизора НЕ должен спавнить pgrep каждый секунд: pgrep может
    /// стоять в ядре намертво, пока другие процессы виснут в pf — так тик и
    /// встал 28.11 в 00:29 (waitUntilExit без дедлайна) и демон «залип».
    /// Живость проверяем дешёвым kill(pid, 0).
    private var trackedBoxPid: Int = 0
    /// leaf-lock: внутри него основной `lock` брать нельзя
    private let pidLock = NSLock()
    private(set) var mode: TunnelMode = .running
    private(set) var sealed = false
    private var expectedAddr: String?
    private var emergencyRules: String?
    private var lastStart = Date.distantPast
    private var lastError = ""
    private var pollThread: Thread?
    private var usedIPs: [String: String] = [:]
    private var dnsCheckTime = Date.distantPast
    private var tunMismatch = 0
    private var lastTunUp = false        // ребра tun up/down для pf state flush
    private var connCounts: [String: (direct: Int, tun: Int)] = [:]  // tag → сокеты
    private var lastConnCheck = Date.distantPast
    private var lastAddrRefresh = Date.distantPast

    // clash состояние
    private var clashNow: [String: String] = [:]    // tag -> now ("" = ещё не live)
    private var clashOK = false                       // /proxies отвечал на свежем снимке
    private var clashCacheTime = Date.distantPast
    private var clashUrgentUntil = Date.distantPast

    // применение
    private var appliedStruct = ""                    // структурный хеш рабочего конфига
    private let governor = RestartGovernor(coalesce: 2)   // коалесинг составов,
    // backoff bounce tun и watchdog «box мёртв» — все паузы в одном месте
    private var desired: [String: String] = [:]     // selector tag -> target
    private let applyQ = DispatchQueue(label: "awgapprouter.apply")
    // «залипшие» direct-сокеты приложений: pf tuple-kill по событию
    private let resetQueue = DispatchQueue(label: "awgapprouter.socket-reset")
    private var resetInFlight = false
    private var lastResetAt = Date.distantPast

    // publish
    private var generation = 0
    private var lastFP = ""
    /// идентичность этого экземпляра демона: GUI сбрасывает доверие к
    /// generation при её смене (иначе снимки после «⟳» отвергаются вечно)
    let bootID = "\(getpid())-\(Int(NSDate().timeIntervalSince1970))"
    private(set) var lastState = DaemonState.empty
    var onPublish: ((DaemonState) -> Void)?
    /// «подключать нужные серверы при старте» (Настройки) — файл-флаг на диске
    private(set) var autoConnectOn = false

    // MARK: - запуск демона (launchd RunAtLoad)

    func boot() {
        migrateLegacyFiles()
        mode = readModeFile() ?? .running
        writeMode(mode)
        autoConnectOn = FileManager.default.fileExists(atPath: Paths.autoConnect)
        if autoConnectOn && mode != .off {
            autoConnectApply("boot")
        }
        do {
            let json = try regenerateConfig()
            appliedStruct = ConfigBuilder.structuralHash(of: json) ?? ""
        } catch {
            lastError = "\(error)"
        }
        expectedAddr = Self.tunAddressFromConfig()
        emergencyRules = try? String(contentsOfFile: Paths.pfEmergency, encoding: .utf8)
        // подобрать осиротевшее ядро от прежнего демона (единственный pgrep
        // в горячем пути; bounded внутри)
        trackedBoxPid = Self.pgrepBox().last.map(Int.init) ?? 0
        if mode != .off {
            NSLog("awgapprouterd: boot, режим %@ — старт ядра", mode.rawValue)
            startBoxIfDead()
            scheduleSelections(attempt: 0)
        }
        // блок в ядре пережил рестарт демона (флаг в памяти новый, ruleset — старый):
        // если tun стоит — блок не нужен, снять немедленно
        if PFFirewall.isSealed() && (mode == .off || tunUp()) {
            PFFirewall.unseal()
            NSLog("awgapprouterd: boot — снятый orphan-блок pf убран")
        }
        publishNow()
        startPolling()
    }

    /// старые одно-серверные файлы -> servers.json
    private func migrateLegacyFiles() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Paths.serversJSON),
              let old = try? String(contentsOfFile: Paths.profileConf, encoding: .utf8),
              !old.isEmpty else { return }
        let oldMode = (try? String(contentsOfFile: Paths.modeFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "block"
        let spec = ServerSpec(id: "srv-1", name: "server-1", confText: old,
                              enabled: oldMode == "tunnel")
        try? writeServers([spec])
        NSLog("awgapprouterd: миграция profile.conf -> servers.json (enabled: \(spec.enabled))")
    }

    // MARK: - XPC-вызываемые операции (сериализованы на applyQ)

    func sync(serversJSON: String, appsJSON: String, newMode: TunnelMode) -> String {
        try? appsJSON.write(toFile: Paths.appsJSON, atomically: true, encoding: .utf8)
        if let data = serversJSON.data(using: .utf8),
           let servers = try? JSONDecoder().decode([ServerSpec].self, from: data) {
            try? writeServers(servers)
        }
        mode = newMode
        writeMode(newMode)
        if newMode == .off {
            let nApps = (appsJSON.data(using: .utf8).flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) })?.count ?? 0
            NSLog("awgapprouterd: сохранено в .off: apps \(nApps), ядро не поднят")
            return applyQ.sync {
                terminateBox()
                if PFFirewall.isSealed() { PFFirewall.unseal() }
                sealed = false
                publishNow()
                return "ядро остановлено (защита СНЯТА)"
            }
        }
        return applyQ.sync { applyIntentLocked("синхронизация") }
    }

    func setServer(id: String, enabled: Bool) -> String {
        var servers = loadServers()
        guard let i = servers.firstIndex(where: { $0.id == id }) else {
            return "сервер \(id) не найден"
        }
        servers[i].enabled = enabled
        try? writeServers(servers)
        if enabled, (try? servers[i].profile()) == nil {
            return "внимание: conf сервера битый — он не будет подключён"
        }
        guard mode != .off else { return "ядро выключено — сервер сохранён, но не подключён" }
        return applyQ.sync { applyIntentLocked("сервер \(id) → \(enabled ? "вкл" : "выкл")") }
    }

    /// Рубильник из «Настроек»: подключить нужные серверы при старте системы.
    /// Применяется не сейчас, а на следующем boot демона — флаг только храним.
    func setAutoConnect(on: Bool) -> String {
        autoConnectOn = on
        if on {
            try? Data("1".utf8).write(to: URL(fileURLWithPath: Paths.autoConnect))
        } else {
            try? FileManager.default.removeItem(atPath: Paths.autoConnect)
        }
        NSLog("awgapprouterd: автоподключение при старте: %@", on ? "вкл" : "выкл")
        publishNow()
        return on ? "включено: после перезагрузки подключит нужные серверы сам"
                  : "выключено: после перезагрузки будет тюрьма"
    }

    /// «как кнопка Подключиться», но на boot демона: включить серверы, к которым
    /// привязаны приложения (если к такому никто не привязан — первый сервер).
    /// Вызывается до генерации конфига и старта ядра — туннель сразу правильный.
    private func autoConnectApply(_ reason: String) {
        var servers = loadServers()
        guard !servers.isEmpty else { return }
        let bound = Set(loadApps().map(\.serverID))
        var names: [String] = []
        for i in servers.indices where !servers[i].enabled {
            if bound.contains(servers[i].id) || (bound.isEmpty && i == 0) {
                servers[i].enabled = true
                names.append(servers[i].name)
            }
        }
        guard !names.isEmpty else { return }
        try? writeServers(servers)
        NSLog("awgapprouterd: автоподключение (%@): включены %@",
              reason, names.joined(separator: ", "))
    }

    func powerOff() -> String {
        guard FileManager.default.fileExists(atPath: Paths.offToken) else {
            return "нужно подтверждение паролем администратора"
        }
        try? FileManager.default.removeItem(atPath: Paths.offToken)
        _ = sync(serversJSON: serversJSONText(), appsJSON: appsJSONText(), newMode: .off)
        return "ok"
    }

    func status() -> DaemonState {
        // живой снимок не старше 1 тика (1 с); pull дешёвый — без clash-похода
        refreshClashCache(force: false)
        publishIfChanged()
        return lastState
    }

    func version() -> String { appRouterProtocolVersion }

    // MARK: - применение намерения (единственная точка, под applyQ)

    /// v13: перегенерировали конфиг → сравнили СТРУКТУРУ (без selector default):
    ///  • структура та же и ядро живо → только clash PUT (мгновенно, без разрывов);
    ///  • иначе → рестарт ядра с последующей доводкой выбора через PUT.
    private func applyIntentLocked(_ reason: String) -> String {
        let json: String
        do { json = try regenerateConfig() }
        catch {
            lastError = "конфиг: \(error)"
            publishNow()
            return "конфиг: \(error)"
        }
        expectedAddr = Self.tunAddressFromConfig()
        guard let newStruct = ConfigBuilder.structuralHash(of: json) else {
            lastError = "не могу разложить конфиг"
            publishNow()
            return lastError
        }
        let running = runningBoxPid() != 0
        let booting = running && Date().timeIntervalSince(lastStart) < 8
        if newStruct == appliedStruct, running, tunUp() || booting {
            applySelectionsLocked()   // тумбла: перетыкаем selector'ы, ядро не трогаем
            NSLog("awgapprouterd: hot-select (\(reason))")
            publishNow()
            let n = loadServers().filter(\.enabled).count
            return n > 0 ? "туннель(и) поднимаются" : "тюрьма активна (защита включена)"
        }
        // серия структурных команд за короткое окно = ОДИН рестарт: свежая
        // заявка переносится на конец окна (конфиг перегенерится и соберёт
        // все команды). Раньше каждый sync/добавление = terminate+spawn.
        let nowD = Date()
        if !governor.structuralRestartAllowed(at: nowD) {
            applyQ.asyncAfter(deadline: .now() + governor.coalesce) { [weak self] in
                _ = self?.applyIntentLocked("коалесинг")
            }
            publishNow()
            return "изменения применятся через мгновение"
        }
        appliedStruct = newStruct
        governor.structuralRestarted(at: nowD)
        // снять блок из ЯДРА, а не только флаг: флаг в памяти мог быть уже
        // сброшен, а правила pf — остаться (иначе WAN заблокирован навсегда)
        if PFFirewall.isSealed() { PFFirewall.unseal() }
        sealed = false
        terminateBox()
        killStaleBoxes()
        clashNow = [:]; clashOK = false
        startBoxIfDead()
        clashUrgentUntil = Date().addingTimeInterval(15)
        scheduleSelections(attempt: 0)
        let n = loadServers().filter(\.enabled).count
        NSLog("awgapprouterd: применено (\(reason)): серверов вкл \(n)/\(loadServers().count)")
        publishNow()
        return n > 0 ? "туннель(и) поднимаются" : "тюрьма активна (защита включена)"
    }

    /// desired = жёлтая дорожка того, что должно быть: app-<i> → srv или block.
    /// Считается из servers.json/apps.json тем же порядком, что и конфиг.
    private func computeDesiredLocked(builder: ConfigBuilder, apps: [AppRule]) {
        var d: [String: String] = [:]
        for (i, app) in apps.enumerated() {
            d[ConfigBuilder.selectorTag(appIndex: i)] = builder.selection(for: app)
        }
        d[ConfigBuilder.aiSelector] = builder.enabledTags.first ?? "block"
        desired = d
    }

    /// PUT только туда, где фактический выбор отличается от желаемого.
    /// После смены — DELETE /connections: закрытые сессии браузер прозрачно
    /// переоткроет уже по новому селектору (иначе sticky keep-alive соединения
    /// дотекают через отключённый сервер и вкладка «помнит» старый IP).
    /// Если селектор ушёл block→туннель — плюс flush pf-состояний: сокеты,
    /// жившие до включения туннеля, Clash не видит (они вне tun), их рвёт только pf.
    private func applySelectionsLocked() {
        refreshClashCache(force: true)
        guard clashOK else { return }
        var changed = false
        for (tag, target) in desired where clashNow[tag] != target {
            if clashRequest("PUT", "/proxies/" + tag, "{\"name\":\"\(target)\"}") != nil {
                clashNow[tag] = target
                changed = true
            }
        }
        if changed {
            // смена маршрута обязана порвать старую путь: DELETE /connections
            // закрывает потоки внутри ядра (переоткроются по новому селектору),
            // killStates — прямые pf-состояния, killStickyDirect — залипшие
            // прямые сокеты приложений, у которых маршрут закейсен в pcb
            // (иначе после block они продолжают качать через en0 — проверено)
            NSLog("awgapprouterd: рвём соединения после смены селектора")
            _ = clashRequest("DELETE", "/connections", nil)
            PFFirewall.killStates()
            killStickyDirect()
        }
    }

    /// после рестарта: ждём clash-контроллер (до 20 с) и доводим выбор
    private func scheduleSelections(attempt: Int) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.7) {
            if attempt > 28 { return }
            let ok: Bool = self.applyQ.sync {
                guard self.mode != .off, self.runningBoxPid() != 0 else { return false }
                self.refreshClashCache(force: true)
                guard self.clashOK else { return false }
                self.applySelectionsLocked()
                return self.desired.allSatisfy { self.clashNow[$0.key] == $0.value }
            }
            if ok {
                // туннель живой: прямые состояния pf, прибитые к en0 до его
                // подъёма, — дыра в защите (даже в тюрьме!). Сбрасываем их,
                // приложения прозрачно переподключатся через tun.
                PFFirewall.killStates()
            }
            self.publishIfChanged()
            if !ok { self.scheduleSelections(attempt: attempt + 1) }
        }
    }

    // MARK: - конфиг

    private func serversJSONText() -> String {
        (try? String(contentsOfFile: Paths.serversJSON, encoding: .utf8)) ?? "[]"
    }

    private func appsJSONText() -> String {
        (try? String(contentsOfFile: Paths.appsJSON, encoding: .utf8)) ?? "[]"
    }

    private func writeServers(_ servers: [ServerSpec]) throws {
        let data = try JSONEncoder().encode(servers)
        try data.write(to: URL(fileURLWithPath: Paths.serversJSON), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Paths.serversJSON)
    }

    private func loadServers() -> [ServerSpec] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Paths.serversJSON)),
              let s = try? JSONDecoder().decode([ServerSpec].self, from: data) else { return [] }
        return s
    }

    private func loadApps() -> [AppRule] {
        guard let data = appsJSONText().data(using: .utf8),
              let apps = try? JSONDecoder().decode([AppRule].self, from: data) else { return [] }
        return apps
    }


    /// Генерирует и валидирует конфиг, меняет рабочий файл.
    /// В конфиг идут ВСЕ валидные серверы (и выключенные тоже — тёплые):
    /// тумбла включения/выключения не меняет структуру и не рестартует ядро.
    private func regenerateConfig() throws -> String {
        var endpoints: [ConfigBuilder.Endpoint] = []
        var unresolved: [String] = []
        for spec in loadServers() {
            guard let p = try? spec.profile() else {
                NSLog("awgapprouterd: сервер %@ — conf битый, пропускаю", spec.id)
                continue
            }
            // ядро требует IP в peer address (хост = FATAL на старте, check не ловит)
            guard let ip = EndpointResolver.address(for: p.endpointHost) else {
                if spec.enabled { unresolved.append("\(spec.name) (\(p.endpointHost))") }
                NSLog("awgapprouterd: сервер %@: %@ не разрешился в IP — пропускаю",
                    spec.id, p.endpointHost)
                continue
            }
            usedIPs[spec.id] = ip
            endpoints.append(ConfigBuilder.Endpoint(id: spec.id, profile: p,
                                                   enabled: spec.enabled, peerIP: ip))
        }
        if !unresolved.isEmpty {
            lastError = "не разрешился эндпоинт: " + unresolved.joined(separator: ", ")
        } else if lastError.hasPrefix("не разрешился") {
            lastError = ""
        }
        var apps = loadApps()
        let gw = Gateway.current() ?? "192.168.1.1"
        let builder = ConfigBuilder(servers: endpoints, apps: apps, gateway: gw)
        computeDesiredLocked(builder: builder, apps: apps)
        let json = try builder.buildJSON()
        // валидация ядром во УНИКАЛЬНОМ tmp (параллельные генерации не дерутся),
        // затем атомарная замена рабочего файла: .atomic = temp+rename внутри,
        // рабочего окна «нет конфига» не существует в principle
        let tmp = Paths.configJSON + ".check-\(UUID().uuidString)"
        try json.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: Paths.boxBinary)
        check.arguments = ["check", "-c", tmp]
        let pipe = Pipe(); check.standardError = pipe; check.standardOutput = pipe
        try check.run()
        check.waitUntilExit()
        // читаем всегда (успешный путь тоже держал оба конца мёртвым грузом)
        let checkOut = String(data: (try? pipe.fileHandleForReading.readToEnd()) ?? Data(),
                              encoding: .utf8) ?? ""
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        guard check.terminationStatus == 0 else {
            throw NSError(domain: "awgapprouter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "ядро отвергло конфиг: \(checkOut.prefix(400))"])
        }
        try json.write(toFile: Paths.configJSON, atomically: true, encoding: .utf8)
        try builder.pfEmergencyRules().write(toFile: Paths.pfEmergency, atomically: true, encoding: .utf8)
        emergencyRules = builder.pfEmergencyRules()
        NSLog("awgapprouterd: конфиг перегенерирован (endpoints: \(endpoints.count), apps: \(apps.count))")
        return json
    }

    // MARK: - снимок состояния

    private func computeState(generation gen: Int) -> DaemonState {
        let running = runningBoxPid() != 0
        let tun = tunUp()
        let booting = running && Date().timeIntervalSince(lastStart) < 8
        let states = loadServers().map { spec -> ServerState in
            let valid = usedIPs[spec.id] != nil
            let phase: ServerPhase
            if !spec.enabled {
                phase = .off
            } else if !valid {
                phase = .down
            } else if !running || !tun {
                phase = booting ? .starting : .down
            } else if !clashOK {
                phase = .starting
            } else {
                phase = (clashNow[spec.id] ?? "").isEmpty ? .down : .up
            }
            return ServerState(id: spec.id, name: spec.name, enabled: spec.enabled,
                               phase: phase, endpoint: spec.endpointDisplay)
        }
        var apps = loadApps()
        refreshConnCounts()   // раз в 2 с: кто реально через tun, кто залип direct
        let routes = apps.enumerated().map { (i, app) -> AppRouteState in
            let tag = ConfigBuilder.selectorTag(appIndex: i)
            let actual = clashOK ? (clashNow[tag] ?? "") : ""
            let carrying = !actual.isEmpty && actual != "block"
                && !(clashNow[actual] ?? "").isEmpty
            let c = connCounts[tag] ?? (0, 0)
            return AppRouteState(name: app.name, selector: tag,
                                 desired: desired[tag] ?? "block",
                                 actual: actual, carrying: carrying,
                                 directConns: c.direct, tunConns: c.tun)
        }
        return DaemonState(generation: gen, bootID: bootID, mode: mode,
                           boxRunning: running, tunUp: tun, sealed: sealed,
                           lastError: lastError, servers: states, appRoutes: routes,
                           autostartConnect: autoConnectOn)
    }

    private func publishNow() {
        lock.lock(); generation += 1; let gen = generation; lock.unlock()
        let s = computeState(generation: gen)
        lastFP = s.fingerprint
        lastState = s
        onPublish?(s)
    }

    private func publishIfChanged() {
        let s = computeState(generation: 0)
        if s.fingerprint != lastFP { publishNow() }
    }

    // MARK: - супервизорный цикл (1 с)

    private func startPolling() {
        let t = Thread { [weak self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                self?.tick()
            }
        }
        t.name = "supervisor"
        pollThread = t
        t.start()
    }

    // MARK: - залипшие сокеты (kernel route cache)

    /// pid'ы защищённых приложений → selector-тег. Тот же матчинг, что и в
    /// конфиге: точный путь бинаря + (если включено) helper'ы из бандла.
    private func appPidMap(_ apps: [AppRule]) -> [String: String] {
        let ps = capture("/bin/ps", ["-axo", "pid=,comm="])
        var map: [String: String] = [:]
        for line in ps.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1,
                                  omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let comm = String(parts[1])
            for (i, app) in apps.enumerated() where app.path == comm
                || (app.includeChildren && app.bundlePath.map { comm.hasPrefix($0 + "/") } == true) {
                map[String(parts[0])] = ConfigBuilder.selectorTag(appIndex: i)
            }
        }
        return map
    }

    struct SockLine { let tag: String; let proto: String; let v6: Bool
        let lh: String; let lp: String; let rh: String; let rp: String }

    /// established-сокеты всех pid'ов одним прогоном lsof (LISTEN отброшен)
    private func appSocketLines(_ pidTag: [String: String]) -> [SockLine] {
        guard !pidTag.isEmpty else { return [] }
        let out = capture("/usr/sbin/lsof", ["-nP", "-i", "-sTCP:ESTABLISHED", "-a",
                                              "-p", pidTag.keys.joined(separator: ",")])
        var res: [SockLine] = []
        for line in out.split(separator: "\n").dropFirst() {
            let c = line.split(separator: " ", omittingEmptySubsequences: true)
            guard c.count >= 9 else { continue }
            guard let tag = pidTag[String(c[1])] else { continue }
            let name = String(c[8])
            guard name.contains("->") else { continue }
            let v6 = String(c[4]).contains("IPv6")
            let proto = line.contains("(UDP)") ? "udp" : "tcp"
            let pair = name.split(separator: "->", maxSplits: 1)
            guard pair.count == 2,
                  let (lh, lp) = Self.splitAddrPort(String(pair[0])),
                  let (rh, rp) = Self.splitAddrPort(String(pair[1])) else { continue }
            res.append(SockLine(tag: tag, proto: proto, v6: v6,
                                lh: lh, lp: lp, rh: rh, rp: rp))
        }
        return res
    }

    /// lan/loopback/link-local — by design идут мимо ядра (роутер, печать,
    /// airplay): не считать их ни утечкой, ни туннелем
    static func isPrivateDest(_ rh: String) -> Bool {
        if rh.hasPrefix("192.168.") || rh.hasPrefix("10.") || rh.hasPrefix("127.")
            || rh.hasPrefix("169.254.") || rh.hasPrefix("fe80") || rh.hasPrefix("::1") { return true }
        if rh.hasPrefix("172."), let o2 = Int(rh.split(separator: ".")[1]) {
            return (16...31).contains(o2)
        }
        return false
    }

    /// сколько established-сокетов у каждого приложения через tun и мимо него.
    /// direct-сокет с адресом физ. интерфейса = залипший (kernel route cache) —
    /// починить нельзя, только показать и попросить рестарт приложения
    private func refreshConnCounts() {
        guard Date().timeIntervalSince(lastConnCheck) >= 2 else { return }
        lastConnCheck = Date()
        var apps = loadApps()
        let tunIP = (expectedAddr ?? "").split(separator: "/").first.map(String.init) ?? ""
        var counts: [String: (direct: Int, tun: Int)] = [:]
        for s in appSocketLines(appPidMap(apps)) {
            if Self.isPrivateDest(s.rh) { continue }
            var v = counts[s.tag] ?? (0, 0)
            if !tunIP.isEmpty && s.lh == tunIP { v.tun += 1 } else { v.direct += 1 }
            counts[s.tag] = v
        }
        connCounts = counts
    }

    /// macОС кэширует маршрут в pcb established-сокета: смена селектора и
    /// DELETE /connections до «залипших» прямых сокетов не достают (они вне
    /// tun, ядро их не видит) — прямые keep-alive продолжают прокачивать трафик
    /// мимо block/seal. Рвём pf-кортежами: TCP → return-rst (приложение
    /// прозрачно переоткроется через tun), UDP → drop. Проверено: убивает
    /// основную массу залипших (94→52 за минуту); остаток — бейдж «⚠».
    /// Только по событию и не чаще раза в 8 с — иначе прошлый вариант
    /// превращался в spam pf-перезагрузок каждые 3 секунды.
    private func killStickyDirect() {
        resetQueue.async {
            guard !self.resetInFlight else { return }
            guard Date().timeIntervalSince(self.lastResetAt) >= 8 else { return }
            self.resetInFlight = true
            self.lastResetAt = Date()
            defer { self.resetInFlight = false }
            var apps = self.loadApps()
            let tunIP = (self.expectedAddr ?? "").split(separator: "/").first.map(String.init) ?? ""
            let pidTag = self.appPidMap(apps)
            guard !pidTag.isEmpty else { return }
            var rules: [String] = []
            var seen = Set<String>()
            for s in self.appSocketLines(pidTag) {
                // tun-сокет — ядро управляет им сам (DELETE /connections)
                if !tunIP.isEmpty && s.lh == tunIP { continue }
                if Self.isPrivateDest(s.rh) { continue }   // LAN/airplay/DNS роутера — штатно мимо tun
                let tuple = "\(s.proto)|\(s.lh)|\(s.lp)|\(s.rh)|\(s.rp)"
                guard seen.insert(tuple).inserted else { continue }
                let action = s.proto == "tcp" ? "block return-rst" : "block drop"
                rules.append("\(action) out quick proto \(s.proto) from \(s.lh) port \(s.lp) to \(s.rh) port \(s.rp)")
                if rules.count >= 400 { break }
            }
            let hasRules = !rules.isEmpty
            if hasRules, !PFFirewall.loadTemp(rules.joined(separator: "\n")) {
                NSLog("awgapprouterd: socket-reset: pf не принял правила (\(rules.count))")
                return
            }
            // ПОРЯДОК КРИТИЧЕН (debug-sticky v2): pf матчит established-пакеты
            // по state ДО правил — killStates обязан быть ПОСЛЕ загрузки block
            PFFirewall.killStates()
            if hasRules {
                NSLog("awgapprouterd: socket-reset: \(rules.count) direct-потоков, pids=\(pidTag.count)")
                Thread.sleep(forTimeInterval: 2)
            }
            // откат: вернуть актуальный режим (seal, если tun снова умер)
            let sealedNow = self.applyQ.sync { self.sealed }
            if sealedNow, let rules = self.emergencyRules {
                _ = PFFirewall.seal(emergencyRules: rules)
            } else {
                PFFirewall.unseal()
            }
        }
    }

    /// "1.2.3.4:5678" / "[::1]:53" → (host, port)
    private static func splitAddrPort(_ s: String) -> (String, String)? {
        guard let colon = s.lastIndex(of: ":") else { return nil }
        let host = String(s[s.startIndex..<colon]).replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
        let port = String(s[s.index(after: colon)...])
        guard !host.isEmpty, !port.isEmpty else { return nil }
        return (host, port)
    }

    /// Выполнить утилиту, вернуть stdout. СНАЧАЛА readDataToEndOfFile,
    /// ПОТОМ waitUntilExit: если наоборот — при выводе >64 КБ (pipe buffer)
    /// ребёнок блокируется на write, родитель на wait — взаимная блокировка
    /// (именно так boot вешался на `ps -axo`: 78 КБ вывода, XPC не отпускался).
    /// Watchdog 8 с — зависший lsof не должен вешать тик/загрузку.
    private func capture(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if p.isRunning { p.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // macOS-26 Foundation НЕ закрывает fd'ы Pipe при выходе ребёнка —
        // практически +1 fd на каждый спавн, за час тиков EMFILE (errno 24)
        // и отказ записи конфига (залипание GUI-кнопок, 28.11 03:49). Явно:
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func tick() {
        lock.lock()
        let m = mode
        lock.unlock()
        guard m != .off else { publishIfChanged(); return }
        if tunUp() {
            tunMismatch = 0
            if !lastTunUp {
                // tun ТОЛЬКО что поднялся (включили защиту/реанимация): pf-состояния,
                // прибитые к en0 пока tun не было, — прямая дыра в защите (даже в
                // тюрьме: залипшие сессии дотекают мимо ядра). Рвём их сразу.
                lastTunUp = true
                governor.tunCameUp(at: Date())   // backoffbounce/crash — снова к базе
                PFFirewall.killStates()
                killStickyDirect()
            }
            // индикатор — ядро, не память: блок мог остаться после рестарта
            // демона (наш флаг тогда чист), а интернет лежать
            if sealed || PFFirewall.isSealed() {
                PFFirewall.unseal()
                sealed = false
                NSLog("awgapprouterd: tun есть — аварийный блок СНЯТ")
                PFFirewall.killStates()   // после снятия блока — тот же редирект трафика
                killStickyDirect()
            }
            recheckEndpointDNS()
        } else {
            // tun мёртв: индикаторы серверов больше не доверять
            lastTunUp = false
            clashNow = [:]; clashOK = false
            // ядро живо, но tun не соответствует конфигу (осиротевший box со старым
            // конфигом пережил bootout) — bounce, иначе seal навсегда
            if runningBoxPid() != 0 {
                tunMismatch += 1
                // раньше bounce был каждые 10 с при мёртвом tun — шторм: TUN/pf
                // дёргались бесконечно. Теперь экспоненциальная пауза (10→300),
                // счётчик mismatch'ей остаётся фильтром ложных срабатываний
                if tunMismatch >= 3 && governor.bounceAllowed(at: Date()) {
                    tunMismatch = 0
                    governor.bounceFired(at: Date())
                    NSLog("awgapprouterd: tun не совпадает с конфигом — перезапускаю ядро")
                    applyQ.async {
                        self.appliedStruct = ""   // structural-галочка не должна спасать
                        _ = self.applyIntentLocked("bounce tun mismatch")
                    }
                }
            }
            // tun мёртв: seal + реанимация
            if sealed && !PFFirewall.isSealed() {
                if let rules = emergencyRules, PFFirewall.seal(emergencyRules: rules) {
                    NSLog("awgapprouterd: block перезагружен (его кто-то стёр)")
                }
            } else if !sealed {
                if let rules = emergencyRules, PFFirewall.seal(emergencyRules: rules) {
                    sealed = true
                    NSLog("awgapprouterd: tun исчез — WAN запечатан (LAN/DHCP/mDNS/endpoint жив)")
                } else {
                    NSLog("awgapprouterd: !! не удалось загрузить аварийный блок")
                }
            }
            // туннель лежит: IP эндпоинтов мог смениться (динамический DNS) — раз в
            // минуту перерезолвливаем и перезаливаем конфиг + pf-блок, иначе блок
            // отрежет новый адрес ядра и мы останемся запечатаны навсегда
            refreshEndpointAddrsIfNeeded()
            restartIfThrottled()
        }
        refreshClashCache(force: Date() < clashUrgentUntil)
        publishIfChanged()
    }

    private func refreshEndpointAddrsIfNeeded() {
        guard Date().timeIntervalSince(lastAddrRefresh) > 60 else { return }
        lastAddrRefresh = Date()
        EndpointResolver.flush()
        applyQ.async { _ = self.applyIntentLocked("tun down: перечитать IP эндпоинтов") }
        if sealed, let rules = try? String(contentsOfFile: Paths.pfEmergency, encoding: .utf8) {
            _ = PFFirewall.seal(emergencyRules: rules)   // обновить IP в блоке
        }
    }

    /// раз в 5 мин сверяем IP эндпоинтов с DNS: у хостингов адреса меняются,
    /// а в конфиг записан IP (ядро хосты не варит) — иначе туннель тихо умрёт
    private func recheckEndpointDNS() {
        guard Date().timeIntervalSince(dnsCheckTime) > 300 else { return }
        dnsCheckTime = Date()
        for spec in loadServers() where spec.enabled {
            guard let p = try? spec.profile() else { continue }
            let host = p.endpointHost
            guard !host.isEmpty else { continue }
            guard let ip = EndpointResolver.address(for: host) else { continue }
            if usedIPs[spec.id] != ip {
                NSLog("awgapprouterd: %@ сменил IP: %@ → %@ — переподключаю",
                    spec.id, usedIPs[spec.id] ?? "—", ip)
                applyQ.async { _ = self.applyIntentLocked("DNS эндпоинта сменился") }
                return
            }
        }
    }

    // MARK: - clash-api: живость urltest и фактический выбор selector'ов

    private func refreshClashCache(force: Bool) {
        if !force, Date().timeIntervalSince(clashCacheTime) < 2 { return }
        clashCacheTime = Date()
        guard let body = clashRequest("GET", "/proxies", nil),
              let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let proxies = obj["proxies"] as? [String: Any] else {
            clashOK = false
            return
        }
        clashOK = true
        for (tag, v) in proxies {
            guard tag.hasPrefix("srv-") || tag.hasPrefix("app-")
                    || tag == ConfigBuilder.aiSelector else { continue }
            // urltest/selector: now непустой = избрал участника (жив / выбран)
            if let d = v as? [String: Any], let now = d["now"] as? String {
                clashNow[tag] = now
            }
        }
    }

    /// HTTP GET/PUT поверх TCP-петли clash_api (127.0.0.1:39080 + Bearer-секрет).
    /// PUT /proxies/<selector> {"name":"srv-1"} — горячее переключение (204).
    private func clashRequest(_ method: String, _ path: String, _ body: String?) -> String? {
        let parts = ConfigBuilder.clashAPI.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]) else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let connected = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let bodyData = body.map { Data($0.utf8) }
        var req = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer \(ConfigBuilder.clashSecret)\r\nConnection: close\r\n"
        if let b = bodyData {
            req += "Content-Type: application/json\r\nContent-Length: \(b.count)\r\n\r\n"
        } else {
            req += "\r\n"
        }
        req.withCString { _ = send(fd, $0, strlen($0), 0) }
        if let b = bodyData { _ = b.withUnsafeBytes { send(fd, $0.baseAddress!, b.count, 0) } }
        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            resp.append(contentsOf: buf[..<n])
        }
        guard let range = resp.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: resp[..<range.lowerBound], encoding: .utf8) ?? ""
        // PUT отвечает 204 без тела — это успех
        guard head.contains(" 200 ") || head.contains(" 204 ") else { return nil }
        return String(data: resp[range.upperBound...], encoding: .utf8)
    }

    // MARK: - box-процесс

    private func startBoxIfDead() {
        lock.lock(); defer { lock.unlock() }
        guard box == nil, runningBoxPid() == 0 else { return }
        lastStart = Date()
        launchBoxLocked()
    }

    private func restartIfThrottled() {
        lock.lock(); defer { lock.unlock() }
        guard box == nil, runningBoxPid() == 0 else { return }
        // было: каждые 5 с до бесконечности — краш-петля битого конфига
        // долбила ядро; теперь 5 → 10 → 20 → … 60 с, сброс при oживлении tun
        let nowD = Date()
        guard governor.crashRestartAllowed(at: nowD) else { return }
        NSLog("awgapprouterd: box мёртв — рестарт")
        lastStart = nowD
        governor.crashRestarted(at: nowD)
        launchBoxLocked()
    }

    private func launchBoxLocked() {
        // вывод ядра — надёжно: sh exec с >> (FileHandle из-под launchd не долетал,
        // а FATAL без лога — не диагностика)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exec " + Paths.boxBinary + " run -c " + Paths.configJSON
                      + " >> " + Paths.boxLog + " 2>&1"]
        p.terminationHandler = { [weak self] proc in
            guard let self else { return }
            self.lock.lock()
            if self.box === proc { self.box = nil }
            self.lastError = "box exited rc=\(proc.terminationStatus)"
            self.lock.unlock()
            self.pidLock.lock()
            if self.trackedBoxPid == Int(proc.processIdentifier) { self.trackedBoxPid = 0 }
            self.pidLock.unlock()
            NSLog("awgapprouterd: box завершился rc=%d", proc.terminationStatus)
        }
        do {
            try p.run()
            box = p
            pidLock.lock(); trackedBoxPid = Int(p.processIdentifier); pidLock.unlock()
            NSLog("awgapprouterd: box запущен pid=%d", p.processIdentifier)
        } catch {
            lastError = "spawn box: \(error)"
            NSLog("awgapprouterd: !! %@", lastError)
        }
    }

    private func terminateBox() {
        lock.lock()
        let p = box
        box = nil
        lock.unlock()
        p?.terminationHandler = nil
        p?.terminate() // SIGTERM — ядро корректно снимает маршруты
        // осиротевшие box от прежних запусков демона (launchd bootout не убивает
        // детей) — снимаем маршруты и tun у них тоже, иначе вечный mismatch
        killOrphans()
    }

    /// убить все awgapprouter-box (осиротевших от прежних демонов тоже)
    private func killOrphans() {
        for pid in Self.pgrepBox() { kill(pid, SIGTERM) }
        for _ in 0..<10 {
            if Self.pgrepBox().isEmpty { break }
            usleep(200_000)
        }
        for pid in Self.pgrepBox() { kill(pid, SIGKILL) }
    }

    /// Убить box-и, порождённые не нами (после смены конфига).
    private func killStaleBoxes() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-x", "awgapprouter-box"]
        try? p.run()
        p.waitUntilExit()
        usleep(500_000)
    }

    private static func pgrepBox() -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-x", "awgapprouter-box"]
        let out = Pipe()
        p.standardOutput = out
        do { try p.run() } catch { return [] }
        // Чтение ДО wait (pipe-дедлок — уже кусали) + watchdog: pgrep умеет
        // встать в ядре намертво, пока другой процесс виснет в pf; без
        // дедлайна он вешал целый тик супервизора (28.11 00:29).
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning {
                NSLog("awgapprouterd: !! pgrep завис (3 с) — принудительно убиваю")
                kill(p.processIdentifier, SIGKILL)
            }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? out.fileHandleForReading.close()
        try? out.fileHandleForWriting.close()
        let txt = String(data: data, encoding: .utf8) ?? ""
        return txt.split(separator: "\n").compactMap { Int32($0) }
    }

    /// жив ли ядро — без спавна детей (см. trackedBoxPid)
    private func runningBoxPid() -> Int {
        pidLock.lock(); let pid = trackedBoxPid; pidLock.unlock()
        guard pid > 0 else { return 0 }
        if kill(pid_t(pid), 0) == 0 { return pid }
        pidLock.lock()
        if trackedBoxPid == pid { trackedBoxPid = 0 }
        pidLock.unlock()
        return 0
    }

    // MARK: - tun

    private func tunUp() -> Bool {
        guard let want = expectedAddr else { return false }
        var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrsPtr) == 0 else { return false }
        defer { freeifaddrs(ifaddrsPtr) }
        var p = ifaddrsPtr
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ok = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                inet_ntop(AF_INET, &sin.pointee.sin_addr, &host, socklen_t(INET_ADDRSTRLEN)) != nil
            }
            if ok && String(cString: host) == want { return true }
        }
        return false
    }

    private static func tunAddressFromConfig() -> String? {
        guard let text = try? String(contentsOfFile: Paths.configJSON, encoding: .utf8),
              let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inbounds = obj["inbounds"] as? [[String: Any]],
              let addr = inbounds.first?["address"] as? [String],
              let first = addr.first else { return nil }
        return String(first.split(separator: "/").first ?? "")
    }

    private func writeMode(_ m: TunnelMode) {
        try? m.rawValue.write(toFile: Paths.modeFile, atomically: true, encoding: .utf8)
    }

    private func readModeFile() -> TunnelMode? {
        guard let s = try? String(contentsOfFile: Paths.modeFile, encoding: .utf8) else { return nil }
        switch s.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "off": return .off
        default:    return .running   // block/tunnel/старое -> running (серверы решают)
        }
    }
}

/// Gateway — см. PFFirewall.swift (pf seal/unseal) — там же обёртка pfctl.
public enum Gateway {
    /// Дефолтный гейтвей: "gateway: x" из `route -n get default`.
    public static func current() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice   // Pipe() тут течь: никто не читал
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let txt = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try? out.fileHandleForReading.close()
        try? out.fileHandleForWriting.close()
        for line in txt.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2 && parts[0] == "gateway" { return parts[1] }
        }
        return nil
    }
}
