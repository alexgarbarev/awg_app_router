import XCTest
@testable import AWGAppRouterKit

/// Характеризационные тесты инварианта «тумблы ≠ рестарт ядра» — тот самый
/// structuralHash, которым Supervisor решает, убивать box или нет. Если один
/// из этих тестов покраснеет — тумбла снова дёрнет рестарт туннеля.
final class StructuralHashTests: XCTestCase {

    /// минимальный валидный .conf (ключи-заглушки: парсер их не крипто-проверяет)
    private func conf(host: String, port: Int, address: String) -> String {
        """
        [Interface]
        PrivateKey = aAAbBBcCCdDDeE FFgGhHkK3nNoPqR8sStTuUvV32wX4yz0ABcDefGhIkLm=
        Address = \(address)
        DNS = 172.29.172.254
        MTU = 1420

        [Peer]
        PublicKey = qK1GkK8sGdJdJ9nN0mMlLkKjJiIhHgGfFeEdDcCbBaA==
        PresharedKey = yKKsS7dDfFgGhHjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ0123456789AB=
        Endpoint = \(host):\(port)
        PersistentKeepalive = 25
        Jc = 5
        Jmin = 200
        Jmax = 800
        S1 = 110
        H1 = 0x01000000000000000000000000000000
        """
    }

    private func profile(_ n: Int, host: String = "203.0.113.1", port: Int = 31101,
                         address: String = "10.8.1.4/32") throws -> AWGProfile {
        try ConfParser.parse(text: conf(host: host, port: port, address: address),
                             name: "srv\(n)")
    }

    private func app(_ name: String) -> AppRule {
        AppRule(name: name, path: "/Applications/\(name).app/Contents/MacOS/\(name)",
                bundlePath: "/Applications/\(name).app", includeChildren: true)
    }

    // MARK: тумблы серверов НЕ меняют структуру → рестарта нет

    func testServerEnabledToggleDoesNotChangeStructuralHash() throws {
        let on = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1), enabled: true),
            .init(id: "srv-2", profile: try profile(2, host: "203.0.113.2", port: 31102),
                  enabled: false),
        ], apps: [app("Chrome")], gateway: "192.168.1.1")
        let off = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1), enabled: false),
            .init(id: "srv-2", profile: try profile(2, host: "203.0.113.2", port: 31102),
                  enabled: true),
        ], apps: [app("Chrome")], gateway: "192.168.1.1")

        let h1 = try ConfigBuilder.structuralHash(of: on.buildJSON())
        let h2 = try ConfigBuilder.structuralHash(of: off.buildJSON())
        XCTAssertEqual(h1, h2, "вкл/выкл сервера не должен менять structuralHash")
    }

    /// ВСЕ валидные серверы всегда в конфиге — эндпоинты тёплые
    func testAllServersPresentInConfigRegardlessOfEnabled() throws {
        let b = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1), enabled: true),
            .init(id: "srv-2", profile: try profile(2, host: "203.0.113.2", port: 31102),
                  enabled: false),
        ], apps: [app("Chrome")], gateway: "192.168.1.1")
        let json = try b.buildJSON()
        XCTAssertTrue(json.contains("\"awg-1\""), "awg-1 должен быть в конфиге")
        XCTAssertTrue(json.contains("\"awg-2\""), "выключенный awg-2 тоже обязан быть")
    }

    // MARK: состав МЕНЯЕТСЯ → рестарт легитимен

    func testAddingServerChangesStructuralHash() throws {
        let one = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1)),
        ], apps: [app("Chrome")], gateway: "192.168.1.1")
        let two = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1)),
            .init(id: "srv-2", profile: try profile(2, host: "203.0.113.2", port: 31102)),
        ], apps: [app("Chrome")], gateway: "192.168.1.1")
        XCTAssertNotEqual(try ConfigBuilder.structuralHash(of: one.buildJSON()),
                          try ConfigBuilder.structuralHash(of: two.buildJSON()),
                          "добавление сервера должно требовать рестарт")
    }

    func testAddingAppChangesStructuralHash() throws {
        let b1 = ConfigBuilder(servers: [.init(id: "srv-1", profile: try profile(1))],
                               apps: [app("Chrome")], gateway: "192.168.1.1")
        let b2 = ConfigBuilder(servers: [.init(id: "srv-1", profile: try profile(1))],
                               apps: [app("Chrome"), app("Claude")], gateway: "192.168.1.1")
        XCTAssertNotEqual(try ConfigBuilder.structuralHash(of: b1.buildJSON()),
                          try ConfigBuilder.structuralHash(of: b2.buildJSON()),
                          "добавление приложения = новый selector = рестарт")
    }

    func testEndpointIPChangeChangesStructuralHash() throws {
        let a = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1), enabled: true, peerIP: "203.0.113.1"),
        ], apps: [], gateway: "192.168.1.1")
        let b = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1), enabled: true, peerIP: "203.0.113.9"),
        ], apps: [], gateway: "192.168.1.1")
        XCTAssertNotEqual(try ConfigBuilder.structuralHash(of: a.buildJSON()),
                          try ConfigBuilder.structuralHash(of: b.buildJSON()),
                          "смена IP эндпоинта должна ловиться как структурная")
    }

    // MARK: tun-адрес стабилен на тумблах

    func testTunAddressStableAcrossToggles() throws {
        let a = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1), enabled: true),
            .init(id: "srv-2", profile: try profile(2, host: "203.0.113.2"), enabled: false),
        ], apps: [], gateway: "192.168.1.1")
        let b = ConfigBuilder(servers: [
            .init(id: "srv-1", profile: try profile(1), enabled: false),
            .init(id: "srv-2", profile: try profile(2, host: "203.0.113.2"), enabled: true),
        ], apps: [], gateway: "192.168.1.1")
        XCTAssertEqual(a.tunAddress, b.tunAddress,
                     "tun адрес не должен зависеть от вкл/выкл — иначе тумбла рвёт туннель")
    }

    func testPrisonTunWhenNoServers() {
        let b = ConfigBuilder(servers: [], apps: [app("Chrome")], gateway: "192.168.1.1")
        XCTAssertEqual(b.tunAddress, ConfigBuilder.prisonTUN)
    }
}
