import Foundation
import AVFoundation

/// VoiceGuide — TTS voice instructions for iOS using AVSpeechSynthesizer.
///
/// iOS equivalent of the Android VoiceGuide. AVSpeechSynthesizer is ready
/// synchronously so no pre-warm / pending phrase mechanism is needed.
internal final class VoiceGuide: NSObject {

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpoken: String = ""
    private var enabled: Bool

    private static let minGapMs: Int = 650
    private var lastSpokenAt: Date = .distantPast

    init(enabled: Bool = true) {
        self.enabled = enabled
        super.init()
        synthesizer.delegate = self
        if enabled {
            configureAudioSession()
        }
    }

    func speak(_ text: String, force: Bool = false) {
        guard enabled else { return }
        guard force || text != lastSpoken else { return }

        let now = Date()
        let gapMs = Int(now.timeIntervalSince(lastSpokenAt) * 1000)
        guard force || gapMs >= Self.minGapMs else { return }

        synthesizer.stopSpeaking(at: .immediate)

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.0
        utterance.pitchMultiplier = 1.0
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
            ?? AVSpeechSynthesisVoice(language: "en-US")

        synthesizer.speak(utterance)
        lastSpoken = text
        lastSpokenAt = now
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        lastSpoken = ""
    }

    // MARK: - Audio session

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(
            .playback,
            mode: .spokenAudio,
            options: [.mixWithOthers, .duckOthers]
        )
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}

extension VoiceGuide: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {}
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {}
}
