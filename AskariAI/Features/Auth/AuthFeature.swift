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
        var firstName: String = ""
        var lastName: String = ""
        var isLoading = false
        var errorMessage: String? = nil
        var mode: Mode = .signIn

        enum Mode: Equatable { case signIn, signUp }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case signInTapped
        case signUpTapped
        case signInSucceeded(StaffMember)
        case signOutSucceeded
        case setError(String?)
        case toggleMode
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .toggleMode:
                state.mode = state.mode == .signIn ? .signUp : .signIn
                state.errorMessage = nil
                return .none

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
                            await send(.setError("Account not linked to a ranger profile. Contact your park administrator."))
                        }
                    } catch {
                        await send(.setError(error.localizedDescription))
                    }
                }

            case .signUpTapped:
                state.isLoading = true
                state.errorMessage = nil
                let email = state.email
                let password = state.password
                let firstName = state.firstName
                let lastName = state.lastName
                return .run { send in
                    do {
                        try await systemManager.connector.signUp(
                            email: email,
                            password: password,
                            firstName: firstName,
                            lastName: lastName
                        )
                        // After sign-up, sign in automatically
                        try await systemManager.connector.signIn(email: email, password: password)
                        if let staff = try await systemManager.getCurrentUser() {
                            await send(.signInSucceeded(staff))
                        } else {
                            // Profile created but staff row not yet visible — connect anyway
                            await send(.setError("Account created! A park administrator needs to link your profile before you can patrol. You can sign in once linked."))
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
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 40)

                    // Logo
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

                    // Mode toggle
                    Picker("Mode", selection: $store.mode) {
                        Text("Sign In").tag(AuthFeature.State.Mode.signIn)
                        Text("Create Account").tag(AuthFeature.State.Mode.signUp)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 32)

                    // Fields
                    VStack(spacing: 16) {
                        if store.mode == .signUp {
                            HStack(spacing: 12) {
                                TextField("First name", text: $store.firstName)
                                    .textFieldStyle(.roundedBorder)
                                    .autocapitalization(.words)
                                TextField("Last name", text: $store.lastName)
                                    .textFieldStyle(.roundedBorder)
                                    .autocapitalization(.words)
                            }
                        }

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
                                .multilineTextAlignment(.center)
                        }

                        Button {
                            if store.mode == .signIn {
                                store.send(.signInTapped)
                            } else {
                                store.send(.signUpTapped)
                            }
                        } label: {
                            if store.isLoading {
                                ProgressView().frame(maxWidth: .infinity)
                            } else {
                                Text(store.mode == .signIn ? "Sign In" : "Create Account")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isLoading || store.email.isEmpty || store.password.isEmpty
                            || (store.mode == .signUp && (store.firstName.isEmpty || store.lastName.isEmpty)))

                        if store.mode == .signUp {
                            Text("After creating your account, a park administrator will link it to your ranger profile.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 32)

                    Spacer().frame(height: 40)
                }
            }
            .navigationBarHidden(true)
        }
    }
}

