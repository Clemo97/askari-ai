import Foundation
import Cactus
import AVFoundation

// MARK: - AIManager
// Singleton that owns CactusAgentSession, CactusSTTSession, and CactusVADSession.
// Models are loaded once and reused. Call destroy() only when exiting the AI flow entirely.

@MainActor
final class AIManager {
    static let shared = AIManager()

    private var agentSession: CactusAgentSession?       // RangerCopilot (thinking model)
    private var dashboardModelURL: URL?         // Admin dashboard — stores downloaded model path
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

    // MARK: - Dashboard Natural Language Query
    //
    // The thinking model (lfm2_5_1_2bThinking) generates unbounded <think> blocks
    // and never emits </think> before hitting context limits, making it unusable
    // for structured output or function-calling dispatch.
    //
    // Solution: parse intent and dispatch entirely in Swift (fast, zero-latency,
    // deterministic). The CactusFunction tool implementations still execute the
    // actual SQL queries — we just call them from Swift rather than via the LLM.
    // The downloaded model remains available for RangerCopilotFeature.

    /// Warms the model cache so the binary is ready for RangerCopilot.
    /// No-op if already downloaded.
    func loadLLMOnly() async throws {
        guard dashboardModelURL == nil else { return }
        dashboardModelURL = try await CactusModelsDirectory.shared.modelURL(
            for: .lfm2_5_1_2bThinking()
        )
    }

    /// Natural-language query → live PowerSync data.
    /// Intent is parsed in Swift; SQL is executed via CactusFunction tool implementations.
    func querySingle(_ text: String) async throws -> String {
        guard dashboardModelURL != nil else { throw AIError.modelsNotLoaded }
        let intent = parseQueryIntent(text)
        let result: String
        switch intent.action {
        case .rangerStats:
            let input = GetRangerStatsTool.Input(daysBack: intent.daysBack, limit: intent.limit)
            result = (try? await GetRangerStatsTool().invoke(input: input)) ?? "No ranger data found."
        default:
            let input = QueryRecentIncidentsTool.Input(daysBack: intent.daysBack, incidentType: intent.incidentType)
            result = (try? await QueryRecentIncidentsTool().invoke(input: input)) ?? "No incidents found."
        }
        return result
    }

    // MARK: - Swift NL Intent Parser

    private enum QueryAction { case queryIncidents, rangerStats }

    private struct QueryIntent {
        var action: QueryAction = .queryIncidents
        var daysBack: Int = 7
        var incidentType: String = ""
        var limit: Int = 5
    }

    private func parseQueryIntent(_ text: String) -> QueryIntent {
        let lower = text.lowercased()
        var intent = QueryIntent()

        // Action
        let rangerKeywords = ["ranger", "staff", "leaderboard", "top", "ranking", "performance", "who logged"]
        if rangerKeywords.contains(where: { lower.contains($0) }) {
            intent.action = .rangerStats
        }

        // Days
        if lower.contains("today") { intent.daysBack = 1 }
        else if lower.contains("yesterday") { intent.daysBack = 2 }
        else if lower.contains("month") || lower.contains("30 day") { intent.daysBack = 30 }
        else if lower.contains("2 week") || lower.contains("14 day") || lower.contains("fortnight") { intent.daysBack = 14 }
        else if lower.contains("week") || lower.contains("7 day") { intent.daysBack = 7 }
        else if let match = lower.range(of: #"(\d+)\s*day"#, options: .regularExpression) {
            intent.daysBack = Int(lower[match].filter(\.isNumber)) ?? 7
        }

        // Incident type — extracted dynamically so any spot_type the user mentions works.
        intent.incidentType = Self.extractIncidentType(from: lower)

        // Limit for ranger stats
        if let match = lower.range(of: #"top\s*(\d+)"#, options: .regularExpression) {
            intent.limit = Int(lower[match].filter(\.isNumber)) ?? 5
        }

        return intent
    }

    /// Strips filler words from the query and returns what's left as the incident-type search term.
    /// e.g. "Show spent cartridge from last 7 days" → "spent cartridge"
    /// e.g. "All snare incidents this week"          → "snare"
    /// e.g. "Total incidents this month"             → "" (no type filter)
    private static func extractIncidentType(from lower: String) -> String {
        // Words that carry no incident-type information
        let stopWords: Set<String> = [
            "show", "me", "find", "get", "list", "give", "fetch",
            "all", "any", "recent", "total", "number", "count", "how", "many",
            "incidents", "incident", "reports", "report", "events", "event",
            "logged", "recorded", "from", "in", "the", "last", "past",
            "this", "today", "yesterday",
            "week", "weeks", "month", "months", "day", "days", "fortnight",
            "7", "14", "30", "1", "2", "3",
        ]

        // Strip trailing date phrases like "last 7 days", "in the past month"
        var cleaned = lower
        let datePatterns = [
            #"(from |in )?(the )?last \d+ days?"#,
            #"(from |in )?(the )?past \d+ days?"#,
            #"(from |in )?(the )?last (week|month|fortnight)"#,
            #"this (week|month|year)"#,
            #"today|yesterday"#,
        ]
        for pattern in datePatterns {
            if let range = cleaned.range(of: pattern, options: .regularExpression) {
                cleaned.removeSubrange(range)
            }
        }

        // Tokenise and remove stop words
        let tokens = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " ")).inverted)
            .joined(separator: " ")
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty && !stopWords.contains($0) && !$0.allSatisfy(\.isNumber) }

        let candidate = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // Reject candidates that are just noise (single very common word)
        let noiseWords: Set<String> = ["incident", "incidents", "report", "activity", "alert"]
        return noiseWords.contains(candidate) ? "" : candidate
    }


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

// MARK: - System Prompts

private let dashboardSystemPrompt = """
You are an AI assistant for Askari AI, a wildlife anti-poaching management system.

When the user asks about incidents, rangers, or activity data:
1. Call the appropriate tool immediately with the correct parameters.
2. After receiving the tool results, give a brief 2-3 sentence summary.

Rules:
- Always call a tool before answering — never guess or invent data.
- Keep answers short and factual.
- If no data is returned, say so clearly.
"""

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
