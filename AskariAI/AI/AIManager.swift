import Foundation
import FoundationModels
import Speech
import AVFoundation
import OSLog

private let sttLog = Logger(subsystem: "ai.askari", category: "STT")

// MARK: - AIManager
// Manages Apple Foundation Models sessions for all intelligence features,
// and SpeechAnalyzer + SpeechTranscriber for on-device voice dictation.
//
// No model downloads required for LLM — Apple Intelligence is built into the OS.
// SpeechAnalyzer assets (locale models) are managed via AssetInventory.

@MainActor
final class AIManager {
    static let shared = AIManager()

    // MARK: - LLM sessions

    private var copilotSession: LanguageModelSession?
    private var dashboardReady = false

    // MARK: - STT state — note dictation (AVAudioRecorder → SpeechAnalyzer file transcription)

    private var noteRecorder: AVAudioRecorder?
    private var noteRecordingURL: URL?

    // MARK: - STT state — live voice recording (AVAudioEngine → SpeechAnalyzer streaming)

    private var audioEngine: AVAudioEngine?
    private var liveAnalyzer: SpeechAnalyzer?
    private var liveTranscriber: SpeechTranscriber?
    private var liveInputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var liveResultsTask: Task<Void, Never>?
    private var lastVoiceText: String = ""
    private var bufferConverter: STTBufferConverter?

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

    /// True when the microphone permission has been granted.
    /// `loadSTTIfNeeded()` will also ensure locale assets are installed.
    func isSTTModelDownloaded() -> Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// Requests microphone + speech-recognition permission, then ensures
    /// SpeechAnalyzer locale assets are installed on-device via AssetInventory.
    func loadSTTIfNeeded() async throws {
        sttLog.info("[loadSTTIfNeeded] start — locale: \(Locale.current.identifier(.bcp47), privacy: .public)")

        // Step 1: microphone permission via AVAudioApplication (iOS 17+).
        // SFSpeechRecognizer.requestAuthorization crashes on Thread 40 in iOS 26 —
        // speech recognition consent is handled automatically by the system when
        // SpeechAnalyzer is first used (via NSSpeechRecognitionUsageDescription).
        sttLog.info("[loadSTTIfNeeded] requesting microphone permission")
        let micGranted = await AVAudioApplication.requestRecordPermission()
        sttLog.info("[loadSTTIfNeeded] microphone granted=\(micGranted, privacy: .public)")
        guard micGranted else {
            sttLog.error("[loadSTTIfNeeded] microphone permission denied")
            throw AIError.speechRecognitionNotAuthorized
        }

        // Step 2: ensure SpeechAnalyzer locale model is installed.
        // First confirm the locale is supported at all, then always run through
        // AssetInventory — it's a no-op when assets are current, but will
        // re-download if the OS purged them (low-storage scenario).
        sttLog.info("[loadSTTIfNeeded] fetching supportedLocales")
        let supported = await SpeechTranscriber.supportedLocales
        let currentBCP47 = Locale.current.identifier(.bcp47)
        sttLog.info("[loadSTTIfNeeded] supportedLocales count=\(supported.count, privacy: .public), currentLocale=\(currentBCP47, privacy: .public)")
        guard supported.map({ $0.identifier(.bcp47) }).contains(currentBCP47) else {
            sttLog.warning("[loadSTTIfNeeded] locale \(currentBCP47, privacy: .public) not in supportedLocales — skipping asset install")
            return
        }

        sttLog.info("[loadSTTIfNeeded] checking AssetInventory for installation request")
        let transcriber = makeTranscriber(for: Locale.current)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            sttLog.info("[loadSTTIfNeeded] asset installation request present — downloading")
            try await request.downloadAndInstall()
            sttLog.info("[loadSTTIfNeeded] downloadAndInstall complete")
        } else {
            sttLog.info("[loadSTTIfNeeded] assets already current — no download needed")
        }
        sttLog.info("[loadSTTIfNeeded] done")
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

