import Foundation

public enum TunnelMode: String, Codable {
    case off        // ядро остановлено (только через admin-подтверждение)
    case running    // ядро живёт; какие серверы подключать — решает servers.json
}

/// Версия контракта/демона. GUI показывает «Обновить демон», пока на диске
/// демон более старой версии (сверка по md5 бинарника).
/// v14: снимок + autostartConnect, метод setAutoConnect (Настройки).
public let appRouterProtocolVersion = "14"

/// Пуш-канал демон → GUI. Клиент экспортирует этот интерфейс при подключении;
/// демон дергает stateChanged при каждом изменении снимка (generation растёт).
/// XPC здесь — mach-сервис (двусторонние асинхронные вызовы через ядро),
/// не pipe и не общая память: событие = «у демона новый снимок», GUI берёт
/// его из тела вызова (push) либо дёргает status() сам (pull-fallback).
@objc public protocol AWGAppRouterObserver: NSObjectProtocol {
    func stateChanged(_ stateJSON: String)
}

/// XPC-контракт. Примитивы (String/Bool) — надёжно через NSXPC.
/// Демон сам хранит состояние (apps.json + servers.json + mode в /etc/awgapprouter)
/// и перегенерирует конфиг при загрузке — GUI лишь пульт.
///
/// v13: любое переключение сервера / выбор сервера приложением применяется
/// БЕЗ рестарта ядра (clash selector), рестарт только при смене состава
/// эндпоинтов/приложений или IP. Статус — DaemonState + push.
@objc public protocol AWGAppRouterDaemon {
    /// Полная синхронизация состояния и применение.
    /// serversJSON: [ServerSpec], appsJSON: [AppRule], mode: "running"|"off".
    func sync(_ serversJSON: String, appsJSON: String, mode: String,
              reply: @escaping (Bool, String) -> Void)
    /// Подключить/отключить один сервер (id) — применяется на лету.
    func setServer(_ id: String, enabled: Bool, reply: @escaping (Bool, String) -> Void)
    /// Рубильник «подключать нужные серверы при старте системы» (Настройки).
    /// Флаг хранится демоном на диске; применяется на его boot, не сейчас.
    func setAutoConnect(_ on: Bool, reply: @escaping (Bool, String) -> Void)
    /// Полное выключение ядра. Требует osascript-admin токен.
    func powerOff(_ reply: @escaping (Bool, String) -> Void)
    /// Текущий снимок DaemonState (JSON). Пуш — через AWGAppRouterObserver.
    func status(_ reply: @escaping (String) -> Void)
    /// Версия контракта — GUI понимает, умеет ли демон пушить.
    func version(_ reply: @escaping (String) -> Void)
}
