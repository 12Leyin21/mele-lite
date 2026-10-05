import SwiftUI

// MARK: - 钱包记账（10-02，服务器 server/api/routes_wallet.py）
//
// Tilia要的：能切人民币（齿轮里换币种）、支出和收入都记、它偶尔提一句（服务器〔钱包〕）、
// 每天点一下刷卡机小图标打出一张小票（那天的支出 + 收入）、标签自己写——写过的存进标签栏，下次直接点，显示按标签归类。
// 一页：月份 · 这个月花了多少（收入、结余、跟上个月比）· 预算条 · 按标签分 · 按天列。右上角 ＋ 记一笔。

extension Notification.Name {
    static let lumiOpenWallet = Notification.Name("LumiOpenWallet")
}

struct WalletEntryDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let kind: String                // out 支出 / in 收入
    let amount: Int                 // 分
    let category: String            // 标签
    let note: String
    let day: String                 // yyyy-MM-dd
    let author: String

    var isIncome: Bool { kind == "in" }
}

struct WalletCustomDTO: Decodable, Hashable {
    var out: [String]
    var `in`: [String]
}

struct WalletMonthDTO: Decodable {
    let month: String
    let total: Int
    let income: Int
    let net: Int
    let lastMonth: Int
    let byCategory: [[WalletCell]]
    let byIncome: [[WalletCell]]
    let entries: [WalletEntryDTO]
    let currency: String
    let symbol: String
    let budget: Int
    let categories: [String]
    let incomeCategories: [String]
    let custom: WalletCustomDTO

    enum CodingKeys: String, CodingKey {
        case month, total, income, net, entries, currency, symbol, budget, categories, custom
        case lastMonth = "last_month", byCategory = "by_category", byIncome = "by_income", incomeCategories = "income_categories"
    }
}

struct WalletReceiptDTO: Decodable, Identifiable {
    let day: String
    let no: Int
    let entries: [WalletEntryDTO]
    let out: Int
    let income: Int
    let net: Int
    let currency: String
    let symbol: String
    var id: String { day }
}

/// by_category 是 [[标签, 金额]]：一格可能是字也可能是数
enum WalletCell: Decodable, Hashable {
    case text(String), number(Int)
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Int.self) { self = .number(n) } else { self = .text(try c.decode(String.self)) }
    }
    var text: String { if case .text(let s) = self { return s }; return "" }
    var number: Int { if case .number(let n) = self { return n }; return 0 }
}

enum WalletFormat {
    static func money(_ cents: Int, _ symbol: String) -> String {
        let v = Double(abs(cents)) / 100
        let s = v.truncatingRemainder(dividingBy: 1) == 0 ? String(format: "%.0f", v) : String(format: "%.2f", v)
        return (cents < 0 ? "-" : "") + symbol + s
    }

    /// 小票上的数：两位小数、不带符号
    static func plain(_ cents: Int) -> String { String(format: "%.2f", Double(cents) / 100) }

    static func icon(_ tag: String, income: Bool = false) -> String {
        switch tag {
        case "吃饭": "fork.knife"
        case "交通": "tram"
        case "购物": "bag"
        case "娱乐": "gamecontroller"
        case "学习": "book"
        case "其他": "ellipsis.circle"
        case "零花钱": "banknote"
        case "打工": "briefcase"
        case "红包": "gift"
        default: income ? "arrow.down.circle" : "tag"
        }
    }

    static let monthKey: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM"; return f
    }()
    static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; return f
    }()
}

