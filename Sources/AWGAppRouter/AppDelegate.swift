import AppKit
import AWGAppRouterKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private let mainVC = MainViewController()
    /// template-иконки трея (ручная рисовка в GIMP → tray-import.swift → PNG 18/@2x):
    /// open — туннель открыт, closed — портал закрыт, off — только прямая дорога
    private var trayImgs: [String: NSImage] = [:]

    private func trayImage(_ name: String) -> NSImage {
        if let c = trayImgs[name] { return c }
        let img: NSImage
        // PNG-пара 18/36 из Resources/tray (рисуются в GIMP, кладёт tray-import.swift)
        if let u1 = Bundle.main.url(forResource: name, withExtension: "png"),
           let d1 = try? Data(contentsOf: u1), let r1 = NSBitmapImageRep(data: d1) {
            img = NSImage()
            r1.size = NSSize(width: 18, height: 18)
            img.addRepresentation(r1)
            if let u2 = Bundle.main.url(forResource: name + "@2x", withExtension: "png"),
               let d2 = try? Data(contentsOf: u2), let r2 = NSBitmapImageRep(data: d2) {
                r2.size = NSSize(width: 18, height: 18)   // 36px на retina-пиксели
                img.addRepresentation(r2)
            }
        } else {
            img = NSImage(systemSymbolName: "network", accessibilityDescription: "AWG App Router")
                ?? NSImage(named: NSImage.networkName)!
        }
        img.isTemplate = true   // меню-бар перекрасит сам под светлую/тёмную тему
        img.size = NSSize(width: 18, height: 18)
        trayImgs[name] = img
        return img
    }

    private var miStatus: NSMenuItem!
    private var miConnect: NSMenuItem!

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)   // отдельное окно + иконка в доке
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainVC.onStatusUpdate = { [weak self] text, connected in
            self?.miStatus?.title = text
            self?.miConnect?.title = connected ? "Отключиться" : "Подключиться"
            self?.refreshIndicator(connected: connected)
        }

        window = NSWindow(contentViewController: mainVC)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = "AWG App Router"
        window.setContentSize(NSSize(width: 640, height: 520))
        window.minSize = NSSize(width: 560, height: 440)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self

        buildStatusItem()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// закрыть окно ≠ выйти: защищённость живёт в демоне;
    /// иконка из Dock тоже уходит (accessory) — остаться в трей, не мозолить
    /// глаза; «Показать» из трея вернёт и окно, и иконку (.regular)
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed() -> Bool { false }

    // MARK: - трей

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = trayImage("tray-off")   // до первого статуса — «выкл»
        }

        let menu = NSMenu()
        menu.delegate = self
        miStatus = NSMenuItem(title: "…", action: nil, keyEquivalent: "")
        miStatus.isEnabled = false
        menu.addItem(miStatus)
        menu.addItem(.separator())
        let show = NSMenuItem(title: "Показать", action: #selector(showWindow), keyEquivalent: "s")
        show.target = self
        menu.addItem(show)
        miConnect = NSMenuItem(title: "Подключиться", action: #selector(connectToggled), keyEquivalent: "")
        miConnect.target = self
        menu.addItem(miConnect)
        let settings = NSMenuItem(title: "Настройки…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let diag = NSMenuItem(title: "Диагностика…", action: #selector(showDiagnostics), keyEquivalent: "")
        diag.target = self
        menu.addItem(diag)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// статус актуален на момент открытия меню
    func menuNeedsUpdate(_ menu: NSMenu) {
        mainVC.refreshStatus()
    }

    @objc private func showWindow() {
        // accessory-режим не пускает окно в Cmd-Tab и не даёт иконку в Dock —
        // вернуть .regular ДО показа, чтобы окноилось как обычное приложение
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func connectToggled() {
        if mainVC.trayConnected {
            mainVC.trayDisconnect()
        } else {
            mainVC.trayConnect()
        }
    }

    @objc private func quit() {
        // защищённость остаётся в демоне — выход из GUI её не снимает
        NSApp.terminate(nil)
    }

    @objc private func showDiagnostics() {
        DiagnosticsWindow.shared.show()
    }

    @objc private func showSettings() {
        SettingsWindow.shared.show()
    }

    /// Цветик на иконке: зелёный — есть live-туннель, оранжевый — тюрьма (защита без
    /// сервера), красный — ядро хочет работать, но tun мёртв/запечатано, серый — выкл.
    private func refreshIndicator(connected: Bool? = nil) {
        DaemonClient.shared.status { [weak self] s in
            guard let self else { return }
            let icon: String
            switch s?.mode ?? .off {
            case .running:
                let anyEnabled = s?.servers.contains { $0.enabled } ?? false
                let anyAlive = s?.servers.contains { $0.enabled && $0.alive == true } ?? false
                if (connected ?? (anyAlive && (s?.tunUp ?? false)))
                    && (s?.tunUp ?? false) && !(s?.sealed ?? false) {
                    icon = "tray-open"      // туннель открыт, трафик идёт
                } else if !anyEnabled {
                    icon = "tray-closed"    // защита стоит, серверов нет
                } else {
                    icon = "tray-closed"    // портал закрыт: мёртв/поднимается/запечатан
                }
            case .off:
                icon = "tray-off"           // ядро выключено — только прямая дорога
            }
            // template-иконка: НЕ ставим contentTintColor — тогда меню-бар сам
            // перекрасит её под тему (белая на тёмной, чёрная на светлой).
            // Состояние различается формой (open/closed/off), цвет не нужен.
            self.statusItem.button?.image = self.trayImage(icon)
            self.statusItem.button?.contentTintColor = nil
        }
    }
}
