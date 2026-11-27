import Foundation

/// Генератор config.json для ядра amnezia-box — v13 «горячие тумблы»:
///  • system DNS не трогаем; резолвим через роутер (default_domain_resolver);
///  • awg — ENDPOINT (не outbound), urltest — OUTBOUND;
///  • ВСЕ валидные серверы всегда в конфиге (вкл/выкл НЕ меняет состав
///    эндпоинтов) — включение 2-го сервера не дёргает первый;
///  • выбор сервера приложением — selector-группа «app-<i>» на каждое
///    приложение: переключение = PUT /proxies/app-<i> через clash API,
///    без рестарта ядра и без переподключения туннелей;
///  • «выключенный» сервер = его приложения на block; сам эндпоинт тёплый
///    (urltest пробует раз в минуту — копейки трафика, зато мгновенный up);
///  • ни одного валидного сервера — prison: tun на 198.18.0.1;
///  • рестарт ядра нужен только при смене СОСТАВА (добавить/убрать сервер
///    или приложение, смена IP/конфа) — structuralHash это и ловит;
///  • clash_api TCP-петля: демон читает now у urltest (alive) и у selector
///    (куда реально ходит приложение), пишет выбор через PUT.
public struct ConfigBuilder {
    // TODO: сделать списки настраиваемыми (UI), сейчас — дефолты
    /// ключевые слова для DNS-страховки AI-сервисов (резолв через туннель)
    public static let aiDNSKeywords =
        ["anthropic", "claude", "claudemcpcontent", "anthropic-observable"]
    /// домены-страховка: если процесс не сматчился — трафик туда всё равно в туннель
    public static let aiDomains =
        ["claude.ai", "anthropic.com", "claudeusercontent.com"]
    /// адрес tun в prison-режиме (RFC2544 benchmarking, ни с чем не конфликтует)
    public static let prisonTUN = "198.18.0.1/32"
    /// clash-контроллер. Эта сборка sing-box принимает ТОЛЬКО host:port
    /// ("unix:///path" → unknown port, "/path" → missing port). TCP-петля + секрет.
    public static let clashAPI = "127.0.0.1:39080"
    public static let clashSecret = "awgapprouter-ctl"
    /// selector для доменного запасного пути AI-сервисов (страховка утечки)
    public static let aiSelector = "sel-ai"

    /// сервер в конфиге: id + профиль + желаемое состояние (для default)
    public struct Endpoint {
        public let id: String          // "srv-1"
        public let profile: AWGProfile
        public let enabled: Bool       // desired (для selectable default; состав не меняет)
        /// резолвнутый адрес эндпоинта: ядро требует IP (см. EndpointResolver)
        public let peerIP: String?
        public init(id: String, profile: AWGProfile, enabled: Bool = true,
                    peerIP: String? = nil) {
            self.id = id; self.profile = profile; self.enabled = enabled
            self.peerIP = peerIP
        }
        /// адрес для peers/pf: IP, иначе (крайний случай) хост как есть
        var peerAddress: String { peerIP ?? profile.endpointHost }
        var shortID: String {
            id.hasPrefix("srv-") ? String(id.dropFirst(4)) : id
        }
        var awgTag: String { "awg-" + shortID }
        var urltestTag: String { id }
        var dnsTag: String { "dns-" + shortID }
    }

    public let servers: [Endpoint]        // все валидные; порядок = приоритет
    public let apps: [AppRule]
    public let gateway: String            // "192.168.1.1"

    public init(servers: [Endpoint], apps: [AppRule], gateway: String) {
        self.servers = servers
        self.apps = apps
        self.gateway = gateway
    }

    /// tun адрес стабилен: первый валидный сервер независимо от вкл/выкл —
    /// иначе тумбла меняли бы адрес tun и дёргали рестарт
    public var tunAddress: String {
        servers.first?.profile.address ?? Self.prisonTUN
    }

    /// теги urltest включённых (по desired) серверов — пул для selector'ов
    public var enabledTags: [String] {
        servers.filter(\.enabled).map(\.urltestTag)
    }

    /// selector-тег i-го приложения (порядок = apps!)
    public static func selectorTag(appIndex: Int) -> String { "app-\(appIndex)" }

    /// желаемый выбор для приложения: выключенный/неизвестный сервер → block
    public func selection(for app: AppRule) -> String {
        let pool = enabledTags
        if app.serverID.isEmpty { return pool.first ?? "block" }
        return pool.contains(app.serverID) ? app.serverID : "block"
    }

    /// членство selector-группы: все urltest + block (direct приложениям нельзя)
    private var selectablePool: [String] {
        servers.map(\.urltestTag) + ["block"]
    }

