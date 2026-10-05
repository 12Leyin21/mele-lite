import SwiftUI
import UIKit

// MARK: - 可选中的正文（移植自之前自用的 App SelectableText，09-06 那版）
//
// 原生 UITextView：能逐句选中、复制、查词；选中的菜单里多两项「划线」「划线说两句」。
// 划线画成下划线（之前自用的 App 09-06 Tilia：不涂底），两个人的笔迹不同颜色；点一道划线开那一句的页边。

struct TextHighlight: Equatable {
    let text: String
    let location: Int?          // 在这一章正文里的 UTF-16 起点；对不上就退回第一处
    let color: UIColor
}

struct SelectableText: UIViewRepresentable {
    let text: String
    let fontSize: CGFloat
    let textColor: UIColor
    var highlights: [TextHighlight] = []
    /// 回调带上选区在本页正文里的 UTF-16 位置，标记按位置锚定
    var onHighlight: ((String, Int) -> Void)? = nil
    var onAnnotate: ((String, Int) -> Void)? = nil
    /// 点到一道已有的划线（2026-09-06 页边聊）：给那道线在本页的起点
    var onTapHighlight: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 9
        paragraph.paragraphSpacing = 10
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ])
        // 铺笔迹：按位置铺那一处；位置对不上（正文改过、老数据）就退回本页第一处
        let ns = text as NSString
        var resolved: [NSRange] = []
        for highlight in highlights where !highlight.text.isEmpty {
            let want = highlight.text as NSString
            var range = NSRange(location: NSNotFound, length: 0)
            if let loc = highlight.location, loc >= 0, loc + want.length <= ns.length,
               ns.substring(with: NSRange(location: loc, length: want.length)) == highlight.text {
                range = NSRange(location: loc, length: want.length)
            } else {
                range = ns.range(of: highlight.text)
            }
            if range.location != NSNotFound {
                // 2026-09-06 Tilia：划线改下划线，不涂底。颜色用实的（原来是给底色配的半透明）
                attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: range)
                attributed.addAttribute(.underlineColor, value: highlight.color.withAlphaComponent(0.9), range: range)
                resolved.append(range)
            }
        }
        context.coordinator.highlightRanges = resolved
        view.attributedText = attributed
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: SelectableText
        var highlightRanges: [NSRange] = []
        init(_ parent: SelectableText) { self.parent = parent }

        /// 单击落在某道划线上 → 开那道线的页边
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView, let onTap = parent.onTapHighlight,
                  view.selectedRange.length == 0 else { return }
            var point = gesture.location(in: view)
            point.x -= view.textContainerInset.left
            point.y -= view.textContainerInset.top
            let index = view.layoutManager.characterIndex(for: point, in: view.textContainer,
                                                          fractionOfDistanceBetweenInsertionPoints: nil)
            guard let hit = highlightRanges.first(where: { NSLocationInRange(index, $0) }) else { return }
            onTap(hit.location)
        }

        /// 选中文字的原生菜单里加两项：划线（安静的）、划线说两句（带话）
        func textView(_ textView: UITextView,
                      editMenuForTextIn range: NSRange,
                      suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0,
                  parent.onHighlight != nil || parent.onAnnotate != nil else {
                return UIMenu(children: suggestedActions)
            }
            let raw = (textView.text as NSString).substring(with: range)
            let selected = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !selected.isEmpty else { return UIMenu(children: suggestedActions) }
            // 去掉前面的空白之后，真正的起点往后挪了几个 UTF-16 单元
            let lead = (String(raw.prefix(while: { $0.isWhitespace || $0.isNewline })) as NSString).length
            let location = range.location + lead
            var actions: [UIMenuElement] = []
            if let onHighlight = parent.onHighlight {
                actions.append(UIAction(title: "划线", image: UIImage(systemName: "highlighter")) { _ in
                    onHighlight(selected, location)
                    textView.selectedTextRange = nil
                })
            }
            if let onAnnotate = parent.onAnnotate {
                actions.append(UIAction(title: "划线说两句", image: UIImage(systemName: "bubble.and.pencil")) { _ in
                    onAnnotate(selected, location)
                    textView.selectedTextRange = nil
                })
            }
            return UIMenu(children: actions + suggestedActions)
        }
    }
}
