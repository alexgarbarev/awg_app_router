import AppKit

/// «Диагностика» — лог-вьювер демона + аварийные средства оживления.
/// Появился после случая «залип демон, кнопки не меняют ничего» (28.11:
/// Foundation-утечка Pipe fds → EMFILE → демон не мог писать конфиг).
/// Окно работает НЕЗАВИСИМО от демона: читает файлы логов subprocess'ом,
/// не через XPC — независимого от зависшего сервиса источника и не бывает:
///   • «Убить демон» — SIGKILL через admin-промпт, launchd KeepAlive поднимет
///     новый экземпляр за пару секунд (зависший так чинится);
///   • «⟳ Обновить демон» — переустановка из бандла (installDaemon force);
///   • хвост /var/log/awgapprouter-daemon.log (plist-редирект stderr launchd)
///     + gui-watchdog.log — видно, что происходило до и во время залипания.
/// Все subprocess — в фоне; главный поток только текст кладёт.
/// Pipe закрывать ЯВНО (macOS-26 Foundation их не освобождает — EMFILE).
final class DiagnosticsWindow: NSObject, NSWindowDelegate {
    static let shared = DiagnosticsWindow()

    private var window: NSWindow!
    private let stateLabel = NSTextField(labelWithString: "демон: проверяю…")
    private let textView = NSTextView()
    private let spanPopup = NSPopUpButton()
    private let liveCheck = NSButton(checkboxWithTitle: "живой поток", target: nil, action: nil)
    private var tails: [(proc: Process, pipe: Pipe)] = []
    private var statusTimer: Timer?
    private let q = DispatchQueue(label: "awgapprouter.diag", qos: .utility)
    private static let spans: [TimeInterval] = [300, 1800, 7200, 86_400]
    private static let spanNames = ["5 мин", "30 мин", "2 часа", "24 часа"]
    private static let daemonLog = "/var/log/awgapprouter-daemon.log"
    private static var guiLog: String {
        (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/AWGAppRouter/gui-watchdog.log")
    }
    private let maxChars = 400_000

    /// окно живёт в singleton: повторный показ не пересобирает и не рвёт поток
    func show() {
        if window == nil { build() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshState()
        reload()
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshState()
        }
    }

    func windowWillClose(_ notification: Notification) {
        statusTimer?.invalidate(); statusTimer = nil
        stopTails()
    }

    // MARK: - layout

    private func build() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 480),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        window.title = "Диагностика AWG App Router"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        let content = NSView()

        stateLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        spanPopup.addItems(withTitles: Self.spanNames)
        spanPopup.target = self
        spanPopup.action = #selector(reload)
        spanPopup.translatesAutoresizingMaskIntoConstraints = false

        liveCheck.target = self
        liveCheck.action = #selector(liveToggled)
        liveCheck.translatesAutoresizingMaskIntoConstraints = false

