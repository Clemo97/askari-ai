import ComposableArchitecture
import SwiftUI

// MARK: - MissionsFeature

@Reducer
struct MissionsFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var missions: [Mission] = []
        var isLoading = false
        var selectedMissionId: UUID? = nil
        var activeMission: ActiveMissionFeature.State? = nil
        var showingCreateMission = false
    }

    enum Action {
        case onAppear
        case missionsUpdated([Mission])
        case selectMission(UUID)
        case activeMission(ActiveMissionFeature.Action)
        case setShowCreateMission(Bool)
        case startMission(UUID)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { send in
                    let stream = try systemManager.db.watch(
                        sql: """
                            SELECT * FROM missions
                            ORDER BY
                                CASE status
                                    WHEN 'current' THEN 0
                                    WHEN 'future' THEN 1
                                    ELSE 2
                                END,
                                start_date DESC
                        """,
                        parameters: []
                    ) { cursor in
                        Mission(cursor: cursor)
                    }
                    for try await missions in stream {
                        await send(.missionsUpdated(missions.compactMap { $0 }))
                    }
                }

            case .missionsUpdated(let missions):
                state.isLoading = false
                state.missions = missions
                return .none

            case .selectMission(let id):
                state.selectedMissionId = id
                return .none

            case .startMission(let id):
                guard let mission = state.missions.first(where: { $0.id == id }) else { return .none }
                state.activeMission = ActiveMissionFeature.State(mission: mission)
                return .none

            case .setShowCreateMission(let show):
                state.showingCreateMission = show
                return .none

            case .activeMission:
                return .none
            }
        }
        .ifLet(\.activeMission, action: \.activeMission) {
            ActiveMissionFeature()
        }
    }
}

// MARK: - MissionsView

struct MissionsView: View {
    let store: StoreOf<MissionsFeature>

    var body: some View {
        NavigationStack {
            Group {
                if store.isLoading {
                    ProgressView("Loading missions…")
                } else if store.missions.isEmpty {
                    ContentUnavailableView("No Missions", systemImage: "map", description: Text("No active missions assigned to you."))
                } else {
                    List {
                        ForEach(store.missions) { mission in
                            MissionRowView(mission: mission)
                                .onTapGesture { store.send(.selectMission(mission.id)) }
                        }
                    }
                }
            }
            .navigationTitle("Missions")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { store.send(.setShowCreateMission(true)) } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .onAppear { store.send(.onAppear) }
    }
}

// MARK: - MissionRowView

struct MissionRowView: View {
    let mission: Mission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mission.name)
                    .font(.headline)
                Spacer()
                MissionStateBadge(state: mission.missionState)
            }
            Text(mission.patrolType.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(mission.objectives)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

struct MissionStateBadge: View {
    let state: Mission.MissionState

    var body: some View {
        Text(state.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    var color: Color {
        switch state {
        case .active:     return .green
        case .paused:     return .orange
        case .completed:  return .blue
        case .notStarted: return .gray
        }
    }
}
