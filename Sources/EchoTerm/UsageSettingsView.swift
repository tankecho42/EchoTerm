import SwiftUI
import Charts

struct AIRoundUsageView: View {
    let summary: AIRoundSummary
    let theme: TerminalTheme
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(theme.line).frame(height: 1)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 13) { tokens; timing }
                VStack(alignment: .leading, spacing: 6) { tokens; timing }
            }
            if summary.usage.missing > 0 {
                Text("\(summary.usage.missing) 次调用未完整返回用量，+ 表示仅统计已知部分。")
                    .font(.system(size: 9))
            }
        }.font(.system(size: 10)).monospacedDigit().foregroundStyle(theme.muted)
            .help("\(summary.model)\n整轮输入与输出之和，包含本轮全部模型调用。缓存读取 \(summary.usage.cached.formatted()) · 缓存写入 \(summary.usage.cacheWrite.formatted()) · 推理 \(summary.usage.reasoning.formatted())（均为子项，不额外相加）")
    }
    private var tokens: some View {
        HStack(spacing: 12) {
            Label("输入 \(summary.usage.inputLabel)", systemImage: "arrow.up")
            Label("输出 \(summary.usage.outputLabel)", systemImage: "arrow.down")
            Text("\(summary.usage.totalLabel) tokens")
        }
    }
    private var timing: some View {
        HStack(spacing: 10) {
            Label(summary.durationLabel, systemImage: "clock")
            if summary.usage.requests > 1 { Text("\(summary.usage.requests) 次调用") }
        }
    }
}

