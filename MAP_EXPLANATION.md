# e-Parcs: Map Architecture Explanation

This document explains two core behaviours in the e-Parcs app:

1. How the admin map is centred on the park when the app opens
2. How MapKit / Apple Maps is integrated and used throughout the app

---

## 1. How the Admin Map is Centred on the Park

### The short answer

The map camera does **not** dynamically compute a region from the park boundary polygon after it loads. Instead, the initial camera position is **hardcoded** to a coordinate that approximates the park's physical location. The park boundary polygon is then loaded from the local PowerSync database and rendered as a visual overlay on top of that fixed starting position.

### Step-by-step walkthrough

#### Step 1 — Default camera position is set in `MapFeature.State`

`eparcs/Features/MapFeature.swift`

```swift
var camera: MapCameraPosition = .region(MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: -17.75, longitude: 27.85),
    span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
))
```

`(-17.75, 27.85)` is Chizarira National Park, Zimbabwe. A `latitudeDelta` / `longitudeDelta` of `0.5` means roughly 50 km of visible area — wide enough to show the full park.

There is also a matching constant in `BaseMapView.swift`:

```swift
struct MapConstants {
    static let defaultCenter  = CLLocationCoordinate2D(latitude: -17.75, longitude: 27.85)
    static let defaultSpan    = MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
}
```

Both places use the same numbers, so the default view always opens on the park.

#### Step 2 — On `.onAppear` the park boundary is fetched with the highest sync priority

`eparcs/Features/MapFeature.swift` — `case .onAppear:` in the reducer

```swift
return .merge(
    // Priority 0: Park boundary (critical) - loads first
    .send(.parkBoundary(.onAppear)),
    // Priority 1: Park blocks (essential) - loads second
    .send(.parkBlocks(.onAppear)),
    // Priority 3: Map features (background) - load after 0.5 s delay
    .run { send in
        try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 s
        await send(.spot(.fetchSpots))
        await send(.polygon(.fetchPolygons))
        await send(.route(.fetchRoutes))
    }
)
```

`ParkBoundaryFeature` calls `systemManager.fetchParkBoundary()`, which queries the local PowerSync SQLite database (`SELECT * FROM park_boundaries LIMIT 1`). PowerSync waits for **SyncPriority 0** to complete before returning data, meaning the boundary is guaranteed to be synced first. This is defined in `Schema.swift` / `SystemManager.swift`:

```swift
enum SyncPriority {
    static let critical   = 0   // Park boundaries — must load first
    static let essential  = 1   // Park blocks — load second
    static let important  = 2   // Staff & missions
    static let background = 3   // Spots, routes, polygons
}
```

#### Step 3 — The boundary is rendered as a `MapPolygon` overlay

`eparcs/Views/Admin/MapContentView.swift`

```swift
// MARK: - Park Boundary (Always visible)
if let parkBoundary = viewStore.parkBoundaryFeature.parkBoundary {
    MapPolygon(coordinates: parkBoundary.coordinateArray)
        .stroke(Color.white, lineWidth: 1)
        .foregroundStyle(Color.gray.opacity(0.1))
}
```

`ParkBoundary.coordinateArray` converts the stored MultiPolygon JSON (`[[[[Double]]]]`) into `[CLLocationCoordinate2D]` by mapping `[lng, lat]` pairs (GeoJSON order) to `CLLocationCoordinate2D(latitude: coord[1], longitude: coord[0])`.

#### Step 4 — Camera stays at the hardcoded position; it is never re-centred to the boundary

There is **no code that reads the boundary's geographic extent and calls something like `MKMapRect.union` or resets `state.camera`**. Once the polygon is drawn the user can freely pan/zoom with standard MapKit gestures (`interactionModes: [.pan, .zoom]`).

If you ever want automatic centering you would:
1. Add a computed property to `ParkBoundary` that returns `MKCoordinateRegion` (from the min/max lat and lng of `coordinateArray`).
2. In the `MapFeature` reducer, handle `.parkBoundary(.parkBoundaryFetched)` and call `.send(.updateCameraPosition(.region(boundary.region)))`.

### `ParkBoundary` data model

```
ParkBoundary (Store Structs/ParkBoundary.swift)
├── id: UUID
├── parkName: String          // e.g. "Chizarira National Park"
├── country: String
├── coordinates: [[[[Double]]]]  // GeoJSON MultiPolygon — [polygon][ring][point][lng, lat]
├── coordinateArray: [CLLocationCoordinate2D]  // flat array for MapPolygon rendering
└── containsCoordinate(_:) -> Bool  // ray-casting point-in-polygon test
```

---

## 2. How MapKit / Apple Maps Is Integrated

### Framework import

Every file that renders a map or processes map coordinates imports the Apple MapKit framework:

```swift
import MapKit
```

There is **no third-party map library**. The app uses the modern SwiftUI `Map` API introduced in iOS 17 / macOS 14.

---

### The `Map` view

`eparcs/Views/Admin/MapContentView.swift` — `makeMapContent(proxy:viewStore:)`

```swift
Map(position: viewStore.binding(
        get: \.camera,
        send: { position in .updateCameraPosition(position) }
    ),
    interactionModes: [.pan, .zoom]
) {
    // ... map content (annotations, polygons, polylines) ...
}
.mapStyle(viewStore.mapStyle)
.onMapCameraChange { context in
    viewStore.send(.updateCameraPosition(.camera(context.camera)))
}
```

