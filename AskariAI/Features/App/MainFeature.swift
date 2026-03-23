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
        var dashboard: DashboardFeature.State = .init()
        var rangerMap: RangerMapFeature.State = .init()
        var selectedTab: Tab = .map

        enum Tab: Equatable {
            case map, intelligence, settings
        }
    }

    enum Action {
        case onAppear
        case setCurrentUser(StaffMember?)
        case dashboard(DashboardFeature.Action)
        case rangerMap(RangerMapFeature.Action)
        case selectTab(State.Tab)
        case signOutTapped
        case signOutCompleted
    }

    var body: some ReducerOf<Self> {
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

            case .signOutTapped:
                return .run { send in
                    try? await systemManager.connector.signOut()
                    await send(.signOutCompleted)
                }

            case .signOutCompleted:
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

            DashboardView(store: store.scope(state: \.dashboard, action: \.dashboard))
                .tabItem { Label("Intelligence", systemImage: "chart.bar.xaxis") }
                .tag(MainFeature.State.Tab.intelligence)

            SettingsView(store: store)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(MainFeature.State.Tab.settings)
        }
        .onAppear { store.send(.onAppear) }
        .tint(.green)
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    let store: StoreOf<MainFeature>
    @State private var showSignOutConfirm = false

    var body: some View {
        NavigationStack {
            List {
                if let user = store.currentUser {
                    Section("Profile") {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.15))
                                    .frame(width: 48, height: 48)
                                Text(user.firstName.prefix(1) + user.lastName.prefix(1))
                                    .font(.headline)
                                    .foregroundColor(.green)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.fullName)
                                    .font(.headline)
                                Text(user.email)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(user.rank.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    Button(role: .destructive) {
                        showSignOutConfirm = true
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .confirmationDialog("Sign out?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                store.send(.signOutTapped)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be returned to the login screen.")
        }
    }
}

