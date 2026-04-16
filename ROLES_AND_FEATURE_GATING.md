# e-Parcs: User Profiles and Feature Gating

This document explains the full role architecture — how roles are defined, detected, selected, verified against the database, propagated into every TCA feature, and used to gate or unlock specific capabilities and entire UI surfaces.

---

## 1. The Role Enum — Single Source of Truth

Every role in the app is a case of `AppFeature.UserRole`, defined in `Features/AppFeature.swift`:

```swift
enum UserRole: String, CaseIterable, Equatable {
    case admin          = "admin"
    case parkHead       = "park_head"
    case ranger         = "ranger"
    case parksAuthority = "parks_authority"
}
```

The `rawValue` strings exactly match the `rank` column stored in the Supabase `staff` table. This is what makes the database-to-role mapping possible at login.

Each case also carries display metadata used throughout the UI:

| Property | Purpose |
|---|---|
| `displayName` | Human-readable label shown in UI |
| `description` | Short purpose text shown on role selection and auth screens |
| `iconName` | SF Symbol used on the role selection and auth screens |
| `roleColor` | `admin` = blue, `parkHead` = purple, `ranger` = green, `parksAuthority` = orange |

---

## 2. How a Role Is Chosen Before Login — Two Paths

### Path A: Device-assigned role (kiosk mode)

`Managers/DeviceManager.swift` manages a persistent role that is saved to `UserDefaults`:

```swift
private let assignedRoleKey = "com.eparcs.assignedRole"

var assignedRole: AppFeature.UserRole? {
    get  { UserDefaults.standard.string(forKey: assignedRoleKey).map { UserRole(rawValue: $0)! } }
    set  { UserDefaults.standard.set(newValue?.rawValue, forKey: assignedRoleKey) }
}
```

A user can **long-press** any role button on the `RoleSelectionView` to permanently brand that device for a specific role:

```swift
// RoleSelectionView.swift
RoleButton(
    role: .admin,
    onLongPress: {
        DeviceManager.shared.assignedRole = .admin
    }
)
```

On the next launch, `AppFeature` reads this first:

```swift
case .onAppear:
    if let deviceRole = DeviceManager.shared.getDeviceRole() {
        state.appState = .authentication(selectedRole: deviceRole)
        // skip the role selection screen entirely
    }
```

`getDeviceRole()` itself has two sub-priorities:
1. **Manually assigned role** (from long-press) — checked first.
2. **Auto-detected from device name** — if the device name contains the word `"admin"` → `.admin`, `"ranger"` / `"patrol"` / `"field"` → `.ranger`.

### Path B: Manual selection at the role screen

If `DeviceManager` returns `nil`, `RoleSelectionView` is shown. The user taps a role button which dispatches:

```swift
viewStore.send(.roleSelected(.admin))   // or .ranger, .parksAuthority
```

`AppFeature` stores this in `state.selectedRole` and advances to:

```swift
state.appState = .authentication(selectedRole: role)
```

> **Note:** `parkHead` is not a button on the role selection screen. Park Heads log in through the **Admin** button; the app detects their actual role from the database rank after sign-in (see §3 below).

---

## 3. Authentication and Database-Driven Role Confirmation

`Features/AuthFeature.swift`

All roles sign in with **email + password** via Supabase Auth:

```swift
let session = try await systemManager.connector.client.auth.signIn(
    email: state.signInEmail,
    password: state.signInPassword
)
```

After Supabase confirms the credentials:

- **`parksAuthority`** — no staff record is fetched. A synthetic `Staff` object is built from the session with `rank: "parks_authority"`.
- **All others** — `SupabaseManager.shared.fetchStaffByEmail(email)` queries the `staff` table in Supabase and returns the full `Staff` record including the `rank` column.

`AppFeature` then performs **rank-based role resolution**:

```swift
case let .authenticationCompleted(staff):
    let normalizedRank = staff.rank.lowercased().replacingOccurrences(of: " ", with: "_")

    let actualRole: UserRole
    if normalizedRank == "parks_authority" {
        actualRole = .parksAuthority
    } else if normalizedRank == "park_head" || normalizedRank == "parkhead" {
        actualRole = .parkHead
    } else if state.selectedRole == .admin {
        actualRole = .admin
    } else {
        actualRole = .ranger
    }
```

This ensures a `parkHead` staff member who selected "Admin" on the role screen is **re-classified** to `.parkHead` after the database confirms their rank.

### Sign-up gating

Only `.admin` and `.parksAuthority` roles can create new accounts:

