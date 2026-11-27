import AppKit
import CryptoKit
import AWGAppRouterKit

/// Клиент XPC к привилегированному демону.
/// v13: двусторонний канал — клиент экспортирует AWGAppRouterObserver,
/// демон пушит DaemonState при изменениях (onState); pull (status) остаётся
/// fallback: окно появилось, кнопка ⟳, старый демон без пуша.
final class DaemonClient {
    static let shared = DaemonClient()

    /// сюда прилетают снимки состояния (из пуша или pull) — всегда на main
    var onState: ((DaemonState) -> Void)?

    private var cachedInstalled: Bool?
    private var connection: NSXPCConnection? {
        didSet { oldValue?.invalidate() }
    }

    /// приёмник пушей: декларативно слабый — клиент-синглтон, живёт вечно
    private final class Observer: NSObject, AWGAppRouterObserver {
        func stateChanged(_ stateJSON: String) {
            guard let s = try? JSONDecoder().decode(DaemonState.self,
                                                   from: Data(stateJSON.utf8)) else { return }
            DispatchQueue.main.async { DaemonClient.shared.onState?(s) }
        }
    }
    private let observer = Observer()

    private func connect() -> NSXPCConnection {
        if let c = connection { return c }
        let c = NSXPCConnection(machServiceName: "com.awgapprouter.daemon",
                                options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: AWGAppRouterDaemon.self)
        // пуш-канал: демон шлёт stateChanged в этот exported-объект
        c.exportedInterface = NSXPCInterface(with: AWGAppRouterObserver.self)
        c.exportedObject = observer
        // демон перезапускается (⟳, reboot) — сокет рвётся; сбрасываем кэш,
        // следующий вызов откроет свежее соединение сам
        c.interruptionHandler = { [weak self] in self?.connection = nil }
        c.resume()
        connection = c
        return c
    }

    /// ошибка XPC — соединение протухло: сбросить кэш
    private func dropConnection() { connection = nil }

