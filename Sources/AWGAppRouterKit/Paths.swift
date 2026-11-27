import Foundation

/// Все пути привилегированной части. Каталог /usr/local/lib/awgapprouter создаётся
/// установщиком (install-privileged.sh) и принадлежит root.
public enum Paths {
    public static let daemonDir = "/usr/local/lib/awgapprouter"
    public static let boxBinary = "/usr/local/lib/awgapprouter/awgapprouter-box"
    public static let daemonBinary = "/usr/local/lib/awgapprouter/awgapprouterd"

    public static let etcDir = "/etc/awgapprouter"
    public static let configJSON = "/etc/awgapprouter/config.json"
    public static let pfEmergency = "/etc/awgapprouter/pf-emergency.rules"
    public static let pfActive = "/etc/awgapprouter/pf-active.rules"
    public static let pfReset = "/etc/awgapprouter/pf-reset.rules"
    public static let enabledFlag = "/etc/awgapprouter/enabled"
    public static let appsJSON = "/etc/awgapprouter/apps.json"
    public static let serversJSON = "/etc/awgapprouter/servers.json"
    public static let profileConf = "/etc/awgapprouter/profile.conf"
    public static let modeFile = "/etc/awgapprouter/mode"
    /// одноразовый токен, создаваемый через osascript with administrator privileges
    public static let offToken = "/etc/awgapprouter/off-ack"
    /// рубильник «автоподключение при старте» (Настройки): файл есть = включено;
    /// демон на boot включает нужные серверы до подъёма ядра
    public static let autoConnect = "/etc/awgapprouter/autoconnect"

    public static let boxLog = "/var/log/awgapprouter-box.log"
    public static let daemonLog = "/var/log/awgapprouter-daemon.log"

    public static let launchDaemonPlist = "/Library/LaunchDaemons/com.awgapprouter.daemon.plist"
    public static let machService = "com.awgapprouter.daemon"

    /// Каталог state.json приложения (non-root).
    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AWGAppRouter", isDirectory: true)
    }
}
