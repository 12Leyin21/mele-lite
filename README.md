# Mele Lite

接入家机的前端，开袋即食。自带模型 key，手机直接连模型，聊天和所有记录只存在你自己的手机上，不经过任何服务器。

An AI companion that lives on your phone. Bring your own model key; your phone talks to the model directly, and everything stays on your device.

TestFlight 上的 Mele Lite 就是这份代码编出来的。有 Mac 的话，也可以自己编、自己改。

## 能做什么

- **聊天**：一泡一泡地聊，发照片、表情包，切「线下」写长段场景；多个联系人、导入酒馆角色卡、新窗口 / 无痕
- **模型**：Claude / ChatGPT / Gemini / DeepSeek，以及 OpenAI 兼容接口
- **TA 能帮你做的**：记账、待办（到点本地提醒）、饮食、人物卡、世界书、记着的事、朋友圈
- **你们的东西**：日记、相册、收藏、里程碑、抽屉里的信、书架（一起读 txt）、塔罗、音乐（Apple Music）
- **好玩的**：TA 申请查你的手机、微信号 + 小号加好友、地图和 TA 的一天
- **主屏**：整个 App 是一部小手机，图标和小组件随便摆；能接你自己的记忆库（MCP）
- **从别的 AI 搬家**：导入 ChatGPT / Claude / DeepSeek / Gemini 官方导出的聊天记录，合成一个新窗口，再挑出值得记住的事让 TA 记得（连着 Mele Host 也能搬）

App 关着的时候 TA 不会自己来找你——那要一台一直醒着的服务器，见下面的 Mele Host。

## Mele Host：让 TA 一直醒着

一台你自己租的小服务器，上面跑一份完整的 Mele。连上以后，App 关着 TA 也会来找你、自己醒来、记得更久（旧聊天卷进账本、联想记忆），还有每日私选、查营养、推送。服务器和数据都是你的，不经过我们。

**要什么**：一台 Linux 服务器，系统选 Ubuntu 24.04，**至少 4GB 内存、20GB 硬盘**，有公网 IPv4（比如 Hetzner 一个月约 5 欧元）。模型和声音照旧用你自己的 key。

**装**：用 root 登进去，粘这一条，等几分钟：

```bash
curl -fsSL https://raw.githubusercontent.com/12Leyin21/mele-lite/main/host/install.sh | bash
```

装完屏幕上有一个二维码：手机相机扫一下，或者在 App 的 Me → Mele Host 里手动填地址和配对码。有自己的域名的话，先把域名解析到这台服务器，再用 `MELE_DOMAIN=你的域名` 跑上面那条。

**⚠️ 主密钥**：装完会打出一串「主密钥」，现在就抄下来放好。它加密你存在服务器上的模型 key，丢了就全解不开。以后随时看：`mele-host key`。

**常用命令**

| 命令 | 做什么 |
|---|---|
| `mele-host pair` | 出一张新配对码（换手机、断开过要重新连） |
| `mele-host update` | 升级到最新版 |
| `mele-host logs` | 看日志 |
| `mele-host status` | 看在不在跑 |
| `mele-host stop` / `start` | 停 / 开 |

**推送怎么走**：苹果只让 App 的开发者推送，所以 Host 的推送会经过一个官方小中转（源码在 `relay/worker.js`）。Host 先用你手机给的钥匙把内容加密，中转只看得到「有一条要送到某台手机」，看不到内容。推送只送得到从 TestFlight 装的 Mele Lite；自己编译的 App 换了包名，苹果不让我们的中转推给它，其他功能照常。

**出事了**：先 `mele-host logs` 看报错；服务器连不上时，App 会让你「断开 Host，先用本机」，修好以后 `mele-host pair` 重新连。这是个人项目，**不提供客服**；遇到问题欢迎在 GitHub 提 issue，但不保证回复。

## 自己编译

要一台 Mac，Xcode 26，iPhone 是 iOS 18 以上。

```bash
brew install xcodegen
cd ios
xcodegen generate
open MeleLite.xcodeproj
```

1. 打开 `ios/project.yml`，把 `DEVELOPMENT_TEAM` 换成你的团队号、`PRODUCT_BUNDLE_IDENTIFIER` 换成你自己的包名，再跑一次 `xcodegen generate`
2. Xcode 里登录你的 Apple ID（Settings → Accounts）
3. 手机连上 Mac，选你的手机，点运行

- 用免费 Apple ID 装的 App，7 天后要重新装一次；付费开发者账号没有这个限制
- 免费账号不支持天气（WeatherKit）的话，把 `project.yml` 里 `com.apple.developer.weatherkit` 那行删掉再生成

零件包（`Sources/MeleLiteCore`）的测试在 Mac 上跑：`swift test`

## 许可 · License

源码公开：[PolyForm Noncommercial 1.0.0](LICENSE)

致谢见 [CREDITS.md](CREDITS.md)。

by Tilia & Quercus
