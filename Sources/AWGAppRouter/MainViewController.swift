import AppKit
import UniformTypeIdentifiers
import AWGAppRouterKit

final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                              NSDraggingDestination, NSMenuItemValidation {
    private let segment = NSSegmentedControl(labels: ["Приложения", "Серверы"],
                                              trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "—")

    // таблица приложений
    private let appsTable = NSTableView()
    private let appsStack = NSStackView()
    // таблица серверов
    private let serversTable = NSTableView()
    private let serversStack = NSStackView()

    private let primaryButton = NSButton(title: "Запустить", target: nil, action: nil)
    private let powerButton = NSButton(title: "⏻ Выключить полностью…", target: nil, action: nil)
    private let updateButton = NSButton(title: "⟳ Обновить демон", target: nil, action: nil)
    /// сообщение «демон устарел/молчит» — отдельная строка ПОД кнопками:
    /// в титрах сверху оно переносилось на две строки и ломало layout
    private let updateNotice = NSTextField(labelWithString: "")
    private var noticeShown = false
    /// версии в углу: «app X · демон Y» — честная расшифровка «устарел/свеж»
    /// одним взглядом (сверка релизных версий, не байтов)
    private let versionLabel = NSTextField(labelWithString: "")
    /// кнопка ручного refresh — по одной в each баре (серверы/приложения)
    private let refreshButtons: [NSButton] = [NSButton(), NSButton()]
    private let refreshIndicators: [NSProgressIndicator] = [NSProgressIndicator(), NSProgressIndicator()]
    private var serversRefreshButton: NSButton { refreshButtons[0] }
    private var appsRefreshButton: NSButton { refreshButtons[1] }
    private var serversIndicator: NSProgressIndicator { refreshIndicators[0] }
    private var appsIndicator: NSProgressIndicator { refreshIndicators[1] }

    private var status: DaemonState?
    /// последний статус-вызов не получил ответа (демон зарегистрирован, но молчит)
    private var daemonOffline = false
    /// событийная модель обновления (v13): демон пушит DaemonState в onState —
    /// любой refresh (push/pull/appear/кнопка) проходит через applyStatus,
    /// все элементы рендерятся из одного снимка, рассинхрон элементов невозможен;
    /// - после команды — pull-страховка 1 Гц ДО ожидаемого состояния: пуш
    ///   доводит мгновенно, таймер только для старого демона без пуша.
    private var pollTimer: Timer?
    private var pollDeadline: Date?
    private var pendingCheck: ((DaemonState?) -> Bool)?
    private var pendingTimeout: TimeInterval = 10
    private var pendingServerIDs = Set<String>()   // где крутим спиннер в точке
    private var pending = false
    private var syncing = false      // наш sync в полёте — состояние на демоне «устарело»
    /// трей спрашивает нас о статусе/подключении ( AppDelegate buildStatusItem )
    var onStatusUpdate: ((String, Bool) -> Void)?

    private let store = Store.shared

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 480))

        segment.target = self
        segment.action = #selector(switchTab)
        segment.selectedSegment = 0
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNotice.font = .systemFont(ofSize: 11, weight: .semibold)
        updateNotice.textColor = .systemOrange
        updateNotice.isHidden = true
        for b in refreshButtons { configureRefresh(b) }
        for iv in refreshIndicators {
            iv.style = .spinning
            iv.controlSize = .small
            iv.isDisplayedWhenStopped = false
        }
        let topBar = NSStackView(views: [segment, NSView(), statusLabel])
        topBar.orientation = .horizontal
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        // ---- вкладка приложений ----
        let addButton = NSButton(title: "＋ Приложение", target: self, action: #selector(addApp))
        let addCLIButton = NSButton(title: "＋ CLI утилита…", target: self, action: #selector(addCLI))
        let removeButton = NSButton(title: "−", target: self, action: #selector(removeSelected))
        let appsBar = NSStackView(views: [addButton, addCLIButton, removeButton, NSView(),
                                            appsIndicator, appsRefreshButton])
        appsBar.orientation = .horizontal
        appsBar.spacing = 8

        for (id, title, width) in [("name", "Приложение", CGFloat(140)),
                                    ("server", "Сервер", CGFloat(110)),
                                    ("conns", "Соединения", CGFloat(92)),
                                    ("kids", "Хелперы", CGFloat(62)),
                                    ("path", "Путь", CGFloat(170))] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            appsTable.addTableColumn(col)
        }
        appsTable.dataSource = self
        appsTable.delegate = self
        appsTable.rowSizeStyle = .small
        appsTable.registerForDraggedTypes([.fileURL])
        appsTable.draggingDestinationFeedbackStyle = .regular
        // удаление — контекстным меню (кнопка «−» остаётся как быстрый путь)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Удалить",
                        action: #selector(removeAppMenuAction), keyEquivalent: "")
        appMenu.items.forEach { $0.target = self }
        appsTable.menu = appMenu
        let appsScroll = wrapping(appsTable)

        appsStack.orientation = .vertical
        appsStack.spacing = 8
        appsStack.translatesAutoresizingMaskIntoConstraints = false
        appsScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        appsScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        appsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        // кнопка/подсказка не должны «дышать» — иначе при нехватке высоты AppKit
        // сжимает бар в 0 и кнопки уезжают за край окна
        appsBar.setContentCompressionResistancePriority(.required, for: .vertical)
        appsBar.setContentHuggingPriority(.required, for: .vertical)
        appsStack.addArrangedSubview(appsBar)
        appsStack.addArrangedSubview(appsScroll)

        // ---- вкладка серверов ----
        let addServerButton = NSButton(title: "＋ Сервер (.conf)…", target: self,
                                        action: #selector(addServer))
        let delServerButton = NSButton(title: "−", target: self, action: #selector(removeServer))
        let srvBar = NSStackView(views: [addServerButton, delServerButton,
                                           NSView(), serversIndicator, serversRefreshButton])
        srvBar.orientation = .horizontal
        srvBar.spacing = 8

        for (id, title, width) in [("dot", "", CGFloat(24)),
                                    ("name", "Имя", CGFloat(150)),
                                    ("endpoint", "Эндпоинт", CGFloat(150)),
                                    ("conn", "Подключение", CGFloat(110))] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            serversTable.addTableColumn(col)
        }
        serversTable.dataSource = self
        serversTable.delegate = self
        // контекстное меню — надёжнее двойного клика
        let srvMenu = NSMenu()
        srvMenu.addItem(withTitle: "Переименовать", action: #selector(renameServerAction),
                        keyEquivalent: "")
        srvMenu.addItem(.separator())
        srvMenu.addItem(withTitle: "Подключить / отключить",
                        action: #selector(toggleSelectedServer), keyEquivalent: "")
        srvMenu.addItem(withTitle: "Удалить", action: #selector(removeServer),
                        keyEquivalent: "")
        srvMenu.items.forEach { $0.target = self }
        serversTable.menu = srvMenu
        // двойной клик по строке = начать переименование (не полагаемся на
        // «второй клик долетит до текстового поля» — таблицу трясёт опросом)
        serversTable.doubleAction = #selector(serverRowDoubleClicked(_:))
        serversTable.target = self
        serversTable.rowSizeStyle = .small
        let srvScroll = wrapping(serversTable)

        serversStack.orientation = .vertical
        serversStack.spacing = 8
        serversStack.isHidden = true
        serversStack.translatesAutoresizingMaskIntoConstraints = false
        srvScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        srvScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        srvScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        srvBar.setContentCompressionResistancePriority(.required, for: .vertical)
        srvBar.setContentHuggingPriority(.required, for: .vertical)
        serversStack.addArrangedSubview(srvBar)
        serversStack.addArrangedSubview(srvScroll)

        // ---- низ ----
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        primaryButton.bezelStyle = .rounded
        // keyEquivalent="\r" убран: он перехватывал Enter из редактора имени
        // сервера и подключал/отключал сервер при переименовании
        powerButton.target = self
        powerButton.action = #selector(powerOffAction)
        powerButton.contentTintColor = .secondaryLabelColor
        updateButton.target = self
        updateButton.action = #selector(updateDaemonAction)
        updateButton.contentTintColor = .controlAccentColor
        updateButton.isHidden = true

        let bottomBar = NSStackView(views: [updateButton, NSView(), powerButton, primaryButton])
        bottomBar.orientation = .horizontal
        bottomBar.spacing = 8
        bottomBar.translatesAutoresizingMaskIntoConstraints = false

        // уведомление об обновлении демона — ПОСЛЕ кнопок: оно появляется
        // редко, окно при этом растягивается (см. showUpdateNotice)
        versionLabel.font = .systemFont(ofSize: 10)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.alignment = .right
        versionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let bottomStack = NSStackView(views: [bottomBar, updateNotice, versionLabel])
        bottomStack.orientation = .vertical
        bottomStack.alignment = .width
        bottomStack.spacing = 4

        appsStack.distribution = .fill
        serversStack.distribution = .fill
        topBar.setContentCompressionResistancePriority(.required, for: .vertical)
        bottomBar.setContentCompressionResistancePriority(.required, for: .vertical)
        bottomBar.setContentHuggingPriority(.required, for: .vertical)
        bottomStack.setContentCompressionResistancePriority(.required, for: .vertical)

        // Обе вкладки поверх друг друга в одном контейнере — единственный
        // «резиновый» элемент общей вертикальной цепи
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(appsStack)
        container.addSubview(serversStack)
        NSLayoutConstraint.activate([
            appsStack.topAnchor.constraint(equalTo: container.topAnchor),
            appsStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            appsStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            appsStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            serversStack.topAnchor.constraint(equalTo: container.topAnchor),
            serversStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            serversStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            serversStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        // ОДИН внешний стек вместо ручной цепочки пинов — нижний бар всегда видим.
        let outer = NSStackView(views: [topBar, container, bottomStack])
        outer.orientation = .vertical
        outer.alignment = .width
        outer.distribution = .fill
        outer.spacing = 8
        outer.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        outer.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(.defaultLow, for: .vertical)
        container.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        root.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: root.topAnchor),
            outer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    private func wrapping(_ table: NSTableView) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = table
        s.hasVerticalScroller = true
        s.borderType = .bezelBorder
        // таблица — единственный «резиновый» элемент: при нехватке высоты
        // сжимается она, а не нижняя панель с кнопками (иначе панель уезжала
        // за край окна и кнопки «исчезали»)
        s.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        s.setContentHuggingPriority(.defaultLow, for: .vertical)
        return s
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // подписка на пуш демона (идемпотентна): все изменения состояния
        // прилетают в applyStatus сами; + один pull при появлении окна —
        // страховка для демона без пуша и на случай разрыва XPC
        DaemonClient.shared.onState = { [weak self] s in self?.applyStatus(s) }
        // заголовок кнопки — по факту диска ДО первого статуса: на чистой
        // машине статуса нет и applyStatus(nil) молча выходит, а кнопка
        // оставалась дефолтной «Запустить» вместо «Установить демон…»
        updateControls()
        refreshStatus()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopPoll()
    }

    // MARK: - событийный refresh (см. свойства выше)

    private func configureRefresh(_ b: NSButton) {
        b.title = ""
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        b.image = NSImage(systemSymbolName: "arrow.clockwise",
                          accessibilityDescription: "Обновить статус")?
            .withSymbolConfiguration(cfg)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Обновить статус"
        b.target = self
        b.action = #selector(manualRefresh)
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 38).isActive = true
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 26).isActive = true
    }

    private func controls() -> [NSControl] {
        [primaryButton, powerButton, updateButton] + refreshButtons
    }

    /// ручной refresh: крутилка на время запроса, один снимок статуса
    @objc private func manualRefresh() {
        refreshIndicators.forEach { $0.startAnimation(nil) }
        refreshButtons.forEach { $0.isEnabled = false }
        DaemonClient.shared.status { [weak self] s in
            guard let self else { return }
            self.applyStatus(s)
            self.reloadAppsIfNeeded(force: true)    // ручной ⟳ — рисуй заново всё
            self.reloadServersIfNeeded(force: true)
            guard self.pollTimer == nil else { return }   // параллельно идёт ожидание
            self.refreshIndicators.forEach { $0.stopAnimation(nil) }
            self.refreshButtons.forEach { $0.isEnabled = true }
        }
    }

    /// после команды — опрос 1 Гц ДО ПОЯВЛЕНИЯ ожидаемого состояния (🟢 или
    /// «защита»), максимум `timeout` сек. Ждём именно зелёного, а не «любого
    /// изменения»: промежуточный снимок показывает красный, которого быть не должно.
    private func startPoll(serverIDs: Set<String>, timeout: TimeInterval,
                           check: @escaping (DaemonState?) -> Bool) {
        pending = true
        pendingServerIDs = serverIDs
        pendingCheck = check
        pendingTimeout = timeout
        pollDeadline = Date().addingTimeInterval(timeout)
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.pollTick()
        }
        refreshIndicators.forEach { $0.startAnimation(nil) }
        controls().forEach { $0.isEnabled = false }
        reloadServersIfNeeded(force: true)   // точки → спиннеры
        updateControls()                       // статус: «поднимаю…», не красный
    }

    private func pollTick() {
        guard pollTimer != nil else { return }
        DaemonClient.shared.status { [weak self] s in
            guard let self, self.pollTimer != nil else { return }
            self.applyStatus(s)   // expectation проверится внутри applyStatus
            if let d = self.pollDeadline, Date() >= d {
                self.stopPoll()
                // демон молчит ≠ эндпоинт битый: не врать пользователю
                self.flashStatus(self.status == nil
                    ? "демон не отвечает за \(Int(self.pendingTimeout)) с — «⟳ Обновить демон»"
                    : "не поднялось за \(Int(self.pendingTimeout)) с — проверь эндпоинт/ключ")
            }
        }
    }

    /// ожидание команды проверяется на КАЖДОМ снимке — и из пуша, и из pull:
    /// демон сообщил целевое состояние — стоп immediately, не дожидаясь тика
    private func evaluatePending() {
        guard pollTimer != nil, pendingCheck?(status) == true else { return }
        stopPoll()
    }

    private func stopPoll() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollDeadline = nil
        pendingCheck = nil
        pendingServerIDs = []
        pending = false
        refreshIndicators.forEach { $0.stopAnimation(nil) }
        refreshButtons.forEach { $0.isEnabled = true }
        reloadServersIfNeeded(force: true)   // спиннеры → реальные точки
        updateControls()
    }

    // ожидаемые состояния

    /// 🟢: туннель поднят и ВСЕ включённые серверы live (urltest выбрал working)
    private func connectedExpectation(_ s: DaemonState?) -> Bool {
        guard let s, s.mode == .running, s.tunUp else { return false }
        let on = store.servers.filter(\.enabled).map(\.id)
        guard !on.isEmpty else { return true }
        return on.allSatisfy { id in s.server(id)?.phase == .up }
    }

    /// «защита»: ни один сервер не live (туннель-тюрьма допустим)
    private func stoppedExpectation(_ s: DaemonState?) -> Bool {
        guard let s else { return false }
        let on = store.servers.filter(\.enabled).map(\.id)
        if !on.isEmpty { return false }
        return !s.servers.contains { $0.alive == true }
    }

    @objc private func switchTab() {
        let apps = segment.selectedSegment == 0
        appsStack.isHidden = !apps
        serversStack.isHidden = apps
        (apps ? appsTable : serversTable).reloadData()
    }

    // MARK: - статус

    func refreshStatus() {
        DaemonClient.shared.status { [weak self] s in
            self?.applyStatus(s)
        }
    }

    ///temporary сообщение в статусной строке (например, про сбой)
    private func flashStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.textColor = .systemRed
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.statusLabel.textColor = .secondaryLabelColor
        }
    }

    private func applyStatus(_ s: DaemonState?) {
        guard let s else {
            // offline: XPC-дедлайн сработал — показать это и разблокировать
            // управление (демон в launchd есть, а не отвечает = завис)
            if DaemonClient.shared.daemonInstalled(), !daemonOffline {
                daemonOffline = true
                statusLabel.stringValue = "демон не отвечает"
                statusLabel.textColor = .systemOrange
                updateControls()
                onStatusUpdate?(statusLabel.stringValue, trayConnected)
            }
            return
        }
        if daemonOffline {
            daemonOffline = false
            statusLabel.textColor = .secondaryLabelColor
        }
        // защита от переупорядочивания: старый generation игнорируем, НО только
        // в пределах одного экземпляра демона — после рестарта счётчик с нуля,
        // bootID другой, снимок признаём (иначе GUI залип на вечном «…»)
        if let cur = status, s.bootID == cur.bootID,
           s.generation != 0, s.generation < cur.generation { return }
        status = s
        evaluatePending()
        // не трогать таблицы/выделение во время переименования — ярлыки можно
        let editing = view.window?.firstResponder is NSText
        // зеркало с демона: он хозяин servers.json (после ⟳-установки там
        // может быть enabled=false) — признаём его состояние, не споря
        if !syncing {
            var mirrored = false
            for ds in s.servers where ds.enabled != (store.servers.first { $0.id == ds.id }?.enabled ?? false) {
                if store.servers.contains(where: { $0.id == ds.id }) {
                    store.setServerEnabled(ds.id, ds.enabled)
                    mirrored = true
                }
            }
            if mirrored { serversSig = "" }   // зеркало → точки серверов тоже перерисуем
        }
        if !editing { reloadServersIfNeeded() }
        if !editing { reloadAppsIfNeeded() }   // бейджи «Трафик» без этого залипали
        updateControls()
        // трей показывает ровно то же, что в правом верхнем угла окна —
        // один источник текста на оба UI, никаких расхождений
        onStatusUpdate?(statusLabel.stringValue, trayConnected)
    }

    /// перезагрузка таблицы приложений только при РЕАЛЬНОМ изменении видимого
    /// (селектор приложения, прямые/туннельные сокеты, набор включённых серверов):
    /// ячейки NSTableView живут до reloadData — без этого «7 direct» висело
    /// часами, хотя демон уже видел tun
    private var appsSig = ""
    private func reloadAppsIfNeeded(force: Bool = false) {
        if view.window?.firstResponder is NSText { return }   // не мешать вводу
        let sig = store.apps.enumerated().map { (i, a) in
            let r = status?.appRoutes.first { $0.selector == ConfigBuilder.selectorTag(appIndex: i) }
            return "\(a.name)|\(a.serverID)|\(a.includeChildren)|"
                + store.servers.filter(\.enabled).map(\.id).joined(separator: ",")
                + "|\(r?.actual ?? "")·\(r?.carrying == true ? 1 : 0)"
                + "·\(r?.directConns ?? -1)/\(r?.tunConns ?? -1)"
        }.joined(separator: ";")
        if force || sig != appsSig {
            appsSig = sig
            appsTable.reloadData()
        }
    }

    /// перезагрузка таблицы серверов только при РЕАЛЬНОМ изменении — reloadData
    /// на каждом опросе сбрасывал выделение строки и закрывал редактор имени
    private var serversSig = ""
    private func reloadServersIfNeeded(force: Bool = false) {
        if view.window?.firstResponder is NSText { return }   // редактируют имя
        let sig = store.servers.map { s in
            let phase = status?.server(s.id)?.phase.rawValue ?? "?"
            return "\(s.id)|\(s.name)|\(s.enabled)|\(phase)|"
                + (pendingServerIDs.contains(s.id) ? "spin" : "")
        }.joined(separator: ";")
        if force || sig != serversSig {
            serversSig = sig
            serversTable.reloadData()
        }
    }

    // MARK: - трей

    var trayConnected: Bool {
        guard let status, status.mode == .running, status.tunUp else { return false }
        if status.appRoutes.isEmpty { return status.servers.contains { $0.alive == true } }
        return status.anyCarrying
    }

    func trayConnect() {
        if !DaemonClient.shared.daemonInstalled() {
            DaemonClient.shared.installDaemon { [weak self] ok, msg in
                guard let self else { return }
                if ok {
                    self.push(mode: .running)
                } else {
                    self.warnIfNeeded(ok, msg)
                    self.updateControls()
                }
            }
            return
        }
        if status?.mode == .off {
            push(mode: .running)
            return
        }
        // включить серверы, к которым привязаны приложения (как основная кнопка)
        var on = store.servers.filter { srv in store.apps.contains { $0.serverID == srv.id } }
        if on.isEmpty, let first = store.servers.first { on = [first] }
        for s in on { store.setServerEnabled(s.id, true) }
        push(mode: .running)
    }

    func trayDisconnect() {
        // 0 включённых серверов = тюрьма: защита остаётся, туннеля нет
        for s in store.servers where s.enabled {
            store.setServerEnabled(s.id, false)
        }
        push(mode: .running)
    }

    private func serverStatus(_ id: String) -> ServerState? {
        status?.server(id)
    }

    /// цвет индикатора берётся строго из фазы демона (одна модель на все UI)
    private func dotColor(_ id: String) -> NSColor {
        switch serverStatus(id)?.phase ?? .off {
        case .off:     return .systemGray
        case .starting: return .systemYellow
        case .up:      return .systemGreen
        case .down:    return .systemRed
        }
    }

    private func updateControls() {
        // единая точка включения/выключения управляющих элементов: раньше
        // startPoll глушил primaryButton/powerButton/updateButton, а stopPoll
        // возвращал только ⟳ — после любой команды кнопки оставались мёртвыми
        let interactive = !pending && !syncing
        primaryButton.isEnabled = interactive
        powerButton.isEnabled = interactive
        updateButton.isEnabled = interactive
        refreshButtons.forEach { $0.isEnabled = !pending }
        guard DaemonClient.shared.daemonInstalled() else {
            primaryButton.title = "Установить демон…"
            statusLabel.stringValue = "демон не установлен (нужен пароль один раз)"
            versionLabel.stringValue = "app \(DaemonClient.shared.appVersion) · демон —"
            powerButton.isHidden = true
            showUpdateNotice(stale: false, offline: false)
            return
        }
        powerButton.isHidden = false
        let stale = DaemonClient.shared.daemonNeedsUpdate(reportedVersion: status?.daemonVersion)
        let demoV = status?.daemonVersion.isEmpty == false ? status!.daemonVersion : "?"
        versionLabel.stringValue = "app \(DaemonClient.shared.appVersion) · демон \(demoV)"
        // демон молчит (завис): кнопка обязательна — installDaemon(force) делает
        // bootout+bootstrap, это единственная починка висящего сервиса;
        // скрыть её «потому что бинарь свежий» = оставить пользователя один на один
        let offline = daemonOffline || status == nil
        updateButton.isHidden = !(stale || offline)
        updateButton.title = offline && !stale ? "⟳ Перезапустить демон" : "⟳ Обновить демон"
        let enabledCount = status?.enabledCount ?? store.servers.filter(\.enabled).count
        let aliveCount = status?.upCount ?? 0
        let appsCount = status.map { $0.appRoutes.isEmpty ? store.apps.count : $0.appRoutes.count } ?? store.apps.count
        // при выключенном ядре «выключать» нечего — прячем экстренную кнопку
        if status?.mode == .off { powerButton.isHidden = true }
        switch status?.mode ?? .running {
        case .running:
            if enabledCount > 0 {
                primaryButton.title = "Остановить все → защита"
                // ждём 🟢 — не красим промежуточное «ещё не live»
                if pending {
                    statusLabel.stringValue = "⏳ поднимаю: \(aliveCount)/\(enabledCount) live · tun \(status?.tunUp == true ? "✓" : "…")"
                } else {
                    let carrying = (status?.appRoutes.isEmpty == false) ? (status?.carryingCount ?? 0) : aliveCount
                    statusLabel.stringValue = "🟢 \(aliveCount)/\(enabledCount) серверов live · \(carrying)/\(appsCount) приложений в туннеле · tun \(status?.tunUp == true ? "✓" : "✗")\(status?.sealed == true ? " · ЗАПЕЧАТАНО" : "")"
                }
            } else {
                primaryButton.title = store.servers.isEmpty ? "Добавь сервер" : "Подключить сервер"
                statusLabel.stringValue = "🔒 защита · \(appsCount) приложений block · остальное direct · tun \(status?.tunUp == true ? "✓" : "…")"
            }
        case .off:
            primaryButton.title = "Включить защиту (запустить ядро)"
            statusLabel.stringValue = "⛔ ядро выключено — ЗАЩИТЫ НЕТ"
        }
        if let err = status?.lastError, !err.isEmpty, status?.mode != .running {
            statusLabel.stringValue = err
        }
        showUpdateNotice(stale: stale, offline: offline)
    }

    /// уведомление об обновлении/офлайне демона — строка ПОД кнопками:
    /// в заголовке длинный текст переносился на две строки и ломал layout;
    /// при появлении/исчезновении окно растягивается/сжимается на её высоту
    private func showUpdateNotice(stale: Bool, offline: Bool) {
        let text: String = offline
            ? "⟳ демон не отвечает — нажмите, чтобы перезапустить"
            : (stale ? "⟳ демон устарел — нажмите, чтобы обновить" : "")
        updateNotice.stringValue = text
        let show = !text.isEmpty
        updateNotice.isHidden = !show
        guard show != noticeShown, let w = view.window else { return }
        noticeShown = show
        var f = w.frame
        let d: CGFloat = 18
        if show { f.origin.y -= d; f.size.height += d }
        else if f.size.height > 300 { f.origin.y += d; f.size.height -= d }
        w.setFrame(f, display: true, animate: true)
    }

    // MARK: - действия

    @objc private func primaryAction() {
        if !DaemonClient.shared.daemonInstalled() {
            DaemonClient.shared.installDaemon { [weak self] ok, msg in
                self?.warnIfNeeded(ok, msg)
                self?.updateControls()
                if ok { self?.push(mode: .running) }
            }
            return
        }
        switch status?.mode ?? .running {
        case .off:
            push(mode: .running)
        case .running:
            guard !store.servers.isEmpty else { addServer(); return }
            if store.servers.contains(where: \.enabled) {
                for s in store.servers where s.enabled { store.setServerEnabled(s.id, false) }
                push(mode: .running)        // 0 серверов = тюрьма
            } else {
                // включаем НЕ «первый попавшийся», а все серверы, к которым
                // привязаны приложения из списка (несколько — если несколько);
                // привязок нет — первый сервер как fallback
                var on = store.servers.filter { srv in
                    store.apps.contains { $0.serverID == srv.id }
                }
                if on.isEmpty, let first = store.servers.first { on = [first] }
                for s in on { store.setServerEnabled(s.id, true) }
                push(mode: .running)
            }
        }
    }

    @objc private func updateDaemonAction() {
        updateButton.isEnabled = false
        let prevMode = status?.mode ?? .running
        DaemonClient.shared.installDaemon(force: true) { [weak self] ok, msg in
            self?.updateButton.isEnabled = true
            self?.warnIfNeeded(ok, msg)
            // демон после install пересевил состояние — возвращаем его к тому,
            // что показано в GUI (серверы, приложения, режим)
            if ok { self?.push(mode: prevMode) } else { self?.refreshStatus() }
        }
    }

    @objc private func powerOffAction() {
        let a = NSAlert()
        a.messageText = "Полностью выключить ядро?"
        a.informativeText = "ЗАЩИТЫ НЕ БУДЕТ: приложения из списка смогут в интернет напрямую.\n"
            + "Для обычной остановки открой вкладку «Серверы» и выключи серверы."
        a.addButton(withTitle: "Выключить")
        a.addButton(withTitle: "Отмена")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        primaryButton.isEnabled = false
        DaemonClient.shared.powerOff { [weak self] ok, msg in
            self?.primaryButton.isEnabled = true
            self?.warnIfNeeded(ok, msg)
            if ok {
                self?.startPoll(serverIDs: [], timeout: 8) { $0?.mode == .off }
            } else {
                self?.refreshStatus()
            }
        }
    }

    private func push(mode: TunnelMode) {
        primaryButton.isEnabled = false
        syncing = true
        DaemonClient.shared.sync(servers: store.servers, apps: store.apps, mode: mode) {
            [weak self] ok, msg in
            guard let self else { return }
            self.syncing = false
            self.warnIfNeeded(ok, msg)
            self.serversTable.reloadData()
            guard ok else {
                self.primaryButton.isEnabled = true
                self.refreshStatus()
                return
            }
            // ждём ЦЕЛЕВОГО состояния, а не «любого»
            switch mode {
            case .off:
                self.startPoll(serverIDs: [], timeout: 8) { $0?.mode == .off }
            case .running:
                let on = Set(self.store.servers.filter(\.enabled).map(\.id))
                if on.isEmpty {   // тюрьма: туннель есть, живых нет
                    self.startPoll(serverIDs: [], timeout: 8,
                                   check: { self.stoppedExpectation($0) })
                } else {
                    self.startPoll(serverIDs: on, timeout: 10,
                                   check: { self.connectedExpectation($0) })
                }
            }
        }
    }

    /// мгновенная картинка из store (не ждём RTT до демона),
    /// затем честная синхронизация с демоном
    private func syncNow() {
        // НЕ пропускаем правки при mode == .off: демон обязан записать
        // серверы/приложения в свои файлы, иначе его apps.json протухает
        // и после «Запустить» приложение окажется без правила (direct-дыра).
        // При .off демон просто сохранит — ядро поднимать не станет.
        guard DaemonClient.shared.daemonInstalled() else { return }
        syncing = true
        DaemonClient.shared.sync(servers: store.servers, apps: store.apps,
                                  mode: status?.mode ?? .running) { [weak self] ok, msg in
            self?.syncing = false
            // правка списка, не доехавшая до демона, — это дыра в защите:
            // молча глотать ошибку нельзя, пользователь решит что «применилось»
            if !ok { self?.warnIfNeeded(ok, msg) }
            self?.refreshStatus()
        }
    }

    private func warnIfNeeded(_ ok: Bool, _ msg: String) {
        if !ok { warn("Не удалось", msg) }
    }

    private func warn(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.runModal()
    }

    // MARK: - приложения

    @objc private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { addAppURL(url) }
    }

    @objc private func addCLI() {
        // свой пикер: поле с autocomplete по $PATH — вместо file-панели
        guard let picked = AddCLIPicker.present() else { return }
        store.addApp(AppRule(name: picked.name, path: picked.path,
                              includeChildren: false, isCLI: true))
        appsTable.reloadData()
        syncNow()   // без этого CLI-приложение жило только в GUI и ходил direct
    }

    @objc private func removeSelected() {
        let row = appsTable.selectedRow
        guard row >= 0 else { return }
        store.removeApp(at: row)
        appsTable.reloadData()
        syncNow()
    }

    /// удаление из контекстного меню: кликабельная строка важнее выделения
    @objc private func removeAppMenuAction() {
        let row = appsTable.clickedRow >= 0 ? appsTable.clickedRow : appsTable.selectedRow
        guard store.apps.indices.contains(row) else { return }
        store.removeApp(at: row)
        appsTable.reloadData()
        syncNow()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(removeAppMenuAction):
            return appsTable.clickedRow >= 0 || appsTable.selectedRow >= 0
        default:
            return true
        }
    }

    private func addAppURL(_ url: URL) {
        let infoPlist = url.appendingPathComponent("Contents/Info.plist")
        if FileManager.default.fileExists(atPath: infoPlist.path),
           let info = NSDictionary(contentsOf: infoPlist),
           let exe = info["CFBundleExecutable"] as? String {
            let name = (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent
            store.addApp(AppRule(name: name,
                                  path: url.appendingPathComponent("Contents/MacOS/\(exe)").path,
                                  bundlePath: url.path))
        } else if FileManager.default.isExecutableFile(atPath: url.path) {
            store.addApp(AppRule(name: url.lastPathComponent, path: url.path,
                                  includeChildren: false, isCLI: true))
        } else {
            return
        }
        appsTable.reloadData()
        syncNow()
    }

    @objc private func toggleChildren(_ sender: NSButton) {
        store.setIncludeChildren(sender.state == .on, at: sender.tag)
        syncNow()
    }

    @objc private func serverPicked(_ sender: NSPopUpButton) {
        let row = sender.tag
        guard appsTable.numberOfRows > 0, row < store.apps.count,
              let id = sender.selectedItem?.identifier?.rawValue else { return }
        store.setAppServer(id, at: row)
        syncNow()
    }

    // MARK: - серверы

    @objc private func addServer() {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        if let confType = UTType(filenameExtension: "conf") {
            panel.allowedContentTypes = [confType]
        } else {
            panel.allowedContentTypes = [.plainText, .text]
        }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var added = false
        for url in panel.urls {
            do {
                _ = try store.importServer(from: url)
                added = true
            }
            catch { warn("Не удалось прочитать \(url.lastPathComponent)", "\(error)") }
        }
        if added {
            serversTable.reloadData()
            appsTable.reloadData()
            syncNow()
        }
    }

    @objc private func removeServer() {
        let row = serversTable.selectedRow
        guard row >= 0 else { return }
        let spec = store.servers[row]
        let bound = store.apps.filter { $0.serverID == spec.id }.count
        let a = NSAlert()
        a.messageText = "Удалить сервер «\(spec.name)»?"
        a.informativeText = bound > 0
            ? "\(bound) прил. привязаны к нему: они уйдут на первый включённый сервер, "
                + "а если включённых не останется — на защиту (без сети)."
            : "Ключи сервера будут стёрты."
        a.addButton(withTitle: "Удалить")
        a.addButton(withTitle: "Отмена")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        store.removeServer(id: spec.id)
        serversTable.reloadData()
        appsTable.reloadData()
        syncNow()
    }

    @objc private func serverRowDoubleClicked(_ sender: NSTableView) {
        editServerName(row: sender.clickedRow)
    }

    /// inline-редактирование имени прямо в строке таблицы (тот же путь,
    /// что и двойной клик); окно-панель убрано — у пользователя один способ
    private func editServerName(row: Int) {
        guard store.servers.indices.contains(row) else { return }
        serversTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let col = serversTable.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }),
              let cell = serversTable.view(atColumn: col, row: row, makeIfNecessary: true)
        else { return }
        // cell — сам редактируемый NSTextField (я его возвращаю из viewFor)
        let tf: NSTextField
        if let t = cell as? NSTextField { tf = t }
        else if let t = cell.subviews.first(where: { $0 is NSTextField }) as? NSTextField { tf = t }
        else { return }
        view.window?.makeFirstResponder(tf)
        tf.selectText(nil)
    }

    @objc private func nameCommitted(_ sender: NSTextField) {
        let row = sender.tag
        guard store.servers.indices.contains(row) else { return }
        store.renameServer(id: store.servers[row].id, to: sender.stringValue)
        appsTable.reloadData()
        syncNow()
    }

    /// «✎ Имя» и пункт контекстного меню — тот же inline-путь, что и двойной клик
    @objc private func renameServerAction() {
        var row = serversTable.selectedRow
        if row < 0 { row = serversTable.clickedRow }
        guard store.servers.indices.contains(row) else {
            warn("Выбери сервер", "Кликни по строке сервера, потом «✎ Имя».")
            return
        }
        editServerName(row: row)
    }

    @objc private func toggleSelectedServer() {
        let row = serversTable.clickedRow >= 0 ? serversTable.clickedRow : serversTable.selectedRow
        guard store.servers.indices.contains(row) else { return }
        let fake = NSButton()
        fake.tag = row
        fake.title = store.servers[row].enabled ? "Остановить" : "Подключить"
        connectToggled(fake)
    }

    @objc private func connectToggled(_ sender: NSButton) {
        let row = sender.tag
        guard store.servers.indices.contains(row) else { return }
        let spec = store.servers[row]
        let enable = sender.title == "Подключить"
        store.setServerEnabled(spec.id, enable)
        serversTable.reloadData()
        // полный sync (а не setServer): новый сервер демон ещё не знает,
        // а конфиг перегенерируется всё равно по всему состоянию
        sender.isEnabled = false
        syncing = true
        DaemonClient.shared.sync(servers: store.servers, apps: store.apps,
                                  mode: status?.mode ?? .running) { [weak self] ok, msg in
            guard let self else { return }
            self.syncing = false
            sender.isEnabled = true
            self.warnIfNeeded(ok, msg)
            self.serversTable.reloadData()
            guard ok else { self.refreshStatus(); return }
            if enable {
                // ждём зелёного именно этой строки (+ tun) —其他 серверы не в счёт
                self.startPoll(serverIDs: [spec.id], timeout: 10, check: { s in
                    guard let s, s.tunUp else { return false }
                    return s.servers.first { $0.id == spec.id }?.alive == true
                })
            } else {
                self.startPoll(serverIDs: [], timeout: 10, check: { s in
                    guard let s else { return false }
                    return !s.servers.contains { $0.id == spec.id && $0.alive == true }
                })
            }
        }
    }

    // MARK: - NSDraggingDestination

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard segment.selectedSegment == 0,
              let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: nil) as? [URL],
              !urls.isEmpty else { return false }
        for url in urls { addAppURL(url) }
        return true
    }

    // MARK: - таблица

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView == appsTable ? store.apps.count : store.servers.count
    }

    // MARK: - бейджи колонки «Приложение»

    /// бейдж CLI: белый «>» на чёрном квадрате 16×16 — та же ширина,
    /// что и иконки .app, левый край списка ровный
    private static let cliBadge: NSImage = {
        let img = NSImage(size: NSSize(width: 16, height: 16))
        img.lockFocus()
        let bg = NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 14, height: 14),
                              xRadius: 3, yRadius: 3)
        NSColor.black.setFill()
        bg.fill()
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: ps,
        ]
        (">" as NSString).draw(in: NSRect(x: 0, y: 1.5, width: 16, height: 13), withAttributes: attrs)
        img.unlockFocus()
        return img
    }()

    private static let iconCache = NSCache<NSString, NSImage>()

    private static func badge(for app: AppRule) -> NSImage {
        if app.isCLI { return cliBadge }
        let key = (app.bundlePath ?? app.path) as NSString
        if let c = iconCache.object(forKey: key) { return c }
        let icon = NSWorkspace.shared.icon(forFile: key as String)
        // копию в кэш: размер правим на своём экземпляре, системный нельзя
        let copy = NSImage(size: NSSize(width: 16, height: 16))
        copy.lockFocus()
        icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        copy.unlockFocus()
        iconCache.setObject(copy, forKey: key)
        return copy
    }

    /// контейнер ячейки: заполняет строку на всю высоту и центрирует контент
    /// по вертикали — обычные вью, возвращённые из viewFor, NSTableView
    /// прижимает к верху строки (текст «прилипает» к верхней границе)
    private func cell(_ content: NSView, inset: CGFloat = 4) -> NSView {
        let c = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        c.addSubview(content)
        NSLayoutConstraint.activate([
            content.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            content.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -inset),
        ])
        if let tf = content as? NSTextField, tf.isEditable { c.textField = tf }
        return c
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                  row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        if tableView == appsTable {
            let app = store.apps[row]
            switch id {
            case "name":
                // иконка приложения / рисуемый бейдж «$» для CLI — одинаковой
                // ширины (16), левый край выровнен
                let iv = NSImageView()
                iv.image = Self.badge(for: app)
                iv.imageScaling = .scaleNone
                iv.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    iv.widthAnchor.constraint(equalToConstant: 16),
                    iv.heightAnchor.constraint(equalToConstant: 16),
                ])
                let tf = NSTextField(labelWithString: app.name)
                tf.lineBreakMode = .byTruncatingTail
                let stack = NSStackView(views: [iv, tf])
                stack.orientation = .horizontal
                stack.spacing = 6
                stack.alignment = .centerY
                return cell(stack)
            case "server":
                let popup = NSPopUpButton(frame: .zero, pullsDown: false)
                popup.tag = row
                popup.target = self
                popup.action = #selector(serverPicked(_:))
                let allowed = store.servers
                for s in allowed {
                    popup.addItem(withTitle: store.serverName(s.id))
                    popup.lastItem?.identifier = NSUserInterfaceItemIdentifier(s.id)
                    popup.lastItem?.toolTip = "\(s.endpointDisplay) · \(s.enabled ? "включен" : "выключен")"
                }
                // "" = «первый включённый» (в UI показываем первый разрешённый)
                let want = app.serverID.isEmpty ? allowed.first?.id : app.serverID
                if let want, popup.item(withTitle: store.serverName(want)) != nil {
                    popup.selectItem(withTitle: store.serverName(want))
                }
                popup.isEnabled = !allowed.isEmpty
                return cell(popup)
            case "conns":
                // established-сокеты приложения. tun — зелёный, direct при живой
                // защите — оранжевый (залипший сокет, kernel route cache):
                // приложение должно ходить только через туннель, ворнинг при 1+
                let tag = ConfigBuilder.selectorTag(appIndex: row)
                let st = status?.appRoutes.first { $0.selector == tag }
                let d = st?.directConns ?? 0, t = st?.tunConns ?? 0
                let protect = status?.tunUp ?? false
                if protect, t + d > 0 {
                    let s = NSMutableAttributedString()
                    let attrs: (NSColor, Bool) -> [NSAttributedString.Key: Any] = { c, b in
                        [.foregroundColor: c,
                         .font: NSFont.systemFont(ofSize: 10, weight: b ? .bold : .regular)]
                    }
                    if t > 0 { s.append(NSAttributedString(string: "● \(t)", attributes: attrs(.systemGreen, false))) }
                    if t > 0 && d > 0 { s.append(NSAttributedString(string: " · ", attributes: attrs(.secondaryLabelColor, false))) }
                    if d > 0 { s.append(NSAttributedString(string: "⚠ \(d) direct", attributes: attrs(.systemOrange, true))) }
                    let tf = NSTextField(labelWithAttributedString: s)
                    tf.toolTip = "через туннель: \(t)" + (d > 0
                        ? "\n⚠ \(d) идут мимо туннеля (открыты до его подъёма, ядро держит их на физическом интерфейсе) — перезапустите приложение"
                        : "")
                    return cell(tf, inset: 2)
                }
                let tf = NSTextField(labelWithString: protect ? "—" : "—")
                tf.font = .systemFont(ofSize: 10)
                tf.textColor = .tertiaryLabelColor
                tf.toolTip = protect ? "нет активных соединений"
                    : "защита выключена — весь трафик идёт direct, это штатно"
                return cell(tf, inset: 2)
            case "kids":
                if app.isCLI { return cell(NSTextField(labelWithString: "—")) }
                let cb = NSButton(checkboxWithTitle: "", target: self,
                                  action: #selector(toggleChildren(_:)))
                cb.tag = row
                cb.state = app.includeChildren ? .on : .off
                return cell(cb, inset: 2)
            default:
                let tf = NSTextField(labelWithString: app.path)
                tf.lineBreakMode = .byTruncatingMiddle
                tf.font = .systemFont(ofSize: 10)
                tf.textColor = .secondaryLabelColor
                tf.toolTip = app.path
                return cell(tf)
            }
        } else {
            let srv = store.servers[row]
            switch id {
            case "dot":
                // ждём поднятия этого сервера — крутилка вместо 🟢/🔴
                if pendingServerIDs.contains(srv.id) {
                    let iv = NSProgressIndicator()
                    iv.style = .spinning
                    iv.isDisplayedWhenStopped = false
                    iv.startAnimation(nil)
                    iv.toolTip = "поднимаем сервер…"
                    return cell(iv, inset: 2)
                }
                let iv = NSImageView()
                let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
                iv.image = img
                iv.contentTintColor = dotColor(srv.id)
                iv.toolTip = dotColor(srv.id) == .systemGreen ? "жив" :
                    (dotColor(srv.id) == .systemRed ? "ошибка (urltest fail)" : "выключен")
                return cell(iv, inset: 2)
            case "name":
                // редактиемое имя: двойной клик как в Finder
                let tf = NSTextField(string: srv.name)
                tf.isBordered = false
                tf.drawsBackground = false
                tf.focusRingType = .none
                tf.lineBreakMode = .byTruncatingTail
                tf.tag = row
                tf.target = self
                tf.action = #selector(nameCommitted(_:))
                tf.toolTip = "двойной клик — переименовать"
                return cell(tf)
            case "endpoint":
                let tf = NSTextField(labelWithString: srv.endpointDisplay)
                tf.font = .systemFont(ofSize: 11)
                tf.textColor = .secondaryLabelColor
                return cell(tf)
            default: // conn
                let b = NSButton(title: srv.enabled ? "Остановить" : "Подключить",
                                 target: self, action: #selector(connectToggled(_:)))
                b.tag = row
                b.controlSize = .small
                b.bezelStyle = .rounded
                return cell(b, inset: 2)
            }
        }
    }
}
