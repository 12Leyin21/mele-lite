import SwiftUI
import UIKit

/// 气泡里的一点点格式（10-01 Tilia：线下模式动作用斜体、重点加粗）：*动作* → 斜体 + 淡一点；**重点** → 加粗。
/// 中文没有斜体字形，系统也不会替它斜，所以斜体用字体矩阵自己斜（中英文都斜）。其余 Markdown（标题、列表、链接）一律当原文。
enum RichText {
    private static let slant = CGAffineTransform(a: 1, b: 0, c: 0.21, d: 1, tx: 0, ty: 0)

    static func render(_ text: String, size: CGFloat, ink: Color) -> AttributedString {
        guard text.contains("*") || text.contains("_"),
              var out = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in out.runs {
            guard let intent = run.inlinePresentationIntent else { continue }
            let bold = intent.contains(.stronglyEmphasized)
            if intent.contains(.emphasized) {
                var desc = UIFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular).fontDescriptor
                desc = desc.withMatrix(slant)
                out[run.range].font = Font(UIFont(descriptor: desc, size: size))
                out[run.range].foregroundColor = ink.opacity(0.7)
            } else if bold {
                out[run.range].font = .system(size: size, weight: .semibold)
            }
            out[run.range].inlinePresentationIntent = nil
            out[run.range].link = nil
        }
        for run in out.runs where run.link != nil { out[run.range].link = nil }   // 链接不变蓝、不能点（原样）
        return out
    }
}
