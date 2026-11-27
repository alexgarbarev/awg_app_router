import Foundation

/// Сервер: стабильный id + сырой .conf + желаемое состояние.
/// id становится тегами: awg-<n> (endpoint), srv-<n> (urltest), dns-<n>.
public struct ServerSpec: Codable, Equatable, Identifiable {
    public var id: String          // "srv-1"
    public var name: String        // "office"
    public var confText: String    // .conf как есть
    public var enabled: Bool       // подключать? (false = сервер в списке, но выключен)

    public init(id: String, name: String, confText: String, enabled: Bool = false) {
        self.id = id
        self.name = name
        self.confText = confText
        self.enabled = enabled
    }

    /// толерантный decode: старые файлы без enabled (и с удалённым paid)
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        confText = try c.decode(String.self, forKey: .confText)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, confText, enabled
    }

    /// валидный профиль или ошибка парсинга
    public func profile() throws -> AWGProfile {
        try ConfParser.parse(text: confText, name: name)
    }
    /// endpoint для UI (host:port) — пусто если conf битый
    public var endpointDisplay: String {
        (try? profile())?.endpoint ?? "?"
    }
}

public enum ServerID {
    /// новый уникальный id: srv-<n>
    public static func next(existing: [String]) -> String {
        var n = 1
        while existing.contains("srv-\(n)") { n += 1 }
        return "srv-\(n)"
    }
}
