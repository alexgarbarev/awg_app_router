import Foundation
import AWGAppRouterKit

/// Обёртка над pfctl. Уроки v9 зафиксированы в ConfigBuilder.pfEmergencyRules:
/// правила только quick и вставляются ПЕРЕД anchor "com.apple/*".
enum PFFirewall {
    /// ВАЖНО: читать pipe ДО waitUntilExit — pfctl -k/-K печатает убитые
    /// состояния построчно, на живой машине это >64 КБ (pipe buffer): ребёнок
    /// встанет на write, родитель на wait — взаимная блокировка навсегда
    /// (именно так встал applyQ и все XPC-кнопки GUI давали «демон не
    /// отвечает», а удалённое приложение оставалось заблокированным).
    /// Watchdog 8 с — зависший pfctl не должен вешать applyQ.
    private static func pfctl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/pfctl")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, "\(error)") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            if p.isRunning { p.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? out.fileHandleForReading.close()
        try? out.fileHandleForWriting.close()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// pf включён? (нужен хук, иначе блок не работает)
    static func ensureEnabled() {
        let (rc, out) = pfctl(["-s", "info"])
        if rc == 0 && !out.contains("Status: Active") {
            _ = pfctl(["-E"])
        }
    }

    static func seal(emergencyRules: String) -> Bool {
        ensureEnabled()
        try? emergencyRules.write(toFile: Paths.pfEmergency, atomically: true, encoding: .utf8)
        return activate(inserting: emergencyRules)
    }

    static func unseal() {
        _ = pfctl(["-f", "/etc/pf.conf"])
    }

    /// Есть ли наш блок в активном ruleset (его мог стереть ALF/перезагрузка конфига).
    static func isSealed() -> Bool {
        let (_, out) = pfctl(["-sr"])
        return out.contains("block drop out quick inet")
    }

    /// Временный ruleset поверх стокового /etc/pf.conf с tuple-блоками для
    /// залипших прямых сокетов (Supervisor.killStickyDirect). Откатывает
    /// вызывающий: seal (если tun мёртв) или unseal.
    @discardableResult
    static func loadTemp(_ block: String) -> Bool {
        ensureEnabled()
        let base = (try? String(contentsOfFile: "/etc/pf.conf", encoding: .utf8)) ?? ""
        var out = ""
        var inserted = false
        for line in base.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inserted && line.hasPrefix("anchor ") {
                out += block + "\n"
                inserted = true
            }
            out += line + "\n"
        }
        if !inserted { out += block + "\n" }
        try? out.write(toFile: Paths.pfReset, atomically: true, encoding: .utf8)
        let (rc, _) = pfctl(["-nf", Paths.pfReset])
        guard rc == 0 else { return false }
        let (rc2, _) = pfctl(["-f", Paths.pfReset])
        return rc2 == 0
    }

    /// Сбросить ВСЕ состояния pf: старые «прямые» сокеты, established ДО
    /// подъёма TUN, не попадают в ядро (clash их не видит, а pf не матчит
    /// по процессу) — дотекают мимо туннеля, пока не умрут. Убийство состояний
    /// заставляет приложения прозрачно переподключиться уже через tun.
    /// Операция редкая (только включение туннеля), обрыв на секунду.
    static func killStates() {
        ensureEnabled()
        var rc: Int32 = -1
        for (flag, net) in [("-k", "0.0.0.0/0"), ("-K", "0.0.0.0/0"),
                             ("-k", "::/0"), ("-K", "::/0")] {
            (rc, _) = pfctl([flag, net])
        }
        NSLog("awgapprouterd: pf state flush (rc=\(rc))")
    }

    /// Вставить emergency-блок в начало filtering-секции (перед первым anchor),
    /// проверить синтаксис и загрузить.
    @discardableResult
    static func activate(inserting block: String) -> Bool {
        let base = (try? String(contentsOfFile: "/etc/pf.conf", encoding: .utf8)) ?? ""
        var out = ""
        var inserted = false
        for line in base.split(separator: "\n", omittingEmptySubsequences: false) {
            if !inserted && line.hasPrefix("anchor ") {
                out += block + "\n"
                inserted = true
            }
            out += line + "\n"
        }
        if !inserted { out += block + "\n" }
        try? out.write(toFile: Paths.pfActive, atomically: true, encoding: .utf8)
        let (rc, _) = pfctl(["-nf", Paths.pfActive])
        guard rc == 0 else { return false }
        let (rc2, err) = pfctl(["-f", Paths.pfActive])
        if rc2 != 0 { NSLog("awgapprouterd: pfctl -f failed: %@", err) }
        return rc2 == 0
    }
}
