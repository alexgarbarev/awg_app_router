import Foundation
import AWGAppRouterKit

// awgapprouterd — root-демон (запускается LaunchDaemon com.awgapprouter.daemon).
// Слушает XPC mach-сервис, супервизорит ядро, сторожит tun, при смерти tun
// печатает pf-пломбу и снимает её при восстановлении.
// Состояние (apps/profile/mode) живёт в /etc/awgapprouter — GUI лишь пульт.

setvbuf(stdout, nil, _IONBF, 0)

// MVP: подключения принимает любой локальный пользователь (однопользовательский Mac).
// Ужесточение (audit-token по UID разработчика) — в roadmap.
let listener = NSXPCListener(machServiceName: Paths.machService)
listener.delegate = DaemonXPC.shared
// boot ДО resume: XPC-команды GUI не должны прилететь в неполностью
// поднятый демон (иначе две перегенерации конфига дерутся за один .tmp)
Supervisor.shared.boot()
listener.resume()
NSLog("awgapprouterd: запущен (pid %d)", ProcessInfo.processInfo.processIdentifier)

RunLoop.main.run()
