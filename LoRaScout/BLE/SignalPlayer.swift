import AVFoundation

/// Signal tones like on the tester: Quindar tone for send, a lower one for receive, a triple chime like Master Caution for failures.
/// The audio session is only active while a tone plays, so music on the iPhone gets quieter and comes back.
final class SignalPlayer {
    static let enabledKey = "signalTones"

    private static let rate = 22050.0
    private static let gap = silence(ms: 100)

    private var player: AVAudioPlayer?

    func play(_ kinds: [EventKind]) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        let samples = kinds.flatMap { Self.samples($0) }
        if !samples.isEmpty { play(samples) }
    }

    func preview() {
        play(Self.sendTone + Self.gap + Self.receiveTone + Self.gap + Self.caution)
    }

    private func play(_ samples: [Double]) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.duckOthers])
        try? session.setActive(true)
        player = try? AVAudioPlayer(data: Self.wav(samples))
        player?.play()
        let duration = player?.duration ?? 0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.3) { [weak self] in
            guard self?.player?.isPlaying != true else { return }
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private static func samples(_ kind: EventKind) -> [Double] {
        switch kind {
        case .sendStarted, .autoUplink: sendTone + gap
        case .networkAnswer, .lateAnswer: receiveTone + gap
        case .noAnswer, .sendFailed, .joinFailed: caution + gap
        default: []
        }
    }

    private static let sendTone = beep(freq: 2525, ms: 250)
    private static let receiveTone = beep(freq: 1750, ms: 250)
    private static let caution = chime(freq: 760, ms: 260) + chime(freq: 760, ms: 260) + chime(freq: 760, ms: 420)

    private static func count(_ ms: Int) -> Int { Int(rate * Double(ms) / 1000) }

    private static func silence(ms: Int) -> [Double] { Array(repeating: 0, count: count(ms)) }

    private static func beep(freq: Double, ms: Int) -> [Double] {
        let n = count(ms)
        return (0..<n).map { i in
            let fade = min(1.0, Double(min(i, n - i)) / 100.0)  // No clicks
            return sin(2 * .pi * freq * Double(i) / rate) * fade
        }
    }

    /// Bell-like chime: a few partials with exponential decay.
    private static func chime(freq: Double, ms: Int) -> [Double] {
        let n = count(ms)
        let partials: [(mult: Double, amp: Double, decay: Double)] = [(1, 0.6, 1), (2, 0.25, 1.6), (3.01, 0.12, 2.4)]
        return (0..<n).map { i in
            let t = Double(i) / rate
            let attack = min(1.0, Double(i) / (rate * 0.004))
            let release = min(1.0, Double(n - i) / 200.0)
            let v = partials.reduce(0.0) { acc, p in
                acc + p.amp * exp(-t * 7 * p.decay) * sin(2 * .pi * freq * p.mult * t)
            }
            return v * attack * release
        }
    }

    /// 16-bit mono PCM WAV.
    private static func wav(_ samples: [Double]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 28000)
            withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) }
        }
        let r = Int(rate)
        var wav = Data()
        func u32(_ x: Int) { withUnsafeBytes(of: UInt32(x).littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ x: Int) { withUnsafeBytes(of: UInt16(x).littleEndian) { wav.append(contentsOf: $0) } }
        wav.append(contentsOf: Array("RIFF".utf8)); u32(36 + pcm.count)
        wav.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(r); u32(r * 2); u16(2); u16(16)
        wav.append(contentsOf: Array("data".utf8)); u32(pcm.count)
        return wav + pcm
    }
}
