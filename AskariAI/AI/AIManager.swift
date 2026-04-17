import Foundation
import FoundationModels
import Speech
import AVFoundation

// MARK: - AIManager
// Manages Apple Foundation Models sessions for all intelligence features,
// and SFSpeechRecognizer for on-device voice dictation.
//
// No model downloads required — Apple Intelligence is built into the OS.
// Availability is gated by SystemLanguageModel.default.isAvailable.

@MainActor
final class AIManager {
    static let shared = AIManager()

    // MARK: - Sessions

    // Per-conversation session for RangerCopilot.
    // Persists across turns so the LLM retains full conversation context.
    private var copilotSession: LanguageModelSession?

    // Flag that a one-shot dashboard session can be created when queried.
    private var dashboardReady = false

    // MARK: - STT state — note dictation (AVAudioRecorder → SFSpeechRecognizer file transcription)

    private var noteRecorder: AVAudioRecorder?
    private var noteRecordingURL: URL?

    // MARK: - STT state — live voice recording (AVAudioEngine + SFSpeechAudioBufferRecognitionRequest)

    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastVoiceText: String = ""

    private init() {}

    // MARK: - Availability

    /// Whether Apple Intelligence is available on this device.
    var isModelAvailable: Bool {
        SystemLanguageModel.default.isAvailable
    }

    // MARK: - Session setup

    /// Prepares the RangerCopilot session with all patrol tools.
    /// Instant — no model download needed.
    func loadModels() async throws {
        guard isModelAvailable else { throw AIError.modelsNotLoaded }
        copilotSession = LanguageModelSession(
            tools: makeCopilotTools(),
            instructions: rangerSystemPrompt
        )
    }

    /// Signals that the dashboard intelligence panel is ready for queries.
    /// Instant — availability is checked at query time.
    func loadLLMOnly() async throws {
        guard isModelAvailable else { throw AIError.modelsNotLoaded }
        dashboardReady = true
    }

    // MARK: - STT availability

