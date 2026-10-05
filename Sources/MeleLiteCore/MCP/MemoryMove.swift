import Foundation

/// 人物卡 / 远事在手机和记忆库之间搬家的规矩（Tilia 10-04）：
/// 谁是用户写的以谁为准；两边都是用户写的（或都是 TA 写的），sourceWinsTies 决定（手机 → 记忆库时手机赢，搬回来时记忆库赢）。
public struct MovePerson: Equatable, Sendable {
    public var id: Int?
    public var name: String
    public var aliases: [String]
    public var relation: String
    public var facts: String
    public var impression: String
    public var byUser: Bool
    public init(id: Int?, name: String, aliases: [String], relation: String, facts: String, impression: String, byUser: Bool) {
        self.id = id; self.name = name; self.aliases = aliases; self.relation = relation
        self.facts = facts; self.impression = impression; self.byUser = byUser
    }
}

public enum PersonMove: Equatable, Sendable {
    case create(MovePerson)
    case overwrite(targetID: Int, MovePerson)
    case addAliases(targetID: Int, [String])
}

public struct MoveDate: Equatable, Sendable {
    public var day: String
    public var title: String
    public var time: String
    public var note: String
    public init(day: String, title: String, time: String, note: String) {
        self.day = day; self.title = title; self.time = time; self.note = note
    }
}

public enum MemoryMove {
    public static func people(from: [MovePerson], into: [MovePerson], sourceWinsTies: Bool) -> [PersonMove] {
        func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces).lowercased() }
        return from.compactMap { s in
            guard let t = into.first(where: { key($0.name) == key(s.name) }), let tid = t.id else { return .create(s) }
            let sourceWins = s.byUser == t.byUser ? sourceWinsTies : s.byUser
            if sourceWins { return .overwrite(targetID: tid, s) }
            let have = Set(([t.name] + t.aliases).map(key))
            let extra = ([s.name] + s.aliases).filter { !have.contains(key($0)) }
            return extra.isEmpty ? nil : .addAliases(targetID: tid, extra)
        }
    }

    public static func dates(from: [MoveDate], into: [MoveDate]) -> [MoveDate] {
        func key(_ d: MoveDate) -> String { d.day + "|" + d.title.trimmingCharacters(in: .whitespaces).lowercased() }
        var seen = Set(into.map(key))
        return from.filter { seen.insert(key($0)).inserted }
    }
}
