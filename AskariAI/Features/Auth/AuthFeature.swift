import ComposableArchitecture
import SwiftUI

// MARK: - AuthFeature

@Reducer
struct AuthFeature {
    @Dependency(\.systemManager) var systemManager

    @ObservableState
    struct State: Equatable {
        var email: String = ""
        var password: String = ""
        var isLoading = false
        var errorMessage: String? = nil
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case signInTapped
        case signInSucceeded(StaffMember)
        case signOutSucceeded
        case setError(String?)
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .signInTapped:
                state.isLoading = true
                state.errorMessage = nil
                let email = state.email
                let password = state.password
                return .run { send in
                    do {
                        try await systemManager.connector.signIn(email: email, password: password)
                        if let staff = try await systemManager.getCurrentUser() {
                            await send(.signInSucceeded(staff))
                        } else {
                            await send(.setError("Account not found in this park."))
                        }
                    } catch {
                        await send(.setError(error.localizedDescription))
                    }
                }

            case .setError(let msg):
                state.isLoading = false
                state.errorMessage = msg
                return .none

            case .signInSucceeded:
                state.isLoading = false
                return .none

            case .signOutSucceeded, .binding:
                return .none
            }
        }
    }
}

// MARK: - AuthView

struct AuthView: View {
    @Bindable var store: StoreOf<AuthFeature>

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "binoculars.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.green)
                    Text("Askari AI")
                        .font(.largeTitle.bold())
                    Text("Ranger Intelligence Copilot")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                VStack(spacing: 16) {
                    TextField("Email", text: $store.email)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                        .textFieldStyle(.roundedBorder)

                    SecureField("Password", text: $store.password)
                        .textFieldStyle(.roundedBorder)

                    if let error = store.errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Button {
                        store.send(.signInTapped)
                    } label: {
                        if store.isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isLoading || store.email.isEmpty || store.password.isEmpty)
                }
                .padding(.horizontal, 32)

                Spacer()
            }
            .navigationBarHidden(true)
        }
    }
}
