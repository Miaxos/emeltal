#if canImport(AppKit)
    import AppKit
#endif
import AVFoundation
import Combine
import Foundation

final actor Speaker {
    var havePreferredVoice = false

    private let voice: AVSpeechSynthesisVoice
    private let synth = AVSpeechSynthesizer()
    private var muted = false
    private let watcher = UtteranceWatcher()
    private let effectPlayer = AVAudioPlayerNode()

    private static func pickFavourite(from voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
        if let premiumFemale = voices.filter({ $0.quality == .premium && $0.gender == .female }).first {
            return premiumFemale
        }
        if let premiumMale = voices.filter({ $0.quality == .premium && $0.gender == .male }).first {
            return premiumMale
        }
        if let enhancedFemale = voices.filter({ $0.quality == .enhanced && $0.gender == .female }).first {
            return enhancedFemale
        }
        if let enhancedMale = voices.filter({ $0.quality == .enhanced && $0.gender == .male }).first {
            return enhancedMale
        }
        if let female = voices.first(where: { $0.gender == .female }) {
            return female
        }
        return voices.first
    }

    func setMute(_ mute: Bool) {
        muted = mute
        if mute {
            cancelIfNeeded()
        }
    }

    @MainActor
    private final class UtteranceWatcher: NSObject, AVSpeechSynthesizerDelegate {
        @objc private dynamic var utterances = Set<AVSpeechUtterance>()

        private func remove(utterance: AVSpeechUtterance) { utterances.remove(utterance) }

        override nonisolated init() {}

        func add(utterance: AVSpeechUtterance) { utterances.insert(utterance) }

        func reset() { utterances.removeAll() }

        nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            Task { @MainActor in
                remove(utterance: utterance)
            }
        }

        nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            Task { @MainActor in
                remove(utterance: utterance)
            }
        }

        func waitForZero() async {
            var observation: Cancellable?
            var pending = true
            await withCheckedContinuation { [weak self] (continuation: CheckedContinuation<Void, Never>) in
                if let self {
                    observation = publisher(for: \.utterances).filter(\.isEmpty).sink { _ in
                        if pending {
                            pending = false
                            continuation.resume()
                        }
                    }
                } else {
                    continuation.resume()
                }
            }
            withExtendedLifetime(observation) {
                log("Speaker stopped speaking")
            }
        }
    }

    init() throws {
        #if os(iOS)
            synth.usesApplicationAudioSession = true
        #endif
        synth.delegate = watcher
        if let preferred = AVSpeechSynthesisVoice(identifier: "com.apple.voice.premium.en-US.Zoe") {
            havePreferredVoice = true
            voice = preferred
        } else {
            let allVoices = AVSpeechSynthesisVoice.speechVoices()
            let enVoices = allVoices.filter { $0.language.hasPrefix("en-US") && !$0.voiceTraits.contains(.isNoveltyVoice) && !$0.voiceTraits.contains(.isPersonalVoice) }
            if let enVoice = Self.pickFavourite(from: enVoices) {
                log("Selected voice: \(enVoice.identifier)")
                voice = enVoice
            } else if let anyVoice = Self.pickFavourite(from: allVoices) {
                log("Fallback voice: \(anyVoice.identifier)")
                voice = anyVoice
            } else {
                throw "Could not find any TTS voices in the system"
            }
        }
    }

    func warmup() async throws {
        try await AudioEngineManager.shared.config { engine in
            effectPlayer.volume = 0.1
            engine.attach(effectPlayer)
            engine.connect(effectPlayer, to: engine.mainMixerNode, format: engine.mainMixerNode.outputFormat(forBus: 0))
        }
        synth.write(AVSpeechUtterance(string: "Warmup")) { _ in }
        log("Speech warmup complete")
    }

    func cancelIfNeeded() {
        synth.stopSpeaking(at: .immediate)
        Task {
            await watcher.reset()
        }
    }

    func waitForCompletion() async {
        await watcher.waitForZero()
    }

    func add(text: String) async {
        if muted { return }
        let utterance = utterance(for: text)
        await watcher.add(utterance: utterance)
        synth.speak(utterance)
    }

    func render(text: String) async -> Data? {
        let utterance = utterance(for: text)
        return await withCheckedContinuation { continuation in
            synth.write(utterance) { audioBuffer in
                if let buf = audioBuffer as? AVAudioPCMBuffer, let speech = buf.floatChannelData?[0] {
                    let data = Data(bytes: speech, count: Int(buf.frameLength))
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func utterance(for text: String) -> AVSpeechUtterance {
        let textToPlay = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let utterance = AVSpeechUtterance(string: textToPlay)
        utterance.voice = voice
        if textToPlay.hasSuffix(".") || textToPlay.hasSuffix("!") || textToPlay.hasSuffix("?") || textToPlay.hasSuffix(":") || textToPlay.hasSuffix("\n") {
            utterance.postUtteranceDelay = 0.2
        }
        return utterance
    }

    enum Effect {
        case startListening, endListening
    }

    private let startCaf = Bundle.main.url(forResource: "MicStart", withExtension: "caf")!
    private let endCaf = Bundle.main.url(forResource: "MicStop", withExtension: "caf")!

    func playEffect(_ effect: Effect) async {
        if muted { return }

        let sound: AVAudioFile = switch effect {
        case .startListening:
            try! AVAudioFile(forReading: startCaf)

        case .endListening:
            try! AVAudioFile(forReading: endCaf)
        }

        try? await AudioEngineManager.shared.willUseEngine()
        let t = Task {
            await effectPlayer.scheduleFile(sound, at: nil)
            await AudioEngineManager.shared.doneUsingEngine()
        }
        effectPlayer.play()
        let msec = sound.processingFormat.sampleRate * 1000 / Double(sound.length)
        try? await Task.sleep(nanoseconds: UInt64(msec + 100) * NSEC_PER_MSEC)
        effectPlayer.stop()
        await t.value
    }
}
