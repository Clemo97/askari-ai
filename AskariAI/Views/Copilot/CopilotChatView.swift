import SwiftUI
import ComposableArchitecture

// MARK: - CopilotChatView

struct CopilotChatView: View {
    @Bindable var store: StoreOf<RangerCopilotFeature>

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Model loading banner
                if case .downloading(let progress) = store.modelLoadState {
                    ModelDownloadBanner(progress: progress)
                }

                // Chat history
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if store.messages.isEmpty {
                                CopilotWelcomeView()
                                    .padding(.top, 40)
                            }
                            ForEach(store.messages) { msg in
                                ChatBubble(message: msg)
                                    .id(msg.id)
                            }
                            if store.isResponding {
                                TypingIndicator()
                            }
                        }
                        .padding()
                    }
                    .onChange(of: store.messages.count) { _, _ in
                        if let last = store.messages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                Divider()

                // Input bar
                ChatInputBar(
                    text: $store.inputText,
                    voiceState: store.voiceState,
                    transcriptionPreview: store.transcriptionPreview,
                    isResponding: store.isResponding,
                    onSend: { store.send(.sendMessage) },
                    onVoiceStart: { store.send(.startVoiceRecording) },
                    onVoiceStop: { store.send(.stopVoiceRecording) }
                )
            }
            .navigationTitle("Ranger AI Copilot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.send(.generateBriefing)
                    } label: {
                        Label("Briefing", systemImage: "doc.text.magnifyingglass")
                    }
                    .disabled(store.modelLoadState != .loaded)
                }
            }
            .sheet(isPresented: $store.showingBriefing) {
                AIBriefingView(
                    briefingText: store.briefingText,
                    isLoading: store.isGeneratingBriefing,
                    onDismiss: { store.send(.setShowingBriefing(false)) }
                )
            }
        }
        .onAppear { store.send(.onAppear) }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: RangerCopilotFeature.ChatMessage

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.role == .assistant {
                Image(systemName: "brain")
                    .foregroundColor(.green)
                    .frame(width: 28)
            }

            Text(message.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleColor)
                .foregroundColor(textColor)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(maxWidth: 300, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                Image(systemName: "person.fill")
                    .foregroundColor(.blue)
                    .frame(width: 28)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
    }

    var bubbleColor: Color {
        switch message.role {
        case .user:      return .blue
        case .assistant: return Color(.secondarySystemBackground)
        case .system:    return .gray.opacity(0.3)
        }
    }

    var textColor: Color {
        message.role == .user ? .white : .primary
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var phase = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 7, height: 7)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}

// MARK: - Chat Input Bar

struct ChatInputBar: View {
    @Binding var text: String
    let voiceState: RangerCopilotFeature.State.VoiceState
    let transcriptionPreview: String
    let isResponding: Bool
    let onSend: () -> Void
    let onVoiceStart: () -> Void
    let onVoiceStop: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if voiceState == .recording || voiceState == .transcribing {
                HStack {
                    Image(systemName: "waveform").foregroundColor(.red)
                    Text(voiceState == .transcribing ? "Transcribing…" : transcriptionPreview.isEmpty ? "Listening…" : transcriptionPreview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                TextField("Ask about patrol data…", text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .disabled(voiceState != .idle)

                // Voice button
                Button {
                    if voiceState == .idle {
                        onVoiceStart()
                    } else {
                        onVoiceStop()
                    }
                } label: {
                    Image(systemName: voiceState == .recording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundColor(voiceState == .recording ? .red : .orange)
                }

                // Send button
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(text.isEmpty || isResponding ? .gray : .green)
                }
                .disabled(text.isEmpty || isResponding)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .background(.regularMaterial)
    }
}

// MARK: - Welcome View

struct CopilotWelcomeView: View {
    let suggestions = [
        "How many snares were found this week?",
        "Which blocks are overdue for patrol?",
        "Who logged the most incidents this month?",
    ]

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 48))
                .foregroundColor(.green)
            Text("Ranger AI Copilot")
                .font(.title2.bold())
            Text("Ask questions about patrol data or log a voice incident.\nAll AI runs on-device — works offline.")
                .multilineTextAlignment(.center)
                .font(.subheadline)
                .foregroundColor(.secondary)
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Text("\u{201C}\(s)\u{201D}")
                        .font(.caption)
                        .padding(10)
                        .background(Color.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundColor(.green)
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Model Download Banner

struct ModelDownloadBanner: View {
    let progress: Double
    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "arrow.down.circle").foregroundColor(.orange)
                Text("Downloading AI model…")
                    .font(.caption.bold())
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: progress)
                .tint(.orange)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.1))
    }
}

// MARK: - AI Briefing View

struct AIBriefingView: View {
    let briefingText: String
    let isLoading: Bool
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLoading {
                        HStack {
                            ProgressView()
                            Text("Generating briefing from local data…")
                                .font(.subheadline).foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 40)
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                            Text("Generated from local data — no internet required")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .background(Color.green.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                        Text(briefingText)
                            .font(.body)
                            .padding()
                    }
                }
                .padding()
            }
            .navigationTitle("Pre-Patrol Briefing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}
