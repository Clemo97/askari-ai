import ComposableArchitecture
import CoreLocation
import SwiftUI

// MARK: - ActiveMissionFeature

@Reducer
struct ActiveMissionFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var mission: Mission
        var incidents: [Incident] = []
        var routePoints: [RoutePoint] = []
        var copilot: RangerCopilotFeature.State
        var showingCopilot = false
        var showingAddIncident = false
        var isTracking = false
        var distanceTraveledKm: Double = 0

        init(mission: Mission) {
            self.mission = mission
            self.copilot = RangerCopilotFeature.State(
                missionId: mission.id,
                missionName: mission.name
            )
        }
    }

    enum Action {
        case onAppear
        case incidentsUpdated([Incident])
        case locationUpdated(CLLocationCoordinate2D)
        case toggleTracking
        case toggleCopilot
        case setShowAddIncident(Bool)
        case copilot(RangerCopilotFeature.Action)
        case pauseMission
        case completeMission
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.copilot, action: \.copilot) {
            RangerCopilotFeature()
        }
        Reduce { state, action in
            switch action {
            case .onAppear:
                let missionId = state.mission.id.uuidString
                return .run { send in
                    let stream = try systemManager.db.watch(
                        sql: "SELECT * FROM map_features WHERE mission_id = ? ORDER BY created_at DESC",
                        parameters: [missionId]
                    ) { cursor in
                        Incident(cursor: cursor)
                    }
                    for try await incidents in stream {
                        await send(.incidentsUpdated(incidents.compactMap { $0 }))
                    }
                }

            case .incidentsUpdated(let incidents):
                state.incidents = incidents
                return .none

            case .toggleCopilot:
                state.showingCopilot.toggle()
                return .none

            case .setShowAddIncident(let show):
                state.showingAddIncident = show
                return .none

            case .toggleTracking:
                state.isTracking.toggle()
                return .none

            case .locationUpdated(let coord):
                let point = RoutePoint(coordinate: coord, timestamp: Date(), accuracy: 5)
                state.routePoints.append(point)
                return .none

            case .pauseMission:
                return .run { [id = state.mission.id] _ in
                    try await systemManager.db.execute(
                        sql: "UPDATE missions SET mission_state = 'paused' WHERE id = ?",
                        parameters: [id.uuidString]
                    )
                }

            case .completeMission:
                return .run { [id = state.mission.id] _ in
                    try await systemManager.db.execute(
                        sql: "UPDATE missions SET mission_state = 'completed', status = 'past' WHERE id = ?",
                        parameters: [id.uuidString]
                    )
                }

            case .copilot:
                return .none
            }
        }
    }
}

// MARK: - ActiveMissionView

struct ActiveMissionView: View {
    @Bindable var store: StoreOf<ActiveMissionFeature>

    var body: some View {
        ZStack(alignment: .bottom) {
            // Map placeholder — integrate MapKit here
            Color.black.opacity(0.9).ignoresSafeArea()
            Text("Map View")
                .foregroundColor(.gray)

            // Bottom HUD
            VStack(spacing: 0) {
                Spacer()
                MissionHUDView(
                    mission: store.mission,
                    incidentCount: store.incidents.count,
                    distanceKm: store.distanceTraveledKm,
                    onCopilotTap: { store.send(.toggleCopilot) },
                    onAddIncidentTap: { store.send(.setShowAddIncident(true)) }
                )
            }
        }
        .navigationTitle(store.mission.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.send(.onAppear) }
        .sheet(isPresented: Binding(
            get: { store.showingCopilot },
            set: { _ in store.send(.toggleCopilot) }
        )) {
            CopilotChatView(store: store.scope(state: \.copilot, action: \.copilot))
        }
    }
}

// MARK: - Mission HUD

struct MissionHUDView: View {
    let mission: Mission
    let incidentCount: Int
    let distanceKm: Double
    let onCopilotTap: () -> Void
    let onAddIncidentTap: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 20) {
                StatPill(value: "\(incidentCount)", label: "Incidents", icon: "exclamationmark.triangle.fill", color: .orange)
                StatPill(value: String(format: "%.1f km", distanceKm), label: "Distance", icon: "figure.walk", color: .blue)
            }
            HStack(spacing: 12) {
                Button(action: onAddIncidentTap) {
                    Label("Log Incident", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                Button(action: onCopilotTap) {
                    Label("AI Copilot", systemImage: "brain")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }
}

struct StatPill: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundColor(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.headline)
                Text(label).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
