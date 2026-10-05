#if LITE
import Foundation
import MeleLiteCore

/// 人物卡 / 远事交给记忆库以后（10-04 Tilia，方案 A）：房间读写远端，搬过去 / 搬回来。
/// 用户在房间里写的走记忆库网页接口 /api（by=user，TA 改不动）；TA 用工具记的走 MCP（by=ai）。
/// 远端的 id 在手机里写成负数：-(远端 id × 100 + 第几个服务)，PATCH / DELETE 不用另带来源。
enum LocalMemoryRooms {
    // MARK: - id 编码

    static func encode(_ id: Int, server: Int) -> Int { -(id * 100 + server + 1) }
    static func decode(_ x: Int) -> (id: Int, server: Int)? {
        guard x < 0 else { return nil }
        let n = -x
        return (n / 100, n % 100 - 1)
    }

    // MARK: - 远端网页接口

    static func api(_ host: LocalHost, _ sv: LocalMCP.Server, _ method: String, _ path: String, _ body: [String: Any]? = nil) async -> LocalResponse {
        guard let url = URL(string: LocalMCP.webBase(sv.url) + path) else { return .error(400, String(localized: "地址不对")) }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        if let t = host.mcp.vault.get(sv.id) { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 { host.mcp.mark(sv.id, MCPError.unauthorized); return .error(502, String(localized: "记忆库的钥匙不对")) }   // 不回 401：App 看到 401 会以为登录过期
            let obj = (try? JSONSerialization.jsonObject(with: data)) ?? [:]
            guard (200..<300).contains(status) else {
                return .error(status, (obj as? [String: Any])?["detail"] as? String ?? String(localized: "记忆库没收下"))
            }
            return .json(obj, status: status)
        } catch {
            host.mcp.mark(sv.id, error)
            return .error(503, String(localized: "连不上记忆库"))
        }
    }

    static func mcp(_ host: LocalHost, _ sv: LocalMCP.Server, _ tool: String, _ args: [String: Any]) async -> Bool {
        guard let c = host.mcp.client(sv),
              let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap({ String(data: $0, encoding: .utf8) }) else { return false }
        do { return !(try await c.call(tool, argumentsJSON: json)).isError } catch { host.mcp.mark(sv.id, error); return false }
    }

    static func index(_ host: LocalHost, _ sv: LocalMCP.Server) -> Int { host.mcp.servers(host.store).firstIndex { $0.id == sv.id } ?? 0 }
    static func server(_ host: LocalHost, index: Int) -> LocalMCP.Server? {
        let all = host.mcp.servers(host.store)
        return all.indices.contains(index) ? all[index] : nil
    }

    // MARK: - 形状转换

    static func personOut(_ p: [String: Any], sv: LocalMCP.Server, index: Int) -> [String: Any] {
        ["id": encode(p["id"] as? Int ?? 0, server: index), "name": p["name"] ?? "", "aliases": p["aliases"] ?? [String](),
         "relation": p["relation"] ?? "", "facts": p["content"] ?? "", "impression": p["impression"] ?? "",
         "created_by": p["created_by"] ?? "user", "updated_by": p["updated_by"] ?? "user", "updated_at": p["updated_at"] ?? "",
         "hidden_from": [String](), "source": sv.id]
    }

    static func personIn(_ b: [String: Any]) -> [String: Any] {
        var o: [String: Any] = [:]
        for k in ["name", "aliases", "relation", "impression"] where b[k] != nil { o[k] = b[k] }
        if let f = b["facts"] { o["content"] = f }
        return o
    }

    static func dateOut(_ d: [String: Any], companion: String, sv: LocalMCP.Server, index: Int) -> [String: Any] {
        LocalRooms.dateOut(["id": encode(d["id"] as? Int ?? 0, server: index), "companion_id": companion, "day": d["day"] ?? "",
                            "time": d["at_time"] ?? "", "title": d["title"] ?? "", "note": d["note"] ?? "", "source": sv.id])
    }

    static func remotePeople(_ host: LocalHost, _ sv: LocalMCP.Server) async -> [[String: Any]]? {
        guard case .json(let v, _) = await api(host, sv, "GET", "/api/people") else { return nil }
        return (v as? [String: Any])?["people"] as? [[String: Any]]
    }

    static func remoteDates(_ host: LocalHost, _ sv: LocalMCP.Server, resolved: Bool = false) async -> [[String: Any]]? {
        guard case .json(let v, _) = await api(host, sv, "GET", "/api/dates" + (resolved ? "?resolved=1" : "")) else { return nil }
        return (v as? [String: Any])?["dates"] as? [[String: Any]]
    }

