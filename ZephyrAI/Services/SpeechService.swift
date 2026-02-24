import Foundation
import AVFoundation

final class SpeechService {
    static let shared = SpeechService()
    
    enum VoiceKind {
        case female
        case male
    }
    
    private let synthesizer = AVSpeechSynthesizer()
    
    private init() {}
    
    func speak(text: String, voice: VoiceKind) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        prepareAudioSession()
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = pickVoice(kind: voice)
        
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }

    private func prepareAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            print("SpeechService audio session error: \(error)")
        }
    }
    
    private func pickVoice(kind: VoiceKind) -> AVSpeechSynthesisVoice? {
        let preferred = Locale.preferredLanguages.first ?? "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let exact = voices.filter { $0.language == preferred }
        let prefix = voices.filter { $0.language.hasPrefix(String(preferred.prefix(2))) }
        let pool = !exact.isEmpty ? exact : (!prefix.isEmpty ? prefix : voices)
        
        if pool.isEmpty {
            return AVSpeechSynthesisVoice(language: "en-US")
        }
        
        switch kind {
        case .female:
            return pool.first
        case .male:
            return pool.dropFirst().first ?? pool.first
        }
    }
}
