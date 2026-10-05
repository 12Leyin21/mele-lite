import SwiftUI

// MARK: - 抽屉（远事 + 抽屉第 8 步，朴素版；Tilia 09-28 设计）
//
// 一个抽屉装着所有联系人写给你的信。你只看得见信封：From 谁、哪天写的、一把锁。
// 到了解锁日自己开；没到的点一下输它给的 4 位密码。样子（一堆乱乱叠着的信、手写体 From）等最后统一调 UI。

struct DrawerItemDTO: Decodable, Identifiable, Hashable {
    let id: Int
    let companionId: String
    let from: String
    let writtenAt: Date
    let unlockAt: String?
    let openable: Bool
    let opened: Bool
    let title: String?
    enum CodingKeys: String, CodingKey {
        case id, from, openable, opened, title
        case companionId = "companion_id", writtenAt = "written_at", unlockAt = "unlock_at"
    }

    var unlockDate: Date? {
        guard let unlockAt else { return nil }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: unlockAt)
    }
}

struct DrawerLetterDTO: Decodable, Identifiable {
    let id: Int
    let from: String
    let title: String
    let content: String
    let writtenAt: Date
    enum CodingKeys: String, CodingKey { case id, from, title, content; case writtenAt = "written_at" }
}

extension Notification.Name {
    /// 打开抽屉（首页小组件、推送都发这个）
    static let lumiOpenDrawer = Notification.Name("LumiOpenDrawer")
}

struct DrawerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    @State private var items: [DrawerItemDTO] = []
    @State private var loaded = false
    @State private var sort = "time"
    @State private var reading: DrawerLetterDTO?
    @State private var asking: DrawerItemDTO?
    @State private var code = ""
    @State private var error: String?

    private var sorted: [DrawerItemDTO] {
        switch sort {
        case "from": return items.sorted { ($0.from, $1.writtenAt) < ($1.from, $0.writtenAt) }
        case "open": return items.sorted { ($0.openable ? 0 : 1, $1.writtenAt) < ($1.openable ? 0 : 1, $0.writtenAt) }
        default: return items.sorted { $0.writtenAt > $1.writtenAt }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("排序", selection: $sort) {
                        Text("按时间").tag("time")
                        Text("按谁写的").tag("from")
                        Text("能拆的在前").tag("open")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                }
                if let error {
                    Text(error).font(Typo.sans(Typo.Size.callout)).foregroundStyle(.red)
                }
                if loaded && items.isEmpty {
                    Text("抽屉还是空的。TA 们偷偷写给你的信会放在这里。")
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                }
                ForEach(sorted) { item in
                    Button { tap(item) } label: { row(item) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground())
            .navigationTitle("抽屉")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关上") { dismiss() } } }
            .alert("输入钥匙", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
                TextField("4 位数", text: $code).keyboardType(.numberPad)
                Button("拆") { if let a = asking { Task { await open(a, code: code) } } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("\(asking?.from ?? "TA") 在聊天里告诉你的那串数字")
            }
            .sheet(item: $reading) { letter in LetterView(letter: letter).environmentObject(theme) }
        }
        .environment(\.colorScheme, .light)
        .task { await load() }
    }

    private func row(_ item: DrawerItemDTO) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.opened ? "envelope.open" : (item.openable ? "lock.open" : "lock"))
                .font(Typo.icon(17))
                .foregroundStyle(item.openable ? theme.accentDeep : theme.inkDim)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "From：\(item.from)")).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                if let t = item.title, !t.isEmpty {
                    Text(t).font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.ink)
                }
                Text(caption(item)).font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func caption(_ item: DrawerItemDTO) -> String {
        let written = String(localized: "\(item.writtenAt.formatted(.dateTime.month().day())) 写")
        if item.opened { return written + String(localized: " · 拆过了") }
        if item.openable { return written + String(localized: " · 今天能拆了") }
        if let d = item.unlockDate { return written + String(localized: " · \(d.formatted(.dateTime.month().day())) 解锁") }
        return written + String(localized: " · 等 TA 给你钥匙")
    }

    private func tap(_ item: DrawerItemDTO) {
        if item.openable { Task { await open(item, code: "") } }
        else { code = ""; asking = item }
    }

    private func load() async {
        do {
            items = try await model.api.call("GET", "drawer")
            error = nil
        } catch { self.error = error.localizedDescription }
        loaded = true
    }

    private func open(_ item: DrawerItemDTO, code: String) async {
        do {
            let letter: DrawerLetterDTO = try await model.api.call("POST", "drawer/\(item.id)/open", json: ["code": code])
            error = nil
            reading = letter
            await load()
        } catch { self.error = error.localizedDescription }
    }
}

/// 拆开的一封：From、标题、正文
struct LetterView: View {
    @EnvironmentObject private var theme: AppTheme
    @Environment(\.dismiss) private var dismiss
    let letter: DrawerLetterDTO

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(String(localized: "From：\(letter.from)"))
                        .font(Typo.sans(Typo.Size.callout)).foregroundStyle(theme.inkDim)
                    if !letter.title.isEmpty {
                        Text(letter.title).font(Typo.sans(Typo.Size.title, .semibold)).foregroundStyle(theme.ink)
                    }
                    Text(letter.content).font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                        .textSelection(.enabled)
                    Text(letter.writtenAt.formatted(.dateTime.year().month().day().hour().minute()))
                        .font(Typo.sans(Typo.Size.caption)).foregroundStyle(theme.inkDim)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 信纸垫一层毛玻璃（10-04 Tilia：壁纸花的时候字看不清；照书架的玻璃）
                .background {
                    RoundedRectangle(cornerRadius: Radii.card, style: .continuous).fill(.ultraThinMaterial)
                        .overlay(RoundedRectangle(cornerRadius: Radii.card, style: .continuous).fill(Color.white.opacity(0.45)))
                        .overlay(RoundedRectangle(cornerRadius: Radii.card, style: .continuous).stroke(Color.white.opacity(0.7), lineWidth: 1))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AppBackground())
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("好") { dismiss() } } }
        }
        .environment(\.colorScheme, .light)
    }
}
