import AppKit
import Darwin
import FanControlCore
import SystemMonitoring

/// Native AppKit regression checks. Every RPC is answered in-process; the
/// window stays hidden and no real installer or fan hardware is constructed.
@MainActor
private final class EditingFanTransport: FanControlTransport {
    var onDisconnect: (() -> Void)?
    var requests: [FanControlRequest] = []
    var status = FanControlStatus()
    var replyOK = true
    var replyCode = "ok"
    var delayReplies = false
    private(set) var pending: FanControlRequest?
    private var completion: ((Result<Data, Error>) -> Void)?

    func send(_ data: Data, completion: @escaping (Result<Data, Error>) -> Void) {
        precondition(pending == nil, "overlapping fake RPCs")
        let request = try! JSONDecoder().decode(FanControlRequest.self, from: data)
        requests.append(request)
        if delayReplies {
            pending = request; self.completion = completion
        } else { complete(request, completion: completion) }
    }

    func finishReply() {
        precondition(pending != nil && completion != nil)
        let request = pending!, callback = completion!
        pending = nil; completion = nil
        complete(request, completion: callback)
    }

    private func complete(_ request: FanControlRequest, completion: (Result<Data, Error>) -> Void) {
        let reply = FanControlReply(ok: replyOK, code: replyCode, status: status, requestID: request.requestID)
        completion(.success(try! JSONEncoder().encode(reply)))
    }

    func disconnect() { onDisconnect?() }
    func invalidate() { pending = nil; completion = nil }
}

