import ComposableArchitecture
import CoreLocation
import SwiftUI

// MARK: - LogIncidentFeature

@Reducer
struct LogIncidentFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var coordinate: CLLocationCoordinate2D
        var selectedSpotTypeId: UUID? = nil
        var description: String = ""
        var severity: Incident.Severity = .medium
        var spotTypes: [SpotType] = []
        var activeMissions: [Mission] = []
        var selectedMissionId: UUID? = nil
        var isSaving = false
        var errorMessage: String? = nil

        // CLLocationCoordinate2D doesn't conform to Equatable
        static func == (lhs: State, rhs: State) -> Bool {
            lhs.coordinate.latitude == rhs.coordinate.latitude &&
            lhs.coordinate.longitude == rhs.coordinate.longitude &&
            lhs.selectedSpotTypeId == rhs.selectedSpotTypeId &&
            lhs.description == rhs.description &&
            lhs.severity == rhs.severity &&
            lhs.spotTypes == rhs.spotTypes &&
            lhs.activeMissions == rhs.activeMissions &&
            lhs.selectedMissionId == rhs.selectedMissionId &&
            lhs.isSaving == rhs.isSaving &&
            lhs.errorMessage == rhs.errorMessage
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case spotTypesLoaded([SpotType])
        case missionsLoaded([Mission])
        case save
        case saved
        case cancel
        case setError(String?)
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .merge(
                    .run { send in
                        let types = try await systemManager.db.getAll(
                            sql: "SELECT * FROM spot_types WHERE is_active = 1 ORDER BY sort_order",
                            parameters: [],
                            mapper: { cursor in SpotType(cursor: cursor) }
                        )
                        await send(.spotTypesLoaded(types.compactMap { $0 }))
                    },
                    .run { send in
                        let missions = try await systemManager.db.getAll(
                            sql: "SELECT * FROM missions WHERE status = 'current' ORDER BY start_date DESC",
                            parameters: [],
                            mapper: { cursor in Mission(cursor: cursor) }
                        )
                        await send(.missionsLoaded(missions.compactMap { $0 }))
                    }
                )

            case .spotTypesLoaded(let types):
                state.spotTypes = types
                if state.selectedSpotTypeId == nil {
                    state.selectedSpotTypeId = types.first?.id
                }
                return .none

            case .missionsLoaded(let missions):
                state.activeMissions = missions
                state.selectedMissionId = missions.first?.id
                return .none

            case .save:
                guard let spotType = state.spotTypes.first(where: { $0.id == state.selectedSpotTypeId })
                        ?? state.spotTypes.first else {
                    state.errorMessage = "Please select an incident type."
                    return .none
                }

                state.isSaving = true
                state.errorMessage = nil

                let coordinate = state.coordinate
                let description = state.description
                let severity = state.severity
                let missionId = state.selectedMissionId

                return .run { send in
                    do {
                        // Get current user & park
                        guard let staff = try await systemManager.connector.fetchCurrentStaff() else {
                            await send(.setError("Could not identify current ranger."))
                            return
                        }

                        let parkId: UUID
                        if let pid = staff.parkId {
                            parkId = pid
                        } else {
                            // Fall back: use first park in local DB
                            let parks = try await systemManager.db.getAll(
                                sql: "SELECT id FROM parks LIMIT 1",
                                parameters: [],
                                mapper: { cursor in (try? cursor.getString(name: "id")).flatMap(UUID.init) }
                            )
                            guard let firstPark = parks.first.flatMap({ $0 }) else {
                                await send(.setError("No park found. Ensure data has synced."))
                                return
                            }
                            parkId = firstPark
                        }

                        let incidentId = UUID()
                        let geoJSON = """
                            {"type":"Point","coordinates":[\(coordinate.longitude),\(coordinate.latitude)]}
                        """

                        // PowerSync local write — syncs to Supabase via uploadData
                        try await systemManager.db.execute(
                            sql: """
                                INSERT INTO map_features
                                    (id, park_id, mission_id, spot_type_id, name, description,
                                     geometry, created_by, captured_by_staff_id,
                                     severity, media_url, is_resolved)
                                VALUES (?,?,?,?,?,?,?,?,?,?,'[]',0)
                            """,
                            parameters: [
                                incidentId.uuidString,
                                parkId.uuidString,
                                missionId?.uuidString as (any Sendable)?,
                                spotType.id.uuidString,
                                spotType.displayName,
                                description,
                                geoJSON,
                                staff.id.uuidString,
                                staff.id.uuidString,
                                severity.rawValue
                            ]
                        )
                        await send(.saved)
                    } catch {
                        await send(.setError(error.localizedDescription))
                    }
                }

            case .setError(let msg):
                state.isSaving = false
                state.errorMessage = msg
                return .none

            case .saved:
                state.isSaving = false
                return .none

            case .cancel, .binding:
                return .none
            }
        }
    }
}

// MARK: - LogIncidentSheet

struct LogIncidentSheet: View {
    @Bindable var store: StoreOf<LogIncidentFeature>

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    HStack {
                        Image(systemName: "mappin.circle.fill")
                            .foregroundColor(.red)
                        Text(String(format: "%.5f, %.5f",
                                    store.coordinate.latitude,
                                    store.coordinate.longitude))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }

                Section("Incident Type") {
                    if store.spotTypes.isEmpty {
                        ProgressView("Loading types…")
                    } else {
                        Picker("Type", selection: $store.selectedSpotTypeId) {
                            ForEach(store.spotTypes) { spotType in
                                Text(spotType.displayName)
                                    .tag(Optional(spotType.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Severity") {
                    Picker("Severity", selection: $store.severity) {
                        ForEach(Incident.Severity.allCases, id: \.self) { s in
                            Text(s.rawValue.capitalized).tag(s)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if !store.activeMissions.isEmpty {
                    Section("Mission (optional)") {
                        Picker("Mission", selection: $store.selectedMissionId) {
                            Text("None").tag(Optional<UUID>.none)
                            ForEach(store.activeMissions) { mission in
                                Text(mission.name).tag(Optional(mission.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section("Notes") {
                    TextField("Describe what you observed…",
                              text: $store.description,
                              axis: .vertical)
                        .lineLimit(4...)
                }

                if let error = store.errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Log Incident")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancel) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        store.send(.save)
                    } label: {
                        if store.isSaving {
                            ProgressView()
                        } else {
                            Text("Log")
                                .bold()
                        }
                    }
                    .disabled(store.isSaving || store.selectedSpotTypeId == nil)
                }
            }
            .onAppear { store.send(.onAppear) }
        }
    }
}
