import ComposableArchitecture
import SwiftUI

// MARK: - AppFeature

@Reducer
struct AppFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var authState: AuthFeature.State = .init()
        var mainState: MainFeature.State = .init()
        var appPhase: AppPhase = .launching

        enum AppPhase: Equatable {
            case launching
            case unauthenticated
            case authenticated(role: UserRole)
        }
    }

    enum Action {
        case appDelegate(AppDelegateAction)
        case auth(AuthFeature.Action)
        case main(MainFeature.Action)
        case _setPhase(State.AppPhase)
    }

    enum AppDelegateAction {
        case didFinishLaunching
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.authState, action: \.auth) {
            AuthFeature()
        }
        Scope(state: \.mainState, action: \.main) {
            MainFeature()
        }
        Reduce { state, action in
            switch action {
            case .appDelegate(.didFinishLaunching):
                return .run { send in
                    do {
                        try await systemManager.connect()
                        if let staff = try await systemManager.getCurrentUser() {
                            await send(._setPhase(.authenticated(role: staff.userRole)))
                        } else {
                            await send(._setPhase(.unauthenticated))
                        }
                    } catch {
                        await send(._setPhase(.unauthenticated))
                    }
                }

            case let ._setPhase(phase):
                state.appPhase = phase
                return .none

            case .auth(.signInSucceeded(let staff)):
                state.appPhase = .authenticated(role: staff.userRole)
                return .none

            case .auth(.signOutSucceeded):
                state.appPhase = .unauthenticated
                return .none

            default:
                return .none
            }
        }
    }
}

// MARK: - AppView

struct AppView: View {
    let store: StoreOf<AppFeature>

    var body: some View {
        switch store.appPhase {
        case .launching:
            LaunchScreenView()

        case .unauthenticated:
            AuthView(store: store.scope(state: \.authState, action: \.auth))

        case .authenticated:
            MainView(store: store.scope(state: \.mainState, action: \.main))
        }
    }
}

// MARK: - Launch Screen

struct LaunchScreenView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "binoculars.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.green)
                Text("Askari AI")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)
                Text("Ranger Intelligence Copilot")
                    .font(.subheadline)
                    .foregroundColor(.gray)
                ProgressView()
                    .tint(.green)
                    .padding(.top, 8)
            }
        }
    }
}
