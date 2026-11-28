import Foundation
import Darwin

/// Форк amnezia-box в awg-эндпоинте принимает peer address ТОЛЬКО как IP:порт:
/// `set ipc config: ParseAddr("host.example"): unexpected character` — и это FATAL
/// на старте ядра, причём `sing-box check` его НЕ ловит (проверка не резолвит).
/// Поэтому резолвим хосты эндпоинтов сами — демон работает ВНЕ туннеля, его DNS
/// идёт напрямую через роутер, так что цикла «туннель резолвит свой эндпоинт» нет.
public enum EndpointResolver {
    private struct Cache { var ip: String; var at: Date }
    private static var cache: [String: Cache] = [:]
    private static let lock = NSLock()
    /// сколько держать IP в кэше: у провайдеров динамический DNS, но не каждую секунду
    public static var ttl: TimeInterval = 10 * 60

    /// IPv4-адрес хоста (или сам хост, если это уже литерал). nil — не разрешился.
    /// При сбое резолва отдаём устаревший кэш: лучше стучаться на старый IP, чем
    /// ронять ядро (приложение всё равно получит защиту, а не утечку).
    public static func address(for host: String) -> String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        if isIPv4(h) || isIPv6(h) { return h }

        lock.lock(); let hit = cache[h]; lock.unlock()
        if let hit, Date().timeIntervalSince(hit.at) < ttl { return hit.ip }

        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: IPPROTO_UDP, ai_addrlen: 0,
                             ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        defer { if res != nil { freeaddrinfo(res) } }
        var ip: String?
        if getaddrinfo(h, nil, &hints, &res) == 0 {
            var p = res
            while let cur = p {
                if cur.pointee.ai_family == AF_INET, let sa = cur.pointee.ai_addr {
                    ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                        var addr = sin.pointee.sin_addr
                        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        guard inet_ntop(AF_INET, &addr, &buf,
                                        socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
                        return String(cString: buf)
                    }
                    if ip != nil { break }
                }
                p = cur.pointee.ai_next
            }
        }
        if let ip {
            lock.lock(); cache[h] = Cache(ip: ip, at: Date()); lock.unlock()
            return ip
        }
        return hit?.ip   // stale-ошибка → держим прошлый адрес
    }

    public static func isIPv4(_ s: String) -> Bool {
        var addr = in_addr()
        return inet_pton(AF_INET, s, &addr) == 1
    }

    public static func isIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        return inet_pton(AF_INET6, s, &addr) == 1
    }

    /// сброс кэша (например, после смены сервера или при «не поднимается»)
    public static func flush() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }
}
