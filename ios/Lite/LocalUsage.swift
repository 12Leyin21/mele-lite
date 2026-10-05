#if LITE
import Foundation
import MeleLiteCore

/// 用量 + 水位（10-04 Tilia）。
/// - 用量：零件包每次调完模型报一声（UsageMeter），这里按「天 × 模型」记进 rooms/usage.json；Me →「用量」看。
///   聊天、写日记、起世界、解塔罗、估饮食……走零件包的都算进来。
/// - 水位：每轮聊天记下这次实际喂了多少 token、聊天记录占了多少字；聊天页左下角一行「当前多少 · 还剩多少满」。
///   到了记性长度，回声（LocalEcho）就把旧的卷进账本。
enum LocalUsage {
    private static let once = NSLock()
    nonisolated(unsafe) private static var installed = false

    static func install(_ host: LocalHost) {
        once.lock(); defer { once.unlock() }
        guard !installed else { return }
        installed = true
        UsageMeter.setSink { [weak host] model, u in
            guard let s = host?.store else { return }
            record(s, model: model, u)
        }
    }

    private static let lock = NSLock()

    static func record(_ s: LocalStore, model: String, _ u: Usage) {
        lock.withLock {
            let day = LocalRooms.today()
            var all = s.collection("usage")
            if let i = all.firstIndex(where: { ($0["day"] as? String) == day && ($0["model"] as? String) == model }) {
                for (k, v) in [("calls", 1), ("input", u.input), ("cache_read", u.cacheRead), ("cache_write", u.cacheWrite), ("output", u.output)] {
                    all[i][k] = (all[i][k] as? Int ?? 0) + v
                }
            } else {
                all.append(["day": day, "model": model, "calls": 1, "input": u.input, "cache_read": u.cacheRead,
                            "cache_write": u.cacheWrite, "output": u.output])
            }
            // 只留 60 天
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            let cut = Calendar.current.date(byAdding: .day, value: -60, to: Date()).map { df.string(from: $0) } ?? ""
            s.saveCollection("usage", all.filter { ($0["day"] as? String ?? "") >= cut })
        }
    }

    /// 水位：这一轮聊天（第一次调用，没算工具来回）实际喂了多少，聊天记录多少字，整份多少字
    static func noteTurn(_ s: LocalStore, conversation: String, usage: Usage, req: ChatRequest) {
        guard var c = s.conversation(conversation) else { return }
        let all = s.messages(conversation).reduce(0) { $0 + ($1["text"] as? String ?? "").count }
        let sent = req.system.count + req.context.count + req.turns.reduce(0) { $0 + $1.text.count }
        c["gauge"] = ["tokens": usage.prompt, "chars_sent": max(1, sent), "history_chars": all, "at": LocalStore.iso(Date())]
        s.saveConversation(c)
    }

    static func handle(_ r: LocalRequest, host: LocalHost) -> LocalResponse? {
        let p = r.parts, s = host.store
        switch (r.method, p.count) {
        case ("GET", 1) where p[0] == "usage":
            return .json(days(s))
        case ("GET", 3) where p[0] == "conversations" && p[2] == "gauge":
            return .json(gauge(s, p[1]))
        default:
            return nil
        }
    }

    // MARK: 水位

    /// 「满」= 到记性长度（回声要卷了）。还剩 = 记性长度 − 上一轮实际喂的 token
    static func gauge(_ s: LocalStore, _ conv: String) -> [String: Any] {
        guard let g = s.conversation(conv)?["gauge"] as? [String: Any], let tokens = g["tokens"] as? Int, tokens > 0 else {
            return ["tokens": 0, "remaining": 0, "full": false, "known": false]
        }
        let comp = s.conversation(conv).flatMap { $0["companion_id"] as? String }.flatMap { s.companion($0) }
        let high = LocalEcho.highWater(comp?["settings"] as? [String: Any] ?? [:])
        return ["tokens": tokens, "remaining": max(0, high - tokens), "full": tokens >= high, "known": true]
    }

    // MARK: 用量页

    static func days(_ s: LocalStore) -> [[String: Any]] {
        let rows = s.collection("usage")
        let byDay = Dictionary(grouping: rows) { $0["day"] as? String ?? "" }
        return byDay.keys.sorted(by: >).map { day in
            let models = (byDay[day] ?? []).map { r -> [String: Any] in
                var o = r
                if let c = cost(r) { o["cost"] = c }
                return o
            }.sorted { ($0["calls"] as? Int ?? 0) > ($1["calls"] as? Int ?? 0) }
            return ["day": day, "models": models]
        }
    }

    /// 按价目估美元（每百万 token）；Claude 1 小时缓存写入 = 输入价 × 2。价目表里找不到这个模型就不估
    static func cost(_ r: [String: Any]) -> Double? {
        let model = (r["model"] as? String ?? "").lowercased()
        guard !model.isEmpty, let p = LocalHost.catalog.first(where: { e in
            let id = (e["id"] as? String ?? "").lowercased()
            return id == model || model.hasPrefix(id) || id.hasPrefix(model)
        }) else { return nil }
        let pin = p["price_in"] as? Double ?? 0, pcache = p["price_cache_read"] as? Double ?? pin, pout = p["price_out"] as? Double ?? 0
        let writeMul = (p["provider"] as? String) == "anthropic" ? 2.0 : 1.0
        let n = { (k: String) in Double(r[k] as? Int ?? 0) }
        return (n("input") * pin + n("cache_read") * pcache + n("cache_write") * pin * writeMul + n("output") * pout) / 1_000_000
    }
}
#endif