struct UsageSettingsView: View {
    @ObservedObject var usage: AIUsageStore
    let theme: TerminalTheme
    @State private var period: UsagePeriod = .day
    @State private var date = Date()
    private var records: [UsageRecord] { usage.filtered(period: period, date: date) }
    private var totals: UsageTotals { AIUsageStore.totals(records) }
    private var interval: DateInterval? { period.interval(containing: date) }
    private var rangeLabel: String {
        guard let interval else { return "所有时间" }
        switch period {
        case .day: return interval.start.formatted(.dateTime.year().month().day())
        case .month: return interval.start.formatted(.dateTime.year().month())
        case .week: return interval.start.formatted(.dateTime.month().day()) + " — " + interval.end.addingTimeInterval(-1).formatted(.dateTime.year().month().day())
        case .all: return "所有时间"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text("用量统计").font(.system(size: 21, weight: .medium))
                Text("对话、自动操作与快速判断，统一记录。")
                    .font(.system(size: 11)).foregroundStyle(theme.muted)
            }
            EchoSegments(selection: $period, choices: UsagePeriod.allCases.map { .init(value: $0, title: $0.rawValue) }, label: "统计范围")
            HStack(spacing: 12) {
                Text(rangeLabel).font(.system(size: 12, weight: .medium))
                Spacer()
                if period != .all {
                    Button { move(-1) } label: { Image(systemName: "chevron.left").frame(width: 26, height: 26).contentShape(Rectangle()) }.help("上一周期")
                    Button { date = Date() } label: { Text("今天").font(.system(size: 10)).padding(6).contentShape(Rectangle()) }
                    Button { move(1) } label: { Image(systemName: "chevron.right").frame(width: 26, height: 26).contentShape(Rectangle()) }
                        .disabled(interval.map { $0.end > Date() } ?? true).help("下一周期")
                }
            }.buttonStyle(.plain).foregroundStyle(theme.muted)
            HStack(spacing: 10) {
                metric("总 Token", value: totals.totalLabel, prominent: true)
                metric("输入", value: totals.inputLabel)
                metric("输出", value: totals.outputLabel)
            }
            HStack {
                Text("\(totals.requests.formatted()) 次模型调用")
                Spacer()
                if totals.missing > 0 { Text("\(totals.missing) 次用量不完整 · + 为已知部分") }
            }.font(.system(size: 10)).foregroundStyle(theme.muted)
            if records.isEmpty {
                VStack(spacing: 10) {
                    EchoPaw().fill(theme.accent.opacity(0.5)).frame(width: 24, height: 24)
                    Text("这段时间还没有调用记录").font(.system(size: 12))
                    Text("与 Echo 对话后，用量会出现在这里。")
                        .font(.system(size: 10)).foregroundStyle(theme.muted)
                }.frame(maxWidth: .infinity).padding(.vertical, 22)
            } else {
                chart
                modelBreakdown
                HStack(spacing: 14) {
                    ForEach(categories, id: \.0) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.0).foregroundStyle(theme.muted)
                            Text("\(item.1.requests) 次 · \(item.1.totalLabel)").monospacedDigit()
                        }.font(.system(size: 9))
                    }
                }
                if totals.cached + totals.cacheWrite + totals.reasoning > 0 {
                    Text("输入含缓存读取 \(totals.cached.formatted())、缓存写入 \(totals.cacheWrite.formatted())；输出含推理 \(totals.reasoning.formatted())。以上子项以接口返回为准。")
                        .font(.system(size: 10)).foregroundStyle(theme.muted).lineSpacing(3)
                }
            }
            Rectangle().fill(theme.line).frame(height: 1)
            Text("从本版本开始记录本机 EchoTerm 的调用，不回填历史用量。按本地时间及请求开始时间归档，每周从周一开始。接口未返回的用量不做估算；缓存和推理 Token 已包含在输入或输出中。")
                .font(.system(size: 10)).foregroundStyle(theme.muted).lineSpacing(4)
            if let error = usage.storageError { Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(.orange) }
        }
    }
    private func metric(_ title: String, value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 10)).foregroundStyle(theme.muted)
            Text(value).font(.system(size: 20, weight: .medium, design: .rounded)).monospacedDigit()
                .foregroundStyle(prominent ? theme.accent : theme.text).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(theme.text.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
    }
    private var models: [(String, UsageTotals)] {
        Dictionary(grouping: records) { "\($0.provider) · \($0.model)" }
            .map { ($0.key, AIUsageStore.totals($0.value)) }.sorted { $0.1.total > $1.1.total }
    }
    private var categories: [(String, UsageTotals)] {
        Dictionary(grouping: records, by: \.category).map { ($0.key, AIUsageStore.totals($0.value)) }.sorted { $0.0 < $1.0 }
    }
    private var modelBreakdown: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack { Text("按模型"); Spacer(); Text("输入 / 输出 · 总计") }.font(.system(size: 10)).foregroundStyle(theme.muted)
            ForEach(models, id: \.0) { item in
                HStack(spacing: 14) {
                    Text(item.0).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Text("\(item.1.inputLabel) / \(item.1.outputLabel) · \(item.1.totalLabel)").monospacedDigit().fixedSize()
                }.font(.system(size: 10))
            }
        }
    }
    private struct Bucket: Identifiable {
        var date: Date
        var total: UsageTotals
        var id: Date { date }
    }
    private var buckets: [Bucket] {
        let calendar = Calendar.current
        let unit: Calendar.Component = period == .day ? .hour : period == .all ? .month : .day
        let end = interval?.end ?? calendar.dateInterval(of: .month, for: Date())!.end
        let start = interval?.start ?? calendar.date(byAdding: .month, value: -12, to: end)!
        let groups = Dictionary(grouping: records.filter { $0.date >= start && $0.date < end }) {
            calendar.dateInterval(of: unit, for: $0.date)!.start
        }
        var result: [Bucket] = [], cursor = start
        while cursor < end, result.count < 366 {
            result.append(.init(date: cursor, total: AIUsageStore.totals(groups[cursor] ?? [])))
            guard let next = calendar.date(byAdding: unit, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return result
    }
    private var chart: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(period == .all ? "最近 12 个月的趋势 · 总计含全部历史" : "Token 分布")
                Spacer()
                Circle().fill(theme.accent).frame(width: 5, height: 5); Text("输入")
                Circle().fill(theme.accent.opacity(0.35)).frame(width: 5, height: 5); Text("输出")
            }.font(.system(size: 9)).foregroundStyle(theme.muted)
            Chart(buckets) { bucket in
                BarMark(x: .value("时间", bucket.date, unit: period == .day ? .hour : period == .all ? .month : .day), y: .value("Token", bucket.total.input))
                    .foregroundStyle(theme.accent)
                BarMark(x: .value("时间", bucket.date, unit: period == .day ? .hour : period == .all ? .month : .day), y: .value("Token", bucket.total.output))
                    .foregroundStyle(theme.accent.opacity(0.35))
            }.chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .frame(height: 120)
            if totals.missing > 0 { Text("图表仅包含已返回的 Token。").font(.system(size: 9)).foregroundStyle(theme.muted) }
        }
    }
    private func move(_ amount: Int) {
        if let next = Calendar.current.date(byAdding: period.component, value: amount, to: interval?.start ?? date) { date = next }
    }
}
