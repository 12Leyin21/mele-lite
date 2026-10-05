import Foundation

enum SSE {
    /// `data: {...}` → `{...}`；别的行（event:、注释、空行）→ nil
    static func data(_ line: String) -> String? {
        guard line.hasPrefix("data:") else { return nil }
        let rest = line.dropFirst(5)
        let s = rest.hasPrefix(" ") ? String(rest.dropFirst()) : String(rest)
        return s.isEmpty ? nil : s
    }
}
