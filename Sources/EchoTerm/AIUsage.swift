import Foundation
import Combine
import CoreFoundation

/// Optional fields distinguish an absent report from a real zero-token response.
struct TokenUsage: Codable, Equatable {
    var input: Int?
    var output: Int?
    var cached: Int?
    var cacheWrite: Int?
    var reasoning: Int?
    var total: Int? { guard let input, let output else { return nil }; return input + output }
    var reported: Bool { input != nil || output != nil }
    static func count(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        guard v.isFinite, v >= 0, v <= 1_000_000_000_000, v.rounded(.down) == v else { return nil }
        return Int(v)
    }
    static func parse(_ value: Any?, api: APIProtocol) -> Self? {
        guard let u = value as? [String: Any] else { return nil }
        let inputDetails = (u["input_tokens_details"] ?? u["prompt_tokens_details"]) as? [String: Any] ?? [:]
        let outputDetails = (u["output_tokens_details"] ?? u["completion_tokens_details"]) as? [String: Any] ?? [:]
        let read = count(api == .anthropic ? u["cache_read_input_tokens"] : inputDetails["cached_tokens"] ?? u["prompt_cache_hit_tokens"])
        let write = count(api == .anthropic ? u["cache_creation_input_tokens"] : inputDetails["cache_write_tokens"])
        var input = count(api == .chatCompletions ? u["prompt_tokens"] : u["input_tokens"])
        // Claude's base input excludes cache reads/writes. OpenAI's includes them.
        if api == .anthropic, let base = input { input = base + (read ?? 0) + (write ?? 0) }
        let result = Self(input: input, output: count(api == .chatCompletions ? u["completion_tokens"] : u["output_tokens"]), cached: read, cacheWrite: write, reasoning: count(outputDetails["reasoning_tokens"]))
        return result.reported ? result : nil
    }
    /// Streaming usage is a cumulative snapshot, not a delta to add repeatedly.
    func merging(_ next: Self?) -> Self {
        guard let next else { return self }
        return Self(input: next.input ?? input, output: next.output ?? output, cached: next.cached ?? cached, cacheWrite: next.cacheWrite ?? cacheWrite, reasoning: next.reasoning ?? reasoning)
    }
}

struct UsageTotals {
    var input = 0, output = 0, cached = 0, cacheWrite = 0, reasoning = 0
    var requests = 0, inputReports = 0, outputReports = 0, missing = 0
    var elapsed: Double = 0
    var total: Int { input + output }
    mutating func add(_ usage: TokenUsage?, elapsed: Double = 0) {
        requests += 1; self.elapsed += elapsed
        if usage?.input == nil || usage?.output == nil { missing += 1 }
        if let n = usage?.input { input += n; inputReports += 1 }
        if let n = usage?.output { output += n; outputReports += 1 }
        cached += usage?.cached ?? 0; cacheWrite += usage?.cacheWrite ?? 0; reasoning += usage?.reasoning ?? 0
    }
    var inputLabel: String { inputReports == 0 && requests > 0 ? "未返回" : input.formatted() + (inputReports < requests ? "+" : "") }
    var totalLabel: String { inputReports + outputReports == 0 && requests > 0 ? "未返回" : total.formatted() + (missing > 0 ? "+" : "") }
    var outputLabel: String { outputReports == 0 && requests > 0 ? "未返回" : output.formatted() + (outputReports < requests ? "+" : "") }
}

struct AIRoundSummary {
    var usage: UsageTotals
    var elapsed: Double
    var model: String
    var durationLabel: String { elapsed >= 60 ? String(format: "%d分 %02d秒", Int(elapsed) / 60, Int(elapsed) % 60) : String(format: "%.1f 秒", elapsed) }
}

@MainActor final class AIRoundMeter {
    private let started = ProcessInfo.processInfo.systemUptime
    private var requests: [UUID: TokenUsage?] = [:]
    func begin(_ id: UUID) { requests[id] = .some(nil) }
    func update(_ id: UUID, usage: TokenUsage?) {
        guard requests.keys.contains(id), let usage else { return }
        requests[id] = .some((requests[id] ?? nil)?.merging(usage) ?? usage)
    }
    func summary(model: String) -> AIRoundSummary {
        var total = UsageTotals(); for usage in requests.values { total.add(usage) }
        return .init(usage: total, elapsed: max(0, ProcessInfo.processInfo.systemUptime - started), model: model)
    }
}

