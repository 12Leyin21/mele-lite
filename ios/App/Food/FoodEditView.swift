// 搬自 fed-myself（github.com/12Leyin21/fed-myself，MIT，Tilia 和 Quercus写的）· 09-29 接进 Mele
import SwiftUI
import PhotosUI

/// 饮食编辑页：
/// 顶上三栏（饮食摄入 / 中间圆环「还剩多少到目标」/ 运动消耗）+ 三条营养小进度；
/// 中间每餐一张卡、点一样东西改或删；最底下一排 +早餐 +午餐 +晚餐 +加餐 +运动。
/// 圆环往满了走，到目标就满，写「到目标」。
/// 
struct FoodEditView: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FoodStore
    let date: String
    @State private var adding: FoodMeal? = ProcessInfo.processInfo.arguments.contains("-foodAdd") ? .breakfast : nil   // 截图用
    @State private var editing: FoodEntry?
    @State private var receipt = false            // 刷卡机吐小票（10-04）
    @State private var macroTab = false           // 点圆环弹出三大营养的小卡

    var body: some View {
        ZStack(alignment: .bottom) {
            AppBackground()
            ScrollView {
                VStack(spacing: 12) {
                    FoodHeader(title: "Log a Meal", subtitle: FoodStore.enLabel(date), back: { dismiss() }) {
                        // 完成键是一台小刷卡机：点了吐一张今天的小票
                        Button {
                            if store.day?.date == date { withAnimation(.easeOut(duration: 0.25)) { receipt = true } } else { dismiss() }
                        } label: { EftposIcon() }
                        .buttonStyle(.plain)
                        .accessibilityLabel("完成，打一张小票")
                    }
                    if let day = store.day, day.date == date {
                        overview(day)
                        ForEach(FoodMeal.allCases) { meal in
                            let items = day.entries(meal)
                            if !items.isEmpty { mealCard(meal, items, total: day.summary.meals[meal.rawValue] ?? 0) }
                        }
                        if day.entries.isEmpty {
                            Text("点下面的按钮记第一样——不用填热量，\(FoodLogConfig.aiName)来估")
                                .font(Fonts.body(13.5)).foregroundStyle(AppTheme.inkFaint).padding(.top, 20)
                        }
                        if let e = store.error {
                            Text(e).font(.system(size: 12.5)).foregroundStyle(AppTheme.inkFaint)
                        }
                    } else {
                        ProgressView().padding(.top, 60)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 110)
            }
            addBar
            if receipt, let day = store.day, day.date == date {
                FoodReceiptOverlay(receipt: FoodReceiptData(day: day)) {
                    withAnimation(.easeOut(duration: 0.2)) { receipt = false }      // 收起回到记一餐（10-04 Tilia）
                }
                .transition(.opacity)
                .zIndex(2)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: date) { await store.loadDay(date) }
        // 还在估的：几秒拉一次，估好了数自己填上（后台一般几秒）
        .task(id: store.day?.entries.filter(\.pending).map(\.id) ?? []) { await store.watchPending(date) }
        .sheet(item: $adding) { meal in
            FoodAddSheet(store: store, date: date, meal: meal).environmentObject(theme)
                .presentationDetents([.medium, .large])
                .presentationBackground { FoodSheetGlass() }
        }
        .sheet(item: $editing) { entry in
            FoodEntrySheet(store: store, entry: entry).environmentObject(theme)
                .presentationDetents([.medium, .large])
                .presentationBackground { FoodSheetGlass() }
        }
    }

    // ── 顶上：摄入 / 圆环 / 运动 + 三条营养
    private func overview(_ day: FoodDay) -> some View {
        let s = day.summary, t = day.targets          // t == nil：只记录，不设目标（Mele 默认）
        let ratio = (t?.kcal ?? 0) > 0 ? min(1, max(0, Double(s.net) / Double(t!.kcal))) : 0
        return FoodCard(padding: 18) {
            VStack(spacing: 18) {
                HStack(alignment: .center) {
                    stat("饮食摄入", s.kcal)
                    ZStack {
                        Circle().stroke(.white.opacity(0.5), lineWidth: 11)
                        ForEach(macroArcs(s), id: \.0) { _, from, to, shade in
                            Circle().trim(from: from, to: to)
                                .stroke(theme.accent.opacity(shade), style: StrokeStyle(lineWidth: 11, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                        }
                        VStack(spacing: 2) {
                            if let t {
                                let reached = s.reached ?? false
                                Text(reached ? "今天" : "还剩（千卡）").font(Fonts.body(11.5)).foregroundStyle(AppTheme.inkFaint)
                                Text(reached ? "到目标" : "\(s.remaining ?? 0)")
                                    .font(.system(size: reached ? 22 : 30, weight: .bold).monospacedDigit())
                                    .foregroundStyle(AppTheme.ink)
                                Text("目标 \(t.kcal)").font(Fonts.body(11)).foregroundStyle(AppTheme.inkFaint)
                            } else {
                                Text("今天吃了（千卡）").font(Fonts.body(11.5)).foregroundStyle(AppTheme.inkFaint)
                                Text("\(s.net)").font(.system(size: 30, weight: .bold).monospacedDigit())
                                    .foregroundStyle(AppTheme.ink)
                            }
                        }
                    }
                    .contentShape(Circle())
                    .onTapGesture { macroTab = true }
                    .popover(isPresented: $macroTab) {
                        VStack(alignment: .leading, spacing: 8) {
                            macroLine("碳水", s.carbs, t?.carbs ?? 0, 1)
                            macroLine("蛋白质", s.protein, t?.protein ?? 0, 0.6)
                            macroLine("脂肪", s.fat, t?.fat ?? 0, 0.32)
                        }
                        .padding(14)
                        .presentationCompactAdaptation(.popover)
                    }
                    .frame(width: 136, height: 136)
                    .frame(maxWidth: .infinity)
                    stat("运动消耗", s.exercise)
                }
                HStack(spacing: 18) {
                    legend("碳水", 1)
                    legend("蛋白质", 0.6)
                    legend("脂肪", 0.32)
                }
                if s.pending > 0 {
                    Text("有 \(s.pending) 样\(FoodLogConfig.aiName)在估，估好了数会自己填上")
                        .font(Fonts.body(12)).foregroundStyle(theme.accent)
                }
            }
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 4) {
            Text(label).font(Fonts.body(12.5)).foregroundStyle(AppTheme.inkFaint)
            Text("\(value)").font(.system(size: 24, weight: .bold).monospacedDigit()).foregroundStyle(AppTheme.ink)
        }
        .frame(width: 76)
    }

    /// 圆环三段：按热量占比（碳水、蛋白质 4 千卡 / 克，脂肪 9），段和段之间留一点缝
    private func macroArcs(_ s: FoodSummary) -> [(Int, CGFloat, CGFloat, Double)] {
        let parts = [(Double(s.carbs) * 4, 1.0), (Double(s.protein) * 4, 0.6), (Double(s.fat) * 9, 0.32)]
        let total = parts.reduce(0) { $0 + $1.0 }
        guard total > 0 else { return [] }
        var out: [(Int, CGFloat, CGFloat, Double)] = []
        var at: CGFloat = 0
        for (i, (v, shade)) in parts.enumerated() where v > 0 {
            let len = CGFloat(v / total)
            out.append((i, at + 0.012, max(at + 0.014, at + len - 0.012), shade))
            at += len
        }
        return out
    }

    private func legend(_ label: String, _ shade: Double) -> some View {
        HStack(spacing: 5) {
            Circle().fill(theme.accent.opacity(shade)).frame(width: 8, height: 8)
            Text(label).font(Fonts.body(12.5)).foregroundStyle(AppTheme.inkDim)
        }
    }

    private func macroLine(_ label: String, _ value: Int, _ target: Int, _ shade: Double) -> some View {
        HStack(spacing: 8) {
            Circle().fill(theme.accent.opacity(shade)).frame(width: 8, height: 8)
            Text(label).font(Fonts.body(13)).foregroundStyle(AppTheme.ink)
            Spacer(minLength: 16)
            Text(target > 0 ? "\(value) / \(target) 克" : "\(value) 克")
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(AppTheme.inkDim)
        }
        .frame(minWidth: 150)
    }

    private func macro(_ label: String, _ value: Int, _ target: Int) -> some View {
        let r = target > 0 ? min(1, Double(value) / Double(target)) : 0
        return VStack(alignment: .leading, spacing: 5) {
            Text(label).font(Fonts.body(13)).foregroundStyle(AppTheme.ink)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.5))
                    Capsule().fill(theme.accent.opacity(0.7)).frame(width: max(4, g.size.width * r))
                }
            }
            .frame(height: 5)
            Text(target > 0 ? "\(value) / \(target) 克" : "\(value) 克").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(AppTheme.inkFaint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── 中间：每餐一张卡
    private func mealCard(_ meal: FoodMeal, _ items: [FoodEntry], total: Int) -> some View {
        FoodCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(meal.rawValue).font(Fonts.serif(18, .semibold)).foregroundStyle(AppTheme.ink)
                    Spacer()
                    Text(meal == .exercise ? "−\(total) 千卡" : "\(total) 千卡")
                        .font(.system(size: 15).monospacedDigit()).foregroundStyle(AppTheme.inkDim)
                }
                ForEach(items) { e in
                    Button { editing = e } label: { itemRow(meal, e) }.buttonStyle(.plain)
                }
            }
        }
    }

    private func itemRow(_ meal: FoodMeal, _ e: FoodEntry) -> some View {
        HStack(spacing: 12) {
            Group {
                if !e.photo.isEmpty {
                    AuthImageView(urlPath: e.photo)
                } else {
                    Image(systemName: meal.icon).font(.system(size: 17)).foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.4))
                }
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(e.text).font(Fonts.body(15, .medium)).foregroundStyle(AppTheme.ink).lineLimit(2)
                let sub = [e.subline, e.source == "watch" ? "⌚️ Apple Watch" : ((e.source == "ai" || e.source == "him") ? "\(FoodLogConfig.aiName)记的" : "")].filter { !$0.isEmpty }.joined(separator: " · ")
                if !sub.isEmpty {
                    Text(sub).font(Fonts.body(11.5)).foregroundStyle(AppTheme.inkFaint).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(e.pending ? "\(FoodLogConfig.aiName)在估…" : e.failed ? "没估出来，点开手填" : "\(Int((e.kcal ?? 0).rounded())) 千卡")
                .font(.system(size: 14).monospacedDigit())
                .foregroundStyle(e.pending ? theme.accent : AppTheme.inkDim)
            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(AppTheme.inkFaint)
        }
    }

    // ── 底下：+早餐 +午餐 +晚餐 +加餐 +运动
    private var addBar: some View {
        HStack(spacing: 0) {
            ForEach(FoodMeal.allCases) { meal in
                Button { adding = meal } label: {
                    VStack(spacing: 4) {
                        Image(systemName: meal.icon).font(.system(size: 19))
                        Text("+\(meal.rawValue)").font(Fonts.body(12))
                    }
                    .foregroundStyle(AppTheme.inkDim)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
        .foodGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// 记东西：一行一样——左边「吃了什么」、右边「里面有什么」。
/// 列表页只显示左边；点进去名字底下灰字是份量和里面有什么（模糊的量 AI 估成克数）。
/// 不用 Form：Form 里多行输入框收起键盘后再点没反应，这里自己排，点哪都能聚焦。
struct FoodAddSheet: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FoodStore
    let date: String
    let meal: FoodMeal

    struct Row: Identifiable { let id = UUID(); var name = ""; var inside = "" }
    @State private var rows: [Row] = [Row()]
    @State private var showNumbers = false
    @State private var kcal: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var picks: [PhotosPickerItem] = []
    @State private var photoDatas: [Data] = []           // 一餐的照片不限张数（Tilia 09-29）
    @State private var saving = false
    @FocusState private var focus: Field?
    enum Field: Hashable { case name(UUID), inside(UUID), number(Int) }
    // 扫条形码 / 拍营养表
    @State private var scanning = false
    @State private var lookingUp = false
    @State private var scanned: BarcodeProduct? = FoodAddSheet.demoScan ? BarcodeProduct(   // 截图用
        name: "Caramel Honey Macadamia", brand: "Connoisseur", kcal_100g: 262, protein_100g: 3.6,
        carbs_100g: 26.1, fat_100g: 15.8, serving: "1 serve (65 g)", kcal_serving: 170) : nil
    private static var demoScan: Bool { ProcessInfo.processInfo.arguments.contains("-foodScanDemo") }
    @State private var scanMiss = false
    @State private var scanGrams: Double? = FoodAddSheet.demoScan ? 65 : nil
    @State private var shootingLabel = false
    @State private var labelPhoto = false
    @State private var searchingName = false
    @State private var scanSource = "条码查的"      // 记下来的那行写「条码查的」还是「搜名字查的」
    private static var searchDemoShown = false

    private var filled: [Row] { rows.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty } }
    private var isExercise: Bool { meal == .exercise }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        // 运动也分两栏：左边练了什么（部位 / 项目），右边多久
                        Text(isExercise ? "练了什么" : "吃了什么").frame(maxWidth: .infinity, alignment: .leading)
                        Text(isExercise ? "多久（可选）" : "里面有什么（可选）").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(Fonts.body(12.5, .medium)).foregroundStyle(.secondary)
                    ForEach($rows) { $row in rowView($row) }
                    // 运动也能一次记好几项（原来只有吃的能「再加一样」）
                    Button {
                        rows.append(Row())
                        focus = .name(rows[rows.count - 1].id)
                    } label: {
                        Label(isExercise ? "再加一项" : "再加一样", systemImage: "plus").font(Fonts.body(14, .medium))
                    }
                    Text(isExercise ? "不用填消耗，\(FoodLogConfig.aiName)来估；运动会从今天吃进去的里面扣。"
                                    : "不用填热量，\(FoodLogConfig.aiName)来估。里面有什么写得越细估得越准，写「半个」「一把」也行，会估成克数。")
                        .font(Fonts.body(12)).foregroundStyle(.secondary)

                    if !isExercise {
                        HStack(spacing: 10) {
                            scanButton("搜名字", "magnifyingglass") { focus = nil; searchingName = true }
                            if BarcodeScannerView.isAvailable || Self.demoScan {
                                scanButton("扫码", "barcode.viewfinder") { focus = nil; scanning = true }
                            }
                            if CameraPicker.isAvailable || Self.demoScan {
                                scanButton("营养表", "tablecells") { focus = nil; shootingLabel = true }
                            }
                        }
                        if lookingUp {
                            HStack { ProgressView(); Text("在查…").font(Fonts.body(13)).foregroundStyle(.secondary) }
                        }
                        if let scanned {
                            BarcodeResultCard(product: scanned, grams: $scanGrams,
                                              icon: scanSource == "搜名字查的" ? "magnifyingglass" : "barcode.viewfinder",
                                              onSave: { Task { await saveScanned(scanned) } },
                                              onCancel: { self.scanned = nil })
                        }
                        if scanMiss {
                            Text("数据库里没有这个条码——拍一下背面的营养成分表，\(FoodLogConfig.aiName)照着表算。")
                                .font(Fonts.body(12.5)).foregroundStyle(.secondary)
                        }
                        if labelPhoto {
                            Text("营养表拍好了。在「里面有什么」写吃了多少克（没写就按一份算），\(FoodLogConfig.aiName)照表算。")
                                .font(Fonts.body(12.5)).foregroundStyle(.secondary)
                        }
                    }

                    if !photoDatas.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Array(photoDatas.enumerated()), id: \.offset) { i, d in
                                    if let img = UIImage(data: d) {
                                        Image(uiImage: img).resizable().scaledToFill()
                                            .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 10))
                                            .overlay(alignment: .topTrailing) {
                                                Button { photoDatas.remove(at: i) } label: {
                                                    Image(systemName: "xmark.circle.fill").font(.system(size: 16))
                                                        .foregroundStyle(.white, .black.opacity(0.5))
                                                }
                                                .padding(3)
                                            }
                                    }
                                }
                            }
                        }
                    }
                    PhotosPicker(selection: $picks, maxSelectionCount: 0, matching: .images) {
                        HStack {
                            Label(photoDatas.isEmpty ? "加照片（可选，几张都行）" : "再加照片", systemImage: "camera")
                            Spacer()
                            if !photoDatas.isEmpty { Text("\(photoDatas.count) 张").font(Fonts.body(13)).foregroundStyle(.secondary) }
                        }
                        .padding(14)
                        .background(FoodSheetGlass.field, in: RoundedRectangle(cornerRadius: 14))
                    }

                    if filled.count <= 1 {
                        VStack(spacing: 10) {
                            Toggle("我自己填数", isOn: $showNumbers)
                            if showNumbers {
                                numberField(isExercise ? "消耗" : "热量", $kcal, "kcal", 0)
                                if !isExercise {
                                    numberField("蛋白质", $protein, "g", 1)
                                    numberField("碳水", $carbs, "g", 2)
                                    numberField("脂肪", $fat, "g", 3)
                                }
                            }
                        }
                        .padding(14)
                        .background(FoodSheetGlass.field, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if let e = store.error {
                        Text(e).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .containerBackground(.clear, for: .navigation)   // 全屏时导航层别自己刷一层纯色
            .navigationTitle("+\(meal.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "存着…" : "记下") { Task { await save() } }
                        .disabled((filled.isEmpty && photoDatas.isEmpty) || saving)   // 只拍了照片也能记（Tilia 09-29）
                }
            }
            .onChange(of: picks) { _, items in
                guard !items.isEmpty else { return }
                Task {
                    for item in items { if let d = await Self.jpeg(from: item) { photoDatas.append(d) } }
                    picks = []
                }
            }
            .fullScreenCover(isPresented: $scanning) {
                ZStack(alignment: .topTrailing) {
                    BarcodeScannerView { code in
                        scanning = false
                        Task { await lookup(code) }
                    }
                    .ignoresSafeArea()
                    Button("取消") { scanning = false }
                        .font(Fonts.body(16, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(20)
                }
            }
            .onAppear {   // 截图用：只自动弹一次，挑完回来别又弹
                if FoodSearchSheet.demo && !Self.searchDemoShown { Self.searchDemoShown = true; searchingName = true }
            }
            .sheet(isPresented: $searchingName) {
                FoodSearchSheet(search: { await store.search($0) }) { p in
                    scanned = p
                    scanGrams = p.servingGrams ?? 100
                    scanSource = "搜名字查的"
                    scanMiss = false
                }
                .environmentObject(theme)
                .presentationDetents([.large])
                .presentationBackground { FoodSheetGlass() }
            }
            .fullScreenCover(isPresented: $shootingLabel) {
                CameraPicker { data in
                    photoDatas.append(data)
                    labelPhoto = true
                    scanMiss = false
                }
                .ignoresSafeArea()
            }
            // 不自动聚焦：一打开就弹键盘会把半屏顶成全屏。默认停在半屏，点输入框或往上拉才全屏
        }
        .tint(theme.accent)
    }

    private func rowView(_ row: Binding<Row>) -> some View {
        let id = row.wrappedValue.id
        return HStack(alignment: .top, spacing: 10) {
            box(focused: focus == .name(id)) {
                TextField(isExercise ? "臀腿" : "番茄炒蛋", text: row.name, axis: .vertical)
                    .focused($focus, equals: .name(id))
                    .lineLimit(1...3)
            }
            .onTapGesture { focus = .name(id) }
            Group {
                box(focused: focus == .inside(id)) {
                    TextField(isExercise ? "45 分钟" : "鸡蛋2个 西红柿1个…", text: row.inside, axis: .vertical)
                        .focused($focus, equals: .inside(id))
                        .lineLimit(1...6)
                }
                .onTapGesture { focus = .inside(id) }
            }
            if rows.count > 1 {
                Button { rows.removeAll { $0.id == id } } label: {
                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            }
        }
    }

    /// 输入框的底：整块都是热区，点哪都聚焦（修「收起键盘后再点没反应」）
    private func box<C: View>(focused: Bool, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .font(Fonts.body(15))
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .topLeading)
            .background(FoodSheetGlass.field, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(focused ? theme.accent.opacity(0.6) : .clear, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func numberField(_ label: String, _ value: Binding<Double?>, _ unit: String, _ tag: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .focused($focus, equals: .number(tag))
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
            Text(unit).foregroundStyle(.secondary)
        }
    }

    private func scanButton(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(Fonts.body(14, .medium))
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(FoodSheetGlass.field, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private func lookup(_ code: String) async {
        lookingUp = true
        scanMiss = false
        scanned = nil
        let r = await store.barcode(code)
        lookingUp = false
        if let p = r?.product {
            scanned = p
            scanGrams = p.servingGrams ?? 100
            scanSource = "条码查的"
        } else {
            scanMiss = true
        }
    }

    /// 扫到的那一样直接记：数是表上的，不用 AI 估
    private func saveScanned(_ p: BarcodeProduct) async {
        guard let g = scanGrams, g > 0 else { return }
        saving = true
        defer { saving = false }
        let k = g / 100
        let name = p.brand.isEmpty ? p.name : "\(p.brand) \(p.name)"
        let ok = await store.add(date: date, meal: meal, text: name,
                                 detail: "\(Int(g.rounded()))g（\(scanSource)，每 100g \(Int(p.kcal_100g.rounded())) kcal）",
                                 kcal: (p.kcal_100g * k).rounded(),
                                 protein: p.protein_100g.map { ($0 * k * 10).rounded() / 10 },
                                 carbs: p.carbs_100g.map { ($0 * k * 10).rounded() / 10 },
                                 fat: p.fat_100g.map { ($0 * k * 10).rounded() / 10 })
        guard ok else { return }
        scanned = nil
        if filled.isEmpty { dismiss() }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        var photos: [String] = []
        for d in photoDatas {
            guard let id = await store.uploadPhoto(d) else { return }
            photos.append(id)
        }
        let own = showNumbers && filled.count == 1 && kcal != nil
        // 只拍了照片、没写吃了什么：记成「拍的这一餐」，后台看图估的时候顺便起个名字
        let rows = filled.isEmpty ? [Row(name: FoodEntry.photoOnly, inside: "")] : filled
        for (i, row) in rows.enumerated() {
            let ok = await store.add(date: date, meal: meal,
                                     text: row.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     detail: row.inside.trimmingCharacters(in: .whitespacesAndNewlines),
                                     kcal: own ? kcal : nil, protein: own ? protein : nil,
                                     carbs: own ? carbs : nil, fat: own ? fat : nil,
                                     photos: i == 0 ? photos : [])
            if !ok { return }
        }
        dismiss()
    }

    /// 相册图 → 长边 1600 的 JPEG（跟聊天发图一个量级）
    static func jpeg(from item: PhotosPickerItem?) async -> Data? {
        guard let item, let raw = try? await item.loadTransferable(type: Data.self),
              let img = UIImage(data: raw) else { return nil }
        let longest = max(img.size.width, img.size.height)
        let scale = min(1, 1600 / max(longest, 1))
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1                     // 按像素缩：默认是屏幕倍数，1600 会变成 4800 像素宽（09-29 真机传不上去）
        let out = UIGraphicsImageRenderer(size: size, format: format).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        return out.jpegData(compressionQuality: 0.72)
    }
}

/// 点一样东西：改名、改数、删掉。改了名又没填数 → 重新待估，AI 再估一次。
struct FoodEntrySheet: View {
    @EnvironmentObject var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: FoodStore
    let entry: FoodEntry
    @State private var text = ""
    @State private var detail = ""
    @State private var kcal: Double?
    @State private var protein: Double?
    @State private var carbs: Double?
    @State private var fat: Double?
    @State private var confirmDelete = false
    // 照片：已经记了的也能加 / 去掉，不限张数（Tilia 09-29）
    @State private var photos: [FoodPhoto] = []
    @State private var photoPicks: [PhotosPickerItem] = []
    @State private var shooting = false
    @State private var photoBusy = false

    var body: some View {
        NavigationStack {
            Form {
                Section(entry.meal == "运动" ? "做了什么" : "吃了什么") {
                    TextField("", text: $text, axis: .vertical).lineLimit(1...5)
                }
                Section("照片") {
                    if !photos.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(photos, id: \.id) { p in
                                    AuthImageView(urlPath: p.path)
                                        .frame(width: 120, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(alignment: .topTrailing) {
                                            Button { Task { await setPhotos(photos.filter { $0.id != p.id }.map(\.id)) } } label: {
                                                Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                                                    .foregroundStyle(.white, .black.opacity(0.5))
                                            }
                                            .padding(4)
                                        }
                                }
                            }
                        }
                    }
                    HStack(spacing: 18) {
                        PhotosPicker(selection: $photoPicks, maxSelectionCount: 0, matching: .images) {
                            Label("从相册加", systemImage: "photo")
                        }
                        if CameraPicker.isAvailable {
                            Button { shooting = true } label: { Label("拍一张", systemImage: "camera") }
                        }
                        Spacer()
                        if photoBusy { ProgressView() }
                    }
                    .buttonStyle(.borderless)
                }
                if entry.meal != "运动" {
                    Section {
                        TextField("鸡蛋2个 西红柿1个…", text: $detail, axis: .vertical).lineLimit(1...6)
                    } header: {
                        Text("里面有什么")
                    } footer: {
                        if let est = entry.detail_est, !est.isEmpty {
                            Text("\(FoodLogConfig.aiName)估的：\(entry.portion.map { $0.isEmpty ? "" : $0 + " · " } ?? "")\(est)")
                        }
                    }
                }
                Section {
                    row(entry.meal == "运动" ? "消耗" : "热量", $kcal, "kcal")
                    if entry.meal != "运动" {
                        row("蛋白质", $protein, "g")
                        row("碳水", $carbs, "g")
                        row("脂肪", $fat, "g")
                    }
                } footer: {
                    Text(entry.pending ? "\(FoodLogConfig.aiName)还在估。你也可以自己填。" :
                            ((entry.source == "ai" || entry.source == "him") ? "这条是\(FoodLogConfig.aiName)记的、\(FoodLogConfig.aiName)估的数。" : ""))
                }
                Section {
                    Button("删掉这条", role: .destructive) { confirmDelete = true }
                }
            }
            .scrollContentBackground(.hidden)   // 升到全屏也保持玻璃
            .containerBackground(.clear, for: .navigation)
            .navigationTitle(entry.meal)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            let textChanged = text != entry.text || detail != (entry.detail ?? "")
                            let numbersChanged = kcal != entry.kcal || protein != entry.protein
                                || carbs != entry.carbs || fat != entry.fat
                            // 只改了名、数没动 → 数清空让 AI 重估；动了数就按用户填的
                            await store.update(entry, text: text, detail: detail,
                                               kcal: (textChanged && !numbersChanged) ? nil : kcal,
                                               protein: protein, carbs: carbs, fat: fat)
                            dismiss()
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("删掉「\(entry.text)」？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删掉", role: .destructive) { Task { await store.delete(entry); dismiss() } }
            }
        }
        .tint(theme.accent)
        .onAppear {
            text = entry.text; detail = entry.detail ?? ""; kcal = entry.kcal; protein = entry.protein; carbs = entry.carbs; fat = entry.fat
            photos = entry.photos
        }
        .onChange(of: photoPicks) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var datas: [Data] = []
                for item in items { if let d = await FoodAddSheet.jpeg(from: item) { datas.append(d) } }
                photoPicks = []
                await addPhotos(datas)
            }
        }
        .fullScreenCover(isPresented: $shooting) {
            CameraPicker { d in Task { await addPhotos([d]) } }.ignoresSafeArea()
        }
    }

    /// 照片当场存（不等「保存」）：传上去，接在后面
    private func addPhotos(_ datas: [Data]) async {
        photoBusy = true
        defer { photoBusy = false }
        var ids = photos.map(\.id)
        for d in datas { if let id = await store.uploadPhoto(d) { ids.append(id) } }
        await setPhotos(ids)
    }

    private func setPhotos(_ ids: [String]) async {
        if await store.setPhotos(entry, ids: ids) {
            photos = store.day?.entries.first(where: { $0.id == entry.id })?.photos ?? []
        }
    }

    private func row(_ label: String, _ value: Binding<Double?>, _ unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", value: value, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
            Text(unit).foregroundStyle(.secondary)
        }
    }
}


/// 饮食两个弹窗的底：升到全屏也保持磨砂玻璃（系统默认半窗是玻璃、全屏变纯色），
/// 跟 Record 门厅同一个配方
struct FoodSheetGlass: View {
    /// 输入框和按钮的底：固定一层浅灰。原来用系统的 .background.secondary，
    /// 半屏（玻璃）时是灰的、全屏时跟弹窗一个颜色看不见了
    static let field = Color.black.opacity(0.06)

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color.white.opacity(0.22)
        }
        .ignoresSafeArea()
    }
}
