import AppKit
import ServiceManagement

/// «Настройки» — три рубильника автозапуска:
///   • демон при старте системы (LaunchDaemon /Library/LaunchDaemons — выключается
///     bootout+удалением plist, включается переустановкой из бандла; пароль админа);
///   • автоподключение нужных серверов при старте демона (флаг в /etc,XPC);
///   • UI-приложение при старте системы (SMAppService логин-айтем, без пароля).
/// Чекбоксы читают РЕАЛЬНОЕ состояние (диск / снимок демона / SMAppService),
/// а не память — после ручных правок в терминале окно не врёт. osascript/SM/XPC —
/// в фоне, главный поток только рисует; на время действия чекбокс глушится (busy),
/// при отмене/ошибке возвращается в прежнее состояние.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow!
    private let daemonCheck = NSButton(checkboxWithTitle: "Стартовать демон при старте системы",
                                       target: nil, action: nil)
    private let autoConnectCheck = NSButton(checkboxWithTitle:
                                        "Автоподключать нужные серверы при старте демона",
                                        target: nil, action: nil)
    private let guiCheck = NSButton(checkboxWithTitle: "Стартовать приложение AWG App Router при старте системы",
                                    target: nil, action: nil)
    private let daemonHint = NSTextField(wrappingLabelWithString: "")
    private let autoConnectHint = NSTextField(wrappingLabelWithString: "")
    private let guiHint = NSTextField(wrappingLabelWithString: "")
    private var busy = false

    private static let daemonPlist = "/Library/LaunchDaemons/com.awgapprouter.daemon.plist"
    private let q = DispatchQueue(label: "awgapprouter.settings", qos: .userInitiated)

    func show() {
        if window == nil { build() }
        refresh()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - layout

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 330),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        window.title = "Настройки AWG App Router"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView()

        daemonCheck.target = self
        daemonCheck.action = #selector(daemonToggled)
        daemonCheck.font = .systemFont(ofSize: 13)

        autoConnectCheck.target = self
        autoConnectCheck.action = #selector(autoConnectToggled)
        autoConnectCheck.font = .systemFont(ofSize: 13)

        guiCheck.target = self
        guiCheck.action = #selector(guiToggled)
        guiCheck.font = .systemFont(ofSize: 13)

        for h in [daemonHint, autoConnectHint, guiHint] {
            h.font = .systemFont(ofSize: 11)
            h.textColor = .secondaryLabelColor   // динамический — сам светлеет с темой
        }

        let stack = NSStackView(views: [daemonCheck, daemonHint,
                                         autoConnectCheck, autoConnectHint,
                                         guiCheck, guiHint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        window.contentView = content
    }

    /// состояние с диска/сервисов — окно всегда говорит правду
    private func refresh() {
        let daemonOn = FileManager.default.fileExists(atPath: Self.daemonPlist)
        daemonCheck.state = daemonOn ? .on : .off
        daemonHint.stringValue = daemonOn
            ? "LaunchDaemon com.awgapprouter.daemon (KeepAlive) — защита поднимается сама после перезагрузки. Рекомендуем."
            : "Демон не автозапускается: после перезагрузки защиты не будет, пока не включишь снова."

        // автоподключение: истина — в снимке демона (флаг /etc root-only);
        // демон offline — локальное зеркало из store
        DaemonClient.shared.status { [weak self] st in
            guard let self, !self.busy else { return }
            let on = st?.autostartConnect ?? Store.shared.autostartConnect
            self.autoConnectCheck.state = on ? .on : .off
            self.autoConnectHint.stringValue = on
                ? "После перезагрузки демон сам включит серверы, к которым привязаны приложения, — как «Подключиться». Тюрьма при «Выключить» не ломается."
                : "После перезагрузки будет тюрьма (серверы выключены) — подключение вручную."
        }

        let guiOn: Bool
        if #available(macOS 13.0, *) {
            guiOn = SMAppService.mainApp.status == .enabled
        } else {
            guiOn = false
        }
        guiCheck.state = guiOn ? .on : .off
        guiHint.stringValue = "Иконка в трее после логина. Не нужно, если запускаешь приложение для управления демоном сам."
    }

    private func setBusy(_ b: Bool) {
        busy = b
        daemonCheck.isEnabled = !b
        autoConnectCheck.isEnabled = !b
        guiCheck.isEnabled = !b
    }

    // MARK: - демон

    @objc private func daemonToggled() {
        guard !busy else { return }
        let wantOn = daemonCheck.state == .on
        if wantOn {
            setBusy(true)
            daemonHint.stringValue = "Устанавливаем LaunchDaemon (понадобится пароль администратора)…"
            DaemonClient.shared.installDaemon(force: true) { [weak self] ok, msg in
                self?.setBusy(false)
                self?.refresh()
                if !ok { self?.daemonHint.stringValue = "Не удалось: \(msg)" }
            }
            return
        }
        // выключение — с подтверждением: демон умрёт сразу, туннель упадёт
        let alert = NSAlert()
        alert.messageText = "Выключить автозапуск демона?"
        alert.informativeText = """
        Демон будет остановлен прямо сейчас (launchctl bootout) и удалён \
        автозапуск: после перезагрузки защиты не будет вовсе. Туннель упадёт \
        сразу; запечатанные pf-правила останутся до перезагрузки — приложения, \
        которые шли через туннель, останутся без сети (утечки не будет). \
        Требуется пароль администратора.
        """
        alert.addButton(withTitle: "Выключить")
        alert.addButton(withTitle: "Отмена")
        alert.alertStyle = .warning
        setBusy(true)
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard let self else { return }
            guard resp == .alertFirstButtonReturn else {
                self.setBusy(false); self.refresh(); return
            }
            self.q.async {
                let script = NSAppleScript(source:
                    "do shell script \"launchctl bootout system/com.awgapprouter.daemon 2>/dev/null; "
                    + "pkill -TERM -x awgapprouter-box; rm -f /Library/LaunchDaemons/com.awgapprouter.daemon.plist; true\" "
                    + "with administrator privileges")
                var err: NSDictionary?
                script?.executeAndReturnError(&err)
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.refresh()
                    if err != nil { self.daemonHint.stringValue = "Отменено (нужен пароль) — автозапуск оставлен" }
                }
            }
        }
    }

    // MARK: - автоподключение

    /// Применяется не сейчас, а на следующем старте демона (boot) — поэтому
    /// безConfirm: переключение ничего живого не рвёт.
    @objc private func autoConnectToggled() {
        guard !busy else { return }
        let wantOn = autoConnectCheck.state == .on
        autoConnectHint.stringValue = "Сохраняем…"
        DaemonClient.shared.setAutoConnect(wantOn) { [weak self] ok, msg in
            guard let self else { return }
            if ok {
                Store.shared.setAutostartConnect(wantOn)   // зеркало на случай offline
                self.refresh()
            } else {
                // демон не установлен/не отвечает: помним намерение локально —
                // установщик засеет флаг из store при первом install
                Store.shared.setAutostartConnect(wantOn)
                self.autoConnectCheck.state = wantOn ? .on : .off
                self.autoConnectHint.stringValue =
                    "Демон пока не принял (\(msg)). Намерение сохранено — "
                    + "применится при установке/перезагрузке."
            }
        }
    }

    // MARK: - UI

    @objc private func guiToggled() {
        guard !busy else { return }
        let wantOn = guiCheck.state == .on
        setBusy(true)
        q.async {
            // SMAppService трогает launchd — пусть не висит на главном потоке
            var failure: String?
            if #available(macOS 13.0, *) {
                do {
                    if wantOn { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    failure = error.localizedDescription
                }
            } else {
                failure = "SMAppService требует macOS 13+"
            }
            DispatchQueue.main.async {
                self.setBusy(false)
                if let f = failure {
                    self.refresh()   // откатить галку по реальному состоянию
                    self.guiHint.stringValue = "Не удалось: \(f)"
                } else {
                    self.refresh()
                }
            }
        }
    }
}
