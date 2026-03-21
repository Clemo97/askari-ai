import ComposableArchitecture
import SwiftUI

// MARK: - MainFeature
// Top-level navigation for authenticated users, branches on role.

@Reducer
struct MainFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var currentUser: StaffMember? = nil
        var missions: MissionsFeature.State = .init()
        var activeMission: ActiveMissionFeature.State? = nil
        var dashboard: DashboardFeature.State = .init()
        var rangerMap: RangerMapFeature.State = .init()
        var selectedTab: Tab = .map

        enum Tab: Equatable {
            case missions, map, staff, settings
        }
    }

    enum Action {
        case onAppear
        case setCurrentUser(StaffMember?)
        case missions(MissionsFeature.Action)
        case activeMission(ActiveMissionFeature.Action)
        case dashboard(DashboardFeature.Action)
        case rangerMap(RangerMapFeature.Action)
        case selectTab(State.Tab)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.missions, action: \.missions) {
            MissionsFeature()
        }
        Scope(state: \.dashboard, action: \.dashboard) {
            DashboardFeature()
        }
        Scope(state: \.rangerMap, action: \.rangerMap) {
            RangerMapFeature()
        }
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    let user = try? await systemManager.connector.fetchCurrentStaff()
                    await send(.setCurrentUser(user))
                }

            case .setCurrentUser(let user):
                state.currentUser = user
                return .none

            case .selectTab(let tab):
                state.selectedTab = tab
                return .none

            default:
                return .none
            }
        }
    }
}

// MARK: - MainView

struct MainView: View {
    let store: StoreOf<MainFeature>

    var body: some View {
        TabView(selection: Binding(
            get: { store.selectedTab },
            set: { store.send(.selectTab($0)) }
        )) {
            NavigationStack {
                RangerMapView(store: store.scope(state: \.rangerMap, action: \.rangerMap))
            }
            .tabItem { Label("Map", systemImage: "map.fill") }
            .tag(MainFeature.State.Tab.map)

            MissionsView(store: store.scope(state: \.missions, action: \.missions))
                .tabItem { Label("Missions", systemImage: "list.bullet.clipboard.fill") }
                .tag(MainFeature.State.Tab.missions)

            DashboardView(store: store.scope(state: \.dashboard, action: \.dashboard))
                .tabItem { Label("Intelligence", systemImage: "chart.bar.xaxis") }
                .tag(MainFeature.State.Tab.staff)

            Text("Settings")
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(MainFeature.State.Tab.settings)
        }
        .onAppear { store.send(.onAppear) }
        .tint(.green)
    }
}

