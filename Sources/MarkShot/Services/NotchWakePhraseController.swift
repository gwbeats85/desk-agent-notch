import AVFoundation
import Foundation
import Speech

@MainActor
final class NotchWakePhraseController: NSObject, ObservableObject {
    private final class AudioBufferSink {
        let request: SFSpeechAudioBufferRecognitionRequest

        init(request: SFSpeechAudioBufferRecognitionRequest) {
            self.request = request
        }

        func append(_ buffer: AVAudioPCMBuffer) {
            request.append(buffer)
        }
    }

    @Published private(set) var isListening = false
    @Published private(set) var warning = ""
    @Published private(set) var lastWakePhrase = ""

    var onWake: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioBufferSink: AudioBufferSink?
    private var shouldKeepListening = false
    private var wakeTriggered = false

    private let wakePhrases = [
        "hey desk",
        "okay desk",
        "yo desk",
        "desk agent",
        "hey agent",
        "okay agent",
        "yo agent"
    ]

    func start() async {
        guard !shouldKeepListening else { return }
        shouldKeepListening = true
        warning = "Waiting for Speech Recognition permission."
        let allowed = await requestPermissions()
        guard shouldKeepListening else { return }
        guard allowed else {
            warning = "Wake phrase needs microphone and speech permission."
            isListening = false
            shouldKeepListening = false
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            warning = "Wake phrase recognizer is unavailable."
            isListening = false
            shouldKeepListening = false
            return
        }

        wakeTriggered = false
        warning = ""
        startRecognitionCycle()
    }

    func stop() {
        shouldKeepListening = false
        isListening = false
        teardown(resetWakeTriggered: true)
    }

    private func startRecognitionCycle() {
        guard shouldKeepListening else { return }
        guard let recognizer, recognizer.isAvailable else {
            warning = "Wake phrase recognizer is unavailable."
            isListening = false
            return
        }

        teardown(resetWakeTriggered: false)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let sink = AudioBufferSink(request: request)
        audioBufferSink = sink

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            sink.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
            isListening = true
            warning = ""
        } catch {
            warning = "Wake phrase mic failed to start."
            isListening = false
            teardown(resetWakeTriggered: false)
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }

                if let result {
                    let transcript = result.bestTranscription.formattedString.lowercased()
                    if let phrase = self.matchingWakePhrase(in: transcript), !self.wakeTriggered {
                        self.lastWakePhrase = phrase
                        self.wakeTriggered = true
                        self.shouldKeepListening = false
                        self.isListening = false
                        self.teardown(resetWakeTriggered: false)
                        self.onWake?()
                        return
                    }

                    if result.isFinal, self.shouldKeepListening {
                        self.restartAfterShortDelay()
                        return
                    }
                }

                if error != nil, self.shouldKeepListening {
                    self.restartAfterShortDelay()
                }
            }
        }
    }

    private func matchingWakePhrase(in transcript: String) -> String? {
        wakePhrases.first { transcript.contains($0) }
    }

    private func restartAfterShortDelay() {
        teardown(resetWakeTriggered: false)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard shouldKeepListening else { return }
            startRecognitionCycle()
        }
    }

    private func teardown(resetWakeTriggered: Bool) {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioBufferSink = nil
        if resetWakeTriggered {
            wakeTriggered = false
        }
    }

    private nonisolated func requestPermissions() async -> Bool {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { value in
                continuation.resume(returning: value == .authorized)
            }
        }
        let micAllowed = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
        return speechAllowed && micAllowed
    }
}
