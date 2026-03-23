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
        var portal: Portal = .none

        enum Mode: Equatable { case signIn, signUp }

        enum Portal: Equatable {
            case none
            case ranger
            case admin

            var displayName: String {
                switch self {
                case .none:   return ""
                case .ranger: return "Ranger"
                case .admin:  return "Admin"
                }
            }

            var color: Color {
                switch self {
                case .none:   return .green
                case .ranger: return .green
                case .admin:  return .blue
                }
            }

            var icon: String {
                switch self {
                case .none:   return ""
                case .ranger: return "figure.walk"
                case .admin:  return "shield.lefthalf.filled"
                }
            }
        }
    }

    enum Action: BindableAction {
        case binding(BindingAction<State>)
        case selectPortal(State.Portal)
        case signInTapped
        case signUpTapped
        case signInSucceeded(StaffMember, UserRole)
        case signOutSucceeded
        case setError(String?)
        case toggleMode
    }

    var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .selectPortal(let portal):
                state.portal = portal
                state.errorMessage = nil
                state.mode = .signIn
                state.email = ""
                state.password = ""
                return .none

            case .toggleMode:
                state.mode = state.mode == .signIn ? .signUp : .signIn
                state.errorMessage = nil
                return .none

            case .signInTapped:
                state.isLoading = true
                state.errorMessage = nil
                let email = state.email
                let password = state.password
                let portal = state.portal
                return .run { send in
                    do {
                        try await systemManager.connector.signIn(email: email, password: password)
                        if let staff = try await systemManager.connector.fetchCurrentStaff() {
                            // Rangers cannot access the admin portal
                            if portal == .admin && (staff.rank == .ranger || staff.rank == .supervisor) {
                                await send(.setError("Access denied. This login is for administrators only. Please use the Ranger login."))
                                return
                            }
                            // Admins signing in via ranger portal get the ranger UI
                            let effectiveRole: UserRole = portal == .ranger ? .ranger : staff.userRole
                            await send(.signInSucceeded(staff, effectiveRole))
                        } else {
                            await send(.setError("No staff profile found. Contact your administrator."))
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
                let rank = state.portal == .admin ? "admin" : "ranger"
                return .run { send in
                    do {
                        try await systemManager.connector.signUp(
                            email: email,
                            password: password,
                            firstName: firstName,
                            lastName: lastName,
                            rank: rank
                        )
                        try await systemManager.connector.signIn(email: email, password: password)
                        try await Task.sleep(for: .seconds(1))
                        if let staff = try await systemManager.connector.fetchCurrentStaff() {
                            await send(.signInSucceeded(staff, staff.userRole))
                        } else {
                            await send(.setError("Account created! Sign in to continue."))
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

            case .signOutSucceeded:
                state.portal = .none
                return .none

            case .binding:
                return .none
            }
        }
    }
}

// MARK: - AuthView

struct AuthView: View {
    @Bindable var store: StoreOf<AuthFeature>

    var body: some View {
        switch store.portal {
        case .none:
            PortalPickerView(store: store)
        case .ranger, .admin:
            LoginFormView(store: store)
        }
    }
}

// MARK: - Portal Picker

private struct PortalPickerView: View {
    @Bindable var store: StoreOf<AuthFeature>

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo
                VStack(spacing: 10) {
                    Image(systemName: "binoculars.fill")
                        .font(.system(size: 56))
                        .foregroundColor(.green)
                    Text("Askari AI")
                        .font(.largeTitle.bold())
                    Text("Ranger Intelligence Copilot")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer().frame(height: 56)

                Text("Sign in as")
                    .font(.headline)
                    .foregroundColor(.secondary)

                Spacer().frame(height: 20)

                // Portal buttons
                HStack(spacing: 16) {
                    PortalCard(
                        title: "Ranger",
                        subtitle: "Field operations & incident reporting",
                        icon: "figure.walk",
                        color: .green
                    ) {
                        store.send(.selectPortal(.ranger))
                    }

                    PortalCard(
                        title: "Admin",
                        subtitle: "Management & intelligence dashboard",
                        icon: "shield.lefthalf.filled",
                        color: .blue
                    ) {
                        store.send(.selectPortal(.admin))
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
        }
    }
}

private struct PortalCard: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Image(systemName: icon)
                        .font(.system(size: 28))
                        .foregroundColor(color)
                }
                Text(title)
                    .font(.headline)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 180)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(color.opacity(0.3), lineWidth: 1.5)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Login Form

private struct LoginFormView: View {
    @Bindable var store: StoreOf<AuthFeature>

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Spacer().frame(height: 20)

                    // Portal header
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(store.portal.color.opacity(0.15))
                                .frame(width: 72, height: 72)
                            Image(systemName: store.portal.icon)
                                .font(.system(size: 32))
                                .foregroundColor(store.portal.color)
                        }
                        Text("\(store.portal.displayName) Login")
                            .font(.title2.bold())
                        Text("Askari AI")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    // Mode toggle (admin portal only)
                    if store.portal == .admin {
                        Picker("Mode", selection: $store.mode) {
                            Text("Sign In").tag(AuthFeature.State.Mode.signIn)
                            Text("Create Account").tag(AuthFeature.State.Mode.signUp)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 32)
                    }

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
                        .tint(store.portal.color)
                        .disabled(
                            store.isLoading || store.email.isEmpty || store.password.isEmpty
                            || (store.mode == .signUp && (store.firstName.isEmpty || store.lastName.isEmpty))
                        )

                        if store.mode == .signUp {
                            Text("New accounts are assigned the ranger role by default. Contact your administrator to change it.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 32)

                    Spacer().frame(height: 40)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        store.send(.selectPortal(.none))
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                        .foregroundColor(store.portal.color)
                    }
                }
            }
        }
    }
}


