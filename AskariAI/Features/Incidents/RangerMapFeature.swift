import ComposableArchitecture
import MapKit
import SwiftUI
import CoreLocation

// MARK: - RangerMapFeature

@Reducer
struct RangerMapFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var camera: MapCameraPosition = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: -1.3751, longitude: 36.8460),
            span: MKCoordinateSpan(latitudeDelta: 0.12, longitudeDelta: 0.12)
        ))
        var boundary: ParkBoundary? = nil
        var incidents: [Incident] = []
        var spotTypes: [SpotType] = []
        var isLoading = true
        var selectedCoordinate: CLLocationCoordinate2D? = nil
        var logIncident: LogIncidentFeature.State? = nil
        var mapStyleType: MapStyleType = .standard

        enum MapStyleType: Equatable { case standard, satellite, hybrid }
        var mapStyle: MapStyle {
            switch mapStyleType {
            case .standard:  return .standard
            case .satellite: return .imagery
            case .hybrid:    return .hybrid
            }
        }

        // MapCameraPosition and CLLocationCoordinate2D don't conform to Equatable.
        static func == (lhs: State, rhs: State) -> Bool {
            lhs.boundary == rhs.boundary &&
            lhs.incidents == rhs.incidents &&
            lhs.spotTypes == rhs.spotTypes &&
            lhs.isLoading == rhs.isLoading &&
            lhs.logIncident == rhs.logIncident &&
            lhs.mapStyleType == rhs.mapStyleType &&
            lhs.selectedCoordinate?.latitude == rhs.selectedCoordinate?.latitude &&
            lhs.selectedCoordinate?.longitude == rhs.selectedCoordinate?.longitude
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case onAppear
        case boundaryLoaded(ParkBoundary?)
        case incidentsUpdated([Incident])
        case spotTypesLoaded([SpotType])
        case mapTapped(CLLocationCoordinate2D)
        case updateCamera(MapCameraPosition)
        case toggleMapStyle
        case logIncident(LogIncidentFeature.Action)
        case dismissLogSheet
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .merge(
                    .run { send in
                        // Load park boundary from local DB
                        let rows = try await systemManager.db.getAll(
                            sql: "SELECT * FROM park_boundaries LIMIT 1",
                            parameters: [],
                            mapper: { cursor in ParkBoundary(cursor: cursor) }
                        )
                        await send(.boundaryLoaded(rows.first.flatMap { $0 }))
                    },
                    .run { send in
                        // Load spot types
                        let types = try await systemManager.db.getAll(
                            sql: "SELECT * FROM spot_types WHERE is_active = 1 ORDER BY sort_order",
                            parameters: [],
                            mapper: { cursor in SpotType(cursor: cursor) }
                        )
                        await send(.spotTypesLoaded(types.compactMap { $0 }))
                    },
                    .run { send in
                        // Live-watch incidents via PowerSync
                        let stream = try systemManager.db.watch(
                            sql: "SELECT * FROM map_features ORDER BY created_at DESC",
                            parameters: [],
                            mapper: { cursor in Incident(cursor: cursor) }
                        )
                        for try await rows in stream {
                            await send(.incidentsUpdated(rows.compactMap { $0 }))
                        }
                    }
                )

            case .boundaryLoaded(let boundary):
                state.isLoading = false
                state.boundary = boundary
                if let center = boundary?.center {
                    state.camera = .region(MKCoordinateRegion(
                        center: center,
                        span: MKCoordinateSpan(latitudeDelta: 0.16, longitudeDelta: 0.16)
                    ))
                }
                return .none

            case .incidentsUpdated(let incidents):
                state.incidents = incidents
                return .none

            case .spotTypesLoaded(let types):
                state.spotTypes = types
                if state.boundaryLoaded { state.isLoading = false }
                return .none

            case .mapTapped(let coord):
                state.selectedCoordinate = coord
                state.logIncident = LogIncidentFeature.State(coordinate: coord)
                return .none

            case .updateCamera(let pos):
                state.camera = pos
                return .none

            case .toggleMapStyle:
                switch state.mapStyleType {
                case .standard:  state.mapStyleType = .satellite
                case .satellite: state.mapStyleType = .hybrid
                case .hybrid:    state.mapStyleType = .standard
                }
                return .none

            case .logIncident(.cancel):
                state.logIncident = nil
                state.selectedCoordinate = nil
                return .none

            case .logIncident(.saved):
                state.logIncident = nil
                state.selectedCoordinate = nil
                return .none

            case .dismissLogSheet:
                state.logIncident = nil
                state.selectedCoordinate = nil
                return .none

            case .logIncident, .binding:
                return .none
            }
        }
        .ifLet(\.logIncident, action: \.logIncident) {
            LogIncidentFeature()
        }
    }
}

