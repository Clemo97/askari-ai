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
        var selectedTab: Tab = .missions

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
        case selectTab(State.Tab)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.missions, action: \.missions) {
            MissionsFeature()
        }
        Scope(state: \.dashboard, action: \.dashboard) {
            DashboardFeature()
        }
        Reduce { state, action in
            switch action {
            case .onAppear:
                return .run { send in
                    let user = try? await systemManager.getCurrentUser()
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
            MissionsView(store: store.scope(state: \.missions, action: \.missions))
                .tabItem { Label("Missions", systemImage: "map.fill") }
                .tag(MainFeature.State.Tab.missions)

            DashboardView(store: store.scope(state: \.dashboard, action: \.dashboard))
                .tabItem { Label("Intelligence", systemImage: "chart.bar.xaxis") }
                .tag(MainFeature.State.Tab.map)

            Text("Staff")
                .tabItem { Label("Staff", systemImage: "person.3.fill") }
                .tag(MainFeature.State.Tab.staff)

            Text("Settings")
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(MainFeature.State.Tab.settings)
        }
        .onAppear { store.send(.onAppear) }
        .tint(.green)
    }
}