@main @MainActor
struct FanInputEditingChecks {
    static func main() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fan-input-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }

        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            guard condition else {
                FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
                exit(1)
            }
            checks += 1; print("PASS: " + message)
        }
        func fan(_ id: Int, target: Double = 2200, automatic: Bool = true) -> FanDeviceReading {
            FanDeviceReading(id: id, actualRPM: 2100, minimumRPM: 1800, maximumRPM: 5600, targetRPM: target, automatic: automatic)
        }
        func snapshot(_ ids: [Int], target: Double = 2200) -> FanControlStatus {
            FanControlStatus(fans: ids.map { fan($0, target: target) }, cpuTemperature: 60, gpuTemperature: 55)
        }
        let transport = EditingFanTransport()
        transport.status = snapshot([0, 1])
        var now = 100.0
        let log = MonitorEventLog(url: directory.appendingPathComponent("client.jsonl"))
        let client = FanControlClient(transport: transport,
            installer: { _, _, _, _ in fatalError("An editing test must never request an installation") },
            runningControllers: { [] }, clock: { now }, eventLog: log,
            capabilities: GoodTouchBarDeviceCapabilities(modelIdentifier:"MacBookPro16,2",processArchitecture:"x86_64",hostSupportsArm64:false,processTranslated:false))
        client.refresh()
        let controller = FanControlWindow(client: client)
        let window = controller.window!
        let root = window.contentView!
        window.layoutIfNeeded(); root.layoutSubtreeIfNeeded()
        client.onChange = { [weak controller] in controller?.render() }
        defer { client.onChange = nil; client.stop(release: false); window.close() }

        func descendants<T: NSView>(_ view: NSView, type: T.Type) -> [T] {
            (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { descendants($0, type: type) }
        }
        func rpmField(_ id: Int, allowLegacy: Bool = false) -> NSTextField? {
            let fields = descendants(root, type: NSTextField.self)
            if let field = fields.first(where: { $0.identifier?.rawValue == "fan-rpm-\(id)" }) { return field }
            // Build34 has no identifiers. This fallback lets its expected first
            // failure exercise the actual busy/editing bug instead of metadata.
            let legacy = fields.filter { $0.placeholderString == "目标 RPM" }
            return allowLegacy && legacy.indices.contains(id) ? legacy[id] : nil
        }
        func button(_ title: String) -> NSButton {
            let result = descendants(root, type: NSButton.self).first { $0.title == title }
            check(result != nil, "native button exists: " + title)
            return result!
        }
        func draft(_ field: NSTextField) -> String { field.currentEditor()?.string ?? field.stringValue }
        func edit(_ field: NSTextField, text: String, selection: NSRange) -> NSTextView {
            window.makeFirstResponder(field)
            field.selectText(nil)
            let editor = field.currentEditor() as? NSTextView
            check(editor != nil && window.firstResponder === editor, "hidden window supplies a real native field editor")
            editor!.insertText(text, replacementRange: NSRange(location: 0, length: editor!.string.utf16.count))
            editor!.setSelectedRange(selection)
            return editor!
        }
        func checkEditing(_ field: NSTextField, _ editor: NSTextView, text: String, selection: NSRange, event: String) {
            check(field.isEnabled, event + ": draft remains editable")
            check(field.currentEditor() === editor && window.firstResponder === editor, event + ": native editing focus remains")
            check(editor.string == text && editor.selectedRange() == selection, event + ": draft and selection remain")
        }

        let field0 = rpmField(0, allowLegacy: true)!, field1 = rpmField(1, allowLegacy: true)!
        let fixed = button("应用固定转速"), boost = button("强力散热 5 分钟")
        check(!window.isVisible && client.statusFresh, "fresh fake status with an entirely hidden window")
        let selection = NSRange(location: 1, length: 1)
        let editor = edit(field0, text: "27", selection: selection)
        transport.delayReplies = true
        client.refresh()
        check(client.busy && transport.pending?.action == .status, "status RPC is held across native editing")
        checkEditing(field0, editor, text: "27", selection: selection, event: "status start")
        check(!fixed.isEnabled && !boost.isEnabled, "status RPC still locks control submission")
        check(field0.identifier?.rawValue == "fan-rpm-0" && field1.identifier?.rawValue == "fan-rpm-1", "RPM fields carry stable native identifiers")
        try await Task.sleep(nanoseconds: 20_000_000)
        transport.status = snapshot([0, 1], target: 3900)
        transport.finishReply()
        checkEditing(field0, editor, text: "27", selection: selection, event: "status reply with changed hardware target")

        // Acquire a fake lease without submitting the deliberately incomplete
        // local draft, then prove the two-second heartbeat cannot interrupt it.
        transport.delayReplies = false
        transport.status = FanControlStatus(phase: .controlling, leaseID: "editing-lease", ownedFanIDs: [0, 1], targets: [0: 2700, 1: 2800], leaseExpiresAt: 112,
            fans: [fan(0, target: 2700, automatic: false), fan(1, target: 2800, automatic: false)], cpuTemperature: 60, gpuTemperature: 55)
        client.applyFixed(targets: [0: 2700, 1: 2800])
        check(client.hasControl, "fake lease acquired without altering the local draft")
        transport.delayReplies = true; now = 102
        client.tick()
        check(transport.pending?.action == .heartbeat && transport.pending?.leaseID == "editing-lease", "real client heartbeat scheduling continues while editing")
        checkEditing(field0, editor, text: "27", selection: selection, event: "heartbeat start")
        try await Task.sleep(nanoseconds: 20_000_000)
        transport.finishReply()
        checkEditing(field0, editor, text: "27", selection: selection, event: "heartbeat reply")

        transport.delayReplies = false
        transport.replyOK = false; transport.replyCode = "hardware_unavailable"
        transport.status = FanControlStatus(error: "hardware_unavailable")
        client.refresh()
        check(rpmField(0) === field0 && rpmField(1) === field1, "temporary empty fan snapshot keeps the original field objects")
        checkEditing(field0, editor, text: "27", selection: selection, event: "empty fan snapshot")
        check(!fixed.isEnabled && !boost.isEnabled, "cached draft rows never enable control for an empty snapshot")
        let unavailable = descendants(root, type: NSTextField.self).contains {
            $0.stringValue.contains("风扇 1") && ($0.stringValue.contains("--") || $0.stringValue.contains("未知"))
        }
        check(unavailable, "empty fan snapshot shows unknown readings rather than cached RPM")
        transport.replyOK = true; transport.replyCode = "ok"; transport.status = snapshot([0, 1], target: 4100)
        client.refresh()
        check(rpmField(0) === field0 && draft(field0) == "27", "valid readings returning do not replace the raw draft")

        transport.disconnect()
        check(!client.connected && !fixed.isEnabled, "connection loss keeps the submission freshness gate")
        checkEditing(field0, editor, text: "27", selection: selection, event: "connection loss")
        client.refresh()
        checkEditing(field0, editor, text: "27", selection: selection, event: "connection recovery")
        now = 107; controller.render()
        check(!client.statusFresh && !fixed.isEnabled && field0.isEnabled && draft(field0) == "27", "stale readings block submission while leaving the local draft editable")
        client.refresh()

        field1.stringValue = " 02800 "
        transport.status = snapshot([0, 1, 2]); client.refresh()
        let field2 = rpmField(2)!
        check(rpmField(0) === field0 && rpmField(1) === field1, "fan addition preserves surviving native field objects")
        check(draft(field0) == "27" && draft(field1) == " 02800 ", "fan addition preserves raw incomplete and whitespace drafts")
        transport.status = snapshot([0, 2]); client.refresh()
        check(rpmField(0) === field0 && rpmField(2) === field2 && rpmField(1) == nil, "fan removal keeps surviving objects and removes only the absent fan")
        check(draft(field0) == "27", "fan removal does not restore the old hardware target")

        field2.stringValue = "2800"
        let finalEditor = edit(field0, text: " 02700 ", selection: NSRange(location: 2, length: 2))
        check(fixed.isEnabled, "fresh valid topology enables the original submission gate")
        let previousRequestCount = transport.requests.count
        transport.delayReplies = true
        fixed.performClick(nil)
        check(transport.requests.count == previousRequestCount + 1 && transport.pending?.action == .fixed, "native Apply button sends exactly one fake fixed-RPM request")
        check(transport.pending?.targets == [0: 2700, 2: 2800], "Apply sends current editor drafts for only the present fan IDs")
        check(!fixed.isEnabled && field0.isEnabled && finalEditor.string == " 02700 ", "fixed-RPM submission locks the button without replacing its editable draft")
        transport.status = FanControlStatus(phase: .controlling, leaseID: "final-lease", ownedFanIDs: [0, 2], targets: [0: 2700, 2: 2800], leaseExpiresAt: 117,
            fans: [fan(0, target: 2700, automatic: false), fan(2, target: 2800, automatic: false)], cpuTemperature: 60, gpuTemperature: 55)
        transport.finishReply()
        check(draft(field0) == " 02700 " && draft(field2) == "2800", "confirmed fake control preserves the original raw drafts")
        check(!window.isVisible, "native regression never displays or activates a window")
        print("\(checks) fan input editing checks passed; hidden native AppKit, no real RPC, authorization or hardware writes")
    }
}