    /// Страховка от зависшего пира: если демон зарегистрирован в launchd, но
    /// его поток стоит, XPC НЕ возвращает ошибку — ни reply, ни errorHandler
    /// не срабатывают никогда. Без дедлайна UI замирал намертво (pending/
    /// syncing=true, кнопки глухи). Первый сработавший канал выигрывает.
    private func guardXPC<T>(timeout: TimeInterval = 4, fallback: T,
                             _ invoke: (@escaping (T) -> Void) -> Void,
                             completion: @escaping (T) -> Void) {
        let lock = NSLock()
        var done = false
        func settle(_ v: T) {
            lock.lock()
            if done { lock.unlock(); return }
            done = true
            lock.unlock()
            DispatchQueue.main.async { completion(v) }
        }
        invoke(settle)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            lock.lock(); let late = done; lock.unlock()
            guard !late else { return }
            self.dropConnection()
            settle(fallback)
        }
    }

    /// Демон установлен (бинарь на месте)? Проверяем диск ВСЕГДА — кэш «false»
    /// раньше запирал UI («пропали кнопки») после временного разрыва XPC.
    /// cachedInstalled означает лишь «демон живо отвечал недавно» (для probe).
    func daemonInstalled() -> Bool {
        let ok = FileManager.default.isExecutableFile(atPath: "/usr/local/lib/awgapprouter/awgapprouterd")
        cachedInstalled = ok
        return ok
    }

    func resetCache() { cachedInstalled = nil }

    /// Установленный демон устарел (бинарь отличается от встроенного в пакет)?
    func daemonNeedsUpdate() -> Bool {
        guard daemonInstalled() else { return false }
        func md5(_ path: String) -> String? {
            guard let d = FileManager.default.contents(atPath: path) else { return nil }
            return Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        let installed = md5("/usr/local/lib/awgapprouter/awgapprouterd")
        let bundled = md5((Bundle.main.resourceURL?.appendingPathComponent("awgapprouterd").path) ?? "")
        guard let i = installed, let b = bundled else { return false }
        return i != b
    }

    /// Быстрая синхронная проверка присутствия демона (не больше 2 с).
    func probe() {
        let sem = DispatchSemaphore(value: 0)
        let proxy = connect().remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.dropConnection()
            self?.cachedInstalled = nil
            sem.signal()
        } as? AWGAppRouterDaemon
        proxy?.status { [weak self] _ in
            self?.cachedInstalled = true
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
    }

    /// Синхронизировать серверы+приложения и применить.
    func sync(servers: [ServerSpec], apps: [AppRule], mode: TunnelMode,
              completion: @escaping (Bool, String) -> Void) {
        guard daemonInstalled() else {
            completion(false, "Демон не установлен. «Установить демон…»")
            return
        }
        func enc<T: Encodable>(_ v: T) -> String {
            String(data: (try? JSONEncoder().encode(v)) ?? Data("[]".utf8),
                   encoding: .utf8) ?? "[]"
        }
        guardXPC(fallback: (false, "демон не отвечает — «⟳ Обновить демон»")) { settle in
            let proxy = self.connect().remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.dropConnection()
                self?.cachedInstalled = nil
                settle((false, "Демон недоступен: \(error.localizedDescription)"))
            } as? AWGAppRouterDaemon
            proxy?.sync(enc(servers), appsJSON: enc(apps), mode: mode.rawValue) { ok, msg in
                settle((ok, msg))
            } ?? settle((false, "демон недоступен"))
        } completion: { ok, msg in completion(ok, msg) }
    }

    /// Подключить/отключить один сервер.
    func setServer(id: String, enabled: Bool, completion: @escaping (Bool, String) -> Void) {
        guard daemonInstalled() else {
            completion(false, "Демон не установлен")
            return
        }
        guardXPC(fallback: (false, "демон не отвечает — «⟳ Обновить демон»")) { settle in
            let proxy = self.connect().remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.dropConnection()
                settle((false, "Демон недоступен: \(error.localizedDescription)"))
            } as? AWGAppRouterDaemon
            proxy?.setServer(id, enabled: enabled) { ok, msg in settle((ok, msg)) }
                ?? settle((false, "демон недоступен"))
        } completion: { ok, msg in completion(ok, msg) }
    }

    /// «Подключать нужные серверы при старте системы» (Настройки) — демоном.
    func setAutoConnect(_ on: Bool, completion: @escaping (Bool, String) -> Void) {
        guard daemonInstalled() else {
            completion(false, "Демон не установлен")
            return
        }
        guardXPC(fallback: (false, "демон не отвечает — «⟳ Обновить демон»")) { settle in
            let proxy = self.connect().remoteObjectProxyWithErrorHandler { [weak self] error in
                self?.dropConnection()
                settle((false, "Демон недоступен: \(error.localizedDescription)"))
            } as? AWGAppRouterDaemon
            proxy?.setAutoConnect(on) { ok, msg in settle((ok, msg)) }
                ?? settle((false, "демон недоступен"))
        } completion: { ok, msg in completion(ok, msg) }
    }

    /// Полное выключение ядра: сначала одноразовый admin-токен через osascript,
    /// потом команда демону. Диалог с паролем показывает система, не мы.
    func powerOff(completion: @escaping (Bool, String) -> Void) {
        guard daemonInstalled() else {
            completion(false, "Демон не установлен")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // osascript создаёт токен от root — это и есть парольные ворота
            let appleScript = NSAppleScript(source:
                "do shell script \"umask 077; touch /etc/awgapprouter/off-ack\" with administrator privileges")
            var errDict: NSDictionary?
            appleScript?.executeAndReturnError(&errDict)
            if let err = errDict, err["NSErrorCode"] as? Int != nil {
                DispatchQueue.main.async { completion(false, "отменено") }
                return
            }
            self.guardXPC(fallback: (false, "демон не отвечает — «⟳ Обновить демон» перезапустит его")) { settle in
                let proxy = self.connect().remoteObjectProxyWithErrorHandler { [weak self] error in
                    self?.dropConnection()
                    settle((false, "Демон недоступен: \(error.localizedDescription)"))
                } as? AWGAppRouterDaemon
                proxy?.powerOff { ok, msg in settle((ok, msg)) }
                    ?? settle((false, "демон недоступен"))
            } completion: { ok, msg in completion(ok, msg) }
        }
    }

    func status(completion: @escaping (DaemonState?) -> Void) {
        guard daemonInstalled() else { completion(nil); return }
        // зависший демон: reply не придёт, errorHandler не дёрнется — 4 с и offline
        guardXPC(fallback: nil as DaemonState?) { settle in
            let proxy = self.connect().remoteObjectProxyWithErrorHandler { [weak self] _ in
                self?.dropConnection()   // перезапуск демона — переподключимся на следующем тике
                settle(nil)
            } as? AWGAppRouterDaemon
            proxy?.status { json in
                settle(try? JSONDecoder().decode(DaemonState.self, from: Data(json.utf8)))
            } ?? settle(nil)
        } completion: { s in completion(s) }
    }

    /// Установка/обновление демона: один admin-промпт, дальше скрипт делает всё.
    func installDaemon(force: Bool = false,
                       completion: @escaping (Bool, String) -> Void) {
        if daemonInstalled() && !force && !daemonNeedsUpdate() {
            cachedInstalled = true
            completion(true, "демон уже установлен")
            return
        }
        let script = (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("install-privileged.sh").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            DispatchQueue.main.async { completion(false, "скрипт установки не найден в пакете") }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // кавычки обязательны внутри AppleScript-строки: путь бандла с пробелом,
            // без них /bin/sh режет команду по первому пробелу (exit 127)
            let appleScript = NSAppleScript(source: "do shell script \"\\\"\(script)\\\" 2>&1\" with administrator privileges")
            var errDict: NSDictionary?
            appleScript?.executeAndReturnError(&errDict)
            let scriptOK = errDict == nil
            // авторитет — живой демон, не код osascript: установка могла пройти,
            // а osascript споткнуться (гонка launchctl) — UI не должен врать
            self.cachedInstalled = nil
            self.probe()
            let ok = (self.cachedInstalled ?? false) || scriptOK
            DispatchQueue.main.async {
                self.cachedInstalled = ok
                completion(ok, ok ? "демон установлен и запущен"
                                  : "установка не подтверждена (\(errDict?["NSlocalizedError"] ?? "нет ответа демона"))")
            }
        }
    }
}
