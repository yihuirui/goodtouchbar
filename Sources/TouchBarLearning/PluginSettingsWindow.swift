import AppKit

@MainActor private final class PluginEditorBackground: NSView {
    override func draw(_ dirtyRect:NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

/// Drafts stay local until Save. Selecting a script never runs it.
@MainActor final class PluginSettingsWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    private let manager: TouchBarPluginManager
    private let didSave: () -> Void
    private let table = NSTableView()
    private let nameField = NSTextField(), idField = NSTextField(), scriptField = NSTextField(), actionField = NSTextField(), iconField = NSTextField(), intervalField = NSTextField()
    private let enabled = NSButton(checkboxWithTitle:"启用脚本（保存后执行）",target:nil,action:nil)
    private let bar = NSButton(checkboxWithTitle:"Touch Bar",target:nil,action:nil)
    private let menuCheck = NSButton(checkboxWithTitle:"菜单栏",target:nil,action:nil)
    private let message = NSTextField(wrappingLabelWithString:"")
    private var drafts: [TouchBarScriptPluginDefinition] = []
    private var barKeys = Set<String>(), menuKeys = Set<String>()
    private var expected = Data()
    private var selected: Int?
    private var loading = false
    init(manager:TouchBarPluginManager,didSave:@escaping () -> Void) {
        self.manager = manager; self.didSave = didSave
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:860,height:580),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
        window.title = "插件配置"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:820,height:570)
        window.contentView = PluginEditorBackground(frame:window.contentView!.bounds)
        super.init(window:window); window.delegate = self; build(); load()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    func present() { showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    private func build() {
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top:20,left:20,bottom:20,right:20); root.translatesAutoresizingMaskIntoConstraints = false
        let content = window!.contentView!; content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:content.leadingAnchor),root.trailingAnchor.constraint(equalTo:content.trailingAnchor),root.topAnchor.constraint(equalTo:content.topAnchor),root.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
        let note = NSTextField(wrappingLabelWithString:"左侧选择插件，右侧修改。可选择脚本文件，无需编辑 JSON。新插件默认停用；勾选启用并保存后开始执行。")
        root.addArrangedSubview(note)
        let body = NSStackView(); body.orientation = .horizontal; body.alignment = .top; body.spacing = 20; root.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive = true
        let left = NSStackView(); left.orientation = .vertical; left.spacing = 10
        let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier("plugin")); column.title = "自定义插件"; table.addTableColumn(column)
        table.dataSource = self; table.delegate = self; table.rowHeight = 32; table.usesAlternatingRowBackgroundColors = true
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        left.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalToConstant:220).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:330).isActive = true
        let actions = NSStackView(); actions.addArrangedSubview(NSButton(title:"添加",target:self,action:#selector(add))); actions.addArrangedSubview(NSButton(title:"删除…",target:self,action:#selector(remove)))
        left.addArrangedSubview(actions); body.addArrangedSubview(left)
        let form = NSStackView(); form.orientation = .vertical; form.alignment = .leading; form.spacing = 12; body.addArrangedSubview(form)
        let fields = [("名称",nameField),("标识",idField),("显示脚本",scriptField),("点击动作",actionField),("图标",iconField),("刷新秒数",intervalField)]
        for (index,pair) in fields.enumerated() {
            let row = NSStackView(); row.spacing = 10
            let label = NSTextField(labelWithString:pair.0); label.widthAnchor.constraint(equalToConstant:64).isActive = true
            pair.1.identifier = NSUserInterfaceItemIdentifier("plugin-field-\(index)")
            pair.1.placeholderString = index == 3 || index == 4 ? "可选" : ""; pair.1.widthAnchor.constraint(greaterThanOrEqualToConstant:220).isActive = true
            row.addArrangedSubview(label); row.addArrangedSubview(pair.1)
            if (2...4).contains(index) { let choose = NSButton(title:"选择…",target:self,action:#selector(chooseFile)); choose.tag = index; row.addArrangedSubview(choose) }
            form.addArrangedSubview(row); row.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true
        }
        form.addArrangedSubview(enabled)
        let positions = NSStackView(); positions.addArrangedSubview(bar); positions.addArrangedSubview(menuCheck); form.addArrangedSubview(positions)
        let help = NSTextField(wrappingLabelWithString:"脚本按 zsh 执行；刷新范围 5–3600 秒。停用后取消执行并停止采集。显示顺序在“显示项目”中调整。")
        help.font = .systemFont(ofSize:12); help.textColor = .secondaryLabelColor; form.addArrangedSubview(help)
        help.widthAnchor.constraint(equalTo:form.widthAnchor).isActive = true
        root.addArrangedSubview(message); message.widthAnchor.constraint(equalTo:body.widthAnchor).isActive = true
        let footer = NSStackView(); footer.spacing = 12
        footer.addArrangedSubview(NSButton(title:"重新载入…",target:self,action:#selector(reloadDrafts)))
        let save = NSButton(title:"保存插件设置",target:self,action:#selector(save)); save.keyEquivalent = "s"; footer.addArrangedSubview(save)
        root.addArrangedSubview(footer)
    }
    private func load() {
        do {
            guard manager.reload() == nil else { throw NSError(domain:"Plugins",code:1,userInfo:[NSLocalizedDescriptionKey:manager.lastError ?? "读取失败"]) }
            expected = try manager.configurationData(); drafts = manager.configuration.scripts
            barKeys = Set(manager.configuration.order); menuKeys = Set(manager.configuration.menuOrder ?? manager.menuKeys)
            loading = true; selected = nil; table.reloadData()
            if !drafts.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false); selected = 0 }
            loading = false; showDraft(); message.stringValue = drafts.isEmpty ? "还没有自定义脚本插件，点击添加。内置指标请使用“显示项目”。" : "已载入；修改后点击保存。"
        } catch { message.stringValue = error.localizedDescription }
    }
    func numberOfRows(in tableView:NSTableView) -> Int { drafts.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        guard drafts.indices.contains(row) else { return nil }
        return NSTextField(labelWithString:drafts[row].name + (drafts[row].isEnabled ? "" : " · 停用"))
    }
    func tableView(_ tableView:NSTableView,shouldSelectRow row:Int) -> Bool { loading || capture() }
    func tableViewSelectionDidChange(_ notification:Notification) {
        guard !loading else { return }; selected = drafts.indices.contains(table.selectedRow) ? table.selectedRow : nil; showDraft()
    }
    private func showDraft() {
        let current = selected.flatMap { drafts.indices.contains($0) ? drafts[$0] : nil }
        for field in [nameField,idField,scriptField,actionField,iconField,intervalField] { field.isEnabled = current != nil }
        idField.isEditable = false
        for button in [enabled,bar,menuCheck] { button.isEnabled = current != nil }
        nameField.stringValue = current?.name ?? ""; idField.stringValue = current?.id ?? ""
        scriptField.stringValue = current?.script ?? ""; actionField.stringValue = current?.actionScript ?? ""; iconField.stringValue = current?.icon ?? ""
        intervalField.stringValue = current.map { String(format:"%g",$0.refreshSeconds ?? 30) } ?? ""
        enabled.state = current?.isEnabled == true ? .on : .off
        bar.state = current.map { barKeys.contains($0.key) } == true ? .on : .off
        menuCheck.state = current.map { menuKeys.contains($0.key) } == true ? .on : .off
    }
    private func draftText(_ field:NSTextField) -> String { field.currentEditor()?.string ?? field.stringValue }
    @discardableResult private func capture() -> Bool {
        guard let index = selected, drafts.indices.contains(index) else { return true }
        guard let seconds = Double(draftText(intervalField)), seconds.isFinite, (5...3600).contains(seconds) else { message.stringValue = "刷新间隔请输入 5–3600 秒。"; return false }
        let old = drafts[index]
        func optional(_ field:NSTextField) -> String? { let text = draftText(field).trimmingCharacters(in:.whitespacesAndNewlines); return text.isEmpty ? nil : text }
        drafts[index] = TouchBarScriptPluginDefinition(id:old.id,name:draftText(nameField),script:draftText(scriptField),refreshSeconds:seconds,actionScript:optional(actionField),icon:optional(iconField),enabled:enabled.state == .on)
        if bar.state == .on { barKeys.insert(old.key) } else { barKeys.remove(old.key) }
        if menuCheck.state == .on { menuKeys.insert(old.key) } else { menuKeys.remove(old.key) }
        return true
    }
    @objc private func add() {
        guard capture() else { return }
        drafts.append(TouchBarScriptPluginDefinition(id:"plugin_"+UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(8),name:"新插件",script:"",refreshSeconds:30,actionScript:nil,icon:nil,enabled:false))
        loading = true; table.reloadData(); selected = drafts.count-1; table.selectRowIndexes(IndexSet(integer:selected!),byExtendingSelection:false); loading = false; showDraft()
        message.stringValue = "选择显示脚本、显示位置，按需勾选启用，然后保存。"
    }
    @objc private func remove() {
        guard let selected, drafts.indices.contains(selected) else { return }
        let alert = NSAlert(); alert.messageText = "删除插件“\(drafts[selected].name)”？"; alert.informativeText = "保存后移除配置并停止该插件；脚本文件保留。"; alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"从列表移除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        let key = drafts.remove(at:selected).key; barKeys.remove(key); menuKeys.remove(key)
        loading = true; self.selected = nil; table.reloadData(); table.deselectAll(nil); loading = false; showDraft(); message.stringValue = "删除待保存。"
    }
    @objc private func chooseFile(_ sender:NSButton) {
        guard selected != nil else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { [2:scriptField,3:actionField,4:iconField][sender.tag]?.stringValue = url.path }
    }
    @objc private func reloadDrafts() {
        let alert = NSAlert(); alert.messageText = "放弃未保存修改并重新载入？"; alert.addButton(withTitle:"取消"); alert.addButton(withTitle:"重新载入")
        if alert.runModal() == .alertSecondButtonReturn { load() }
    }
    @objc private func save() {
        guard capture() else { return }
        do {
            try manager.saveScripts(drafts,expected:expected,barKeys:barKeys,menuKeys:menuKeys)
            expected = try manager.configurationData(); table.reloadData(); didSave()
            message.stringValue = "已保存；启用项开始执行，停用项已停止。"
        } catch { message.stringValue = error.localizedDescription }
    }
}
