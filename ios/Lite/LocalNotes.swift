#if LITE
import Foundation

/// 「TA 刚做了什么，下一轮告诉它一声」（10-05 对照服务器补的）：表情、拆信、饮食、钱包、快到的远事，外加每轮最后那行人设锚。
/// 措辞照服务器原话（brain/reactions.py、drawer.py、far_dates.py、wallet.py、food/store.py、inject.py 的 anchor）。
/// 取了就标 told；没有 told 这个键的老条目当作已经说过（别一升级就把攒了几个月的全倒给它）。
enum LocalNotes {
    static let snip = 20
    static let nearDays = 14, maxDateLines = 5
    static let walletGap: TimeInterval = 12 * 3600
    static let reshow: TimeInterval = 2 * 3600

    /// TA 给它哪句点了表情（这个窗口）
    static func reactionLines(_ s: LocalStore, conversation conv: String, zh: Bool) -> [String] {
        var list = s.messages(conv)
        var out: [String] = []
        for i in list.indices where list[i]["reaction_told"] as? Bool == false {
            list[i]["reaction_told"] = true
            guard let e = list[i]["reaction"] as? String, !e.isEmpty else { continue }
            let t = (list[i]["text"] as? String ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let cut = t.count <= snip ? t : String(t.prefix(snip)) + "…"
            out.append(zh ? "〔TA 给你那句「\(cut)」点了 \(e)〕" : "〔They reacted \(e) to your line \"\(cut)\"〕")
        }
        if !out.isEmpty || list.contains(where: { $0["reaction_told"] as? Bool == false }) { s.saveMessages(conv, list) }
        return out
    }

    /// TA 拆了它哪封信
    static func openedLines(_ s: LocalStore, companion cid: String, zh: Bool) -> [String] {
        var all = s.collection("drawer")
        var out: [String] = []
        for i in all.indices where (all[i]["companion_id"] as? String) == cid && all[i]["told_opened"] as? Bool == false {
            all[i]["told_opened"] = true
            let d = LocalStore.date(all[i]["written_at"])
            let md = Calendar.current.dateComponents([.month, .day], from: d)
            let title = all[i]["title"] as? String ?? ""
            out.append(zh ? "〔TA 拆了你 \(md.month ?? 0)/\(md.day ?? 0) 写的那封\(title.isEmpty ? "" : "《\(title)》")〕"
                          : "〔They opened the letter you wrote on \(md.month ?? 0)/\(md.day ?? 0)\(title.isEmpty ? "" : " \"\(title)\"")〕")
        }
        if !out.isEmpty { s.saveCollection("drawer", all) }
        return out
    }

    /// 〔饮食〕TA 自己在饮食页记的（它工具记的不算），估好了才说
    static func foodNote(_ s: LocalStore, zh: Bool) -> String {
        var all = s.collection("food")
        var items: [String] = []
        for i in all.indices where all[i]["told"] as? Bool == false && (all[i]["status"] as? String) != "pending" {
            all[i]["told"] = true
            let meal = all[i]["meal"] as? String ?? "", text = all[i]["text"] as? String ?? ""
            if (all[i]["status"] as? String) == "failed" {
                items.append(zh ? "\(meal) \(text)（没估出来）" : "\(meal) \(text) (couldn't estimate)")
            } else {
                let k = Int(((all[i]["kcal"] as? Double) ?? Double(all[i]["kcal"] as? Int ?? 0)).rounded())
                items.append(zh ? "\(meal) \(text)（约 \(k) 千卡）" : "\(meal) \(text) (~\(k) kcal)")
            }
        }
        guard !items.isEmpty else { return "" }
        s.saveCollection("food", all)
        let today = LocalRooms.today()
        let total = LocalFood.summary(all.filter { ($0["date"] as? String) == today }, nil)["kcal"] as? Int ?? 0
        return zh ? "〔饮食〕TA 刚记了：\(items.joined(separator: "；"))。今天一共 \(total) 千卡。"
                  : "〔Food〕They just logged: \(items.joined(separator: "; ")). \(total) kcal so far today."
    }

    /// 〔钱包〕TA 自己记的、它还没听说的；离上次提过半天以上才给一次
    static func walletNote(_ s: LocalStore, zh: Bool) -> String {
        var st = s.read("notes-state.json") as? [String: Any] ?? [:]
        if let at = st["wallet_told_at"] as? String, Date().timeIntervalSince(LocalStore.date(at)) < walletGap { return "" }
        var all = s.collection("wallet")
        let fresh = all.indices.filter { all[$0]["told"] as? Bool == false }
        guard !fresh.isEmpty else { return "" }
        for i in fresh { all[i]["told"] = true }
        s.saveCollection("wallet", all)
        st["wallet_told_at"] = LocalStore.iso(Date())
        s.write("notes-state.json", st)
        let ws = LocalRooms2.walletSettings(s)
        let sym = ws["symbol"] as? String ?? ""
        func money(_ c: Int) -> String {
            String(format: "%@%.2f", sym, Double(c) / 100).replacingOccurrences(of: ".00", with: "")
        }
        let items = fresh.suffix(8).map { i -> String in
            let e = all[i]
            let note = e["note"] as? String ?? ""
            return ((e["kind"] as? String) == "in" ? "+" : "") + "\(e["category"] as? String ?? "") \(money(e["amount"] as? Int ?? 0))"
                + (note.isEmpty ? "" : (zh ? "（\(note)）" : " (\(note))"))
        }
        let month = String((all[fresh.last!]["day"] as? String ?? LocalRooms.today()).prefix(7))
        let spent = all.filter { ($0["kind"] as? String ?? "out") == "out" && ($0["day"] as? String ?? "").hasPrefix(month) }
            .reduce(0) { $0 + ($1["amount"] as? Int ?? 0) }
        let budget = ws["budget"] as? Int ?? 0
        if zh {
            return "〔钱包〕TA 最近记了：\(items.joined(separator: "、"))。这个月花了 \(money(spent))\(budget > 0 ? "，预算 \(money(budget))" : "")。"
                + "想提就随口提一句（像朋友那样，不评判花多花少、不说教）。"
        }
        return "〔Wallet〕They recently logged: \(items.joined(separator: ", ")). Spent \(money(spent)) this month\(budget > 0 ? ", budget \(money(budget))" : ""). "
            + "Mention it in passing if you feel like it (like a friend — no judging, no lecturing)."
    }

    /// 快到的远事（昨天没了结的到两周内，最多 5 行）；跟〔TA 那边〕一个规矩：变了才给、隔两小时再给
    static func datesLines(_ s: LocalStore, companion cid: String, conversation conv: String, zh: Bool) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
        guard let today = f.date(from: LocalRooms.today()) else { return "" }
        let rows = s.collection("dates").filter {
            ($0["companion_id"] as? String) == cid && ($0["resolved_at"] == nil || $0["resolved_at"] is NSNull)
        }.compactMap { d -> (Int, String, [String: Any])? in
            guard let day = f.date(from: d["day"] as? String ?? "") else { return nil }
            let n = Int((day.timeIntervalSince(today) / 86400).rounded())
            return (-1...nearDays).contains(n) ? (n, (d["day"] as? String ?? "") + (d["time"] as? String ?? ""), d) : nil
        }.sorted { ($0.0, $0.1) < ($1.0, $1.1) }.prefix(maxDateLines)
        let lines = rows.map { n, _, d -> String in
            let t = d["title"] as? String ?? "", time = d["time"] as? String ?? ""
            let at = time.isEmpty ? "" : (zh ? "（\(time)）" : " (\(time))")
            let md = (d["day"] as? String ?? "").split(separator: "-").suffix(2).compactMap { Int($0) }.map(String.init).joined(separator: "/")
            switch n {
            case -1: return zh ? "昨天：\(t)（还没问怎么样）" : "Yesterday: \(t) (haven't asked how it went)"
            case 0: return zh ? "今天：\(t)\(at)" : "Today: \(t)\(at)"
            case 1: return zh ? "明天：\(t)\(at)" : "Tomorrow: \(t)\(at)"
            default: return zh ? "还有 \(n) 天：\(md) \(t)\(at)" : "In \(n) days: \(md) \(t)\(at)"
            }
        }
        let text = lines.joined(separator: "\n")
        guard !text.isEmpty, var c = s.conversation(conv) else { return "" }
        let key = text                                   // 最多 5 行，直接拿原文当指纹
        if (c["dates_key"] as? String) == key, let at = c["dates_at"] as? String,
           Date().timeIntervalSince(LocalStore.date(at)) < reshow { return "" }
        c["dates_key"] = key
        c["dates_at"] = LocalStore.iso(Date())
        s.saveConversation(c)
        return text
    }

    /// 人设锚（服务器 10-01：怕脱离人设）：每轮离它开口最近的一行
    static func anchor(_ name: String, zh: Bool) -> String {
        let n = name.isEmpty ? "Lumi" : name
        return zh ? "〔你是\(n)〕照你自己的性格和口吻回。" : "〔You are \(n)〕Answer in your own personality and voice."
    }

    /// 它自己用工具记的（钱包 / 饮食）：不用再告诉它
    static func markTold(_ s: LocalStore, _ collection: String, id: Any?) {
        guard let id = id as? Int else { return }
        var all = s.collection(collection)
        guard let i = all.firstIndex(where: { ($0["id"] as? Int) == id }) else { return }
        all[i]["told"] = true
        s.saveCollection(collection, all)
    }
}
#endif
