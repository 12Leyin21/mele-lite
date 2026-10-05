import SwiftUI
import UIKit

/// 登录：邮箱 → 发验证码 → 6 格验证码 → 进去。开发阶段验证码打印在 Mac 的服务器日志里。
/// 长按标题可以改服务器地址（开发用；上线后去掉）。
struct LoginView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var email = ""
    @State private var code = ""
    @State private var step: Step = .email
    @State private var busy = false
    @State private var error: String?
    @State private var editingServer = false
    @FocusState private var focused: Bool
    @FocusState private var codeFocused: Bool    // 验证码框单独一个：跟邮箱框共用的话，邮箱框消失那一下会把焦点关掉

    enum Step { case email, code }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer()
            Text("Mele")
                .font(Typo.accent(Typo.Size.largeTitle))
                .onLongPressGesture { editingServer = true }
            Text(step == .email ? "一个记得你的伙伴。" : "验证码发到了 \(email)")
                .font(Typo.sans(Typo.Size.headline))
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Group {
                if step == .email { emailField } else { codeBoxes }
            }
            .padding(.top, 40)
            if let error {
                Text(error).font(Typo.sans(Typo.Size.body)).foregroundStyle(.red).padding(.top, 12)
            }
            Button(action: submit) {
                ZStack {
                    Text(step == .email ? "发验证码" : "进去").opacity(busy ? 0 : 1)
                    if busy { ProgressView().tint(Color(uiColor: .systemBackground)) }
                }
                .font(Typo.sans(Typo.Size.headline, .medium))
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .foregroundStyle(Color(uiColor: .systemBackground))
            }
            .disabled(busy || !canSubmit)
            .opacity(canSubmit ? 1 : 0.35)
            .padding(.top, 24)
            if step == .code {
                Button("换个邮箱") { step = .email; code = ""; error = nil }
                    .font(Typo.sans(Typo.Size.body)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.top, 16)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 28)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .onAppear { focused = true }
        .alert("服务器地址", isPresented: $editingServer) {
            TextField("http://…", text: $session.serverURL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("好") {}
        }
    }

    private var emailField: some View {
        TextField("邮箱", text: $email)
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(Typo.sans(Typo.Size.title))
            .focused($focused)
            .padding(.vertical, 14)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.15)).frame(height: 1) }
            .submitLabel(.send)
            .onSubmit(submit)
    }

    /// 6 格验证码：格子只负责显示；一个透明的输入框盖在格子上面收字（点格子就是点它，短信验证码能一键填）。
    private var codeBoxes: some View {
        ZStack {
            HStack(spacing: 10) {
                ForEach(0..<6, id: \.self) { i in
                    let chars = Array(code)
                    Text(i < chars.count ? String(chars[i]) : "")
                        .font(Typo.number(Typo.Size.title, .medium))
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(i == min(chars.count, 5) && codeFocused ? Color.primary : Color.primary.opacity(0.15),
                                    lineWidth: i == min(chars.count, 5) && codeFocused ? 1.5 : 1))
                }
            }
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .foregroundStyle(.clear)
                .tint(.clear)
                .frame(maxWidth: .infinity, minHeight: 58)
                .onChange(of: code) { _, new in
                    let clean = String(new.filter(\.isNumber).prefix(6))
                    if clean != new { code = clean }
                    if clean.count == 6 { submit() }
                }
        }
        .task { try? await Task.sleep(for: .milliseconds(200)); codeFocused = true }
    }

    private var canSubmit: Bool {
        step == .email ? email.contains("@") && email.contains(".") : code.count == 6
    }

    private func submit() {
        guard canSubmit, !busy else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                if step == .email {
                    try await session.api.send("POST", "auth/email/code", json: ["email": email.trimmingCharacters(in: .whitespaces)])
                    step = .code
                } else {
                    let device = UIDevice.current.identifierForVendor?.uuidString ?? ""
                    let r: LoginDTO = try await session.api.call("POST", "auth/email/verify",
                                                                 json: ["email": email, "code": code, "device_id": device])
                    session.loggedIn(token: r.token)
                }
            } catch {
                self.error = error.localizedDescription
                if step == .code { code = "" }
            }
        }
    }
}
