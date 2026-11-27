import Foundation

/// Профиль AmneziaWG (.conf, как экспортирует приложение Amnezia).
/// Ключи в экспорте CamelCase (`HeaderProtectionKey`) — парсим регистронезависимо.
public struct AWGProfile: Codable, Equatable {
    public var name: String
    public var endpointHost: String      // "93.115.19.153"
    public var endpointPort: Int         // 31101
    public var address: String           // "10.8.1.4/32"
    public var dns: String               // "172.29.172.254"
    public var privateKey: String
    public var publicKey: String
    public var presharedKey: String?
    public var keepalive: Int           // persistent_keepalive_interval
    public var mtu: Int?                // опционально из [Interface] MTU
    /// awg-параметры: junk-числа (jc/jmin/jmax/s1-4 → Int), h1-4 и тайминги → String,
    /// random_trailers/disable_cookies → Bool. Ключи — lowercase.
    public var junkInts: [String: Int] = [:]
    public var junkStrings: [String: String] = [:]
    public var randomTrailers: Bool = false
    public var disableCookies: Bool = false

    public var endpoint: String { "\(endpointHost):\(endpointPort)" }

    enum CodingKeys: String, CodingKey {
        case name, endpointHost, endpointPort, address, dns, privateKey, publicKey
        case presharedKey, keepalive, mtu, junkInts, junkStrings, randomTrailers, disableCookies
    }
}

public enum ConfError: Error, CustomStringConvertible, LocalizedError {
    case missing(String)
    public var description: String { "в .conf отсутствует \(field)" }
    public var errorDescription: String? { description }
    private var field: String {
        switch self { case .missing(let f): return f }
    }
}

public enum ConfParser {
    private static let intKeys: Set<String> = ["jc", "jmin", "jmax", "s1", "s2", "s3", "s4"]
    /// нормализованный ключ (нижний регистр, без подчёркиваний) -> канон JSON-ключа
    private static let stringKeys: [String: String] = [
        "h1": "h1", "h2": "h2", "h3": "h3", "h4": "h4",
        "headerprotectionkey": "header_protection_key",
        "rekeyaftertime": "rekey_after_time",
        "rekeytimeout": "rekey_timeout",
        "rejectaftertime": "reject_after_time",
        "keepalivetimeout": "keepalive_timeout",
        "maxhandshakeattempts": "max_handshake_attempts",
        "contentpaddingaddition": "content_padding_addition",
    ]

    private static func normalize(_ k: String) -> String {
        k.replacingOccurrences(of: "_", with: "")
    }

    /// Amnezia экспортирует интервалы («25-35») — берём середину (как spike/mkconf.sh).
    static func rangeOrInt(_ s: String?, fallback: Int) -> Int {
        guard let s = s, !s.isEmpty else { return fallback }
        if let i = Int(s) { return i }
        let parts = s.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count >= 2 { return (parts.first! + parts.last!) / 2 }
        return fallback
    }

    public static func parse(text: String, name: String) throws -> AWGProfile {
        var kv: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty && !v.isEmpty { kv[k] = v }
        }
        func req(_ k: String) throws -> String {
            guard let v = kv[k], !v.isEmpty else { throw ConfError.missing(k) }
            return v
        }
        let ep = try req("endpoint")                       // host:port
        guard let colon = ep.lastIndex(of: ":") else { throw ConfError.missing("endpoint port") }
        let hostOnly = String(ep[..<colon])
        guard let port = Int(ep[ep.index(after: colon)...]), port > 0 else {
            throw ConfError.missing("endpoint port")
        }
        let addr = try req("address").split(separator: ",").first.map(String.init) ?? ""
        guard addr.contains("/") else { throw ConfError.missing("address (CIDR)") }
        let dns = (kv["dns"] ?? "").split(separator: ",").first.map(String.init) ?? ""

        var junkInts: [String: Int] = [:]
        var junkStrings: [String: String] = [:]
        var normalized: [String: String] = [:]
        for (k, v) in kv { normalized[Self.normalize(k)] = v }
        for (n, v) in normalized {
            if intKeys.contains(n), let i = Int(v) { junkInts[n] = i }
            else if let canon = stringKeys[n] { junkStrings[canon] = v }
        }
        let boolTrue: Set<String> = ["on", "true", "1", "yes"]
        return AWGProfile(
            name: name,
            endpointHost: hostOnly,
            endpointPort: port,
            address: addr,
            dns: dns,
            privateKey: try req("privatekey"),
            publicKey: try req("publickey"),
            presharedKey: kv["presharedkey"],
            keepalive: Self.rangeOrInt(kv["persistentkeepaliveinterval"], fallback: 30),
            mtu: Int(kv["mtu"] ?? ""),
            junkInts: junkInts,
            junkStrings: junkStrings,
            randomTrailers: boolTrue.contains(normalized["randomtrailers"] ?? ""),
            disableCookies: boolTrue.contains(normalized["disablecookies"] ?? "")
        )
    }
}
