import Foundation

@main struct AgentSpeedChecks {
    static func main() throws {
        var count = 0
        func check(_ result: Bool, _ name: String) { precondition(result, name); count += 1; print("PASS: \(name)") }
        func line(_ object: [String: Any]) -> String {
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }
        func data(_ rows: [[String: Any]]) -> Data {
            Data(rows.map(line).joined(separator: "\n").utf8)
        }

        // MARK: WorkBuddy

        func wbStep(_ id: String, _ output: Int, _ at: Int) -> [String: Any] {
            [
                "type": "reasoning",
                "timestamp": at,
                "providerData": [
                    "messageId": id,
                    "stepSeq": 1,
                    "model": "test-model",
                    "rawUsage": ["completion_tokens": output, "prompt_tokens": 1000],
                ],
            ]
        }

        let basic = WorkBuddyTranscriptParser.parse(data([
            ["type": "message", "role": "user", "timestamp": 1000],
            wbStep("m1", 100, 3000),
        ]))
        check(basic.steps.count == 1, "wb single step parsed")
        check(abs((basic.steps[0].speed ?? 0) - 50) < 0.001, "wb speed = tokens / duration")
        check(basic.outputTokens == 100, "wb output tokens summed")
        check(basic.latestActivity == Date(timeIntervalSince1970: 3), "wb latest activity")
        check(basic.steps[0].model == "test-model", "wb model captured")

        let chained = WorkBuddyTranscriptParser.parse(data([
            ["type": "message", "role": "user", "timestamp": 1000],
            wbStep("m1", 100, 3000),
            ["type": "function_call", "callId": "c1", "timestamp": 3000],
            ["type": "function_call_result", "callId": "c1", "timestamp": 4000],
            wbStep("m2", 200, 5000),
        ]))
        check(chained.steps.count == 2, "wb two steps")
        check(abs((chained.steps[1].speed ?? 0) - 200) < 0.001, "wb tool time excluded")
        check(chained.pendingToolCalls == 0, "wb resolved tool not pending")

        let pendingWB = WorkBuddyTranscriptParser.parse(data([
            ["type": "message", "role": "user", "timestamp": 1000],
            wbStep("m1", 100, 3000),
            ["type": "function_call", "callId": "c2", "timestamp": 3000],
        ]))
        check(pendingWB.pendingToolCalls == 1, "wb unresolved tool pending")

        let tiny = WorkBuddyTranscriptParser.parse(data([
            ["type": "message", "role": "user", "timestamp": 1000],
            wbStep("m1", 3, 2000),
            ["type": "function_call_result", "callId": "z", "timestamp": 3000],
            wbStep("m2", 100, 3000),
        ]))
        check(tiny.steps[0].speed == nil, "wb tiny output has no speed")
        check(tiny.steps[1].speed == nil, "wb zero duration has no speed")

        let truncated = WorkBuddyTranscriptParser.parse(Data("""
        {"type":"reasoning","timestamp":99,"providerD
        {"type":"message","role":"user","timestamp":1000}
        {"type":"reasoning","timestamp":3000,"providerData":{"messageId":"m1","stepSeq":1,"model":"m","rawUsage":{"completion_tokens":100}}}
        """.utf8))
        check(truncated.steps.count == 1, "wb truncated line skipped")

        // MARK: Codex

        func codexUsage(_ output: Int, _ iso: String) -> [String: Any] {
            ["type": "token_usage_record", "timestamp": iso, "payload": ["usage": ["output_tokens": output]]]
        }
        func codexItem(_ type: String, _ iso: String, callID: String? = nil) -> [String: Any] {
            var payload: [String: Any] = ["type": type]
            if let callID { payload["call_id"] = callID }
            return ["type": "response_item", "timestamp": iso, "payload": payload]
        }
        let context: [String: Any] = [
            "type": "turn_context",
            "timestamp": "2026-10-13T03:53:01.500Z",
            "payload": ["model": "gpt-6.1-sol"],
        ]
        let started: [String: Any] = [
            "type": "event_msg",
            "timestamp": "2026-10-13T03:53:02.000Z",
            "payload": ["type": "task_started"],
        ]

        let codex = CodexTranscriptParser.parse(data([
            context,
            started,
            codexUsage(100, "2026-10-13T03:53:12.000Z"),
            codexItem("function_call", "2026-10-13T03:53:12.100Z", callID: "c1"),
            codexItem("function_call_output", "2026-10-13T03:53:22.000Z", callID: "c1"),
            codexUsage(200, "2026-10-13T03:53:32.000Z"),
        ]))
        check(codex.steps.count == 2, "codex two responses")
        check(abs((codex.steps[0].speed ?? 0) - 10) < 0.001, "codex speed from task start")
        check(abs((codex.steps[1].speed ?? 0) - 20) < 0.001, "codex tool time excluded")
        check(codex.steps[0].model == "gpt-6.1-sol", "codex model from turn context")
        check(codex.outputTokens == 300, "codex output tokens summed")
        check(codex.pendingToolCalls == 0, "codex resolved tool not pending")
        check(codex.latestActivity == codex.steps[1].endedAt, "codex latest activity")

        let codexPending = CodexTranscriptParser.parse(data([
            context,
            started,
            codexUsage(100, "2026-10-13T03:53:12.000Z"),
            codexItem("custom_tool_call", "2026-10-13T03:53:12.100Z", callID: "c9"),
        ]))
        check(codexPending.pendingToolCalls == 1, "codex unresolved tool pending")

        let codexNoAnchor = CodexTranscriptParser.parse(data([
            context,
            codexUsage(100, "2026-10-13T03:53:12.000Z"),
        ]))
        check(codexNoAnchor.steps.count == 1 && codexNoAnchor.steps[0].speed == nil, "codex without anchor has no speed")

        // MARK: 快照与合集

        let now = Date()
        let international = AgentSpeedSnapshot(
            source: .workbuddyInternational, state: .running, speed: 86.34, model: "deepseek-v4.1-flash",
            outputTokens: 100, updatedAt: now, detail: "deepseek-v4.1-flash · 100 词元"
        )
        check(international.touchBarText == "WB 86", "international touch bar text")
        check(international.rowText == "国际版 · 86.3 t/s", "international row text")
        check(international.menuText.hasPrefix("WorkBuddy 国际版：86.3 t/s"), "international menu text")

        let domestic = AgentSpeedSnapshot(
            source: .workbuddyDomestic, state: .completed, speed: 60, model: nil,
            outputTokens: 0, updatedAt: now.addingTimeInterval(-60), detail: ""
        )
        check(domestic.touchBarText == "WB·CN 60", "domestic touch bar text")
        check(domestic.rowText == "国内版 · 60.0 t/s", "domestic row text")

        let codexSnapshot = AgentSpeedSnapshot(
            source: .codex, state: .running, speed: 22.5, model: "gpt-6.1-sol",
            outputTokens: 0, updatedAt: now.addingTimeInterval(-1), detail: ""
        )
        check(codexSnapshot.touchBarText == "CX 23", "codex touch bar text")
        check(codexSnapshot.rowText == "Codex · 22.5 t/s", "codex row text")

        let stale = AgentSpeedSnapshot(
            source: .codex, state: .stale, speed: nil, model: nil,
            outputTokens: 0, updatedAt: now.addingTimeInterval(-3600), detail: ""
        )
        check(stale.rowText == "Codex · 过期", "stale row text")
        check(stale.needsAttention, "stale needs attention")
        check(AgentSpeedSnapshot.idle(.codex).rowText == "Codex · 待命", "idle row text")

        // 国际版五分钟前、国内版一分钟前、Codex 刚刚 → 主显示取 Codex
        let olderInternational = AgentSpeedSnapshot(
            source: .workbuddyInternational, state: .completed, speed: 86.34, model: "deepseek-v4.1-flash",
            outputTokens: 100, updatedAt: now.addingTimeInterval(-300), detail: ""
        )
        let bundle = AgentSpeedBundle(snapshots: [olderInternational, domestic, codexSnapshot])
        check(bundle.primary.source == .codex, "bundle primary is most recent")
        check(bundle.touchBarText == "CX 23", "bundle touch bar follows primary")
        check(bundle.snapshot(for: .workbuddyDomestic).speed == 60, "bundle lookup by source")
        check(bundle.activeCount == 1, "bundle counts running sources")

        // 全部过期时退回到最近有活动的那个
        let allStale = AgentSpeedBundle(snapshots: [
            stale,
            AgentSpeedSnapshot(source: .workbuddyDomestic, state: .stale, speed: nil, model: nil,
                               outputTokens: 0, updatedAt: now.addingTimeInterval(-7200), detail: ""),
            AgentSpeedSnapshot(source: .workbuddyInternational, state: .stale, speed: nil, model: nil,
                               outputTokens: 0, updatedAt: now.addingTimeInterval(-1800), detail: ""),
        ])
        check(allStale.primary.source == .workbuddyInternational, "all stale falls back to most recent")
        check(AgentSpeedBundle.idle.snapshots.count == 3, "idle bundle covers three sources")

        // MARK: 来源路径

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("goodtouchbar-fixture-\(UUID().uuidString)")
        check(AgentSpeedSource.workbuddyInternational.root(home: home).path == home.appendingPathComponent(".workbuddy-ai/projects").path, "international root")
        check(AgentSpeedSource.workbuddyDomestic.root(home: home).path == home.appendingPathComponent(".workbuddy/projects").path, "domestic root")
        check(AgentSpeedSource.codex.root(home: home).path == home.appendingPathComponent(".codex/sessions").path, "codex root")
        check(AgentSpeedSource.allCases.count == 3, "three sources covered")
        check(AgentSpeedSource.codex.fileNamePrefix == "rollout-", "codex only reads rollouts")
        check(AgentSpeedSource.workbuddyDomestic.fileNamePrefix == nil, "workbuddy reads every jsonl")

        print("AgentSpeedChecks: \(count) passed")
    }
}