    /// Whether speech recognition is currently authorized and available.
    /// Maps to the old "is model downloaded" concept — no downloads needed.
    func isSTTModelDownloaded() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && (SFSpeechRecognizer(locale: .current)?.isAvailable ?? false)
    }

    /// Requests speech recognition authorization from the user.
    /// Maps to the old "model download" step; presents a one-time permission prompt.
    func loadSTTIfNeeded() async throws {
        let status = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized else {
            throw AIError.speechRecognitionNotAuthorized
        }
    }

    // MARK: - Dashboard query
    // Each dashboard query creates a fresh ephemeral session with data tools.
    // The LLM selects which tool(s) to call based on the question,
    // receives DB-serialised results as context, and generates a grounded answer.

    func querySingle(_ text: String) async throws -> String {
        guard dashboardReady && isModelAvailable else { throw AIError.modelsNotLoaded }
        let session = LanguageModelSession(
            tools: [QueryRecentIncidentsTool(), GetRangerStatsTool()],
            instructions: dashboardSystemPrompt
        )
        let response = try await session.respond(to: text)
        return response.content
    }

    // MARK: - Copilot multi-turn chat

    /// Appends the latest user message to the persistent copilot session.
    /// The session retains full transcript context for follow-up questions.
    func query(messages: [RangerCopilotFeature.ChatMessage], missionId: UUID) async throws -> String {
        if copilotSession == nil { try await loadModels() }
        guard let session = copilotSession else { throw AIError.modelsNotLoaded }
        guard let last = messages.last(where: { $0.role == .user }) else {
            throw AIError.noUserMessage
        }
        let response = try await session.respond(to: last.text)
        return response.content
    }

    /// Starts a fresh copilot conversation (clears transcript).
    func resetCopilotSession() {
        guard isModelAvailable else { return }
        copilotSession = LanguageModelSession(
            tools: makeCopilotTools(),
            instructions: rangerSystemPrompt
        )
    }

    // MARK: - Voice incident processing

    func processVoiceIncident(transcription: String, missionId: UUID) async throws -> String {
        if copilotSession == nil { try await loadModels() }
        guard let session = copilotSession else { throw AIError.modelsNotLoaded }
        let prompt = """
        [VOICE INCIDENT LOG] The ranger reported: "\(transcription)"
        Parse this as a patrol incident and call log_incident with appropriate fields.
        """
        let response = try await session.respond(to: prompt)
        return response.content
    }

    // MARK: - Pre-Patrol Briefing
    // Uses a fresh ephemeral session so the briefing doesn't pollute copilot history.
    // Flow: prompt → LLM calls query_recent_incidents + get_ranger_stats tools →
    //       DB returns serialised data → LLM generates briefing grounded in real data.

    func generateBriefing(missionId: UUID) async throws -> String {
        guard isModelAvailable else { throw AIError.modelsNotLoaded }
        let session = LanguageModelSession(
            tools: [QueryRecentIncidentsTool(), GetRangerStatsTool()],
            instructions: "Generate concise pre-patrol briefings for wildlife rangers based on real incident data from tools."
        )
        let response = try await session.respond(to: """
        Generate a pre-patrol briefing. Call query_recent_incidents (daysBack: 14, \
        incidentType: "") and get_ranger_stats (daysBack: 14, limit: 5) to get \
        real data, then write a brief covering:
        - Recent incident hotspots and patterns
        - Incident type breakdown
        - Recommended patrol focus areas
        Keep it under 200 words. Write for a ranger about to deploy in the field.
        """)
        return response.content
    }

    // MARK: - Note Dictation  (AVAudioRecorder → SFSpeechRecognizer file transcription)
    //
    // AVAudioRecorder writes a clean WAV file with no SDK conflicts.
    // SFSpeechRecognizer transcribes it after recording stops.
    // On-device recognition is requested so no audio leaves the device.

    func startNoteRecording() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("askari_note_\(UUID().uuidString).wav")
        noteRecordingURL = url

        let settings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             16000.0,
            AVNumberOfChannelsKey:       1,
            AVLinearPCMBitDepthKey:      16,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        try AVAudioSession.sharedInstance().setCategory(.record, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.prepareToRecord() else { throw AIError.recordingFailed }
        recorder.record()
        noteRecorder = recorder
    }

    func stopNoteRecording() async -> String {
        noteRecorder?.stop()
        noteRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = noteRecordingURL else { return "" }
        noteRecordingURL = nil

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            try? FileManager.default.removeItem(at: url)
            return ""
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation

        return await withCheckedContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let result, result.isFinal {
                    finished = true
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    finished = true
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume(returning: "")
                }
            }
        }
    }

    // MARK: - Live Voice Recording  (AVAudioEngine → SFSpeechAudioBufferRecognitionRequest)
    // Streams audio buffers directly to SFSpeechRecognizer for real-time partial results.

    func startVoiceRecording(onPartial: @escaping (String) -> Void) async {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        recognitionRequest = request
        lastVoiceText = ""

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            if let result {
                let text = result.bestTranscription.formattedString
                self?.lastVoiceText = text
                onPartial(text)
            }
        }

        audioEngine = AVAudioEngine()
        guard let engine = audioEngine else { return }
        let inputNode = engine.inputNode
        let format    = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .record, mode: .measurement, options: .duckOthers
            )
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            engine.prepare()
            try engine.start()
        } catch {
            recognitionTask?.cancel()
            recognitionTask    = nil
            recognitionRequest = nil
            audioEngine        = nil
        }
    }

    func stopVoiceRecording() async -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.finish()
        recognitionTask = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let text = lastVoiceText
        lastVoiceText = ""
        return text
    }

    // MARK: - Cleanup

    func destroy() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine        = nil
        recognitionTask?.cancel()
        recognitionTask    = nil
        recognitionRequest = nil
        noteRecorder?.stop()
        noteRecorder   = nil
        copilotSession = nil
        dashboardReady = false
    }
}

// MARK: - Tools factories

private extension AIManager {
    func makeCopilotTools() -> [any Tool] {
        [QueryRecentIncidentsTool(), LogIncidentTool(), GetRangerStatsTool()]
    }
}

// MARK: - System Prompts

private let dashboardSystemPrompt = """
You are an AI assistant for Askari AI, a wildlife anti-poaching platform.
When asked about incidents or rangers, call the appropriate tool immediately.
After receiving tool results, give a brief 2–3 sentence summary.
Never guess or invent data — always call a tool first.
"""

private let rangerSystemPrompt = """
You are an AI intelligence copilot for wildlife park rangers. Use your tools to \
query real-time patrol data from the local database.
- Only answer based on tool results — never hallucinate facts.
- Keep answers brief and actionable for a ranger in the field.
- When logging incidents, confirm details before writing to the database.
- Express distances in kilometers. Never show raw coordinates to the user.
"""

// MARK: - Errors

enum AIError: Error, LocalizedError {
    case modelsNotLoaded
    case noUserMessage
    case speechRecognitionNotAuthorized
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded:
            return "Apple Intelligence is not available on this device. Ensure Apple Intelligence is enabled in Settings."
        case .noUserMessage:
            return "No user message found."
        case .speechRecognitionNotAuthorized:
            return "Speech recognition permission denied. Enable it in Settings → Privacy & Security → Speech Recognition."
        case .recordingFailed:
            return "Microphone recording failed to start."
        }
    }
}


