import ComposableArchitecture
import SwiftUI

// MARK: - DashboardFeature
// Intelligence overview for park heads and admins.

@Reducer
struct DashboardFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var recentIncidents: [Incident] = []
        var totalIncidentsThisMonth: Int = 0
        var isLoading = false

        // AI Query
        var aiModelState: AIModelState = .notLoaded
        var isQuerying = false
        var aiResponse: String? = nil

        enum AIModelState: Equatable {
            case notLoaded
            case loading
            case ready
            case failed(String)
        }
    }

    enum Action {
        case onAppear
        case dataLoaded(incidents: [Incident])

        // AI
        case loadAIModel
        case aiModelReady
        case aiModelFailed(String)
        case submitAIQuery(String)
        case aiQueryResult(String)
        case clearAIResponse
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { send in
                    let incidents = try? await loadRecentIncidents()
                    await send(.dataLoaded(incidents: incidents ?? []))
                }

            case .dataLoaded(let incidents):
                state.recentIncidents = incidents
                state.isLoading = false
                return .none

            // MARK: AI

            case .loadAIModel:
                guard state.aiModelState == .notLoaded else { return .none }
                state.aiModelState = .loading
                return .run { send in
                    do {
                        try await AIManager.shared.loadLLMOnly()
                        await send(.aiModelReady)
                    } catch {
                        await send(.aiModelFailed(error.localizedDescription))
                    }
                }

            case .aiModelReady:
                state.aiModelState = .ready
                return .none

            case .aiModelFailed(let msg):
                state.aiModelState = .failed(msg)
                return .none

            case .submitAIQuery(let text):
                guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
                state.isQuerying = true
                state.aiResponse = nil
                return .run { send in
                    do {
                        let result = try await AIManager.shared.querySingle(text)
                        await send(.aiQueryResult(result))
                    } catch {
                        await send(.aiQueryResult("⚠️ \(error.localizedDescription)"))
                    }
                }

            case .aiQueryResult(let text):
                state.aiResponse = text
                state.isQuerying = false
                return .none

            case .clearAIResponse:
                state.aiResponse = nil
                return .none
            }
        }
    }

    private func loadRecentIncidents() async throws -> [Incident] {
        let rows = try await systemManager.db.getAll(
            sql: """
                SELECT * FROM map_features
                WHERE created_at >= datetime('now', '-7 days')
                ORDER BY created_at DESC
                LIMIT 20
            """,
            parameters: [],
            mapper: { cursor in Incident(cursor: cursor) }
        )
        return rows.compactMap { $0 }
    }
}

// MARK: - DashboardView

struct DashboardView: View {
    let store: StoreOf<DashboardFeature>
    @State private var queryInput = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                aiQuerySection
                incidentsSection
            }
            .navigationTitle("Intelligence")
            .refreshable { store.send(.onAppear) }
        }
        .onAppear { store.send(.onAppear) }
    }

    // MARK: - AI Query Section

    @ViewBuilder
    private var aiQuerySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                    Text("Askari AI")
                        .font(.headline)
                    Spacer()
                    modelStateIndicator
                }

                // Input + Send
                HStack(spacing: 8) {
                    TextField(
                        "e.g. Show snares from last 14 days",
                        text: $queryInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .disabled(store.aiModelState != .ready || store.isQuerying)
                    .submitLabel(.send)
                    .onSubmit { sendQuery() }

                    Button(action: sendQuery) {
                        if store.isQuerying {
                            ProgressView()
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                                .foregroundStyle(canSend ? .blue : .secondary)
                        }
                    }
                    .disabled(!canSend)
                }

                // Load model button (only when not yet loaded)
                if store.aiModelState == .notLoaded {
                    Button {
                        store.send(.loadAIModel)
                    } label: {
                        Label("Load AI Model", systemImage: "arrow.down.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                }

                // AI Response
                if let response = store.aiResponse {
                    Divider()
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.blue)
                            .font(.caption)
                            .padding(.top, 2)
                        Text(response)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Button {
                            store.send(.clearAIResponse)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("AI Intelligence")
        }
    }

    @ViewBuilder
    private var modelStateIndicator: some View {
        switch store.aiModelState {
        case .notLoaded:
            Text("Not loaded")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .loading:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.7)
                Text("Downloading model…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let msg):
            Text("Error: \(msg)")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var canSend: Bool {
        store.aiModelState == .ready && !store.isQuerying && !queryInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func sendQuery() {
        guard canSend else { return }
        store.send(.submitAIQuery(queryInput))
        queryInput = ""
        inputFocused = false
    }

    // MARK: - Incidents Section

    @ViewBuilder
    private var incidentsSection: some View {
        Section("Recent Incidents (7 days)") {
            if store.isLoading {
                ProgressView("Loading…")
            } else if store.recentIncidents.isEmpty {
                Text("No incidents reported.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(store.recentIncidents) { incident in
                    IncidentRowView(incident: incident)
                }
            }
        }
    }
}

struct IncidentRowView: View {
    let incident: Incident
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(incident.severity == .critical ? .red : incident.severity == .high ? .orange : .yellow)
                    .frame(width: 8, height: 8)
                Text(incident.name).font(.subheadline.bold())
                Spacer()
                Text(incident.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption2).foregroundColor(.secondary)
            }
            Text(incident.description).font(.caption).foregroundColor(.secondary).lineLimit(2)
        }
    }
}