```swift
var canShowSignUp: Bool {
    selectedRole == .admin || selectedRole == .parksAuthority
}
```

Rangers can only **sign in** — their accounts are created by an admin.

---

## 4. Role Propagation Into TCA Child Features

After `authenticationCompleted`, `AppFeature` pushes the resolved role down into every child feature via TCA actions:

```swift
state.map.userRole = actualRole
state.missions.userRole = actualRole
state.staff.userRole = actualRole
state.settings.userRole = actualRole

return .merge(
    .send(.map(.setUserRole(actualRole))),
    .send(.missions(.mission(.setCurrentStaffId(staff.id)))),
    .send(.settings(.setUserRole(actualRole)))
)
```

`parksAuthority` is excluded from this block — they have their own entirely separate UI and none of these features apply to them.

Each feature holds its own copy of `userRole: AppFeature.UserRole` in its `State` struct. This is a **value-type snapshot** — changing it later requires another `setUserRole` dispatch.

---

## 5. Top-Level Navigation Gating (Whole-Screen)

`eparcsApp.swift` — `MainContentView`

The first fork is at the very top of the navigation hierarchy. Based on the authenticated role, a completely different root view is presented:

```swift
if userRole == .ranger {
    // Full screen: mission execution view only
    ActiveMissionView(...)

} else if userRole == .parksAuthority {
    // Full screen: swipeable parks overview
    ParksOverviewView(...)

} else {
    // .admin and .parkHead: full NavigationSplitView with sidebar
    NavigationSplitView {
        SidebarView(tabs: allowedTabs)
    } detail: {
        switch selectedTab {
        case .dashboard:  DashboardView(...)
        case .map:        MapContentView(...)
        case .missions:   MissionsView(...)
        case .staff:      StaffListView(...)
        case .reports:    ReportsView()
        case .settings:   SettingsView(...)
        }
    }
}
```

| Role | Root View | Sidebar |
|---|---|---|
| `.ranger` | `ActiveMissionView` only | None |
| `.parksAuthority` | `ParksOverviewView` only | None |
| `.admin` | Full sidebar + detail navigation | Dashboard, Map, Missions, Staff, Reports, Settings |
| `.parkHead` | Same as admin (same code path) | Same tabs, but capability gating applies inside |

---

## 6. Feature-Level Gating via Computed `Bool` Properties

Every TCA feature `State` exposes role-based computed properties. These are the single source of truth for capability gating inside reducers and views.

### `MapFeature.State`

```swift
var canCreatePolygons: Bool { userRole == .admin }
var canCreateRoutes:   Bool { userRole == .admin }
var canCreateAreas:    Bool { userRole == .admin }
var hasLocationTracking: Bool { userRole == .ranger }
```

### `SpotFeature.State`

```swift
var supportsMedia: Bool          { userRole == .ranger }
var requiresSpotModeToggle: Bool { userRole == .admin }
```

Rangers add spots on any tap (no mode-toggle needed). Admins must explicitly activate "Add Spot" mode first.

### `RouteFeature.State`

```swift
var canCreateRoutes: Bool { userRole == .admin }
var canUndo: Bool { !routePoints.isEmpty && canCreateRoutes }
var canRedo: Bool { !undonePoints.isEmpty && canCreateRoutes }
```

### `AreaFeature.State`

```swift
var canCreateAreas: Bool { userRole == .admin }
```

### `StaffFeature.State`

```swift
var canManageStaff: Bool { userRole == .admin || userRole == .parkHead }
```

### `MissionsFeature.State`

```swift
var canCreateMissions: Bool { userRole == .admin || userRole == .parkHead }
// (accessed as a local in MissionsView)
```

### `ParkBlocksFeature.State`

```swift
var canEditParkBlocks: Bool { userRole == .parkHead }
```

---

## 7. Reducer-Level Enforcement (Action Gating)

Computed properties are not just for views — reducers `guard` on them before processing state mutations. This means even if a bug in the UI sent an action it shouldn't, the reducer would silently ignore it.

Examples:

```swift
// AreaFeature
case .toggleAreaMode:
    guard state.canCreateAreas else { return .none }
    ...

// RouteFeature
case .toggleRouteMode:
    guard state.canCreateRoutes else { return .none }
    ...

// ParkBlocksFeature
case .editBlock:
    // only processed if canEditParkBlocks is true (parkHead role)
```

In `MapFeature`, taps are routed role-sensitively:

