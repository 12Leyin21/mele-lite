import Compression
import Foundation

/// 只读的 zip（10-05 导入官方聊天记录用）：从目录里找一个文件拿出来，认「不压缩」和「deflate」两种。
/// 官方导出包都是这两种；ZIP64（单个文件超过 4GB）不认。
public enum MiniZip {
    public enum Failure: Error, Equatable { case notZip, unsupported, broken }

    /// 按文件名找（只比最后一段，导出包里可能套了一层文件夹）；没有这个文件返回 nil
    public static func entry(_ name: String, in data: Data) throws -> Data? {
        try entry(in: data) { $0 == name }
    }

    /// 第一个文件名（最后一段）合条件的
    public static func entry(in data: Data, where match: (String) -> Bool) throws -> Data? {
        try scan(data, { match(($0 as NSString).lastPathComponent) }, all: false).first?.data
    }

    /// 完整路径合条件的全部文件（Google Takeout 的文件夹名才认得出是哪个产品）
    public static func entries(in data: Data, path match: (String) -> Bool) throws -> [(path: String, data: Data)] {
        try scan(data, match, all: true)
    }

    static func scan(_ data: Data, _ match: (String) -> Bool, all: Bool) throws -> [(path: String, data: Data)] {
        var found: [(path: String, data: Data)] = []
        let b = [UInt8](data)
        guard b.count >= 22, let eocd = (0...(b.count - 22)).reversed().first(where: { u32(b, $0) == 0x0605_4B50 }) else {
            throw Failure.notZip
        }
        let count = Int(u16(b, eocd + 10))
        var p = Int(u32(b, eocd + 16))
        for _ in 0..<count {
            guard p + 46 <= b.count, u32(b, p) == 0x0201_4B50 else { throw Failure.broken }
            let method = u16(b, p + 10)
            let packed = Int(u32(b, p + 20)), size = Int(u32(b, p + 24))
            let nameLen = Int(u16(b, p + 28)), extraLen = Int(u16(b, p + 30)), commentLen = Int(u16(b, p + 32))
            let local = Int(u32(b, p + 42))
            guard p + 46 + nameLen <= b.count else { throw Failure.broken }
            let path = String(decoding: b[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            p += 46 + nameLen + extraLen + commentLen
            guard match(path) else { continue }
            if packed == 0xFFFF_FFFF || size == 0xFFFF_FFFF { throw Failure.unsupported }
            guard local + 30 <= b.count, u32(b, local) == 0x0403_4B50 else { throw Failure.broken }
            let start = local + 30 + Int(u16(b, local + 26)) + Int(u16(b, local + 28))
            guard start + packed <= b.count else { throw Failure.broken }
            let raw = Array(b[start..<(start + packed)])
            switch method {
            case 0: found.append((path, Data(raw)))
            case 8: found.append((path, try inflate(raw, size: size)))
            default: throw Failure.unsupported
            }
            if !all { break }
        }
        return found
    }

    static func inflate(_ src: [UInt8], size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        var out = [UInt8](repeating: 0, count: size)
        let n = compression_decode_buffer(&out, size, src, src.count, nil, COMPRESSION_ZLIB)   // 苹果的 ZLIB = 裸 deflate
        guard n == size else { throw Failure.broken }
        return Data(out)
    }

    static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
