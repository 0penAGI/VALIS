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
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.voice = pickVoice(kind: voice)
        
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
    }
    
    private func pickVoice(kind: VoiceKind) -> AVSpeechSynthesisVoice? {
        let language = Locale.preferredLanguages.first ?? "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { v in
                v.language == language
            }
        
        if voices.isEmpty {
            return AVSpeechSynthesisVoice(language: language)
        }
        
        switch kind {
        case .female:
            return voices.first
        case .male:
            return voices.dropFirst().first ?? voices.first
        }
    }
}

