import Foundation
import AWGAppRouterKit

/// Пользовательский выбор: серверы + приложения (какое — на какой сервер).
/// Лежит в ~/Library/Application Support/AWGAppRouter/state.json (без root).
final class Store {
    static let shared = Store()

    private(set) var apps: [AppRule] = []
    private(set) var servers: [ServerSpec] = []
    /// «подключать нужные серверы при старте системы» — зеркало флага демона
    /// (актуальное берём из снимка статуса; это — кэш, когда демон недоступен)
    private(set) var autostartConnect = false

    private let fm = FileManager.default

    private init() { migrateLegacySupportDir(); load() }

    /// ренойм AppRouter → AWG App Router (28.11): переезд каталога
    /// «Application Support/AppRouter» в «AWGAppRouter» целиком (state.json,
    /// profiles/). Старый остаётся только если новый уже создан вручную —
    /// данные тогда не трогаем.
    private func migrateLegacySupportDir() {
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = dir.appendingPathComponent("AppRouter", isDirectory: true)
        let new = dir.appendingPathComponent("AWGAppRouter", isDirectory: true)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(atPath: old.path, toPath: new.path)
    }

    var hasServers: Bool { !servers.isEmpty }

    func serverName(_ id: String) -> String {
        guard let s = servers.first(where: { $0.id == id }) else { return "—" }
        return s.name
    }

    // MARK: серверы

    /// импорт .conf как нового сервера (валидация парсером сразу)
    @discardableResult
    func importServer(from url: URL) throws -> ServerSpec {
        let text = try String(contentsOf: url, encoding: .utf8)
        let name = url.deletingPathExtension().lastPathComponent
        _ = try ConfParser.parse(text: text, name: name)   // битый .conf — сюда не попадёт
        let spec = ServerSpec(id: ServerID.next(existing: servers.map(\.id)),
                              name: name, confText: text, enabled: false)
        servers.append(spec)
        // копия в своё хранилище — quarantine на Desktop потом не помеха
        let dir = Paths.appSupport.appendingPathComponent("profiles", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent(spec.id + ".conf"), atomically: true, encoding: .utf8)
        save()
        return spec
    }

    func removeServer(id: String) {
        servers.removeAll { $0.id == id }
        for i in apps.indices where apps[i].serverID == id { apps[i].serverID = "" }
        save()
    }

    func setServerEnabled(_ id: String, _ enabled: Bool) {
        guard let i = servers.firstIndex(where: { $0.id == id }) else { return }
        servers[i].enabled = enabled
        save()
    }

    /// переименование: имя — только UI/метка, id (srv-N) и конфиг не трогаем
    func renameServer(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let i = servers.firstIndex(where: { $0.id == id }),
              servers[i].name != trimmed else { return }
        servers[i].name = trimmed
        save()
    }

    // MARK: приложения

    func addApp(_ rule: AppRule) {
        guard !apps.contains(where: { $0.path == rule.path }) else { return }
        var r = rule
        if r.serverID.isEmpty {
            r.serverID = servers.first?.id ?? ""
        }
        apps.append(r)
        save()
    }

    func removeApp(at index: Int) {
        guard apps.indices.contains(index) else { return }
        apps.remove(at: index)
        save()
    }

    func setIncludeChildren(_ value: Bool, at index: Int) {
        guard apps.indices.contains(index) else { return }
        apps[index].includeChildren = value
        save()
    }

    func setAppServer(_ serverID: String, at index: Int) {
        guard apps.indices.contains(index) else { return }
        apps[index].serverID = serverID
        save()
    }

    /// сохранить зеркало флага автоподключения (истина — на диске у демона)
    func setAutostartConnect(_ value: Bool) {
        autostartConnect = value
        save()
    }

    // MARK: persist

    private struct State: Codable {
        var apps: [AppRule]
        var servers: [ServerSpec]
        var profileName: String?    // legacy v1
        var profileText: String?    // legacy v1
        var autoConnect: Bool?      // «подключать нужные серверы при старте»

        init(apps: [AppRule], servers: [ServerSpec], profileName: String?,
             profileText: String?, autoConnect: Bool?) {
            self.apps = apps; self.servers = servers
            self.profileName = profileName; self.profileText = profileText
            self.autoConnect = autoConnect
        }

        /// Толерантный decode: v1-файлы вообще не знают ключей servers/paid.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            apps = (try? c.decode([AppRule].self, forKey: .apps)) ?? []
            servers = (try? c.decode([ServerSpec].self, forKey: .servers)) ?? []
            profileName = try? c.decode(String.self, forKey: .profileName)
            profileText = try? c.decode(String.self, forKey: .profileText)
            autoConnect = try? c.decode(Bool.self, forKey: .autoConnect)
        }
    }

    private var stateURL: URL { Paths.appSupport.appendingPathComponent("state.json") }

    private func load() {
        guard let data = try? Data(contentsOf: stateURL),
              let s = try? JSONDecoder().decode(State.self, from: data) else { return }
        apps = s.apps
        servers = s.servers
        autostartConnect = s.autoConnect ?? false
        // миграция v1: один профиль -> srv-1. enabled=false (тюрьма): разрешение
        // даёт демон (его servers.json), UI подхватит зеркалом из статуса.
        if servers.isEmpty, let t = s.profileText, !t.isEmpty {
            let name = s.profileName ?? "server-1"
            if (try? ConfParser.parse(text: t, name: name)) != nil {
                servers = [ServerSpec(id: "srv-1", name: name, confText: t, enabled: false)]
                for i in apps.indices where apps[i].serverID.isEmpty {
                    apps[i].serverID = "srv-1"
                }
                save()
            }
            // битый conf — legacy-текст оставляем в файле, чтобы не потерять данные
        } else if !servers.isEmpty {
            save()
        }
    }

    private func save() {
        try? fm.createDirectory(at: Paths.appSupport, withIntermediateDirectories: true)
        // legacy v1-поля сохраняем, пока своих серверов нет (данные не теряем)
        var legacyName: String?
        var legacyText: String?
        if servers.isEmpty,
           let data = try? Data(contentsOf: stateURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            legacyName = obj["profileName"] as? String
            legacyText = obj["profileText"] as? String
        }
        let s = State(apps: apps, servers: servers,
                      profileName: legacyName, profileText: legacyText,
                      autoConnect: autostartConnect)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: stateURL)
        }
    }
}