    // MARK: - Note Dictation  (AVAudioRecorder → SpeechAnalyzer file transcription)
    //
    // 1. AVAudioRecorder captures to a temp WAV.
    // 2. SpeechAnalyzer.start(inputAudioFile:finishAfterFile:true) processes the
    //    whole file autonomously. finalizeAndFinishThroughEndOfInput() flushes
    //    results and terminates the transcriber.results stream.
    // 3. Only isFinal results are collected — volatile partials are irrelevant
    //    for a completed recording.

    func startNoteRecording() throws {
        sttLog.info("[startNoteRecording] start")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("askari_note_\(UUID().uuidString).wav")
        noteRecordingURL = url
        sttLog.info("[startNoteRecording] recording to: \(url.lastPathComponent, privacy: .public)")

        let settings: [String: Any] = [
            AVFormatIDKey:               kAudioFormatLinearPCM,
            AVSampleRateKey:             16000.0,
            AVNumberOfChannelsKey:       1,
            AVLinearPCMBitDepthKey:      16,
            AVLinearPCMIsFloatKey:       false,
            AVLinearPCMIsBigEndianKey:   false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        sttLog.info("[startNoteRecording] activating audio session")
        try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)

        sttLog.info("[startNoteRecording] creating AVAudioRecorder")
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.prepareToRecord() else {
            sttLog.error("[startNoteRecording] prepareToRecord() returned false")
            throw AIError.recordingFailed
        }
        recorder.record()
        noteRecorder = recorder
        sttLog.info("[startNoteRecording] recording started")
    }

    func stopNoteRecording() async -> String {
        sttLog.info("[stopNoteRecording] stopping recorder")
        noteRecorder?.stop()
        noteRecorder = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = noteRecordingURL else {
            sttLog.warning("[stopNoteRecording] no recording URL — aborting")
            return ""
        }
        noteRecordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }

        let transcriber = makeTranscriber(for: Locale.current)
        let analyzer    = SpeechAnalyzer(modules: [transcriber])

        guard let audioFile = try? AVAudioFile(forReading: url) else {
            sttLog.error("[stopNoteRecording] failed to open audio file at \(url.lastPathComponent, privacy: .public)")
            return ""
        }
        sttLog.info("[stopNoteRecording] audio file opened, frameCount=\(audioFile.length, privacy: .public)")

        var finalText = ""
        let resultsTask = Task {
            do {
                for try await result in transcriber.results where result.isFinal {
                    let t = String(result.text.characters)
                    sttLog.info("[stopNoteRecording] isFinal result: \(t, privacy: .private)")
                    finalText = t
                }
            } catch {
                sttLog.error("[stopNoteRecording] results stream error: \(error, privacy: .public)")
            }
        }

        do {
            sttLog.info("[stopNoteRecording] calling analyzer.start(inputAudioFile:finishAfterFile:)")
            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            sttLog.info("[stopNoteRecording] start returned — calling finalizeAndFinishThroughEndOfInput")
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            sttLog.info("[stopNoteRecording] finalize complete")
        } catch {
            sttLog.error("[stopNoteRecording] analyzer error: \(error, privacy: .public)")
            await analyzer.cancelAndFinishNow()
        }

