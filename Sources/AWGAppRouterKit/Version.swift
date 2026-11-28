/// Версионирование. Разделяем жизнь GUI и демона, чтобы UI-релизы не гоняли
/// переустановку демона впустую.
///
///  • appReleaseVersion — версия приложения (бандла). Растёт КАЖДЫЙ релиз;
///    release.sh пишет её же в Info.plist. Показывается в UI.
///  • daemonVersion — версия демона. Растёт только когда реально менялся
///    демон (его поведение/протокол). Демон зашивает её в себя и приносит
///    в DaemonState.daemonVersion.
///  • minDaemonVersion — минимальная версия демона, которую принимает GUI.
///    Если запущенный демон ниже — GUI предлагает «Обновить демон». UI-only
///    релиз оставляет minDaemonVersion прежним → старый рабочий демон не
///    переустанавливается.
///
/// Почему не md5 бинарей: codesign разных версий macOS переписывает ad-hoc
/// подпись иначе байт-в-байт — на чистых установках вечно горело «устарел».
/// Версия от байт не зависит.
///
/// release.sh: `release.sh X.Y.Z` — bump appReleaseVersion (UI-only);
/// `release.sh X.Y.Z --daemon` — поднимает ещё daemonVersion и
/// minDaemonVersion (изменения в демоне обязательны для этого GUI).
public let appReleaseVersion = "1.0.4"
public let daemonVersion = "1.0.4"
public let minDaemonVersion = "1.0.4"

/// Числовой сравнитель semver «a < b?» (неполные версии дополняются нулями).
/// Не используем стандартную строковую '<': "1.10.0" < "1.9.0" было бы неправдой.
public func daemonVersionOlderThan(_ reported: String, than minimum: String) -> Bool {
    func parts(_ s: String) -> [Int] {
        s.split(separator: ".").map { Int($0) ?? 0 }
    }
    let a = parts(reported), b = parts(minimum)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x < y }
    }
    return false
}
