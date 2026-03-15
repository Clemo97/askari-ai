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
        var overdueBlocks: [ParkBlock] = []
        var activeMissionCount: Int = 0
        var totalIncidentsThisMonth: Int = 0
        var isLoading = false
    }

    enum Action {
        case onAppear
        case dataLoaded(incidents: [Incident], blocks: [ParkBlock], missionCount: Int)
    }

    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .onAppear:
                state.isLoading = true
                return .run { send in
                    async let incidents = loadRecentIncidents()
                    async let blocks = loadOverdueBlocks()
                    async let missionCount = loadActiveMissionCount()
                    await send(.dataLoaded(incidents: (try? await incidents) ?? [], blocks: (try? await blocks) ?? [], missionCount: (try? await missionCount) ?? 0))
                }

            case .dataLoaded(let incidents, let blocks, let count):
                state.recentIncidents = incidents
                state.overdueBlocks = blocks
                state.activeMissionCount = count
                state.isLoading = false
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

    private func loadOverdueBlocks() async throws -> [ParkBlock] {
        let rows = try await systemManager.db.getAll(
            sql: """
                SELECT * FROM park_blocks
                WHERE last_patrolled IS NULL
                   OR julianday('now') - julianday(last_patrolled) > rate_of_decay
                ORDER BY last_patrolled ASC
            """,
            parameters: [],
            mapper: { cursor in ParkBlock(cursor: cursor) }
        )
        return rows.compactMap { $0 }
    }

    private func loadActiveMissionCount() async throws -> Int {
        let rows = try await systemManager.db.getAll(
            sql: "SELECT COUNT(*) as count FROM missions WHERE status = 'current' AND mission_state = 'active'",
            parameters: [],
            mapper: { cursor in (try? cursor.getString(name: "count")) ?? "0" }
        )
        return Int(rows.first ?? "0") ?? 0
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
                    Section("Active Missions") {
                        HStack {
                            Image(systemName: "map.fill").foregroundColor(.green)
                            Text("\(store.activeMissionCount) active patrol\(store.activeMissionCount == 1 ? "" : "s")")
                        }
                    }

                    if !store.overdueBlocks.isEmpty {
                        Section("⚠️ Overdue Blocks") {
                            ForEach(store.overdueBlocks) { block in
                                BlockOverdueRow(block: block)
                            }
                        }
                    }

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

struct BlockOverdueRow: View {
    let block: ParkBlock
    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(block.blockName).font(.headline)
                if let last = block.lastPatrolled {
                    Text("Last patrolled: \(last.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundColor(.secondary)
                } else {
                    Text("Never patrolled").font(.caption).foregroundColor(.red)
                }
            }
            Spacer()
            Text("\(Int(block.healthScore * 100))%")
                .font(.caption.bold())
                .foregroundColor(block.healthScore < 0.3 ? .red : .orange)
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