struct UsageRecord: Codable, Identifiable {
    var id: UUID
    var date: Date
    var provider: String
    var model: String
    var category: String
    var usage: TokenUsage?
    var elapsed: Double
    var outcome: String
}

enum UsagePeriod: String, CaseIterable, Identifiable {
    case day = "按天", week = "按周", month = "按月", all = "总计"
    var id: String { rawValue }
    var component: Calendar.Component { switch self { case .day: return .day; case .week: return .weekOfYear; case .month, .all: return .month } }
    func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard self != .all else { return nil }
        var calendar = calendar; calendar.firstWeekday = 2; calendar.minimumDaysInFirstWeek = 4
        return calendar.dateInterval(of: component, for: date)
    }
}

@MainActor final class AIUsageStore: ObservableObject {
    @Published private(set) var records: [UsageRecord] = []
    @Published private(set) var storageError: String?
    private var ids: Set<UUID> = []
    private let fileURL: URL?
    static var defaultURL: URL {
        let id = Bundle.main.bundleIdentifier ?? "app.echoterm.development"
        let directory = id == "app.echoterm.desktop" ? "EchoTerm" : id
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(directory).appendingPathComponent("Usage/events.jsonl")
    }
    /// nil is an in-memory ledger, used by tests; only the app supplies defaultURL.
    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            for line in data.split(separator: 10) where !line.isEmpty {
                if let item = try? JSONDecoder().decode(UsageRecord.self, from: Data(line)) {
                    if ids.insert(item.id).inserted { records.append(item) }
                } else { storageError = "部分用量记录无法读取，已保留原文件。当前统计只包含可读取记录。" }
            }
        } catch { storageError = "用量历史暂时无法读取；本次统计保留在内存中。" }
    }
    func record(_ record: UsageRecord) {
        guard ids.insert(record.id).inserted else { return }
        records.append(record)
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoded = try JSONEncoder().encode(record)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                guard FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: fileURL); defer { try? handle.close() }
            try handle.seekToEnd()
            // A leading newline isolates a truncated last record after an abrupt exit.
            try handle.write(contentsOf: Data([10]) + encoded + Data([10]))
            try handle.synchronize()
        } catch { storageError = "用量记录未能保存到磁盘；本次统计仍保留在内存中。" }
    }
    func filtered(period: UsagePeriod, date: Date, calendar: Calendar = .current) -> [UsageRecord] {
        guard let interval = period.interval(containing: date, calendar: calendar) else { return records }
        return records.filter { $0.date >= interval.start && $0.date < interval.end }
    }
    static func totals(_ records: [UsageRecord]) -> UsageTotals {
        var result = UsageTotals(); for record in records { result.add(record.usage, elapsed: record.elapsed) }; return result
    }
}

@MainActor enum AIUsageRecorder {
    static func wrap(_ transport: @escaping AITransport, store: AIUsageStore?) -> AITransport {
        { request, update in
            let id = UUID(), date = Date(), start = ProcessInfo.processInfo.systemUptime
            var usage: TokenUsage?, outcome = "中断"
            request.round?.begin(id)
            defer {
                let model = request.purpose == .conversation ? request.config.model : request.config.fastConfiguration.model
                store?.record(.init(id: id, date: date, provider: request.config.name, model: model, category: request.usageCategory ?? request.purpose.usageTitle, usage: usage, elapsed: max(0, ProcessInfo.processInfo.systemUptime - start), outcome: outcome))
            }
            do {
                let reply = try await transport(request) { value in
                    if let incoming = value.usage { usage = usage?.merging(incoming) ?? incoming; request.round?.update(id, usage: usage) }
                    update(value)
                }
                usage = usage?.merging(reply.usage) ?? reply.usage; request.round?.update(id, usage: usage)
                outcome = Task.isCancelled ? "已停止" : "完成"
                return reply
            } catch { outcome = Task.isCancelled || error is CancellationError ? "已停止" : "失败"; throw error }
        }
    }
}

extension AIRequestPurpose {
    var usageTitle: String { switch self { case .conversation: return "对话与操作"; case .intent: return "快速意图"; case .tabTitle: return "会话命名" } }
}
