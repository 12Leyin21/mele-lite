import SwiftUI

// MARK: - 设定页的格子（10-03 Tilia）
//
// 不用 Form 的列表了：列表里一行行插进来时会闪、会露空（她试出来的）。改成自己排的格子：
// · 每一格一整块，底照「我的气泡」浅色 TA 那侧的样子，角跟气泡圆角，底下一层淡淡的影子；格子里不画分割线。
// · 小标题：毛玻璃胶囊，背景带一点主题色（字不变色）。
// · 点开 / 收起：内容在格子里长出来、把下面推开，只淡入淡出，不飞。

struct SettingsTileBackground: View {
    @EnvironmentObject private var theme: AppTheme
    @AppStorage("bubbleStyleLight") private var bubbleStyleLight = ""

    var style: BubbleStyle {
        var s = BubbleStyle.effective(raw: bubbleStyleLight, mode: .light) ?? .lightDefault
        s.tail = false
        s.highlight = false              // 叠高光会显得一格一格鼓起来
        return s
    }

    var body: some View {
        ChatBubbleBackground(skin: ChatSkin(mode: .light, accent: theme.accent, scale: 1, bubble: style), mine: false)
    }
}

/// 小标题（10-03 Tilia挑的 D）：不要胶囊，前面一道主题色细竖条 + 灰字
struct GlassHeader: View {
    @EnvironmentObject private var theme: AppTheme
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(theme.accent).frame(width: 3, height: 15)
            Text(title)
                .font(Typo.sans(Typo.Size.callout, .semibold))
                .foregroundStyle(theme.inkDim)
        }
        .padding(.leading, 4)
    }
}

/// 一格：可选的小标题、内容、可选的说明。用法跟 Section 一样（Tile { } header: { } footer: { }）。
struct Tile<Content: View, Header: View, Footer: View>: View {
    @EnvironmentObject private var theme: AppTheme
    let content: Content
    let header: Header
    let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.content = content(); self.header = header(); self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    SettingsTileBackground()
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 3)
                }
            footer
                .font(Typo.sans(Typo.Size.caption))
                .foregroundStyle(theme.inkFaint)
                .padding(.horizontal, 8)
        }
    }
}

extension Tile where Header == EmptyView, Footer == EmptyView {
    init(@ViewBuilder content: () -> Content) { self.init(content: content, header: { EmptyView() }, footer: { EmptyView() }) }
}
extension Tile where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) { self.init(content: content, header: header, footer: { EmptyView() }) }
}
extension Tile where Header == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) { self.init(content: content, header: { EmptyView() }, footer: footer) }
}

/// 左边一行说明、右边一个下拉选（列表外的 Picker 不会自己摆标签）
struct RowPicker<V: Hashable, Content: View, Label: View>: View {
    @EnvironmentObject private var theme: AppTheme
    let selection: Binding<V>
    let content: Content
    let label: Label

    init(selection: Binding<V>, @ViewBuilder content: () -> Content, @ViewBuilder label: () -> Label) {
        self.selection = selection; self.content = content(); self.label = label()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            label.layoutPriority(1)
            Spacer(minLength: 8)
            Picker(selection: selection) { content } label: { EmptyView() }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(theme.inkDim)          // 跟原来列表里一样：选中的值用灰字，不用主题色（浅主题色上看不清）
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// 整页：滚动 + 一格格往下排
struct TilePage<Content: View>: View {
    @EnvironmentObject private var theme: AppTheme
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .tint(theme.accent)              // 按钮、开关跟主题色（下拉选自己另设灰字）
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

/// 点开 / 收起：在同一格里长出来，把下面推开；只淡入淡出
struct ExpandRow<Label: View, Content: View>: View {
    @EnvironmentObject private var theme: AppTheme
    @Binding var open: Bool
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.smooth(duration: 0.28)) { open.toggle() }
            } label: {
                HStack {
                    label()
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(Typo.icon(13))
                        .foregroundStyle(theme.inkFaint)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content().transition(.opacity)
            }
        }
    }
}
