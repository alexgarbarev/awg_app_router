import XCTest
@testable import AWGAppRouterKit

/// Логика «укрощения» рестартов ядра: экспоненциальный backoff для bounce
/// (tun мёртв) и watchdog-рестартов, плюс коалесинг структурных рестартов.
/// Чистые типы, время инжектируется — тесты детерминированы.
///
/// Семантика Backoff: allowed = прошло >= current с последнего fire;
/// fire поднимает current на 2*current (с потолком); reset возвращает к base.
final class BackoffTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func t(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    // MARK: Backoff

    func testFirstFireAllowedImmediately() {
        // до первого события backoff не блокирует: первая реакция быстрая,
        // base задаёт интервал МЕЖДУ событиями
        var b = Backoff(base: 10, ceiling: 300)
        XCTAssertTrue(b.allowed(at: t(0)))
        b.fire(at: t(0))
        XCTAssertFalse(b.allowed(at: t(9.9)))
        XCTAssertTrue(b.allowed(at: t(10)))
    }

    func testDelayDoublesAfterEachFire() {
        // интервалы после каждого fire: base(10), 20, 40, …
        var b = Backoff(base: 10, ceiling: 300)
        b.fire(at: t(10))
        XCTAssertFalse(b.allowed(at: t(19.9)))
        XCTAssertTrue(b.allowed(at: t(20)))
        b.fire(at: t(20))
        XCTAssertFalse(b.allowed(at: t(39.9)))
        XCTAssertTrue(b.allowed(at: t(40)))       // окно 20
        b.fire(at: t(40))
        XCTAssertTrue(b.allowed(at: t(80)))       // окно 40
    }

    func testCeilingRespected() {
        var b = Backoff(base: 10, ceiling: 60)
        var now = t(0)
        for _ in 0..<10 {
            while !b.allowed(at: now) { now = now.addingTimeInterval(1) }
            b.fire(at: now)
        }
        XCTAssertEqual(b.current, 60, "потолок не пробивается")
    }

    func testResetReturnsToBase() {
        var b = Backoff(base: 10, ceiling: 300)
        b.fire(at: t(10))
        XCTAssertEqual(b.current, 10, "первый интервал — база")
        b.fire(at: t(20))
        XCTAssertEqual(b.current, 20)
        b.fire(at: t(40))
        XCTAssertEqual(b.current, 40)
        b.reset()
        XCTAssertEqual(b.current, 10)
        XCTAssertFalse(b.allowed(at: t(49.9)))
        XCTAssertTrue(b.allowed(at: t(50)))
    }

    // MARK: RestartGovernor — коалесинг структурных рестартов

    func testStructuralRestartsCoalesced() {
        var g = RestartGovernor(coalesce: 2)
        XCTAssertTrue(g.structuralRestartAllowed(at: t(0)), "первый — сразу")
        g.structuralRestarted(at: t(0))
        XCTAssertFalse(g.structuralRestartAllowed(at: t(1.9)))
        XCTAssertTrue(g.structuralRestartAllowed(at: t(2)))
    }

    // MARK: RestartGovernor — bounce с экспоненциальной паузой

    func testBounceBackoffDoublesAndResetsOnTunUp() {
        var g = RestartGovernor(coalesce: 2)
        XCTAssertTrue(g.bounceAllowed(at: t(0)), "первый bounce не заблокирован")
        g.bounceFired(at: t(0))
        XCTAssertTrue(g.bounceAllowed(at: t(10)), "первое окно — база 10")
        g.bounceFired(at: t(10))
        XCTAssertFalse(g.bounceAllowed(at: t(29)))
        XCTAssertTrue(g.bounceAllowed(at: t(30)))     // окно 20
        g.bounceFired(at: t(30))
        XCTAssertFalse(g.bounceAllowed(at: t(69)))
        XCTAssertTrue(g.bounceAllowed(at: t(70)))     // окно 40
        g.tunCameUp(at: t(71))                        // туннель ожил
        XCTAssertTrue(g.bounceAllowed(at: t(71)),     // reset к базе
                      "после восстановления tun backoff возвращается к базе")
        g.bounceFired(at: t(71))
        XCTAssertFalse(g.bounceAllowed(at: t(80)))
        XCTAssertTrue(g.bounceAllowed(at: t(81)))     // снова 10, не 80
    }

    func testCrashBackoffSeparateInstance() {
        // watchdog «box мёртв»: база 5, окна 5 → 10 → 20 → 40 → 60 (потолок)
        var b = Backoff(base: 5, ceiling: 60)
        XCTAssertTrue(b.allowed(at: t(0)))
        b.fire(at: t(0)); XCTAssertTrue(b.allowed(at: t(5)))    // окно 5 (база)
        b.fire(at: t(5)); XCTAssertTrue(b.allowed(at: t(15)))    // окно 10
        b.fire(at: t(15)); XCTAssertTrue(b.allowed(at: t(35)))   // окно 20
        b.fire(at: t(35)); XCTAssertTrue(b.allowed(at: t(75)))   // окно 40
        b.fire(at: t(75)); XCTAssertTrue(b.allowed(at: t(135)))  // окно 60 = потолок
        XCTAssertFalse(b.allowed(at: t(134.9)))
    }
}
