import OllamaCore
import AVFoundation
import Speech

final class VoiceInputController: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isAvailable = true
    @Published var errorMessage: String?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func startRecording(onTranscript: @escaping @MainActor (String, Bool) -> Void) {
        Task { @MainActor in
            guard await requestPermissionsIfNeeded() else { return }
            do {
                try configureAndStartRecognition(onTranscript: onTranscript)
            } catch {
                stopRecording()
                errorMessage = friendlyErrorMessage(for: error)
            }
        }
    }

    func stopRecording() {
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        isRecording = false
    }

    private func requestPermissionsIfNeeded() async -> Bool {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let speechAuthorized: Bool
        switch speechStatus {
        case .authorized:
            speechAuthorized = true
        case .notDetermined:
            speechAuthorized = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            speechAuthorized = false
        }

        guard speechAuthorized else {
            isAvailable = false
            errorMessage = "Speech recognition permission is required for voice input."
            return false
        }

        let micAuthorized = await requestMicrophonePermission()
        guard micAuthorized else {
            isAvailable = false
            errorMessage = "Microphone permission is required for voice input."
            return false
        }

        isAvailable = speechRecognizer?.isAvailable == true
        guard isAvailable else {
            errorMessage = "Voice input is currently unavailable for your selected language."
            return false
        }

        return true
    }

    private func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func configureAndStartRecognition(onTranscript: @escaping @MainActor (String, Bool) -> Void) throws {
        stopRecording()

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.duckOthers, .defaultToSpeaker, .allowBluetooth]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        isRecording = true
        errorMessage = nil

        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                Task { @MainActor in
                    onTranscript(result.bestTranscription.formattedString, result.isFinal)
                }

                if result.isFinal {
                    Task { @MainActor in
                        self.stopRecording()
                    }
                    return
                }
            }

            if let error {
                Task { @MainActor in
                    self.stopRecording()
                    self.errorMessage = self.friendlyErrorMessage(for: error)
                }
            }
        }
    }

    private func friendlyErrorMessage(for error: Error) -> String {
        let nsError = error as NSError

        if nsError.code == 1_852_797_029 {
            return "Voice input couldn't start because audio capture is unavailable right now. Stop other recording apps or reconnect your audio device, then try again."
        }

        let message = nsError.localizedDescription.trimmedForLookup
        return message.isEmpty ? "Voice input failed to start." : message
    }
}

