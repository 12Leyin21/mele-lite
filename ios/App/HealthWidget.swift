import HealthKit
import SwiftUI

// MARK: - 健康小组件（10-04 Tilia）：默认步数，点卡选显示哪一项。
// 小号 = 今天的数；中号 / 大号 = 再加最近 7 天的小柱子（心率只给最近一次）。只读苹果健康，不往外传。

enum HealthMetric: String, CaseIterable, Identifiable {
    case steps, distance, energy, sleep, heartRate

    var id: String { rawValue }
    var title: String {
        switch self {
        case .steps: return String(localized: "步数")
        case .distance: return String(localized: "走了多远")
        case .energy: return String(localized: "活动消耗")
        case .sleep: return String(localized: "睡眠")
        case .heartRate: return String(localized: "心率")
        }
    }
    var unit: String {
        switch self {
        case .steps: return String(localized: "步")
        case .distance: return "km"
        case .energy: return String(localized: "千卡")
        case .sleep: return String(localized: "小时")
        case .heartRate: return "bpm"
        }
    }
    var icon: String {
        switch self {
        case .steps: return "figure.walk"
        case .distance: return "map"
        case .energy: return "flame"
        case .sleep: return "moon.zzz"
        case .heartRate: return "heart"
        }
    }
    func format(_ v: Double) -> String {
        switch self {
        case .distance, .sleep: return String(format: "%.1f", v)
        default: return "\(Int(v.rounded()))"
        }
    }
}

@MainActor
final class HealthWidgetData: ObservableObject {
    static let shared = HealthWidgetData()
    private let store = HKHealthStore()
    /// 每一项：最近 7 天（旧 → 新），最后一个是今天（睡眠是昨晚）
    @Published var week: [HealthMetric: [Double]] = [:]

    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.stepCount), HKQuantityType(.distanceWalkingRunning), HKQuantityType(.activeEnergyBurned),
         HKQuantityType(.heartRate), HKCategoryType(.sleepAnalysis)]
    }

    func load(_ m: HealthMetric) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try? await store.requestAuthorization(toShare: [], read: readTypes)
        switch m {
        case .steps: week[m] = await daily(.stepCount, .count())
        case .distance: week[m] = await daily(.distanceWalkingRunning, .meterUnit(with: .kilo))
        case .energy: week[m] = await daily(.activeEnergyBurned, .kilocalorie())
        case .sleep: week[m] = await nights()
        case .heartRate: week[m] = [await latestHeartRate() ?? 0]
        }
    }

    /// 最近 7 天每天的总和
    private func daily(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async -> [Double] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -6, to: today) else { return [] }
        return await withCheckedContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: HKQuantityType(id),
                                                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: Date()),
                                                options: .cumulativeSum, anchorDate: start, intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, result, _ in
                var out: [Double] = []
                result?.enumerateStatistics(from: start, to: Date()) { s, _ in
                    out.append(s.sumQuantity()?.doubleValue(for: unit) ?? 0)
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    /// 最近 7 晚睡了几小时（前一天 18 点到当天 12 点算一晚）
    private func nights() async -> [Double] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [Double] = []
        for back in stride(from: 6, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -back, to: today),
                  let from = cal.date(byAdding: .hour, value: -6, to: day),
                  let to = cal.date(byAdding: .hour, value: 12, to: day) else { continue }
            out.append(await asleepHours(from: from, to: to))
        }
        return out
    }

    private func asleepHours(from: Date, to: Date) async -> Double {
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        return await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: HKQuery.predicateForSamples(withStart: from, end: to),
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                let secs = (samples as? [HKCategorySample] ?? []).filter { asleep.contains($0.value) }
                    .reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
                cont.resume(returning: secs / 3600)
            }
            store.execute(q)
        }
    }

    private func latestHeartRate() async -> Double? {
        await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKQuantityType(.heartRate), predicate: nil, limit: 1,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, _ in
                let v = (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                cont.resume(returning: v)
            }
            store.execute(q)
        }
    }
}

struct HealthCard: View {
    @EnvironmentObject private var theme: AppTheme
    @ObservedObject private var data = HealthWidgetData.shared
    let metric: HealthMetric
    let size: WidgetSize
    var onPick: (HealthMetric) -> Void = { _ in }
    @State private var choosing = false

    private var values: [Double] { data.week[metric] ?? [] }
    private var today: Double { values.last ?? 0 }

    var body: some View {
        Button { choosing = true } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(metric.title).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    Spacer()
                    Image(systemName: metric.icon).font(Typo.icon(14)).foregroundStyle(theme.accent)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(metric.format(today))
                        .font(Typo.accent(size == .large ? Typo.Size.largeTitle * 1.6 : Typo.Size.largeTitle))
                        .foregroundStyle(theme.ink)
                        .contentTransition(.numericText())
                    Text(metric.unit).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.inkDim)
                }
                Spacer(minLength: 0)
                if size != .small && metric != .heartRate && values.count > 1 {
                    bars.frame(height: size == .large ? 120 : 44)
                    Text(metric == .sleep ? String(localized: "最近 7 晚") : String(localized: "最近 7 天"))
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                } else {
                    Text(metric == .sleep ? String(localized: "昨晚") : metric == .heartRate ? String(localized: "最近一次") : String(localized: "今天"))
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: metric) { await data.load(metric) }
        .confirmationDialog("显示哪一项", isPresented: $choosing, titleVisibility: .visible) {
            ForEach(HealthMetric.allCases) { m in Button(m.title) { onPick(m) } }
        }
    }

    /// 7 根柱子：今天那根主题色，其余是主题色淡一档
    private var bars: some View {
        let top = max(values.max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                RoundedRectangle(cornerRadius: 3)
                    .fill(i == values.count - 1 ? theme.accent : theme.accent.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, CGFloat(v / top) * (size == .large ? 120 : 44)))
            }
        }
    }
}