struct WalletView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var month = Date()
    @State private var data: WalletMonthDTO?
    @State private var adding = false
    @State private var editing: WalletEntryDTO?
    @State private var receipt: WalletReceiptDTO?
    @State private var showSettings = false
    @State private var error: String?

    private var api: APIClient { session.api }
    private var symbol: String { data?.symbol ?? "A$" }
    private let incomeColor = Color(red: 0.25, green: 0.55, blue: 0.50)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monthBar
                    if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
                    if let d = data {
                        summary(d)
                        if !d.byCategory.isEmpty { breakdown(d.byCategory, total: d.total, title: String(localized: "花在哪")) }
                        if !d.byIncome.isEmpty { breakdown(d.byIncome, total: d.income, title: String(localized: "从哪来"), income: true) }
                        days(d)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                }
                .padding(20)
            }
            .background(AppBackground())
            .navigationTitle("钱包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        Button { adding = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $adding) { editor(nil) }
            .sheet(item: $editing) { e in editor(e) }
            .sheet(item: $receipt) { r in
                ReceiptSheet(receipt: r).environmentObject(theme).presentationDetents([.large])
            }
            .sheet(isPresented: $showSettings) {
                WalletSettingsView(data: data) { await load() }.environmentObject(session).environmentObject(theme)
            }
        }
        .environment(\.colorScheme, .light)
        .task(id: WalletFormat.monthKey.string(from: month)) { await load() }
    }

    private func editor(_ e: WalletEntryDTO?) -> some View {
        WalletEntryEditor(entry: e, outTags: data?.categories ?? [], inTags: data?.incomeCategories ?? [], symbol: symbol) { await load() }
            .environmentObject(session).environmentObject(theme)
            .presentationDetents([.large])
    }

    private func load() async {
        do {
            data = try await api.call("GET", "wallet", query: [URLQueryItem(name: "month", value: WalletFormat.monthKey.string(from: month))])
            error = nil
        } catch {
            self.error = "账本没拉下来：\(error.localizedDescription)"
        }
    }

    private func printReceipt(_ day: String) {
        Task {
            if let r: WalletReceiptDTO = try? await api.call("GET", "wallet/receipt", query: [URLQueryItem(name: "day", value: day)]) {
                receipt = r
            }
        }
    }

    private var monthBar: some View {
        HStack {
            Button { month = Calendar.current.date(byAdding: .month, value: -1, to: month) ?? month } label: { Image(systemName: "chevron.left") }
            Spacer()
            Text(month.formatted(.dateTime.year().month(.wide))).font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            Spacer()
            Button { month = Calendar.current.date(byAdding: .month, value: 1, to: month) ?? month } label: { Image(systemName: "chevron.right") }
                .disabled(Calendar.current.isDate(month, equalTo: Date(), toGranularity: .month))
        }
        .foregroundStyle(theme.accentDeep)
    }

    private func summary(_ d: WalletMonthDTO) -> some View {
        PhoneGlassCard(padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("这个月花了").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                Text(WalletFormat.money(d.total, d.symbol)).font(Typo.number(Typo.Size.largeTitle)).foregroundStyle(theme.ink)
                HStack(spacing: 14) {
                    if d.income > 0 {
                        Label(WalletFormat.money(d.income, d.symbol), systemImage: "arrow.down.left")
                            .foregroundStyle(incomeColor)
                        Text("结余 \(WalletFormat.money(d.net, d.symbol))").foregroundStyle(theme.inkDim)
                    }
                    if d.lastMonth > 0 {
                        let diff = d.total - d.lastMonth
                        Text(diff >= 0 ? "比上个月多 \(WalletFormat.money(diff, d.symbol))" : "比上个月少 \(WalletFormat.money(-diff, d.symbol))")
                            .foregroundStyle(theme.inkFaint)
                    }
                }
                .font(Typo.sans(Typo.Size.caption))
                if d.budget > 0 {
                    let ratio = min(1, Double(d.total) / Double(d.budget))
                    VStack(alignment: .leading, spacing: 5) {
                        GeometryReader { g in
                            Capsule().fill(Color.white.opacity(0.55))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(ratio >= 1 ? Color.orange : theme.accentDeep).frame(width: max(6, g.size.width * ratio))
                                }
                        }
                        .frame(height: 8)
                        Text(d.total >= d.budget ? "预算 \(WalletFormat.money(d.budget, d.symbol)) 已经用完了"
                             : "预算 \(WalletFormat.money(d.budget, d.symbol)) · 还剩 \(WalletFormat.money(d.budget - d.total, d.symbol))")
                            .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                    }
                }
            }
        }
    }

    private func breakdown(_ rows: [[WalletCell]], total: Int, title: String, income: Bool = false) -> some View {
        let palette: [Color] = income
            ? [incomeColor, incomeColor.opacity(0.7), incomeColor.opacity(0.5), incomeColor.opacity(0.35)]
            : [theme.accentDeep, theme.accent, Color.teal.opacity(0.7), Color.orange.opacity(0.7), Color.indigo.opacity(0.6), Color.gray.opacity(0.5)]
        return PhoneGlassCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.inkDim)
                GeometryReader { g in
                    HStack(spacing: 2) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, kv in
                            Rectangle().fill(palette[i % palette.count])
                                .frame(width: max(3, g.size.width * Double(kv.last?.number ?? 0) / Double(max(total, 1)) - 2))
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(Capsule())
                ForEach(Array(rows.enumerated()), id: \.offset) { i, kv in
                    HStack(spacing: 8) {
                        Circle().fill(palette[i % palette.count]).frame(width: 8, height: 8)
                        Image(systemName: WalletFormat.icon(kv.first?.text ?? "", income: income)).font(Typo.icon(12)).foregroundStyle(theme.inkDim)
                        Text(kv.first?.text ?? "").font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink)
                        Spacer()
                        Text(WalletFormat.money(kv.last?.number ?? 0, symbol)).font(Typo.number(Typo.Size.callout)).foregroundStyle(theme.ink)
                    }
                }
            }
        }
    }

    private func days(_ d: WalletMonthDTO) -> some View {
        let grouped = Dictionary(grouping: d.entries, by: \.day).sorted { $0.key > $1.key }
        return VStack(alignment: .leading, spacing: 12) {
            if d.entries.isEmpty {
                Text("这个月还没记账。右上角 ＋ 记一笔，或者在聊天里跟它说「刚买咖啡花了 6 块」，它会替你记上。")
                    .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim).padding(.top, 10)
            }
            ForEach(grouped, id: \.key) { day, list in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(WalletFormat.dayKey.date(from: day)?.formatted(.dateTime.month().day().weekday()) ?? day)
                            .font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.inkDim)
                        Spacer()
                        Text(WalletFormat.money(list.filter { !$0.isIncome }.reduce(0) { $0 + $1.amount }, d.symbol))
                            .font(Typo.number(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                        // 刷卡机：打一张这天的小票
                        Button { printReceipt(day) } label: {
                            Image(systemName: "creditcard.and.123").font(Typo.icon(13)).foregroundStyle(theme.accentDeep)
                                .frame(width: 28, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("打这天的小票")
                    }
                    PhoneGlassCard(padding: 12) {
                        VStack(spacing: 10) {
                            ForEach(list) { e in row(e, d.symbol) }
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: WalletEntryDTO, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: WalletFormat.icon(e.category, income: e.isIncome)).font(Typo.icon(14))
                .foregroundStyle(e.isIncome ? incomeColor : theme.accentDeep)
                .frame(width: 28, height: 28).background(Circle().fill(Color.white.opacity(0.6)))
            VStack(alignment: .leading, spacing: 1) {
                Text(e.note.isEmpty ? e.category : e.note).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                if !e.note.isEmpty {
                    Text(e.category).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkFaint)
                }
            }
            Spacer()
            Text((e.isIncome ? "+" : "") + WalletFormat.money(e.amount, symbol)).font(Typo.number(Typo.Size.body))
                .foregroundStyle(e.isIncome ? incomeColor : theme.ink)
        }
        .contentShape(Rectangle())
        .onTapGesture { editing = e }
        .contextMenu {
            Button(role: .destructive) {
                Task { _ = try? await api.raw("DELETE", "wallet/\(e.id)"); await load() }
            } label: { Label("删掉", systemImage: "trash") }
        }
    }
}

// MARK: - 小票（刷卡机打出来的那种）

struct ReceiptSheet: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let receipt: WalletReceiptDTO
    @State private var printed: CGFloat = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 出纸口
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.25), Color(white: 0.4)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 300, height: 14)
                        .zIndex(1)
                    ReceiptPaper(receipt: receipt)
                        .frame(width: 280)
                        .mask(alignment: .top) {
                            GeometryReader { g in Rectangle().frame(height: g.size.height * printed) }
                        }
                        .offset(y: -6)
                }
                .padding(.top, 24)
                .frame(maxWidth: .infinity)
            }
            .background(AppBackground())
            .navigationTitle("小票").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    if let image = ImageRenderer(content: ReceiptPaper(receipt: receipt).frame(width: 280)).uiImage {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("小票 \(receipt.day)", image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear { withAnimation(.easeOut(duration: 1.4)) { printed = 1 } }
    }
}

