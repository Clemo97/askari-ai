import Foundation
import Cactus
import AVFoundation

// MARK: - AIManager
// Singleton that owns CactusAgentSession, CactusSTTSession, and CactusVADSession.
// Models are loaded once and reused. Call destroy() only when exiting the AI flow entirely.

@MainActor
final class AIManager {
    static let shared = AIManager()

    private var agentSession: CactusAgentSession?
    private var sttSession: CactusSTTSession?
    private var vadSession: CactusVADSession?
    private var transcriptionStream: CactusTranscriptionStream?
    private var audioEngine: AVAudioEngine?

    private init() {
        if let key = Secrets.cactusCloudKey {
            Cactus.cactusCloudAPIKey = key
        }
    }

    // MARK: - Model loading

    func loadModels() async throws {
        // LLM (thinking model for reasoning + function calling)
        let lmURL = try await CactusModelsDirectory.shared.modelURL(
            for: .lfm2_5_1_2bThinking()
        )
        agentSession = try CactusAgentSession(
            from: lmURL,
            functions: makeTools()
        ) {
            rangerSystemPrompt
        }

        // STT — NPU-accelerated Whisper for field transcription
        let whisperURL = try await CactusModelsDirectory.shared.modelURL(
            for: .whisperSmall(pro: .apple)
        )
        sttSession = try CactusSTTSession(from: whisperURL)

        // VAD — strips silence before transcription to save compute
        let vadURL = try await CactusModelsDirectory.shared.modelURL(for: .sileroVad())
        vadSession = try CactusVADSession(from: vadURL)
    }

    // MARK: - Natural Language Query

    func query(messages: [RangerCopilotFeature.ChatMessage], missionId: UUID) async throws -> String {
        guard let session = agentSession else {
            throw AIError.modelsNotLoaded
        }
        // Build a fresh message from the last user message
        guard let lastUserMsg = messages.last(where: { $0.role == .user }) else {
            throw AIError.noUserMessage
        }
        let message = CactusUserMessage { lastUserMsg.text }
        let completion = try await session.respond(to: message)
        return completion.output
    }

    // MARK: - Voice Recording

    private var voiceChunks: [AVAudioPCMBuffer] = []
    private var partialCallback: ((String) -> Void)?

    func startVoiceRecording(onPartial: @escaping (String) -> Void) async {
        voiceChunks.removeAll()
        partialCallback = onPartial

        let whisperURL = try? await CactusModelsDirectory.shared.modelURL(
            for: .whisperSmall(pro: .apple)
        )
        guard let whisperURL else { return }

        do {
            transcriptionStream = try CactusTranscriptionStream(from: whisperURL)
        } catch { return }

        audioEngine = AVAudioEngine()
        let inputNode = audioEngine!.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            voiceChunks.append(buffer)
            Task { @MainActor in
                try? await self.transcriptionStream?.process(buffer: buffer)
            }
        }

        // Stream partial transcriptions
        Task {
            guard let stream = transcriptionStream else { return }
            for try await chunk in stream {
                onPartial(chunk.confirmed)
            }
        }

        try? audioEngine?.start()
    }

    func stopVoiceRecording() async -> String {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil

        do {
            _ = try await transcriptionStream?.finish()
        } catch {}

        // Run VAD + full transcription on collected buffers
        guard let stt = sttSession, !voiceChunks.isEmpty else { return "" }

        let combinedSamples = voiceChunks.flatMap { buffer -> [Float] in
            guard let data = buffer.floatChannelData else { return [] }
            return Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
        }

        // Merge to a single buffer for STT
        guard let firstFormat = voiceChunks.first?.format,
              let merged = AVAudioPCMBuffer(pcmFormat: firstFormat, frameCapacity: AVAudioFrameCount(combinedSamples.count)) else {
            return ""
        }
        merged.frameLength = AVAudioFrameCount(combinedSamples.count)
        combinedSamples.withUnsafeBufferPointer { ptr in
            merged.floatChannelData?[0].update(from: ptr.baseAddress!, count: combinedSamples.count)
        }

        do {
            let request = CactusTranscription.Request(
                prompt: .whisper(language: .english, includeTimestamps: false),
                content: try .pcm(merged)
            )
            let transcription = try await stt.transcribe(request: request)
            return transcription.content.response
        } catch {
            return ""
        }
    }

    // MARK: - Voice Incident Processing

    func processVoiceIncident(transcription: String, missionId: UUID) async throws -> String {
        guard let session = agentSession else { throw AIError.modelsNotLoaded }

        let message = CactusUserMessage {
            """
            [VOICE INCIDENT LOG] The ranger said: "\(transcription)"

            Parse this as an incident and call log_incident with the appropriate fields.
            """
        }
        let completion = try await session.respond(to: message)
        return completion.output
    }

    // MARK: - Pre-Patrol Briefing

    func generateBriefing(missionId: UUID) async throws -> String {
        guard let session = agentSession else { throw AIError.modelsNotLoaded }

        let message = CactusUserMessage {
            """
            Generate a pre-patrol briefing for the park ranger.

            Call query_recent_incidents (daysBack: 14, incidentType: "") and get_ranger_stats (daysBack: 14, limit: 5)
            to gather data, then write a concise briefing covering:
            - Recent incidents in the park (last 14 days)
            - Incident hotspots based on frequency
            - Recommended areas of focus based on incident density

            Keep it practical and under 200 words. Write for a ranger about to go on patrol.
            """
        }
        let completion = try await session.respond(to: message)
        return completion.output
    }

    // MARK: - Cleanup

    func destroy() {
        audioEngine?.stop()
        audioEngine = nil
        agentSession = nil
        sttSession = nil
        vadSession = nil
    }
}

// MARK: - Tools factory

private extension AIManager {
    func makeTools() -> [any CactusFunction] {
        [
            QueryRecentIncidentsTool(),
            LogIncidentTool(),
            GetRangerStatsTool(),
        ]
    }
}

// MARK: - System Prompt

private let rangerSystemPrompt = """
You are an AI intelligence copilot for wildlife park rangers. You have access to tools \
that query real-time patrol data from the local database.

Rules:
- Only answer based on data returned by your tools — never guess or hallucinate facts.
- Keep answers brief and actionable for a ranger in the field.
- When logging incidents, always confirm the details before writing to the database.
- Distances should be in kilometers. Coordinates should not be shown to the user.
- If data is missing, say so clearly.
"""

// MARK: - Errors

enum AIError: Error, LocalizedError {
    case modelsNotLoaded
    case noUserMessage

    var errorDescription: String? {
        switch self {
        case .modelsNotLoaded: return "AI models are not loaded yet. Please wait for download to complete."
        case .noUserMessage: return "No user message found."
        }
    }
}