```swift
case let .mapTapped(coordinate):
    // Rangers always add a spot on tap
    if state.userRole == .ranger {
        return .send(.spot(.selectLocation(coordinate)))
    }
    // Admins only act if a drawing mode is explicitly active
    switch (state.spotFeature.isAddingSpot,
            state.polygonFeature.isAddingPolygon,
            state.routeFeature.isAddingRoute) {
    case (true, _, _):
        return .send(.spot(.selectLocation(coordinate)))
    case (_, true, _) where state.canCreatePolygons:
        return .send(.polygon(.addPoint(coordinate)))
    case (_, _, true) where state.canCreateRoutes:
        return .send(.route(.startDrawing(coordinate)))
    default:
        return .none
    }
```

---

## 8. View-Level Gating (UI Elements)

### Map toolbar — `MapControlsView.swift`

```swift
// Admin gets drawing tools (polygon, route, area, spot pin)
if viewStore.userRole == .admin {
    adminCreationTools(viewStore: viewStore)
} else {
    rangerCreationTools(viewStore: viewStore)
}

// Drawing mode controls only shown for admin
if viewStore.userRole == .admin {
    drawingControls(viewStore: viewStore)
}
```

### Map overlays — `MapContentView.swift`

```swift
// Areas layer only rendered for admin
if viewStore.userRole == .admin && viewStore.areaFeature.showAreas {
    ForEach(viewStore.areaFeature.areas) { ... }
}

// Route dash style differs by role
.stroke(..., style: StrokeStyle(
    dash: viewStore.userRole == .admin ? [8, 4] : []
))
```

### Missions — `MissionsView.swift`

```swift
let canCreateMissions = viewStore.userRole == .admin
// "Add Mission" button is only rendered when canCreateMissions == true
```

### Auth screen — `AuthView.swift`

```swift
// Sign-up/Sign-in toggle only shown for admin and parksAuthority
if viewStore.canShowSignUp {
    Button("Need an account? Sign Up") { ... }
}
```

---

## 9. Summary Table — Role Capabilities

| Capability | `.admin` | `.parkHead` | `.ranger` | `.parksAuthority` |
|---|:---:|:---:|:---:|:---:|
| Full sidebar navigation | ✅ | ✅ | ❌ | ❌ |
| Create missions | ✅ | ✅ | ❌ | ❌ |
| Create accounts (sign up) | ✅ | ❌ | ❌ | ✅ |
| Add spots (any tap) | ❌ | ❌ | ✅ | ❌ |
| Add spots (mode toggle) | ✅ | ✅ | ❌ | ❌ |
| Attach photos/videos to spot | ❌ | ❌ | ✅ | ❌ |
| Draw hotspot polygons | ✅ | ❌ | ❌ | ❌ |
| Draw routes | ✅ | ❌ | ❌ | ❌ |
| Draw areas | ✅ | ❌ | ❌ | ❌ |
| Edit park blocks | ❌ | ✅ | ❌ | ❌ |
| Manage staff | ✅ | ✅ | ❌ | ❌ |
| Live GPS tracking | ❌ | ❌ | ✅ | ❌ |
| Park overview (Defend HQ) | ❌ | ❌ | ❌ | ✅ |
| Park management / settings | ✅ | ✅ | ❌ | ❌ |
| View all map layers | ✅ | ✅ | partial | ❌ |

---

## 10. Role Reset on Sign-Out

On sign-out, `AppFeature` resets all child feature states back to their defaults (which all default to `.admin` role). This prevents any role bleed-through between sessions:

```swift
case .signOutComplete:
    state.map      = MapFeature.State()       // defaults to .admin internally
    state.missions = MissionsFeature.State()
    state.staff    = StaffFeature.State()
    state.settings = SettingsFeature.State()
```

If the device has an assigned role, the app immediately re-enters `.authentication(selectedRole:)` for that device role — skipping role selection again.

---

## 11. How to Add a New Role-Gated Feature

1. **Add the case** to `AppFeature.UserRole` (and its `rawValue` must match the Supabase `staff.rank` value).
2. **Add `userRole: AppFeature.UserRole` to the feature's `State`** (if not already present).
3. **Add a computed `Bool` capability property** to `State` (e.g. `var canDoX: Bool { userRole == .newRole }`).
4. **Guard in the reducer**: `guard state.canDoX else { return .none }` at the top of relevant action cases.
5. **Conditionally render in Views**: `if viewStore.canDoX { ... }`.
6. **Propagate in `AppFeature.authenticationCompleted`**: add `state.newFeature.userRole = actualRole` and `.send(.newFeature(.setUserRole(actualRole)))`.
7. **Handle in `signOutComplete`**: reset the feature state: `state.newFeature = NewFeature.State()`.