/// 小票本身：等宽字、虚线、锯齿边、最底下一截条码
struct ReceiptPaper: View {
    let receipt: WalletReceiptDTO
    private let ink = Color(white: 0.18)

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 3) {
                Text("MELE · 小票").font(.system(size: 16, weight: .bold, design: .monospaced))
                Text(dateLine).font(.system(size: 12, design: .monospaced))
                Text(String(format: "No. %06d   %@", receipt.no, receipt.currency)).font(.system(size: 11, design: .monospaced)).opacity(0.7)
            }
            dashes
            if receipt.entries.isEmpty {
                Text("这天什么都没记").font(.system(size: 12, design: .monospaced)).opacity(0.6).padding(.vertical, 6)
            }
            ForEach(receipt.entries) { e in
                HStack(alignment: .top) {
                    Text(e.note.isEmpty ? e.category : "\(e.note)（\(e.category)）")
                        .font(.system(size: 12, design: .monospaced)).lineLimit(2)
                    Spacer(minLength: 8)
                    Text((e.isIncome ? "+" : "-") + WalletFormat.plain(e.amount)).font(.system(size: 12, design: .monospaced))
                }
            }
            dashes
            line("支出", WalletFormat.plain(receipt.out))
            line("收入", WalletFormat.plain(receipt.income))
            line("结余", (receipt.net >= 0 ? "+" : "-") + WalletFormat.plain(abs(receipt.net)), bold: true)
            dashes
            Text(receipt.net >= 0 ? "今天也好好过了 · 明天见" : "花在自己身上的都值得 · 明天见")
                .font(.system(size: 11, design: .monospaced)).opacity(0.75)
            barcode.padding(.top, 4)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 22)
        .background(Color(red: 0.99, green: 0.985, blue: 0.97))
        .mask(ZigzagEdges())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }

    private var dateLine: String {
        guard let d = WalletFormat.dayKey.date(from: receipt.day) else { return receipt.day }
        return d.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).weekday(.abbreviated))
    }

    private var dashes: some View {
        Text(String(repeating: "- ", count: 20)).font(.system(size: 10, design: .monospaced)).lineLimit(1).opacity(0.5)
    }

    private func line(_ k: String, _ v: String, bold: Bool = false) -> some View {
        HStack {
            Text(k)
            Spacer()
            Text(v)
        }
        .font(.system(size: 13, weight: bold ? .bold : .regular, design: .monospaced))
    }

    /// 条码：按日期和单号定的粗细，每天一样
    private var barcode: some View {
        let seed = receipt.day.unicodeScalars.reduce(receipt.no) { $0 &* 31 &+ Int($1.value) }
        return HStack(spacing: 1.5) {
            ForEach(0..<38, id: \.self) { i in
                Rectangle().frame(width: [1, 1.5, 2.5, 1][abs(seed >> (i % 16) ^ i) % 4], height: 34)
            }
        }
    }
}

