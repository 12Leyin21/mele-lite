import SwiftUI

@main
struct LumiApp: App {
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    @StateObject private var session = SessionStore()
    @StateObject private var theme = AppTheme()
    @StateObject private var avatars = AvatarStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(session)
                .environmentObject(theme)
                .environmentObject(avatars)
        }
    }
}

/// 没登录 → 登录页；登录了 → 账号里还没填名字就走引导，否则进两个标签的骨架（第二块）。
struct RootView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        if CommandLine.arguments.contains("-albumPreview") {          // 自测：直接开相册样子预览（不用登录）
            FilmRollView(demo: FilmDemo.cached)
        } else if session.isLoggedIn {
            SignedIn(api: session.api).id(session.hostEpoch)        // 连上 / 断开 Mele Host：AppModel 整个重来
        } else {
            LoginView()
        }
    }
}

/// 登录以后：AppModel 跟着这次登录活，退出登录就整个扔掉
private struct SignedIn: View {
    @StateObject private var model: AppModel
    @EnvironmentObject private var session: SessionStore
    @EnvironmentObject private var theme: AppTheme
    @State private var hostLink: HostPrefill?
    @State private var leaveHost = false
    struct HostPrefill: Identifiable { let address: String; let code: String; var id: String { address + code } }

    init(api: APIClient) { _model = StateObject(wrappedValue: AppModel(api: api)) }

    var body: some View {
        Group {
            if !model.loaded {
                VStack(spacing: 16) {
                    if let err = model.loadError {
                        Text(err).font(Typo.sans(Typo.Size.body)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("再试一次") { Task { await model.refresh() } }
                        if Lite.on && HostLink.connected {
                            // 10-05：Host 挂了 / 删了，光有「再试一次」就永远进不去。给一条回本机的路
                            Text("连不上你的 Mele Host。服务器修好以前，可以先断开、用手机里那份。")
                                .font(Typo.sans(Typo.Size.caption)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                .padding(.top, 8)
                            Button("断开 Host，先用本机") { leaveHost = true }
                        }
                    } else {
                        ProgressView()
                    }
                }
                .padding(32)
                .task { await model.refresh() }
                .confirmationDialog(String(localized: "断开 Mele Host？"), isPresented: $leaveHost, titleVisibility: .visible) {
                    Button(String(localized: "断开"), role: .destructive) {
                        HostLink.disconnect()
                        session.switchHost()
                    }
                } message: {
                    Text("回到手机里那份。Host 上的聊天留在 Host 上；修好以后在服务器上运行 mele-host pair 拿新的配对码，到 Me 里重新连。")
                }
            } else if (model.profile?.name ?? "").isEmpty {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .environmentObject(model)
        .onOpenURL { url in                          // 扫了 Mele Host 的二维码（mele://host?u=…&c=…，10-04）：引导里也接
            if Lite.on, let l = HostLink.parse(url) { hostLink = HostPrefill(address: l.address, code: l.code) }
        }
        .sheet(item: $hostLink) { p in
            HostConnectSheet(address: p.address, code: p.code).environmentObject(session).environmentObject(theme)
        }
    }
}
