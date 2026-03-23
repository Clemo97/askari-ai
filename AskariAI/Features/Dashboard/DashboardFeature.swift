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
    }

    enum Action {
        case onAppear
        case dataLoaded(incidents: [Incident])
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
            }
        }
    }

    private func loadRecentIncidents() async throws -> [Incident] {        let rows = try await systemManager.db.getAll(
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

    var body: some View {
        NavigationStack {
            List {
                if store.isLoading {
                    Section {
                        ProgressView("Loading intelligence…")
                    }
                } else {
                    Section("Recent Incidents (7 days)") {
                        if store.recentIncidents.isEmpty {
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
            .navigationTitle("Intelligence")
            .refreshable { store.send(.onAppear) }
        }
        .onAppear { store.send(.onAppear) }
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