/// 上下两条锯齿边（撕下来的小票）
struct ZigzagEdges: Shape {
    func path(in r: CGRect) -> Path {
        let tooth: CGFloat = 8, depth: CGFloat = 5
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + depth))
        var x = r.minX
        while x < r.maxX {
            p.addLine(to: CGPoint(x: min(x + tooth / 2, r.maxX), y: r.minY))
            p.addLine(to: CGPoint(x: min(x + tooth, r.maxX), y: r.minY + depth))
            x += tooth
        }
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - depth))
        x = r.maxX
        while x > r.minX {
            p.addLine(to: CGPoint(x: max(x - tooth / 2, r.minX), y: r.maxY))
            p.addLine(to: CGPoint(x: max(x - tooth, r.minX), y: r.maxY - depth))
            x -= tooth
        }
        p.closeSubpath()
        return p
    }
}

// MARK: - 记一笔 / 改一笔

struct WalletEntryEditor: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let entry: WalletEntryDTO?
    let outTags: [String]
    let inTags: [String]
    let symbol: String
    var onSaved: () async -> Void
    @State private var kind = "out"
    @State private var amount = ""
    @State private var tag = "吃饭"
    @State private var newTag = ""
    @State private var note = ""
    @State private var day = Date()
    @State private var error: String?
    @FocusState private var amountFocused: Bool

    private var tags: [String] {
        let base = kind == "in" ? inTags : outTags
        return base.isEmpty ? (kind == "in" ? ["零花钱", "打工", "红包", "其他收入"] : ["吃饭", "交通", "购物", "娱乐", "学习", "其他"]) : base
    }
    private var chosen: String { newTag.trimmingCharacters(in: .whitespaces).isEmpty ? tag : newTag.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if entry == nil {
                        Picker("", selection: $kind) {
                            Text("支出").tag("out")
                            Text("收入").tag("in")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: kind) { _, k in tag = k == "in" ? (inTags.first ?? "零花钱") : (outTags.first ?? "吃饭") }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(kind == "in" ? "+" + symbol : symbol).font(Typo.number(Typo.Size.title)).foregroundStyle(theme.inkDim)
                        TextField("0", text: $amount).keyboardType(.decimalPad).focused($amountFocused)
                            .font(Typo.number(Typo.Size.largeTitle)).foregroundStyle(theme.ink)
                    }
                    Text("标签").font(Typo.sans(Typo.Size.caption, .semibold)).foregroundStyle(theme.inkDim)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(tags, id: \.self) { c in
                            let on = newTag.trimmingCharacters(in: .whitespaces).isEmpty && tag == c
                            Button { tag = c; newTag = "" } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: WalletFormat.icon(c, income: kind == "in")).font(Typo.icon(12))
                                    Text(c).font(Typo.sans(Typo.Size.callout, on ? .semibold : .regular)).lineLimit(1)
                                }
                                .foregroundStyle(on ? Color.white : theme.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(Capsule().fill(on ? theme.accentDeep : Color.white.opacity(0.6)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    TextField("或者写一个新标签（会存下来，下次直接点）", text: $newTag)
                        .font(Typo.sans(Typo.Size.callout)).padding(12)
                        .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous).fill(Color.white.opacity(0.6)))
                    TextField(kind == "in" ? "从哪来的（可以不写）" : "买了什么（可以不写）", text: $note)
                        .font(Typo.sans(Typo.Size.body)).padding(12)
                        .background(RoundedRectangle(cornerRadius: Radii.control, style: .continuous).fill(Color.white.opacity(0.6)))
                    DatePicker("哪天", selection: $day, in: ...Date(), displayedComponents: .date)
                        .font(Typo.sans(Typo.Size.body))
                    if let error { Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red) }
                    if let entry {
                        Button(role: .destructive) {
                            Task { _ = try? await session.api.raw("DELETE", "wallet/\(entry.id)"); await onSaved(); dismiss() }
                        } label: { Text("删掉这一笔").frame(maxWidth: .infinity) }
                        .padding(.top, 10)
                    }
                }
                .padding(20)
            }
            .background(AppBackground())
            .navigationTitle(entry == nil ? "记一笔" : "改一笔").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("存") { Task { await save() } }.disabled(amount.isEmpty) }
            }
        }
        .environment(\.colorScheme, .light)
        .onAppear {
            if let e = entry {
                kind = e.kind
                amount = e.amount % 100 == 0 ? "\(e.amount / 100)" : String(format: "%.2f", Double(e.amount) / 100)
                tag = e.category
                note = e.note
                day = WalletFormat.dayKey.date(from: e.day) ?? Date()
            } else {
                tag = outTags.first ?? "吃饭"
                amountFocused = true
            }
        }
    }

    private func save() async {
        let body: [String: Any] = ["amount": amount, "category": chosen, "kind": kind, "note": note,
                                   "day": WalletFormat.dayKey.string(from: day)]
        do {
            if let e = entry {
                _ = try await session.api.raw("PATCH", "wallet/\(e.id)", json: body)
            } else {
                _ = try await session.api.raw("POST", "wallet", json: body)
            }
            await onSaved()
            dismiss()
        } catch {
            self.error = "没存上：\(error.localizedDescription)"
        }
    }
}