    /// 这个 TA 的远事归记忆库吗
    static func datesServer(_ host: LocalHost, companion cid: String) -> LocalMCP.Server? {
        guard let comp = host.store.companions.first(where: { ($0["id"] as? String) == cid }),
              let sv = host.mcp.memoryServer(host.store, companion: comp) else { return nil }
        let st = comp["settings"] as? [String: Any] ?? [:]
        return (st["memory_dates"] as? String ?? "remote") == "remote" ? sv : nil
    }

    // MARK: - 路由

    static func handle(_ r: LocalRequest, host: LocalHost) async -> LocalResponse? {
        let p = r.parts
        switch (r.method, p.first ?? "", p.count) {
        case ("GET", "people", 2) where p[1] == "sources":
            var out: [[String: Any]] = [["id": NSNull(), "name": String(localized: "手机")]]
            var seen: Set<String> = []
            for c in host.store.companions {
                let st = c["settings"] as? [String: Any] ?? [:]
                guard (st["memory_people"] as? String ?? "remote") == "remote",
                      let sv = host.mcp.memoryServer(host.store, companion: c), seen.insert(sv.id).inserted else { continue }
                out.append(["id": sv.id, "name": sv.name])
            }
            return .json(out)
        case ("GET", "people", 1):
            guard let sid = r.query["source"], let sv = host.mcp.servers(host.store).first(where: { $0.id == sid }) else { return nil }
            guard let list = await remotePeople(host, sv) else { return .error(503, String(localized: "连不上记忆库")) }
            let i = index(host, sv)
            return .json(list.map { personOut($0, sv: sv, index: i) })
        case ("POST", "people", 1):
            guard let sid = r.query["source"], let sv = host.mcp.servers(host.store).first(where: { $0.id == sid }) else { return nil }
            let res = await api(host, sv, "POST", "/api/people", personIn(r.json))
            guard case .json(let v, _) = res, let pp = (v as? [String: Any])?["person"] as? [String: Any] else { return res }
            return .json(personOut(pp, sv: sv, index: index(host, sv)), status: 201)
        case ("PATCH", "people", 2):
            guard let (id, i) = Int(p[1]).flatMap(decode), let sv = server(host, index: i) else { return nil }
            let res = await api(host, sv, "PATCH", "/api/people/\(id)", personIn(r.json))
            guard case .json(let v, _) = res, let pp = (v as? [String: Any])?["person"] as? [String: Any] else { return res }
            return .json(personOut(pp, sv: sv, index: i))
        case ("DELETE", "people", 2):
            guard let (id, i) = Int(p[1]).flatMap(decode), let sv = server(host, index: i) else { return nil }
            let res = await api(host, sv, "DELETE", "/api/memories/\(id)")
            if case .json = res { return .empty }
            return res
        case ("GET", "companions", 3) where p[2] == "dates":
            guard let sv = datesServer(host, companion: p[1]) else { return nil }
            guard let list = await remoteDates(host, sv) else { return .error(503, String(localized: "连不上记忆库")) }
            let i = index(host, sv)
            return .json(list.map { dateOut($0, companion: p[1], sv: sv, index: i) })
        case ("POST", "companions", 3) where p[2] == "dates":
            guard let sv = datesServer(host, companion: p[1]) else { return nil }
            let b = r.json
            let title = (b["title"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return .error(400, String(localized: "写一下是什么事")) }
            guard let day = b["day"] as? String, day.count == 10 else { return .error(400, "day 要写成 YYYY-MM-DD") }
            guard await mcp(host, sv, "date_add", ["day": day, "title": title, "at_time": b["time"] as? String ?? "", "note": b["note"] as? String ?? ""])
            else { return .error(503, String(localized: "连不上记忆库")) }
            return .json(LocalRooms.dateOut(["id": 0, "companion_id": p[1], "day": day, "time": b["time"] ?? "", "title": title, "note": b["note"] ?? ""]), status: 201)
        case ("PATCH", "dates", 2):
            guard let (id, i) = Int(p[1]).flatMap(decode), let sv = server(host, index: i) else { return nil }
            var body: [String: Any] = [:]
            for k in ["day", "title", "note"] where r.json[k] != nil { body[k] = r.json[k] }
            if let t = r.json["time"] { body["at_time"] = t }
            let res = await api(host, sv, "PATCH", "/api/dates/\(id)", body)
            guard case .json(let v, _) = res, let d = (v as? [String: Any])?["date"] as? [String: Any] else { return res }
            return .json(dateOut(d, companion: "", sv: sv, index: i))
        case ("DELETE", "dates", 2):
            guard let (id, i) = Int(p[1]).flatMap(decode), let sv = server(host, index: i) else { return nil }
            let res = await api(host, sv, "DELETE", "/api/dates/\(id)")
            if case .json = res { return .empty }
            return res
        case ("POST", "companions", 3) where p[2] == "memory":
            return await setMemory(host, companion: p[1], r.json)
        default:
            return nil
        }
    }

    // MARK: - TA 设定：接哪个记忆库、人物卡 / 远事归哪边、要不要搬

    static func setMemory(_ host: LocalHost, companion cid: String, _ b: [String: Any]) async -> LocalResponse {
        let s = host.store
        guard var comp = s.companions.first(where: { ($0["id"] as? String) == cid }) else { return .error(404, String(localized: "没有这个联系人")) }
        var st = comp["settings"] as? [String: Any] ?? [:]
        let oldServer = st["memory_server"] as? String
        let oldPeople = oldServer == nil ? "local" : (st["memory_people"] as? String ?? "remote")
        let oldDates = oldServer == nil ? "local" : (st["memory_dates"] as? String ?? "remote")
        let newServer = b.keys.contains("server") ? b["server"] as? String : oldServer
        let newPeople = newServer == nil ? "local" : (b["people"] as? String ?? st["memory_people"] as? String ?? "remote")
        let newDates = newServer == nil ? "local" : (b["dates"] as? String ?? st["memory_dates"] as? String ?? "remote")
        st["memory_server"] = newServer ?? NSNull()
        st["memory_people"] = b["people"] as? String ?? st["memory_people"] ?? "remote"
        st["memory_dates"] = b["dates"] as? String ?? st["memory_dates"] ?? "remote"
        comp["settings"] = st
        s.saveCompanion(comp)

        var out: [String: Any] = ["moved_people": 0, "moved_dates": 0]
        guard b["move"] as? Bool ?? false else { return .json(out) }
        let servers = host.mcp.servers(s)
        let target = newServer.flatMap { id in servers.first { $0.id == id } }
        let source = oldServer.flatMap { id in servers.first { $0.id == id } }
        do {
            if newPeople == "remote", let sv = target, oldPeople != "remote" || oldServer != newServer {
                out["moved_people"] = try await peopleToRemote(host, sv, companion: cid)
            } else if newPeople == "local", oldPeople == "remote", let sv = source {
                out["moved_people"] = try await peopleToLocal(host, sv)
            }
            if newDates == "remote", let sv = target, oldDates != "remote" || oldServer != newServer {
                out["moved_dates"] = try await datesToRemote(host, sv, companion: cid)
            } else if newDates == "local", oldDates == "remote", let sv = source {
                out["moved_dates"] = try await datesToLocal(host, sv, companion: cid)
            }
        } catch {
            out["detail"] = String(localized: "连不上记忆库，没搬完")
        }
        return .json(out)
    }

    struct Offline: Error {}

    static func movePerson(_ d: [String: Any], remote: Bool) -> MovePerson {
        MovePerson(id: d["id"] as? Int, name: d["name"] as? String ?? "", aliases: d["aliases"] as? [String] ?? [],
                   relation: d["relation"] as? String ?? "", facts: (remote ? d["content"] : d["facts"]) as? String ?? "",
                   impression: d["impression"] as? String ?? "", byUser: (d["created_by"] as? String) != "ai")
    }

    static func peopleToRemote(_ host: LocalHost, _ sv: LocalMCP.Server, companion cid: String) async throws -> Int {
        guard let remote = await remotePeople(host, sv) else { throw Offline() }
        let mine = host.store.collection("people").filter { !(($0["hidden_from"] as? [String]) ?? []).contains(cid) }
        let plan = MemoryMove.people(from: mine.map { movePerson($0, remote: false) }, into: remote.map { movePerson($0, remote: true) },
                                     sourceWinsTies: true)
        var n = 0
        for step in plan {
            let ok: Bool
            switch step {
            case .create(let p), .overwrite(_, let p):
                let fields: [String: Any] = ["name": p.name, "aliases": p.aliases, "relation": p.relation, "content": p.facts, "impression": p.impression]
                if p.byUser {
                    if case .overwrite(let tid, _) = step { ok = await isJSON(api(host, sv, "PATCH", "/api/people/\(tid)", fields)) }
                    else { ok = await isJSON(api(host, sv, "POST", "/api/people", fields)) }
                } else {
                    ok = await mcp(host, sv, "person_upsert", fields)
                }
            case .addAliases(let tid, let extra):
                let have = remote.first { ($0["id"] as? Int) == tid }?["aliases"] as? [String] ?? []
                ok = await isJSON(api(host, sv, "PATCH", "/api/people/\(tid)", ["aliases": have + extra]))
            }
            guard ok else { throw Offline() }
            n += 1
        }
        return n
    }

    static func peopleToLocal(_ host: LocalHost, _ sv: LocalMCP.Server) async throws -> Int {
        guard let remote = await remotePeople(host, sv) else { throw Offline() }
        let s = host.store
        var mine = s.collection("people")
        let plan = MemoryMove.people(from: remote.map { movePerson($0, remote: true) }, into: mine.map { movePerson($0, remote: false) },
                                     sourceWinsTies: false)
        for step in plan {
            switch step {
            case .create(let p):
                mine.append(["id": s.nextID("person"), "name": p.name, "aliases": p.aliases, "relation": p.relation, "facts": p.facts,
                             "impression": p.impression, "created_by": p.byUser ? "user" : "ai", "updated_by": p.byUser ? "user" : "ai",
                             "updated_at": LocalStore.iso(Date()), "hidden_from": [String]()])
            case .overwrite(let tid, let p):
                guard let i = mine.firstIndex(where: { ($0["id"] as? Int) == tid }) else { continue }
                for (k, v) in ["aliases": p.aliases, "relation": p.relation, "facts": p.facts, "impression": p.impression,
                               "created_by": p.byUser ? "user" : "ai"] as [String: Any] { mine[i][k] = v }
                mine[i]["updated_at"] = LocalStore.iso(Date())
            case .addAliases(let tid, let extra):
                guard let i = mine.firstIndex(where: { ($0["id"] as? Int) == tid }) else { continue }
                mine[i]["aliases"] = (mine[i]["aliases"] as? [String] ?? []) + extra
            }
        }
        s.saveCollection("people", mine)
        return plan.count
    }

    static func moveDate(_ d: [String: Any], remote: Bool) -> MoveDate {
        MoveDate(day: d["day"] as? String ?? "", title: d["title"] as? String ?? "",
                 time: (remote ? d["at_time"] : d["time"]) as? String ?? "", note: d["note"] as? String ?? "")
    }

    static func datesToRemote(_ host: LocalHost, _ sv: LocalMCP.Server, companion cid: String) async throws -> Int {
        guard let remote = await remoteDates(host, sv, resolved: true) else { throw Offline() }
        let s = host.store
        var all = s.collection("dates")
        let mineIdx = all.indices.filter { (all[$0]["companion_id"] as? String) == cid && all[$0]["moved_to"] == nil }
        let add = MemoryMove.dates(from: mineIdx.map { moveDate(all[$0], remote: false) }, into: remote.map { moveDate($0, remote: true) })
        for d in add {
            guard await mcp(host, sv, "date_add", ["day": d.day, "title": d.title, "at_time": d.time, "note": d.note]) else { throw Offline() }
        }
        for i in mineIdx { all[i]["moved_to"] = sv.id }
        s.saveCollection("dates", all)
        return add.count
    }

    static func datesToLocal(_ host: LocalHost, _ sv: LocalMCP.Server, companion cid: String) async throws -> Int {
        guard let remote = await remoteDates(host, sv) else { throw Offline() }
        let s = host.store
        var all = s.collection("dates")
        for i in all.indices where (all[i]["companion_id"] as? String) == cid && (all[i]["moved_to"] as? String) == sv.id {
            all[i].removeValue(forKey: "moved_to")
        }
        let mine = all.filter { ($0["companion_id"] as? String) == cid }
        let add = MemoryMove.dates(from: remote.map { moveDate($0, remote: true) }, into: mine.map { moveDate($0, remote: false) })
        for d in add {
            all.append(["id": s.nextID("date"), "companion_id": cid, "day": d.day, "time": d.time, "title": d.title, "note": d.note])
        }
        s.saveCollection("dates", all)
        return add.count
    }

    static func isJSON(_ r: LocalResponse) -> Bool { if case .json = r { true } else { false } }
}
#endif