    public func buildJSON() throws -> String {
        var endpoints: [[String: Any]] = []
        var outbounds: [[String: Any]] = [
            ["type": "direct", "tag": "direct"],
            ["type": "block", "tag": "block"],
        ]
        for ep in servers {
            let p = ep.profile
            var e: [String: Any] = [
                "type": "awg",
                "tag": ep.awgTag,
                "useIntegratedTun": false,
                "private_key": p.privateKey,
                "address": [p.address],
            ]
            if !p.dns.isEmpty { e["dns"] = [p.dns] }   // legacy — нужно urltest-пробам
            if let mtu = p.mtu { e["mtu"] = mtu }
            for (k, v) in p.junkInts { e[k] = v }
            for (k, v) in p.junkStrings { e[k] = v }
            if p.randomTrailers { e["random_trailers"] = true }
            if p.disableCookies { e["disable_cookies"] = true }
            var peer: [String: Any] = [
                "address": ep.peerAddress,   // IP! хост → FATAL у этого форка
                "port": p.endpointPort,
                "public_key": p.publicKey,
                "allowed_ips": ["0.0.0.0/0", "::/0"],
                "persistent_keepalive_interval": p.keepalive,
            ]
            if let psk = p.presharedKey { peer["preshared_key"] = psk }
            e["peers"] = [peer]
            endpoints.append(e)
            outbounds.append(["type": "urltest", "tag": ep.urltestTag,
                              "outbounds": [ep.awgTag],
                              "url": "https://api.ipify.org",
                              "interval": "1m", "tolerance": 30])
        }
        // selector на каждое приложение: default = желаемый выбор прямо сейчас
        // (переживает рестарт ядра), дальнейшие смены — PUT через clash API
        for (i, app) in apps.enumerated() {
            outbounds.append(["type": "selector",
                              "tag": Self.selectorTag(appIndex: i),
                              "default": selection(for: app),
                              "outbounds": selectablePool])
        }
        // доменный запасной путь AI-сервисов — тоже selector (тумблы без рестарта)
        let aiDefault = enabledTags.first ?? "block"
        outbounds.append(["type": "selector", "tag": Self.aiSelector,
                          "default": aiDefault, "outbounds": selectablePool])

        var dnsServers: [[String: Any]] = [
            ["type": "udp", "tag": "router-dns", "server": gateway],
        ]
        var dnsRules: [[String: Any]] = []
        for ep in servers where !ep.profile.dns.isEmpty {
            dnsServers.append(["type": "udp", "tag": ep.dnsTag,
                               "server": ep.profile.dns, "detour": ep.urltestTag])
        }
        // AI-домены резолвит первый сервер с legacy-DNS (без него — роутер);
        // стабильно по составу, тумблы не влияют
        if let first = servers.first(where: { !$0.profile.dns.isEmpty }) {
            dnsRules.append(["action": "route", "server": first.dnsTag,
                             "domain_keyword": Self.aiDNSKeywords])
        }

        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["action": "hijack-dns", "protocol": "dns"],
        ]
        for (i, app) in apps.enumerated() {
            routeRules.append(app.routeRule(outbound: Self.selectorTag(appIndex: i)))
        }
        // доменный запасной путь для AI-сервисов (если процесс не сматчился)
        routeRules.append(["action": "route", "outbound": Self.aiSelector,
                           "domain_suffix": Self.aiDomains])

        let root: [String: Any] = [
            "log": ["level": "debug", "timestamp": true],
            "dns": [
                "servers": dnsServers,
                "rules": dnsRules,
                "final": "router-dns",
            ],
            "inbounds": [[
                "type": "tun", "tag": "tun0",
                "address": [tunAddress],
                "auto_route": true, "strict_route": false, "stack": "gvisor",
            ]],
            "endpoints": endpoints,
            "outbounds": outbounds,
            "route": [
                "rules": routeRules,
                "final": "direct",
                "auto_detect_interface": true,
                "default_domain_resolver": "router-dns",
            ],
            "experimental": [
                "clash_api": ["external_controller": Self.clashAPI,
                              "secret": Self.clashSecret],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: root,
                                              options: [.prettyPrinted, .sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    /// структурный срез конфига: ВСЁ, кроме «default» у selector'ов.
    /// Совпал — значит состав (эндпоинты/приложения/IP/DNS) не менялся:
    /// применять можно через clash PUT, без рестарта ядра.
    public static func structuralHash(of json: String) -> String? {
        guard let data = json.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var ubs = obj["outbounds"] as? [[String: Any]] else { return nil }
        for i in ubs.indices where (ubs[i]["type"] as? String) == "selector" {
            ubs[i].removeValue(forKey: "default")
        }
        obj["outbounds"] = ubs
        obj.removeValue(forKey: "log")
        guard let d = try? JSONSerialization.data(withJSONObject: obj,
                                                  options: [.sortedKeys]) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Аварийные pf-правила: LAN/DHCP/mDNS/UDP-эндпоинты живы, остальной WAN — блок.
    /// quick обязателен (в pf без quick последнее совпадение выигрывает),
    /// вставка — ПЕРЕД anchor "com.apple/*" (см. watchdog).
    public func pfEmergencyRules() -> String {
        var rules = """
        # аварийный блок: sing-box мёртв, tun исчез — запечатать WAN
        pass in quick on lo0 all
        pass out quick on lo0 all
        pass out quick inet to 192.168.0.0/16
        pass out quick inet to 10.0.0.0/8
        pass out quick inet to 172.16.0.0/12
        pass out quick inet6 to fe80::/10
        pass out quick proto udp from any port = 68 to any port = 67
        """
        for ep in servers {
            rules += "\npass out quick proto udp to \(ep.peerAddress) port = \(ep.profile.endpointPort)"
        }
        rules += "\nblock drop out quick inet\nblock drop out quick inet6"
        return rules
    }
}