// Computed helper used in reducer
private extension RangerMapFeature.State {
    var boundaryLoaded: Bool { boundary != nil }
}

// MARK: - RangerMapView

struct RangerMapView: View {
    @Bindable var store: StoreOf<RangerMapFeature>

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MapReader { proxy in
                Map(position: Binding(
                    get: { store.camera },
                    set: { store.send(.updateCamera($0)) }
                )) {
                    // Park boundary overlay
                    if let boundary = store.boundary,
                       !boundary.coordinateArray.isEmpty {
                        MapPolygon(coordinates: boundary.coordinateArray)
                            .stroke(.green.opacity(0.9), lineWidth: 2)
                            .foregroundStyle(.green.opacity(0.08))
                    }

                    // Incidents as annotations
                    ForEach(store.incidents) { incident in
                        let color = incidentColor(incident: incident, spotTypes: store.spotTypes)
                        Annotation(
                            incident.name,
                            coordinate: incident.coordinate,
                            anchor: .bottom
                        ) {
                            IncidentPin(color: color, severity: incident.severity)
                        }
                    }

                    // Tapped location marker
                    if let coord = store.selectedCoordinate {
                        Marker("New Incident", coordinate: coord)
                            .tint(.red)
                    }

                    // Ranger's own location
                    UserAnnotation()
                }
                .mapStyle(store.mapStyle)
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                    MapScaleView()
                }
                .onTapGesture { screenPoint in
                    if let coordinate = proxy.convert(screenPoint, from: .local) {
                        store.send(.mapTapped(coordinate))
                    }
                }
                .onMapCameraChange { ctx in
                    store.send(.updateCamera(.camera(ctx.camera)))
                }
            }

            // Map style toggle button
            VStack(spacing: 8) {
                Button {
                    store.send(.toggleMapStyle)
                } label: {
                    Image(systemName: mapStyleIcon(store.mapStyleType))
                        .padding(10)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.top, 60)
                .padding(.trailing, 12)
            }

            // Loading overlay
            if store.isLoading {
                VStack {
                    ProgressView("Syncing park data…")
                        .padding()
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.15))
            }
        }
        .sheet(
            item: Binding(
                get: { store.logIncident.map { _ in SheetID() } },
                set: { if $0 == nil { store.send(.dismissLogSheet) } }
            )
        ) { _ in
            if let logStore = store.scope(state: \.logIncident, action: \.logIncident) {
                LogIncidentSheet(store: logStore)
                    .presentationDetents([.medium, .large])
            }
        }
        .navigationTitle("Patrol Map")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.send(.onAppear) }
    }

    private func incidentColor(incident: Incident, spotTypes: [SpotType]) -> Color {
        if let spotTypeId = incident.spotTypeId,
           let spotType = spotTypes.first(where: { $0.id == spotTypeId }) {
            return spotType.color
        }
        return severityColor(incident.severity)
    }

    private func severityColor(_ severity: Incident.Severity) -> Color {
        switch severity {
        case .low:      return .yellow
        case .medium:   return .orange
        case .high:     return .red
        case .critical: return .purple
        }
    }

    private func mapStyleIcon(_ style: RangerMapFeature.State.MapStyleType) -> String {
        switch style {
        case .standard:  return "map"
        case .satellite: return "globe.americas.fill"
        case .hybrid:    return "map.fill"
        }
    }
}

// Small Equatable wrapper so sheet(item:) works
private struct SheetID: Identifiable, Equatable {
    let id = UUID()
}

// MARK: - IncidentPin

struct IncidentPin: View {
    let color: Color
    let severity: Incident.Severity

    var body: some View {
        ZStack {
            Circle()
                .fill(color)
                .frame(width: 28, height: 28)
                .shadow(radius: 2)
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
    }

    private var iconName: String {
        switch severity {
        case .critical: return "exclamationmark.triangle.fill"
        case .high:     return "exclamationmark.circle.fill"
        case .medium:   return "circle.fill"
        case .low:      return "info.circle.fill"
        }
    }
}