        await resultsTask.value
        sttLog.info("[stopNoteRecording] done — text length=\(finalText.count, privacy: .public)")
        return finalText
    }

    // MARK: - Live Voice Recording  (AVAudioEngine → SpeechAnalyzer streaming)
    //
    // Mirrors the Apple sample (WWDC25 session 277):
    // 1. Options-based SpeechTranscriber init with .volatileResults so partial
    //    results stream in real time; .audioTimeRange for timing metadata.
    // 2. bestAvailableAudioFormat selects the optimal PCM format for the model.
    // 3. AVAudioConverter with primeMethod = .none avoids timestamp drift.
    // 4. analyzer.start(inputSequence:) — autonomous mode, returns immediately.
    // 5. stopVoiceRecording() finishes the AsyncStream continuation then calls
    //    finalizeAndFinishThroughEndOfInput() to flush and close result streams.

    func startVoiceRecording(onPartial: @escaping (String) -> Void) async {
        let transcriber = makeTranscriber(for: Locale.current)
        liveTranscriber = transcriber

        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return }

        let engine = AVAudioEngine()
        audioEngine   = engine
        lastVoiceText = ""
        bufferConverter = STTBufferConverter()

        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        liveInputBuilder = inputBuilder

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        liveAnalyzer = analyzer

        // Results task: distinguish volatile (partial) vs final results.
        liveResultsTask = Task { [transcriber] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    await MainActor.run {
                        self.lastVoiceText = text
                        onPartial(text)
                    }
                }
            } catch { }
        }

        // Start analysis autonomously — returns immediately.
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            inputBuilder.finish()
            liveInputBuilder = nil
            liveResultsTask?.cancel()
            liveResultsTask  = nil
            audioEngine      = nil
            return
        }

        let inputNode   = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let converter = self.bufferConverter else { return }
            guard let converted = try? converter.convert(buffer, to: targetFormat),
                  converted.frameLength > 0 else { return }
            inputBuilder.yield(AnalyzerInput(buffer: converted))
        }

        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            engine.prepare()
            try engine.start()
        } catch {
            inputBuilder.finish()
            liveInputBuilder = nil
            liveResultsTask?.cancel()
            liveResultsTask  = nil
            audioEngine      = nil
        }
    }

    func stopVoiceRecording() async -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine     = nil
        bufferConverter = nil

        // Finish the input stream; the analyzer drains remaining buffers.
        liveInputBuilder?.finish()
        liveInputBuilder = nil

        // Flush pending results and close the transcriber.results stream.
        do { try await liveAnalyzer?.finalizeAndFinishThroughEndOfInput() }
        catch { await liveAnalyzer?.cancelAndFinishNow() }
        liveAnalyzer = nil

        await liveResultsTask?.value   // wait for all result callbacks to complete
        liveResultsTask  = nil
        liveTranscriber  = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        let text = lastVoiceText
        lastVoiceText = ""
        return text
    }

    // MARK: - Cleanup

    func destroy() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine      = nil
        bufferConverter  = nil
        liveInputBuilder?.finish()
        liveInputBuilder = nil
        liveResultsTask?.cancel()
        liveResultsTask  = nil
        liveAnalyzer     = nil
        liveTranscriber  = nil
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

    /// Options-based SpeechTranscriber init (no preset) matching Apple sample.
    /// - volatileResults: delivers in-progress partial results as the user speaks.
    /// - audioTimeRange: attaches CMTime range metadata to each result.
    func makeTranscriber(for locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
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

// MARK: - STTBufferConverter
// Matches the BufferConverter from the Apple WWDC25 sample (session 277).
// Lazily creates AVAudioConverter on first use and reuses it for the session.
// primeMethod = .none sacrifices the very first samples to avoid timestamp drift.

final class STTBufferConverter {
    enum ConversionError: Error {
        case failedToCreateConverter
        case failedToAllocateBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else { return buffer }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none  // avoid timestamp drift on first buffer
        }
        guard let converter else { throw ConversionError.failedToCreateConverter }

        let ratio         = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let frameCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let output  = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                              frameCapacity: frameCapacity) else {
            throw ConversionError.failedToAllocateBuffer
        }

        var nsError: NSError?
        // Use a nonisolated local to avoid capturing a var across concurrency boundary.
        nonisolated(unsafe) var inputUsed = false
        let status = converter.convert(to: output, error: &nsError) { _, outStatus in
            defer { inputUsed = true }
            outStatus.pointee = inputUsed ? .noDataNow : .haveData
            return inputUsed ? nil : buffer
        }
        guard status != .error else { throw ConversionError.conversionFailed(nsError) }
        return output
    }
}