// MARK: - 设置：币种、预算、自己写过的标签

struct WalletSettingsView: View {
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let data: WalletMonthDTO?
    var onSaved: () async -> Void
    @State private var currency = "AUD"
    @State private var budget = ""
    @State private var outTags: [String] = []
    @State private var inTags: [String] = []
    @State private var error: String?

    private let currencies = [("AUD", "澳元"), ("CNY", "人民币"), ("USD", "美元"), ("NZD", "纽币"), ("HKD", "港币"),
                              ("JPY", "日元"), ("EUR", "欧元"), ("GBP", "英镑")]

    var body: some View {
        NavigationStack {
            Form {
                Section("币种") {
                    Picker("币种", selection: $currency) {
                        ForEach(currencies, id: \.0) { Text("\($0.1) \($0.0)").tag($0.0) }
                    }
                }
                Section {
                    TextField("不设就空着", text: $budget).keyboardType(.decimalPad)
                } header: { Text("一个月的预算") } footer: { Text("设了的话，钱包页上会有一根条，看这个月用了多少。") }
                Section {
                    if outTags.isEmpty && inTags.isEmpty {
                        Text("还没有。记账时写一个新标签，它就会出现在这儿。").foregroundStyle(.secondary)
                    }
                    ForEach(outTags, id: \.self) { Text($0) }.onDelete { outTags.remove(atOffsets: $0) }
                    ForEach(inTags, id: \.self) { Text("\($0)（收入）") }.onDelete { inTags.remove(atOffsets: $0) }
                } header: { Text("自己写过的标签") } footer: { Text("左滑删掉不用的。默认的那几个（吃饭、交通、零花钱……）一直都在。") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("钱包设置").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("存") { Task { await save() } } }
            }
        }
        .onAppear {
            currency = data?.currency ?? "AUD"
            if let b = data?.budget, b > 0 { budget = b % 100 == 0 ? "\(b / 100)" : String(format: "%.2f", Double(b) / 100) }
            outTags = data?.custom.out ?? []
            inTags = data?.custom.in ?? []
        }
    }

    private func save() async {
        do {
            _ = try await session.api.raw("PUT", "wallet/settings",
                                          json: ["currency": currency, "budget": budget.isEmpty ? "0" : budget,
                                                 "custom": ["out": outTags, "in": inTags]])
            await onSaved()
            dismiss()
        } catch {
            self.error = "没存上：\(error.localizedDescription)"
        }
    }
}
