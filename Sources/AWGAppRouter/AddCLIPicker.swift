import AppKit

/// Кастомное окно «＋ CLI утилита»: поле поиска + выпадающий список
/// исполняемых файлов из пользовательского $PATH ( autocomplete ).
/// Строка результата: имя — жирным, полный путь — серым. Выбор сворачивает
/// dropdown, путь ложится под поле, ОК становится активной.
final class AddCLIPicker: NSObject, NSWindowDelegate, NSSearchFieldDelegate,
                         NSTableViewDataSource, NSTableViewDelegate {
    struct Entry: Equatable { let name: String; let path: String }

    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let pathLabel = NSTextField(labelWithString: "начни вводить — например curl")
    private let okButton = NSButton(title: "ОК", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Отмена", target: nil, action: nil)

    private var entries: [String: String] = [:]   // name → path (первый в PATH побеждает)
    private var filtered: [Entry] = []
    private var fullList: [Entry] = []      // отсортированный список при пустом запросе
    private var chosen: Entry?
    private var debounce: DispatchWorkItem?
    private var filterEpoch = 0
    /// «shell-PATH ещё сканируется» — крутилка в ряду кнопок: кто быстро
    /// пользователь должен видеть, что список ещё не догрузился
    private let spinner = NSProgressIndicator()
    private(set) var window: NSWindow!
    // фильтр — своя priority-очередь (не ждёт долгие сканы при печати);
    // сканы — последовательные, чтобы fallback не затёр merges от shell-PATH
    private let workQueue = DispatchQueue(label: "awgapprouter.cli-filter", qos: .userInitiated,
                                          attributes: .concurrent)
    private let scanQueue = DispatchQueue(label: "awgapprouter.cli-scan", qos: .userInitiated)

    private static let listMax: CGFloat = 220

    // MARK: - present

    /// Модально. nil — отмена.
    static func present() -> (name: String, path: String)? {
        let picker = AddCLIPicker()
        picker.build()
        NSApp.activate(ignoringOtherApps: true)
        let resp = NSApp.runModal(for: picker.window)
        if resp == .OK, let c = picker.chosen { return (c.name, c.path) }
        return nil
    }

    // MARK: - layout

    private func build() {
        // высота сразу полная (поле + список + путь + кнопки): показ/скрытие
        // dropdown через setFrame(animate:) делало перекладку окна на каждый
        // keystroke — 73% CPU в окне по профилю Instruments 28.11
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 372),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Добавить CLI утилиту"
        window.delegate = self
        window.isReleasedWhenClosed = false

        searchField.delegate = self
        searchField.placeholderString = "имя команды…"
        searchField.sendsWholeSearchString = false
        searchField.translatesAutoresizingMaskIntoConstraints = false

        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false

        table.headerView = nil
        table.rowHeight = 34
        table.backgroundColor = .textBackgroundColor
        table.dataSource = self
        table.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("cmd"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        scroll.documentView = table

        pathLabel.font = .systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false

        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.isEnabled = false
        okButton.target = self
        okButton.action = #selector(okPressed)
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.toolTip = "PATH из шелла ещё сканируется — список пополнится через пару секунд"
        spinner.translatesAutoresizingMaskIntoConstraints = false
        let buttons = NSStackView(views: [NSView(), cancelButton, okButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(searchField)
        content.addSubview(scroll)
        content.addSubview(pathLabel)
        content.addSubview(spinner)
        content.addSubview(buttons)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: Self.listMax),

            pathLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            pathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            pathLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            buttons.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),

            spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            spinner.centerYAnchor.constraint(equalTo: buttons.centerYAnchor),
        ])
        window.contentView = content
        window.center()
        window.initialFirstResponder = searchField
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)

        scan([.fallback])          // мгновенный стартовый список
        refreshFromShellPATH()     // пользовательский PATH — асинхронно
    }

    // MARK: - список

    /// окно фиксированной высоты — список никогда не анимируется, только
    /// меняется его содержимое; reload лишь когда результат реально изменился.
    /// Выбранная строка сохраняется, пока её путь есть в новом списке;
    /// иначе выделение уходит вместе с ОК
    private func apply(_ result: [Entry]) {
        guard result != filtered else { return }
        filtered = result
        table.reloadData()
        if let c = chosen, let idx = filtered.firstIndex(where: { $0.path == c.path }) {
            table.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    private func filter(_ raw: String) {
        let q = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else {
            apply(Array(fullList.prefix(60))); return
        }
        // heavy pass по entries и сортировка — в фоне; на главный потоке
        // только присвоение. epoch отбрасывает запоздалые ответы старого
        // поиска (быстро набрал «curl», а вернулся ответ для «c»)
        let snapshot = entries
        filterEpoch += 1
        let myEpoch = filterEpoch
        workQueue.async { [weak self] in
            var prefix: [Entry] = [], contains: [Entry] = []
            for (name, path) in snapshot {
                if name.hasPrefix(q) { prefix.append(Entry(name: name, path: path)) }
                else if name.contains(q) { contains.append(Entry(name: name, path: path)) }
            }
            prefix.sort { $0.name < $1.name }
            contains.sort { $0.name < $1.name }
            let result = Array((prefix + contains).prefix(60))
            DispatchQueue.main.async {
                guard let self, self.filterEpoch == myEpoch else { return }
                self.apply(result)
            }
        }
    }

    // MARK: - сканирование PATH

    private enum Src { case fallback }

    private static let fallbackDirs: [String] = {
        let home = NSHomeDirectory()
        return ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
                home + "/.local/bin", home + "/.opencode/bin", home + "/.tools/bin"]
    }()

    /// PATH пользовательского шелла: GUI из Finder/Flyout его не получает
    /// (launchd отдаёт урезанный), поэтому спрашиваем zsh. Ключ -i обязателен:
    /// -lc — неинтерактивный логин, а ~/.zshrc (nvm, rbenv, rvm, .tools)
    /// zsh читает только интерактивно — без -i node-пакеты «пропадают».
    /// Таймаут 6 с: интерактивный rc с nvm может грузиться секунды; окно при
    /// этом живо (spawn в фоне, список показывается сразу из fallback).
    private static func shellPATH() -> [String] {
        var dirs: [String] = []
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-ilc", "printf %s \"$PATH\""]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { sem.signal(); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 6) {
                if p.isRunning { p.terminate() }
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            try? out.fileHandleForReading.close()
            try? out.fileHandleForWriting.close()
            dirs = String(data: data, encoding: .utf8)?
                .split(separator: ":").map(String.init) ?? []
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 7)
        return dirs
    }

    private func scan(_ srcs: [Src], extra: [String] = [], thenDone: Bool = false) {
        var dirs = Self.fallbackDirs
        dirs = extra.filter { !dirs.contains($0) } + dirs   // приоритет PATH
        // stat каждого файла — тысячи вызовов, вне главного потока;
        // на главном только присвоение готового словаря + дозагрузка фильтра
        scanQueue.async { [weak self] in
            guard let self else { return }
            var collected: [String: String] = [:]
            let fm = FileManager.default
            for dir in dirs {
                guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for it in items where !it.hasPrefix(".") {
                    guard collected[it] == nil else { continue }   // первый в PATH побеждает
                    let full = dir + "/" + it
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: full, isDirectory: &isDir), !isDir.boolValue,
                          fm.isExecutableFile(atPath: full) else { continue }
                    collected[it] = full
                }
            }
            DispatchQueue.main.async {
                self.entries = collected
                self.fullList = collected.map { Entry(name: $0.key, path: $0.value) }
                    .sorted { $0.name < $1.name }
                if thenDone { self.spinner.stopAnimation(nil) }
                if self.searchField.stringValue.isEmpty {
                    self.apply(Array(self.fullList.prefix(60)))
                } else {
                    self.filter(self.searchField.stringValue)
                }
            }
        }
    }

    private func refreshFromShellPATH() {
        spinner.startAnimation(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dirs = Self.shellPATH()
            guard let self else { return }
            DispatchQueue.main.async {
                // пустой PATH (шелл не поднялся/таймаут) — крутим дольше нельзя,
                // иначе «вечная загрузка» врёт: fallback-список уже на экране
                if dirs.isEmpty { self.spinner.stopAnimation(nil); return }
                self.scan([.fallback], extra: dirs, thenDone: true)
            }
        }
    }

    // MARK: - выбор

    /// выбор живёт в выделении таблицы (одинарный клик/стрелки),
    /// строка поиска — нетронутый ввод пользователя
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        if filtered.indices.contains(row) {
            chosen = filtered[row]
            pathLabel.stringValue = filtered[row].path
            okButton.isEnabled = true
        } else {
            chosen = nil
            pathLabel.stringValue = "начни вводить — например curl"
            okButton.isEnabled = false
        }
    }

    private func moveSelection(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let cur = table.selectedRow < 0 ? (delta > 0 ? -1 : 0) : table.selectedRow
        let next = min(max(cur + delta, 0), filtered.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func enterPressed() -> Bool {
        // Enter = ОК: выбор — это уже выделенная строка (chosen ставится
        // через tableViewSelectionDidChange); без выделения — ничего,
        // чтобы Enter не «выбрал» первое совпадение помимо воли
        guard chosen != nil else { NSSound.beep(); return true }
        finish(.OK)
        return true
    }

    @objc private func okPressed() {
        guard chosen != nil else { NSSound.beep(); return }
        finish(.OK)
    }

    @objc private func cancelPressed() { finish(.cancel) }

    private func finish(_ resp: NSApplication.ModalResponse) {
        window.orderOut(nil)
        // ВАЖНО: stopModal() без кода — runModal вернёт .stopModal, а не .OK:
        // тогда present() считает любой выбор отменой и «ничего не происходит»
        NSApp.stopModal(withCode: resp)
        if resp == .cancel { chosen = nil }
    }

    // MARK: - делегаты

    func controlTextDidChange(_ obj: Notification) {
        // выбор НЕ сбрасываем здесь: apply() сам решит — если путь выбранной
        // строки остался в новом списке, выделение и ОК живут, иначе уходят
        debounce?.cancel()
        let text = searchField.stringValue
        let work = DispatchWorkItem { [weak self] in self?.filter(text) }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)): moveSelection(1); return true
        case #selector(NSResponder.moveUp(_:)):   moveSelection(-1); return true
        case #selector(NSResponder.insertNewline(_:)): return enterPressed()
        case #selector(NSResponder.cancelOperation(_:)): finish(.cancel); return true
        default: return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 34 }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = filtered[row]
        let id = NSUserInterfaceItemIdentifier("cmdRow")
        if let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            // переиспользованная: только текст поменяли
            (cell.viewWithTag(1) as? NSTextField)?.stringValue = e.name
            (cell.viewWithTag(2) as? NSTextField)?.stringValue = e.path
            return cell
        }
        // первая сборка строки — один раз, дальше пул сам крутит их
        let cell = NSTableCellView()
        cell.identifier = id
        let name = NSTextField(labelWithString: e.name)
        name.tag = 1
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        let path = NSTextField(labelWithString: e.path)
        path.tag = 2
        path.font = .systemFont(ofSize: 10, weight: .regular)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        name.translatesAutoresizingMaskIntoConstraints = false
        path.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(name)
        cell.addSubview(path)
        cell.textField = name
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            name.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            path.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            path.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            path.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 1),
        ])
        return cell
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { finish(.cancel); return true }
}
