import AVFoundation
import SwiftUI

// MARK: - TA 发语音条（10-03，声音第二块；服务器 POST /conversations/{id}/voice）
//
// 输入框空着时发送键变麦克风：按住就录，松手发；左滑取消；上滑到小锁锁住（不用按着），
// 锁住后点停止 → 先听一遍 → 发送 / 扔掉。最长 2 分钟。样子统一调 UI 时重画。

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Float = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var url: URL { FileManager.default.temporaryDirectory.appendingPathComponent("mele-voice.m4a") }
    static let maxSeconds: Double = 120

    func start() async -> Bool {
        let ok = await AVAudioApplication.requestRecordPermission()
        guard ok else { return false }
        VoicePlayer.shared.stop()
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? s.setActive(true)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16000,
                                       AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        guard let r = try? AVAudioRecorder(url: url, settings: settings) else { return false }
        r.isMeteringEnabled = true
        r.record(forDuration: Self.maxSeconds)
        recorder = r
        recording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let r = self.recorder else { return }
                r.updateMeters()
                self.elapsed = r.currentTime
                self.level = max(0, (r.averagePower(forChannel: 0) + 50) / 50)
                if !r.isRecording && self.recording { self.recording = false }
            }
        }
        return true
    }

    /// 停下，返回 (录音, 秒数)；太短（不到 0.6 秒）当没录
    func stop() -> (Data, Double)? {
        let secs = recorder?.currentTime ?? elapsed
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        recording = false
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        let final = max(secs, elapsed)
        guard final >= 0.6, let data = try? Data(contentsOf: url) else { return nil }
        return (data, final)
    }

    func cancel() { _ = stop() }
}

struct VoiceRecordButton: View {
    @EnvironmentObject private var theme: AppTheme
    let skin: ChatSkin
    /// 录着 / 等试听时为 true：输入框让开，小条整条放进输入栏里（10-03：浮在栏外面的点不到，锁住后发不出去）
    @Binding var active: Bool
    let onSend: (Data, Double) -> Void
    @StateObject private var rec = VoiceRecorder()
    @State private var drag: CGSize = .zero
    @State private var locked = false
    @State private var pressing = false
    @State private var review: (Data, Double)?
    @State private var previewPlayer: AVAudioPlayer?
    @State private var denied = false

    private static let cancelX: CGFloat = -90
    private static let lockY: CGFloat = -80

    var body: some View {
        HStack(spacing: 10) {
            if rec.recording || review != nil {
                panel.frame(maxWidth: .infinity, alignment: .leading)
            }
            if locked || review != nil {
                // 锁住了 / 停下来试听：右边是发送键（锁住时点它 = 停下并发出）
                Button { sendNow() } label: {
                    Image(systemName: "arrow.up")
                        .font(Typo.icon(16, .bold)).foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(theme.accent))
                }
                .buttonStyle(.plain)
            } else {
                mic
            }
        }
        .onChange(of: rec.recording || review != nil, initial: true) { _, on in active = on }
        .onChange(of: rec.recording) { _, on in
            if !on && locked && review == nil { review = rec.stop() ?? nil; if review == nil { locked = false } }   // 录满 2 分钟自己停
        }
        .alert("要开麦克风权限", isPresented: $denied) { Button("好", role: .cancel) {} } message: {
            Text("在「设置 → Mele → 麦克风」里打开，才能发语音。")
        }
    }

    private var mic: some View {
        Image(systemName: "mic.fill")
            .font(Typo.icon(16, .bold))
            .foregroundStyle(rec.recording ? .white : theme.accent)
            .frame(width: 36, height: 36)
            .background {
                if rec.recording { Circle().fill(theme.accent) } else { paintedChrome(Circle(), skin: skin) }
            }
            .scaleEffect(rec.recording ? 1.2 : 1)
            .offset(x: min(drag.width, 0), y: min(drag.height, 0))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if !pressing {
                            pressing = true
                            Task { if !(await rec.start()) { denied = true; pressing = false } }
                        }
                        guard rec.recording else { return }
                        drag = v.translation
                        if v.translation.height < Self.lockY {
                            withAnimation(.spring(duration: 0.25)) { locked = true; drag = .zero }
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { v in
                        pressing = false
                        guard !locked else { return }
                        defer { drag = .zero }
                        if v.translation.width < Self.cancelX { rec.cancel(); return }
                        if let got = rec.stop() { onSend(got.0, got.1) }
                    }
            )
    }

    private func sendNow() {
        previewPlayer?.stop()
        let got = review ?? rec.stop()
        review = nil
        locked = false
        if let got { onSend(got.0, got.1) }
    }

    /// 输入栏里的小条：录着时是时长 + 提示（锁住后多一个停止键）；停了以后是试听 + 扔掉
    @ViewBuilder
    private var panel: some View {
        HStack(spacing: 12) {
            if let got = review {
                Button { playPreview(got.0) } label: { Image(systemName: "play.fill") }
                Text(clock(got.1)).monospacedDigit()
                Spacer(minLength: 0)
                Button(role: .destructive) { previewPlayer?.stop(); review = nil; locked = false } label: { Image(systemName: "trash") }
            } else {
                Circle().fill(.red).frame(width: 8, height: 8).opacity(0.4 + Double(rec.level) * 0.6)
                Text(clock(rec.elapsed)).monospacedDigit()
                if locked {
                    Spacer(minLength: 0)
                    Button(role: .destructive) { rec.cancel(); locked = false } label: { Image(systemName: "trash") }
                    Button { review = rec.stop(); if review == nil { locked = false } } label: { Image(systemName: "stop.fill") }
                } else {
                    Text(drag.width < Self.cancelX ? "松手取消" : "← 左滑取消 · ↑ 上滑锁定")
                        .font(Typo.sans(skin.size(Typo.Size.caption))).foregroundStyle(skin.inkDim)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .font(Typo.sans(skin.size(Typo.Size.callout), .medium))
        .foregroundStyle(skin.ink)
        .tint(theme.accent)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(paintedChrome(Capsule(), skin: skin))
    }

    private func clock(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }

    private func playPreview(_ data: Data) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        previewPlayer = try? AVAudioPlayer(data: data)
        previewPlayer?.play()
    }
}