        let reloadBtn = NSButton(title: "Обновить", target: self, action: #selector(reload))
        reloadBtn.bezelStyle = .rounded
        let killBtn = NSButton(title: "⚠ Убить демон", target: self, action: #selector(forceKillDaemon))
        killBtn.bezelStyle = .rounded
        let updateBtn = NSButton(title: "⟳ Обновить демон", target: self, action: #selector(updateDaemon))
        updateBtn.bezelStyle = .rounded

        let row = NSStackView(views: [spanPopup, liveCheck, reloadBtn, NSView(), killBtn, updateBtn])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        // динамические системные цвета — сами темнеют/светлеют с темой
        textView.textColor = .textColor
        textView.insertionPointColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 6, height: 8)
        scroll.documentView = textView

        content.addSubview(stateLabel)
        content.addSubview(scroll)
        content.addSubview(row)
        NSLayoutConstraint.activate([
            stateLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stateLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stateLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: stateLabel.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: row.topAnchor, constant: -8),

            row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content
    }

    // MARK: - статус

    private func refreshState() {
        DaemonClient.shared.status { [weak self] s in
            guard let self else { return }
            guard let s else {
                self.stateLabel.stringValue = "демон: НЕ ОТВЕЧАЕТ — «⚠ Убить демон», launchd поднимет новый"
                return
            }
            self.stateLabel.stringValue = "демон онлайн · boot \(s.bootID) · gen \(s.generation) · "
                + "режим \(s.mode.rawValue) · box \(s.boxRunning ? "жив" : "нет") · "
                + "tun \(s.tunUp ? "up" : "down") · pf-запечатан: \(s.sealed ? "да" : "нет")"
                + (s.lastError.isEmpty ? "" : " · ошибка: \(s.lastError)")
        }
    }

    // MARK: - лог

    @objc private func reload() {
        let sel = max(0, spanPopup.indexOfSelectedItem)
        append("—— срез за \(Self.spanNames[sel]) ——\n")
        readTail(Self.daemonLog, span: Self.spans[sel], marker: "демон")
        readTail(Self.guiLog, span: Self.spans[sel], marker: "gui")
    }

    /// хвост файла за последние span секунд. Формат строк обоих логов:
    /// «yyyy-MM-dd HH:mm:ss...» в начале — по нему и режем. Читаем не более
    /// 512 КБ с конца: суточный файл может быть огромным.
    private func readTail(_ path: String, span: TimeInterval, marker: String) {
        q.async { [weak self] in
            guard let self else { return }
            guard let h = FileHandle(forReadingAtPath: path) else {
                DispatchQueue.main.async { self.append("(\(marker): лог не найден: \(path))\n") }
                return
            }
            defer { try? h.close() }
            let size = (try? h.seekToEnd()) ?? 0
            let back = min(size, 512 * 1024)
            h.seek(toFileOffset: size - back)
            let raw = (try? h.readToEnd()) ?? Data()
            let cut = Date().addingTimeInterval(-span)
            var kept = 0
            let out: String = Self.timestampFilter(String(data: raw, encoding: .utf8) ?? "",
                                                    cut: cut, count: &kept)
            DispatchQueue.main.async {
                self.append("— \(marker): \(kept) строк —\n")
                self.append(out.isEmpty ? "(пусто)\n" : out)
            }
        }
    }

    private static func timestampFilter(_ text: String, cut: Date, count: inout Int) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")
        var kept: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let head = String(line.prefix(19))
            if let t = fmt.date(from: head) {
                if t >= cut { kept.append(String(line)) }
            } else {
                // без таймстампа (многострочный хвост) — тащим за предыдущей
                if !kept.isEmpty { kept.append(String(line)) }
            }
        }
        count = kept.count
        return kept.joined(separator: "\n")
    }

    @objc private func liveToggled() {
        stopTails()
        guard liveCheck.state == .on else { append("—— поток остановлен ——\n"); return }
        append("—— живой поток (tail -F) ———\n")
        for path in [Self.daemonLog, Self.guiLog] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            p.arguments = ["-F", path]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            out.fileHandleForReading.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.append(s) }
            }
            do {
                try p.run()
                tails.append((p, out))
            } catch {
                append("tail не поднялся (\(path)): \(error.localizedDescription)\n")
            }
        }
    }

    private func stopTails() {
        for (p, pipe) in tails {
            p.terminationHandler = nil
            p.terminate()
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        tails.removeAll()
    }

    // MARK: - аварийные кнопки

    @objc private func forceKillDaemon() {
        let alert = NSAlert()
        alert.messageText = "Убить демон принудительно (SIGKILL)?"
        alert.informativeText = """
        Зависший awgapprouterd будет убит; launchd поднимет новый экземпляр \
        за пару секунд. Туннель упадёт и поднимется заново (если режим «рабочий»), \
        незащищённое окно — секунды. Требуется пароль администратора.
        """
        alert.addButton(withTitle: "Убить")
        alert.addButton(withTitle: "Отмена")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .alertFirstButtonReturn else { return }
            self?.append("→ убиваем awgapprouterd SIGKILL (ждём пароль)…) ")
            self?.q.async {
                let script = NSAppleScript(source:
                    "do shell script \"pkill -9 -x awgapprouterd; pkill -9 -x awgapprouter-box; true\" "
                    + "with administrator privileges")
                var err: NSDictionary?
                script?.executeAndReturnError(&err)
                DispatchQueue.main.async {
                    if err != nil { self?.append("отменено/ошибка\n") }
                    else { self?.append("ок — launchd перезапустит за ~2 с\n") }
                }
            }
        }
    }

    @objc private func updateDaemon() {
        append("→ переустанавливаю демон из бандла (ждём пароль)…) ")
        DaemonClient.shared.installDaemon(force: true) { [weak self] ok, msg in
            self?.append(ok ? "ок: \(msg)\n" : "не удалось: \(msg)\n")
        }
    }

    // MARK: - text

    private func append(_ s: String) {
        // foregroundColor ЯВНО = динамический системный цвет: приложенный
        // attributed string без цвета рисуется дефолтным (тёмным) и на тёмной
        // теме текст пропадал
        textView.textStorage?.append(NSAttributedString(string: s, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.textColor]))
        // срез «хвоста», чтобы окно не раздувалось от суточного потока
        let n = textView.string.count
        if n > maxChars {
            textView.textStorage?.deleteCharacters(in: NSRange(location: 0, length: n - maxChars))
        }
        textView.scrollToEndOfDocument(nil)
    }
}
