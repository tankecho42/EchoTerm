#if DEBUG
import Foundation

@MainActor enum UsageSelfTests {
    static func run(check: (Bool, String) -> Void) async throws {
        let chat = TokenUsage.parse(["prompt_tokens": 100, "completion_tokens": 30, "prompt_tokens_details": ["cached_tokens": 80], "completion_tokens_details": ["reasoning_tokens": 20]], api: .chatCompletions)
        check(chat?.total == 130 && chat?.cached == 80 && chat?.reasoning == 20, "OpenAI cache and reasoning details are subsets, never double-counted")
        let claude = TokenUsage.parse(["input_tokens": 10, "cache_read_input_tokens": 70, "cache_creation_input_tokens": 20, "output_tokens": 30], api: .anthropic)
        check(claude?.input == 100 && claude?.total == 130, "Claude input includes base input plus cache reads and writes")
        check(TokenUsage.parse(["prompt_tokens": true, "completion_tokens": -2], api: .chatCompletions) == nil && TokenUsage.count(1.5) == nil && TokenUsage.count(1e20) == nil, "Invalid, negative, boolean and out-of-range usage values remain unknown")
        let zero = TokenUsage.parse(["input_tokens": 0, "output_tokens": 0], api: .responses)
        check(zero?.total == 0 && TokenUsage.parse([:], api: .responses) == nil, "A true zero-token report differs from absent usage")
        var partial = UsageTotals(); partial.add(.init(input: 10)); partial.add(.init(output: 20))
        check(partial.missing == 2 && partial.inputLabel == "10+" && partial.outputLabel == "20+" && partial.totalLabel == "30+", "Mixed partial requests count all incomplete reports and label only known totals")
        var missing = UsageTotals(); missing.add(nil)
        check(missing.inputLabel == "未返回" && missing.totalLabel == "未返回", "Missing usage is not presented as zero")

        var stream = AIStreamAccumulator(apiProtocol: .anthropic)
        try feed(["type": "message_start", "message": ["usage": ["input_tokens": 10, "cache_read_input_tokens": 70, "cache_creation_input_tokens": 20, "output_tokens": 1]]], to: &stream)
        try feed(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 15]], to: &stream)
        try feed(["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 30]], to: &stream)
        try feed(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "finished"]], to: &stream)
        try feed(["type": "message_stop"], to: &stream)
        check(try stream.finish().usage?.total == 130, "Claude cumulative deltas replace output counts and retain start-event cache usage")
        let meter = AIRoundMeter(), request = UUID()
        meter.begin(request); meter.update(request, usage: chat); meter.update(request, usage: chat)
        check(meter.summary(model: "test").usage.total == 130, "Repeated streaming/final usage snapshots count once per request")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EchoTerm-usage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("ledger.jsonl"), store = AIUsageStore(fileURL: url)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let march = calendar.date(from: .init(year: 2026, month: 3, day: 8, hour: 12))!
        let day = UsagePeriod.day.interval(containing: march, calendar: calendar)!
        check(day.duration == 23 * 3600, "Day filters follow local daylight-saving boundaries")
        for (offset, date) in [day.start.addingTimeInterval(-1), day.start, day.end.addingTimeInterval(-1), day.end].enumerated() {
            let record = UsageRecord(id: UUID(), date: date, provider: "fixture", model: "primary", category: "对话与操作", usage: chat, elapsed: Double(offset), outcome: "完成")
            store.record(record); store.record(record)
        }
        check(store.records.count == 4 && store.filtered(period: .day, date: march, calendar: calendar).count == 2, "Ledger deduplicates request IDs and uses inclusive start / exclusive end")
        check(store.filtered(period: .week, date: march, calendar: calendar).count == 3 && store.filtered(period: .month, date: march, calendar: calendar).count == 4 && store.filtered(period: .all, date: march).count == 4, "Monday weeks, month and all-time filters select their complete ranges")
        let loaded = AIUsageStore(fileURL: url)
        check(loaded.records.count == 4 && AIUsageStore.totals(loaded.records).total == 520, "Token totals persist across app restarts")
        let file = try FileHandle(forWritingTo: url); try file.seekToEnd(); try file.write(contentsOf: Data("truncated".utf8)); try file.close()
        let recovered = AIUsageStore(fileURL: url)
        recovered.record(.init(id: UUID(), date: march, provider: "fixture", model: "fast", category: "快速意图", usage: nil, elapsed: 1, outcome: "失败"))
        let repaired = AIUsageStore(fileURL: url)
        check(repaired.records.count == 5 && repaired.storageError != nil && AIUsageStore.totals(repaired.records).missing == 1, "A truncated ledger record preserves valid history and subsequent appends")
        let contents = try String(contentsOf: url)
        check(!contents.contains("messages") && !contents.contains("api_key") && !contents.contains("context"), "Usage persistence stores metadata without conversation content or credentials")

        let suite = "EchoTerm.Usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults), providers = ProviderStore(defaults: defaults)
        preferences.quickIntents = false
        providers.configurations = [.init(id: "usage-fixture", name: "fixture", endpoint: "http://localhost/v1", model: "primary", apiProtocol: .chatCompletions, quickModel: "fast")]
        providers.selectedID = "usage-fixture"
        var compatible = providers.selected
        let included = try JSONSerialization.jsonObject(with: AIClient.request(config: compatible, key: "", messages: [], context: "").httpBody!) as! [String: Any]
        compatible.includeStreamUsage = false
        let excluded = try JSONSerialization.jsonObject(with: AIClient.request(config: compatible, key: "", messages: [], context: "").httpBody!) as! [String: Any]
        check((included["stream_options"] as? [String: Bool])?["include_usage"] == true && excluded["stream_options"] == nil, "Chat streams request final usage with an opt-out for older compatible gateways")
        let auxiliary = AIUsageStore()
        let wrapped = AIUsageRecorder.wrap({ _, update in
            update(.init(text: "", phase: "", usage: chat)); return .init(text: "done", usage: chat)
        }, store: auxiliary)
        for purpose in [AIRequestPurpose.intent, .tabTitle] {
            _ = try await wrapped(.init(config: providers.selected, messages: [], context: "", mode: .answer, streaming: false, purpose: purpose)) { _ in }
        }
        check(auxiliary.records.count == 2 && auxiliary.records.allSatisfy { $0.model == "fast" } && Set(auxiliary.records.map(\.category)).count == 2 && AIUsageStore.totals(auxiliary.records).total == 260, "Fast intents and title requests use their actual model and count once globally")

        let session = TerminalSession(directory: "/tmp", loadShellConfig: false)
        session.usesBlockEditor = true; session.start(); defer { session.close() }
        try await wait { session.ready }
        session.defaultAssistantMode = .autonomous
        var calls = 0
        let roundStore = AIUsageStore()
        let assistant = AssistantStore(providers: providers, preferences: preferences, transport: { _, update in
            calls += 1
            update(.init(text: "working", phase: "", usage: chat))
            if calls <= 2 {
                let args = #"{"command":"printf 'usage-test\n'","explanation":"test","risk":"read"}"#
                return .init(text: "step", calls: [.init(id: "usage-\(calls)", name: AIClient.executeTool, arguments: args)], usage: chat)
            }
            return .init(text: "finished", usage: chat)
        }, usage: roundStore)
        assistant.ask("check", session: session)
        try await wait { !assistant.thinking.contains(session.id) }
        let messages = assistant.messages(for: session), summary = messages.last?.roundSummary
        check(summary?.usage.total == 390 && summary?.usage.requests == 3 && roundStore.records.count == 3, "A full autonomous turn sums all API calls including the final answer")
        check(messages.filter { $0.roundSummary != nil }.count == 1 && messages.last?.text == "finished" && summary!.elapsed > 0, "Only the final AI block carries whole-turn usage and elapsed time")
        session.defaultAssistantMode = .answer
        let failure = AssistantStore(providers: providers, preferences: preferences, transport: { _, update in
            update(.init(text: "partial", phase: "", usage: .init(input: 10)))
            throw AIError.message("fixture disconnected")
        }, usage: roundStore)
        failure.ask("fail", session: session); try await wait { !failure.thinking.contains(session.id) }
        check(failure.messages(for: session).last?.roundSummary?.usage.input == 10 && roundStore.records.last?.outcome == "失败", "Failed streams retain already-reported usage instead of discarding consumed input")
        let cancelled = AssistantStore(providers: providers, preferences: preferences, transport: { _, update in
            update(.init(text: "partial", phase: "", usage: .init(input: 20)))
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return .init(text: "late")
        }, usage: roundStore)
        cancelled.ask("stop", session: session); try await wait { cancelled.messages(for: session).last?.text == "partial" }
        cancelled.cancel(session: session); try await wait { roundStore.records.last?.outcome == "已停止" }
        check(cancelled.messages(for: session).last?.roundSummary?.usage.input == 20 && cancelled.messages(for: session).last?.roundSummary?.usage.missing == 1, "Manual stop freezes a partial round summary and records the cancelled request")
        for theme in TerminalTheme.allCases {
            preferences.theme = theme
            check(Preferences(defaults: defaults).theme == theme && theme.ansiColors.count == 16, "\(theme.rawValue) theme persists with a complete ANSI palette")
        }
    }
    private static func feed(_ object: [String: Any], to stream: inout AIStreamAccumulator) throws {
        try stream.consume(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 { if predicate() { return }; try await Task.sleep(nanoseconds: 25_000_000) }
        throw AIError.message("Usage test timed out")
    }
}
#endif
