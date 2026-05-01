import AppKit

/// First-launch picker. Lists every iPhone/iPad we've previously
/// authenticated with (and the synthetic "Listen for any device" option),
/// lets the user pick one or more, and closes itself once a selection is
/// made. The chosen descriptors are forwarded via `onSelect`. The caller
/// (AppDelegate) opens one streaming window per selected descriptor; if
/// the synthetic row is picked, a single window without a target filter
/// is opened.
final class DevicePickerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {

    /// `nil` element in the result array means "any device" (no filter).
    var onSelect: (([DeviceDescriptor?]) -> Void)?

    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let forgetButton  = NSButton(title: "Forget",  target: nil, action: nil)
    private let renameButton  = NSButton(title: "Rename…", target: nil, action: nil)
    private let anyButton     = NSButton(title: "Listen for any device",
                                         target: nil, action: nil)
    private let titleLabel = NSTextField(labelWithString: "Choose device(s)")
    private let subtitleLabel = NSTextField(labelWithString:
        "ScreenMirror will start a window for each device you select. " +
        "iPhones connect on their own — pick the one you expect to see.")

    private var records: [DeviceRecord] = []

    init() {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
                           styleMask: style, backing: .buffered, defer: false)
        win.title = "ScreenMirror — Devices"
        win.center()
        super.init(window: win)
        buildLayout()
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(titleLabel)

        subtitleLabel.font = .systemFont(ofSize: 11, weight: .regular)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(subtitleLabel)

        // Table: 3 columns — name, last seen, model id.
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.rowHeight = 28
        table.dataSource = self
        table.delegate = self
        table.doubleAction = #selector(connectTapped)
        table.target = self

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Device"
        nameCol.width = 240
        table.addTableColumn(nameCol)

        let seenCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("seen"))
        seenCol.title = "Last seen"
        seenCol.width = 120
        table.addTableColumn(seenCol)

        let resCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("res"))
        resCol.title = "Resolution"
        resCol.width = 110
        table.addTableColumn(resCol)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .regular
        connectButton.keyEquivalent = "\r"   // default button (Return)
        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        connectButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(connectButton)

        forgetButton.bezelStyle = .rounded
        forgetButton.controlSize = .regular
        forgetButton.target = self
        forgetButton.action = #selector(forgetTapped)
        forgetButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(forgetButton)

        renameButton.bezelStyle = .rounded
        renameButton.controlSize = .regular
        renameButton.target = self
        renameButton.action = #selector(renameTapped)
        renameButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(renameButton)

        anyButton.bezelStyle = .rounded
        anyButton.controlSize = .regular
        anyButton.target = self
        anyButton.action = #selector(anyTapped)
        anyButton.toolTip = "Open the streaming window without filtering — accepts whichever device connects first."
        anyButton.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(anyButton)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -18),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),

            scroll.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            scroll.bottomAnchor.constraint(equalTo: anyButton.topAnchor, constant: -12),

            anyButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            anyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),

            forgetButton.leadingAnchor.constraint(equalTo: anyButton.trailingAnchor, constant: 12),
            forgetButton.centerYAnchor.constraint(equalTo: anyButton.centerYAnchor),

            renameButton.leadingAnchor.constraint(equalTo: forgetButton.trailingAnchor, constant: 6),
            renameButton.centerYAnchor.constraint(equalTo: anyButton.centerYAnchor),

            connectButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            connectButton.centerYAnchor.constraint(equalTo: anyButton.centerYAnchor),
            connectButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    func reload() {
        records = DeviceHistory.load()
            .sorted { $0.lastSeen > $1.lastSeen }   // most recent first
        table.reloadData()
        updateButtonStates()
    }

    private func updateButtonStates() {
        let hasSel = !table.selectedRowIndexes.isEmpty
        connectButton.isEnabled = hasSel
        forgetButton.isEnabled  = hasSel
        renameButton.isEnabled  = table.selectedRowIndexes.count == 1
    }

    // MARK: - Actions

    @objc private func connectTapped() {
        let picks = table.selectedRowIndexes.map { records[$0].descriptor }
        guard !picks.isEmpty else { return }
        DeviceHistory.save(records)   // persist any pending mutations
        let result: [DeviceDescriptor?] = picks.map { Optional($0) }
        onSelect?(result)
        window?.close()
    }

    @objc private func anyTapped() {
        onSelect?([nil])
        window?.close()
    }

    @objc private func forgetTapped() {
        let toRemove = table.selectedRowIndexes.map { records[$0].descriptor }
        for d in toRemove { DeviceHistory.forget(d) }
        reload()
    }

    @objc private func renameTapped() {
        guard let idx = table.selectedRowIndexes.first else { return }
        let rec = records[idx]
        let alert = NSAlert()
        alert.messageText = "Rename device"
        alert.informativeText = "Pick a friendly name. Leave blank to use the model name."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = rec.nickname ?? ""
        field.placeholderString = rec.descriptor.displayName
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            DeviceHistory.setNickname(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                       for: rec.descriptor)
            reload()
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tv: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let r = records[row]
        let id = column?.identifier.rawValue ?? ""
        let cell: NSTableCellView
        let cellID = NSUserInterfaceItemIdentifier("smir.cell.\(id)")
        if let v = tv.makeView(withIdentifier: cellID, owner: nil) as? NSTableCellView {
            cell = v
        } else {
            cell = NSTableCellView()
            cell.identifier = cellID
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingTail
            tf.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        switch id {
        case "name": cell.textField?.stringValue = r.displayLabel
        case "seen": cell.textField?.stringValue = r.lastSeenRelative
        case "res":  cell.textField?.stringValue = "\(r.descriptor.width)×\(r.descriptor.height)"
        default:     cell.textField?.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }
}