Key points:

| API | Purpose |
|---|---|
| `Map(position:interactionModes:)` | Renders the map and exposes a two-way `Binding<MapCameraPosition>` |
| `.mapStyle(_:)` | Switches tile style: `.standard`, `.imagery` (satellite), `.hybrid` |
| `.onMapCameraChange` | Fires whenever the user pans/zooms; the new `MapCamera` is sent back into TCA state |
| `MapReader { proxy in }` | Wraps the map to make coordinate conversion available (see below) |

---

### Camera management

The camera is stored as a `MapCameraPosition` value inside `MapFeature.State`:

```swift
var camera: MapCameraPosition = .region(MKCoordinateRegion(
    center: CLLocationCoordinate2D(latitude: -17.75, longitude: 27.85),
    span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
))
```

`MapCameraPosition` can be:
- `.region(MKCoordinateRegion)` — used as the initial value
- `.camera(MapCamera)` — used after any user interaction (set by `.onMapCameraChange`)

The zoom level is also tracked separately (used only for display, not for camera driving):

```swift
case .updateCameraPosition(let position):
    state.camera = position
    if let region = position.region {
        state.zoomLevel = region.span.latitudeDelta
    }
```

---

### Map styles

`MapStyleType` is a custom enum defined in `MapFeature.swift` to keep state `Equatable` (MapKit's `MapStyle` is not):

```swift
enum MapStyleType: Equatable {
    case standard   // → MapStyle.standard
    case satellite  // → MapStyle.imagery
    case hybrid     // → MapStyle.hybrid
}
```

`MapFeature.State` has a computed property that converts it:

```swift
var mapStyle: MapStyle {
    switch mapStyleType {
    case .standard:  return .standard
    case .satellite: return .imagery
    case .hybrid:    return .hybrid
    }
}
```

Cycling through styles is triggered by a toolbar button dispatching `.toggleMapType`.

---

### Drawing on the map

All drawing interaction uses `MapReader` and `MapProxy`:

```swift
MapReader { proxy in
    Map(...) { ... }
        .onTapGesture { location in
            // location is a CGPoint in local (view) coordinates
            if let coordinate = proxy.convert(location, from: .local) {
                viewStore.send(.mapTapped(coordinate))
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: MapUtilities.minimumDragDistance)
                .onChanged { value in
                    if let coordinate = proxy.convert(value.location, from: .local) {
                        // dispatch drawing update
                    }
                }
        )
}
```

`MapProxy.convert(_:from:)` does the screen-space → geographic coordinate conversion. Drawing is throttled at **50 ms** (20 updates/second) via `DrawingThrottle` to avoid overloading the TCA state update loop.

---

### Map content (annotations and overlays)

All content is declared inside the `Map { }` closure using MapKit's native types:

| Type | Used for |
|---|---|
| `MapPolygon` | Park boundary, park blocks, hotspots (polygons), areas, in-progress polygon drawing |
| `MapPolyline` | Patrol routes, path/track recordings, in-progress route drawing |
| `Annotation` | Custom icon spots (snare, carcass, arrest, etc. — `Image` + `renderingMode(.template)`) |
| `Marker` | Default red pin for a freshly tapped "selected location" |
| `UserAnnotation()` | The ranger's live GPS position (ranger role only) |

Example spot annotation:

```swift
Annotation(
    spot.name,
    coordinate: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude),
    anchor: .bottom
) {
    Image(spot.imageName)               // e.g. "snare", "carcass"
        .resizable()
        .renderingMode(.template)       // coloured via .foregroundColor
        .foregroundColor(spot.color)
        .frame(width: 30, height: 30)
}
```

---

### GPS / user location

`LocationManager` wraps Apple's `CLLocationManager`:

```swift
@StateObject private var locationManager = LocationManager()
```

- Permission is requested only when the authenticated user is a **ranger** (`viewStore.hasLocationTracking`).
- The ranger's position is shown with the standard `UserAnnotation()` widget.
- Admins do not request location permission or show the user dot.

---

### Role-based map behaviour

| Feature | Admin | Park Head | Ranger |
|---|---|---|---|
| Can draw polygons (hotspots) | ✅ | ❌ | ❌ |
| Can draw routes | ✅ | ❌ | ❌ |
| Can draw areas | ✅ | ❌ | ❌ |
| Can add spots on tap | only if `isAddingSpot = true` | only if `isAddingSpot = true` | always on tap |
| User location shown | ❌ | ❌ | ✅ |
| Admin creation toolbar | ✅ | ❌ | ❌ |

---

### Supporting utilities

| File | Role |
|---|---|
| `BaseMapView.swift` | View extensions (`mapViewFullScreen()`, `roleBasedMapStyling()`), `MapConstants` (colours, default region, drawing constants) |
| `SharedMapComponents.swift` | `MapUtilities` (throttle constants, coordinate conversion helpers), `DrawingThrottle` (per-gesture update throttling), `MapInteractionModeHelper` |
| `MapControlsView.swift` | Floating toolbar over the map — drawing mode toggles, layer toggles, map style toggle, PDF export |
| `TerrainDrawingMapView.swift` | Standalone map used inside the Park Setup Wizard for uploading terrain/block GeoJSON |
