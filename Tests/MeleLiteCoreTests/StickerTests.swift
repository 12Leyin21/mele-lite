import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MeleLiteCore

/// 一个按请求回固定描述的假模型，记下收到的请求
final class FakeClient: LLMClient, @unchecked Sendable {
    var reply: String
    var thinking: String
    var error: LLMError?
    private(set) var requests: [ChatRequest] = []
    init(reply: String, thinking: String = "", error: LLMError? = nil) { self.reply = reply; self.thinking = thinking; self.error = error }
    func stream(_ r: ChatRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        requests.append(r)
        let (reply, thinking, error) = (reply, thinking, error)
        return AsyncThrowingStream { c in
            if let error { c.finish(throwing: error); return }
            if !thinking.isEmpty { c.yield(.thinking(thinking)) }
            for ch in reply { c.yield(.text(String(ch))) }
            c.yield(.done(nil)); c.finish()
        }
    }
}

func solidPNG(_ gray: CGFloat = 0.5, size: Int = 64) -> Data {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return out as Data
}

@Suite struct StickerTests {
    @Test func sameImageOnce() throws {
        let lib = StickerLibrary(root: tempRoot())
        let a = try lib.add(solidPNG(0.3))
        let b = try lib.add(solidPNG(0.3))
        #expect(a.id == b.id && lib.all().count == 1)
        _ = try lib.add(solidPNG(0.7))
        #expect(lib.all().count == 2)
    }

    @Test func captionOnceWithImage() async throws {
        let lib = StickerLibrary(root: tempRoot())
        let s = try lib.add(solidPNG())
        let fake = FakeClient(reply: "一只灰色的方块，面无表情")
        let c = try await lib.caption(s, using: fake, lang: .zh)
        #expect(c.caption == "一只灰色的方块，面无表情" && c.captionedAt != nil)
        #expect(fake.requests.first?.turns.first?.imageJPEG != nil)
        _ = try await lib.caption(c, using: fake, lang: .zh)
        #expect(fake.requests.count == 1)
        #expect(lib.all().first?.caption == "一只灰色的方块，面无表情")
    }

    @Test func editCaptionAndRemove() throws {
        let lib = StickerLibrary(root: tempRoot())
        let s = try lib.add(solidPNG())
        try lib.setCaption(id: s.id, text: "我的心情")
        #expect(lib.all().first?.caption == "我的心情")
        try lib.remove(id: s.id)
        #expect(lib.all().isEmpty)
    }

    @Test func capAt300() throws {
        let lib = StickerLibrary(root: tempRoot(), limit: 3)
        for g in [0.1, 0.2, 0.3] { _ = try lib.add(solidPNG(g)) }
        #expect(throws: StickerLibrary.Full.self) { try lib.add(solidPNG(0.4)) }
    }

    @Test func bestMatch() throws {
        let lib = StickerLibrary(root: tempRoot())
        let a = try lib.add(solidPNG(0.1)); try lib.setCaption(id: a.id, text: "猫猫翻白眼")
        let b = try lib.add(solidPNG(0.2)); try lib.setCaption(id: b.id, text: "小狗抱抱")
        #expect(lib.match("猫猫翻白眼")?.id == a.id)
        #expect(lib.match("抱抱")?.id == b.id)
        #expect(lib.match("完全不相干") == nil)
    }

    @Test func cutoutOnPlainImageIsNil() async {
        #expect(await Cutout.liftSubject(solidPNG()) == nil)
    }
}
