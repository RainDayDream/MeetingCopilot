import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay, noMic
    var errorDescription: String? { self == .noMic ? "未找到可用的麦克风" : "未找到可捕获的显示器" }
}

/// 只读地捕获系统音频（会议里对方的声音）。不修改、不注入任何内容。
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "mc.sysaudio")

    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        self.handler = handler
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 16000
        cfg.channelCount = 1
        // 只要音频：把视频压到最小，降低开销
        cfg.width = 2; cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue) // 丢弃画面，避免系统报“找不到输出”
        try await s.startCapture()
        stream = s
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        handler = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sb.isValid, let buf = Self.pcm(from: sb) else { return }
        handler?(buf)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NotificationCenter.default.post(name: .captureStopped, object: error.localizedDescription)
    }

    static func pcm(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var desc = asbd.pointee
        guard let fmt = AVAudioFormat(streamDescription: &desc) else { return nil }
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard n > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n) else { return nil }
        buf.frameLength = n
        let st = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(n),
                                                              into: buf.mutableAudioBufferList)
        return st == noErr ? buf : nil
    }
}

/// 麦克风（你自己的发言）。
/// 用 AVCaptureSession 而不是 AVAudioEngine：AVAudioEngine 在 macOS 上会创建“默认输入输出聚合设备”
/// （CADefaultDeviceAggregate），可能干扰其他应用使用麦克风；AVCaptureSession 只是一个普通的共享输入客户端。
/// 只在“开始监听”时才创建，空闲时完全不碰音频设备。
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private var handler: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "mc.mic")

    func start(handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        guard let dev = AVCaptureDevice.default(for: .audio) else { throw CaptureError.noMic }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: dev)
        let out = AVCaptureAudioDataOutput()
        guard s.canAddInput(input), s.canAddOutput(out) else { throw CaptureError.noMic }
        s.addInput(input)
        out.setSampleBufferDelegate(self, queue: queue)
        s.addOutput(out)
        self.handler = handler
        s.startRunning()
        session = s
    }

    func stop() {
        session?.stopRunning()
        session = nil
        handler = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sb.isValid, let buf = SystemAudioCapture.pcm(from: sb) else { return }
        handler?(buf)
    }
}

/// 一次性只读截图（排除本 App 自己的窗口）
enum Screenshot {
    static func screenID(_ s: NSScreen) -> CGDirectDisplayID? {
        s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// displayID 为 nil 时取鼠标所在的屏幕
    static func capture(displayID: UInt32? = nil, maxWidth: Int = 1600) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mouse = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }.flatMap(screenID)
        let wanted = displayID ?? mouse
        guard let display = content.displays.first(where: { $0.displayID == wanted }) ?? content.displays.first
        else { throw CaptureError.noDisplay }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let cfg = SCStreamConfiguration()
        let w = min(display.width, maxWidth)
        cfg.width = w
        cfg.height = display.height * w / max(display.width, 1)
        cfg.showsCursor = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        let rep = NSBitmapImageRep(cgImage: img)
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw CaptureError.noDisplay
        }
        return jpg
    }
}

extension AVAudioPCMBuffer {
    /// 0...1 的音量（RMS），用于界面上的电平指示
    var level: Float {
        guard let ch = floatChannelData, frameLength > 0 else { return 0 }
        var sum: Float = 0
        let n = Int(frameLength)
        for i in 0..<n { sum += ch[0][i] * ch[0][i] }
        return min(1, (sum / Float(n)).squareRoot() * 8)
    }
}

extension Notification.Name {
    static let captureStopped = Notification.Name("mc.captureStopped")
    static let hotkeyAsk = Notification.Name("mc.hotkeyAsk")
}
