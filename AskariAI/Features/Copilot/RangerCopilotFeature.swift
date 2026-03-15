import ComposableArchitecture
import Cactus
import SwiftUI

// MARK: - RangerCopilotFeature
// Handles all three AI features:
//   1. Natural Language Query (chat)
//   2. Voice Incident Logging
//   3. Pre-Patrol AI Briefing

@Reducer
struct RangerCopilotFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        // Context
        var missionId: UUID
        var missionName: String

        // Model state
        var modelLoadState: ModelLoadState = .idle
        var downloadProgress: Double = 0

        // Chat
        var messages: [ChatMessage] = []
        var inputText: String = ""
        var isResponding = false

        // Voice
        var voiceState: VoiceState = .idle
        var transcriptionPreview: String = ""

        // Briefing
        var briefingText: String = ""
        var isGeneratingBriefing = false
        var showingBriefing = false

        enum ModelLoadState: Equatable {
            case idle
            case downloading(progress: Double)
            case loaded
            case failed(String)
        }

        enum VoiceState: Equatable {
            case idle
            case recording
            case transcribing
            case processing
        }
    }

    // MARK: - Chat Message

    struct ChatMessage: Identifiable, Equatable {
        let id: UUID
        let role: Role
        let text: String
        let timestamp: Date

        enum Role: Equatable { case user, assistant, system }

        init(id: UUID = UUID(), role: Role, text: String, timestamp: Date = Date()) {
            self.id = id
            self.role = role
            self.text = text
            self.timestamp = timestamp
        }
    }

    // MARK: - Actions

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case loadModels
        case modelDownloadProgress(Double)
        case modelsReady
        case modelFailed(String)

        // Chat
        case sendMessage
        case appendMessage(ChatMessage)
        case setResponding(Bool)

        // Voice
        case startVoiceRecording
        case stopVoiceRecording
        case voiceTranscribed(String)
        case setVoiceState(State.VoiceState)
        case transcriptionUpdated(String)

        // Briefing
        case generateBriefing
        case briefingGenerated(String)
        case setShowingBriefing(Bool)
    }

    // MARK: - Body

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {

            case .onAppear:
                guard state.modelLoadState == .idle else { return .none }
                return .send(.loadModels)

            case .loadModels:
                state.modelLoadState = .downloading(progress: 0)
                return .run { send in
                    do {
                        // Download LLM model
                        let lmURL = try await CactusModelsDirectory.shared.modelURL(
                            for: .lfm2_5_1_2bThinking()
                        )
                        // Download Whisper model for voice
                        let _ = try await CactusModelsDirectory.shared.modelURL(
                            for: .whisperSmall(pro: .apple)
                        )
                        await send(.modelsReady)
                    } catch {
                        await send(.modelFailed(error.localizedDescription))
                    }
                }

            case .modelDownloadProgress(let progress):
                state.modelLoadState = .downloading(progress: progress)
                state.downloadProgress = progress
                return .none

            case .modelsReady:
                state.modelLoadState = .loaded
                return .none

            case .modelFailed(let msg):
                state.modelLoadState = .failed(msg)
                return .none

            // MARK: Chat

            case .sendMessage:
                guard !state.inputText.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
                let userMsg = ChatMessage(role: .user, text: state.inputText)
                state.messages.append(userMsg)
                state.inputText = ""
                state.isResponding = true
                let allMessages = state.messages
                let missionId = state.missionId
                return .run { send in
                    do {
                        let response = try await AIManager.shared.query(
                            messages: allMessages,
                            missionId: missionId
                        )
                        await send(.appendMessage(ChatMessage(role: .assistant, text: response)))
                    } catch {
                        await send(.appendMessage(ChatMessage(role: .assistant, text: "Sorry, I couldn't process that. Try again.")))
                    }
                    await send(.setResponding(false))
                }

            case .appendMessage(let msg):
                state.messages.append(msg)
                return .none

            case .setResponding(let responding):
                state.isResponding = responding
                return .none

            // MARK: Voice

            case .startVoiceRecording:
                state.voiceState = .recording
                state.transcriptionPreview = ""
                return .run { send in
                    await AIManager.shared.startVoiceRecording { partial in
                        Task { await send(.transcriptionUpdated(partial)) }
                    }
                }

            case .stopVoiceRecording:
                state.voiceState = .transcribing
                return .run { send in
                    let text = await AIManager.shared.stopVoiceRecording()
                    await send(.voiceTranscribed(text))
                }

            case .transcriptionUpdated(let partial):
                state.transcriptionPreview = partial
                return .none

            case .voiceTranscribed(let text):
                guard !text.isEmpty else {
                    state.voiceState = .idle
                    return .none
                }
                state.voiceState = .processing
                state.transcriptionPreview = text
                let missionId = state.missionId
                return .run { send in
                    do {
                        let response = try await AIManager.shared.processVoiceIncident(
                            transcription: text,
                            missionId: missionId
                        )
                        await send(.appendMessage(ChatMessage(role: .user, text: text)))
                        await send(.appendMessage(ChatMessage(role: .assistant, text: response)))
                    } catch {
                        await send(.appendMessage(ChatMessage(role: .assistant, text: "Couldn't log incident. Try again.")))
                    }
                    await send(.setVoiceState(.idle))
                }

            case .setVoiceState(let vs):
                state.voiceState = vs
                return .none

            // MARK: Briefing

            case .generateBriefing:
                state.isGeneratingBriefing = true
                let missionId = state.missionId
                return .run { send in
                    do {
                        let briefing = try await AIManager.shared.generateBriefing(missionId: missionId)
                        await send(.briefingGenerated(briefing))
                    } catch {
                        await send(.briefingGenerated("Unable to generate briefing. Check that AI models are downloaded."))
                    }
                }

            case .briefingGenerated(let text):
                state.briefingText = text
                state.isGeneratingBriefing = false
                state.showingBriefing = true
                return .none

            case .setShowingBriefing(let show):
                state.showingBriefing = show
                return .none

            case .binding:
                return .none
            }
        }
    }
}
