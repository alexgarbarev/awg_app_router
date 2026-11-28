import Foundation

/// Экспоненциальный backoff: события разрешены не чаще, чем раз в `current`;
/// первое событие не блокируется, интервалы: base, 2·base, 4·base, …
/// с потолком `ceiling`; reset возвращает к `base`. Время инжектируется —
/// тесты детерминированы.
public struct Backoff {
    public let base: TimeInterval
    public let ceiling: TimeInterval
    /// окно, которое должно пройти с последнего события, чтобы разрешить следующее
    public private(set) var current: TimeInterval
    public private(set) var last = Date.distantPast
    private var fired = false

    public init(base: TimeInterval, ceiling: TimeInterval) {
        self.base = base
        self.ceiling = ceiling
        self.current = base
    }

    public func allowed(at now: Date) -> Bool {
        now.timeIntervalSince(last) >= current
    }

    public mutating func fire(at now: Date) {
        if fired { current = min(current * 2, ceiling) }
        fired = true
        last = now
    }

    public mutating func reset() {
        current = base
        fired = false
    }
}

/// Решатель рестартов ядра: коалесинг структурных рестартов (серия команд
/// за короткое окно = один рестарт) и экспоненциальный backoff для bounce
/// (tun не поднимается: 10…300 с вместо шторма каждые 10 секунд).
/// Класс с внутренним замком — вызывается из разных очередей (tick, applyQ).
public final class RestartGovernor {
    public let coalesce: TimeInterval
    public private(set) var bounce = Backoff(base: 10, ceiling: 300)
    /// watchdog «box умер»: первая реакция через 5 с (как было), краш-петля — до 60 с
    public private(set) var crash = Backoff(base: 5, ceiling: 60)
    private let lk = NSLock()
    private var lastStructural = Date.distantPast

    public init(coalesce: TimeInterval = 2) {
        self.coalesce = coalesce
    }

    /// рестарт по смене состава можно делать? (внутри окна коалесинга — нет,
    /// заявка будет применена отложенной отработкой окна)
    public func structuralRestartAllowed(at now: Date) -> Bool {
        lk.lock(); defer { lk.unlock() }
        return now.timeIntervalSince(lastStructural) >= coalesce
    }

    public func structuralRestarted(at now: Date) {
        lk.lock(); lastStructural = now; lk.unlock()
    }

    /// bounce tun-несоответствия разрешён? (счётчик mismatch'ей у вызывает)
    public func bounceAllowed(at now: Date) -> Bool {
        lk.lock(); defer { lk.unlock() }
        return bounce.allowed(at: now)
    }

    public func bounceFired(at now: Date) {
        lk.lock(); bounce.fire(at: now); lk.unlock()
    }

    /// туннель ожил — обратно к быстрой реакции
    public func tunCameUp(at now: Date) {
        lk.lock(); bounce.reset(); crash.reset(); lk.unlock()
    }

    /// watchdog «box умер»: 5 с, при краш-петле — до 60 с
    public func crashRestartAllowed(at now: Date) -> Bool {
        lk.lock(); defer { lk.unlock() }
        return crash.allowed(at: now)
    }

    public func crashRestarted(at now: Date) {
        lk.lock(); crash.fire(at: now); lk.unlock()
    }
}
