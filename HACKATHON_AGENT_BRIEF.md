# Ranger Intelligence Copilot — Hackathon Agent Brief
> PowerSync AI Hackathon · Submission deadline: 20 March 2026  
> This file is written for an LLM agent session to understand the full context, architecture, and implementation plan.

---

## 1. Project Overview

**What we're building:** An AI layer added to an existing wildlife conservation / anti-poaching iOS app called **e-parcs** (internal name: iranger). The AI features run entirely **on-device** with no connectivity required, using local SQLite data that is synchronized via PowerSync.

**Hackathon category:** Local-First & Offline-Capable AI Products

**Prize categories targeted:**
- Core prize (PowerSync + AI)
- Best Local-First Submission ($500)
- Best Submission Using Supabase ($1,000 credits)
- Best Submission Using Cactus (1 month compute) — via swift-cactus package

**Stack:**
- iOS app: **Swift + SwiftUI + The Composable Architecture (TCA)**
- Sync engine: **PowerSync** (Swift SDK, already integrated)
- Backend: **Supabase** (already integrated — Postgres + Auth + Storage)
- On-device AI: **swift-cactus** (community Swift package wrapping Cactus engine)
- Language: **Swift only** — no React Native, no web layer

---

## 2. Existing App Architecture

### 2.1 App Purpose
e-parcs is a field operations app for wildlife park rangers and park management. It operates in remote areas with unreliable connectivity. Core features:

- **Rangers** execute patrol missions on foot/vehicle, log incidents (poaching signs), track GPS paths
- **Admins / Park Heads** create missions, assign rangers, manage park blocks, view historical data
- **Parks Authority (Defend HQ)** monitors across multiple parks

### 2.2 User Roles
```swift
enum UserRole: String {
    case admin          // Manage everything
    case parkHead       // Manage park blocks, missions, staff
    case ranger         // Execute missions, log spots
    case parksAuthority // Read-only cross-park overview ("Defend HQ")
}
```

### 2.3 TCA Architecture Pattern
The app uses **The Composable Architecture (TCA)**. Every feature follows:
```
@Reducer struct XFeature {
    struct State: Equatable { ... }
    enum Action { ... }
    var body: some ReducerOf<Self> { ... }
}
```
Views use `WithViewStore(store, observe: { $0 }) { viewStore in ... }`.

Key features are scoped via `Scope(state:action:)` in parent reducers.

The `@Dependency(\.systemManager)` pattern provides `SystemManager` throughout the app.

### 2.4 PowerSync Integration (Already Working)
PowerSync is the core data synchronization layer. It maintains a local SQLite database that syncs bidirectionally with Supabase when connectivity is available.

**SystemManager** (`eparcs/Managers/SystemManager.swift`):
```swift
@Observable
@MainActor
final class SystemManager {
    let connector = SupabaseConnector()
    let db: PowerSyncDatabaseProtocol
    let attachments: AttachmentQueue?
    
    init() {
        db = PowerSyncDatabase(
            schema: AppSchema,
            dbFilename: "powersync-swift.sqlite"
        )
    }
    
    func connect() async {
        try await db.connect(
            connector: connector,
            options: ConnectOptions(...)
        )
        // Uses priority-based sync (see below)
        try await waitForCriticalDataSync()
        try await attachments?.startSync()
    }
}
```

**Priority-Based Sync** — data loads in order of importance:
```swift
enum SyncPriority {
    static let critical   = 0  // Park boundaries — load first
    static let essential  = 1  // Park blocks — load second  
    static let important  = 2  // Staff & missions — load third
    static let background = 3  // Map features (spots, routes) — background
}
// Usage:
try await db.waitForFirstSync(priority: Int32(SyncPriority.critical))
```

**SupabaseConnector** (`eparcs/Managers/SupabaseConnector.swift`):
- Implements `PowerSyncBackendConnectorProtocol`
- `fetchCredentials()` — gets JWT from Supabase auth, passes to PowerSync
- `uploadData()` — writes local mutations back to Supabase (`upsert/update/delete`)
- Handles fatal Postgres error codes (22xxx, 23xxx, 42501, PGRST204) by discarding rather than blocking

**Querying the local database:**
```swift
// Watch (reactive, streams updates)
try db.watch(options: WatchOptions(sql: "SELECT * FROM spots WHERE mission_id = ?", parameters: [missionId])) { cursor in
    // map cursor to model
}

// One-shot fetch
let rows = try await db.getAll(sql: "SELECT * FROM missions WHERE status = 'current'", parameters: [])
```

**Writing to local database (syncs automatically):**
```swift
try await db.execute(
    "INSERT INTO map_features (id, name, description, ...) VALUES (?, ?, ?, ...)",
    parameters: [id, name, description, ...]
)
```

### 2.5 PowerSync Schema (`eparcs/Managers/Schema.swift`)
All columns are `text`, `real`, or `integer` — SQLite types. IDs are text UUIDs. Dates are text ISO8601 strings. Complex types (coordinates, arrays) are JSON-encoded text.

Key tables for the AI features:

```swift
// Spots/incidents logged by rangers during missions
let map_features = Table(name: "map_features", columns: [
    .text("name"),              // spot type display name
    .text("description"),       // ranger's free-text notes
    .text("geometry"),          // JSON: {type, coordinates}
    .text("created_by"),        // staff UUID
    .text("created_at"),        // ISO8601
    .text("media_url"),         // JSON array of attachment IDs
    .text("mission_id"),        // link to mission
    .text("captured_by_staff_id"),
    .text("spot_type_id")       // FK to spot_types
])

// Patrol missions
let missions = Table(name: "missions", columns: [
    .text("name"),
    .text("objectives"),
    .text("start_date"),
    .text("end_date"),
    .text("patrol_type"),       // "Fence/Boundary", "Local", "Mobile", etc.
    .text("status"),            // "current", "future", "past"
    .text("mission_state"),     // "not_started", "active", "paused"
    .text("staff_ids"),         // JSON array of UUIDs
    .text("leader_id"),
    .text("selected_block_ids") // JSON array of park block UUIDs
])

// Park patrol zones
let park_blocks = Table(name: "park_blocks", columns: [
    .text("block_name"),
    .text("coordinates"),       // JSON: [[lon,lat],...]
    .real("threshold"),         // % of block that must be patrolled
    .real("visibility"),        // ranger visibility radius (meters)
    .real("rate_of_decay"),     // days for block health to decay
    .text("last_patrolled")     // ISO8601
])

// Rangers and staff
let staff = Table(name: "staff", columns: [
    .text("email"),
    .text("first_name"),
    .text("last_name"),
    .text("rank"),              // "ranger", "supervisor", "park_head", "admin"
    .text("user_id")            // Supabase Auth UUID
])

// Configurable incident categories
let spot_types = Table(name: "spot_types", columns: [
    .text("code_name"),         // e.g. "snare", "carcass", "poison"
    .text("display_name"),
    .text("color_hex"),
    .integer("is_active"),
    .integer("sort_order")
])

// GPS tracks per mission
let mission_track = Table(name: "mission_track", columns: [
    .text("mission_id"),
    .text("path_geometry"),         // GeoJSON FeatureCollection with vehicle/foot segments
    .text("coverage_geometry"),     // GeoJSON Polygon/MultiPolygon — area covered
    .real("distance_traveled_km"),
    .text("created_at")
])

// Scoring per mission
let mission_scores = Table(name: "mission_scores", columns: [
    .text("mission_id"),
    .real("distance_traveled_km"),
    .real("buffer_points"),
    .integer("mission_completed"), // 0 or 1
    .text("completed_at")
])
```

Full schema registered as:
```swift
let AppSchema = Schema(
    staff, map_features, missions, mission_role_types, staff_mission,
    map_features_missions, mission_scores, park_blocks, park_boundaries,
    mission_track, terrains, filter_presets, spot_types,
    createAttachmentTable(name: "attachments")
)
```

### 2.6 Key Data Models

```swift
// Incident/spot logged in field
struct Spot: Identifiable, Codable {
    let id: UUID
    let name: String        // spot type label
    let description: String // ranger's notes
    let latitude: Double
    let longitude: Double
    let mediaURLs: [String]
    let createdAt: Date
    let missionId: UUID?
}

// Spot categories (from spot_types table)
enum SpotType: String, CaseIterable {
    case snare, ditchTrap, poacherCamp, spentCartridge, arrest,
         carcass, poison, charcoalKiln, loggingSite, injuredAnimal,
         trackFootprint, vandalizedFence
}

// Patrol mission
struct Mission: Identifiable, Codable {
    let id: UUID
    let name: String
    let objectives: String
    let startDate: Date
    let endDate: Date
    let patrolType: String
    let staffIds: [UUID]
    let leaderId: UUID
    let status: MissionStatus?         // current/future/past
    let missionState: MissionState     // notStarted/active/paused
}

// Park patrol zone
struct ParkBlock: Identifiable, Codable {
    let id: UUID
    let blockName: String
    let coordinates: [CLLocationCoordinate2D]
    let threshold: Double
    let visibility: Double
    let rateOfDecay: Double
    let lastPatrolled: Date?
}
```

### 2.7 Secrets Pattern
Credentials live in `eparcs/Managers/_Secrets.swift` (gitignored):
```swift
enum Secrets {
    static let supabaseURL = URL(string: "https://xxx.supabase.co")!
    static let supabaseAnonKey = "eyJ..."
    static let powerSyncEndpoint = "https://xxx.powersync.journeyapps.com"
    static let supabaseStorageBucket: String? = "eparcs-attachments"
}
```

---

## 3. AI Features to Build

Three focused features. All work offline. All use PowerSync local SQLite as data source.

### Feature 1: Voice Incident Logging
**Who:** Rangers during patrol  
**What:** Ranger speaks a description → Cactus Whisper transcribes → LLM with tool calling parses into structured spot record → writes to local SQLite → PowerSync syncs when back in range

**Flow:**
```
Ranger taps mic → AVAudioEngine captures PCM → CactusSTTSession (Whisper Small, NPU) 
→ transcription text → CactusAgentSession with LogIncidentTool 
→ tool call: INSERT into map_features → PowerSync syncs to Supabase
```

### Feature 2: Natural Language Patrol Query
**Who:** Rangers (simple queries) + Park Heads (complex analysis)  
**What:** Ask questions in plain language, answered from local SQLite via function calling. Works fully offline.

Example queries:
- *"How many snares were found in Block 7 this week?"*
- *"Which ranger has logged the most incidents this month?"*
- *"What's the patrol status of the eastern boundary blocks?"*

**Flow:**
```
User types/speaks question → CactusAgentSession + 3-5 CactusFunction tools
→ model picks tool + arguments → Swift executes SQL on db → returns to model
→ natural language answer shown in chat UI
```

### Feature 3: Pre-Patrol AI Briefing
**Who:** Rangers before mission starts  
**What:** Tapping "Get AI Briefing" generates a natural language mission briefing from local data — requires zero connectivity.

Content of briefing:
- Recent incidents in assigned blocks (last 14 days)
- Which blocks haven't been patrolled recently (based on `last_patrolled`)
- Objectives reminder from mission data
- Highest-risk areas based on incident density

**Flow:**
```
Ranger opens mission → taps "AI Briefing" → app queries local SQLite for relevant data
→ constructs prompt with data → CactusAgentSession generates briefing
→ displayed as formatted text (can be read offline)
```

---

## 4. swift-cactus Integration

### 4.1 Package
Add to Xcode project via SPM:
```
https://github.com/mhayes853/swift-cactus  (from: "2.0.0")
```
Product: `Cactus`

### 4.2 Key Classes

**CactusAgentSession** — the LLM with optional function calling:
```swift
import Cactus

let modelURL = try await CactusModelsDirectory.shared.modelURL(
    for: .lfm2_5_1_2bThinking()  // ~1.2B param thinking model
)

let session = try CactusAgentSession(from: modelURL, functions: [myTools...]) {
    "You are a wildlife ranger intelligence assistant. Only answer based on provided patrol data."
}

let message = CactusUserMessage { "How many incidents last week in Block 4?" }
let completion = try await session.respond(to: message)
print(completion.output)
```

**CactusSTTSession** — speech to text (Whisper):
```swift
let whisperURL = try await CactusModelsDirectory.shared.modelURL(
    for: .whisperSmall()  // or .moonshineBase() for faster, lighter
)

let sttSession = try CactusSTTSession(from: whisperURL)

// From AVAudioPCMBuffer (microphone)
let request = CactusTranscription.Request(
    prompt: .whipser(language: .english, includeTimestamps: false),
    content: try .pcm(avAudioPCMBuffer)
)
let transcription = try await sttSession.transcribe(request: request)
print(transcription.content)
```

**Live transcription** (streaming from microphone):
```swift
let stream = try CactusTranscriptionStream(from: whisperURL)

let recordingTask = Task {
    for try await chunk in stream {
        print("Partial:", chunk)  // update UI in real-time
    }
}

// feed AVAudioPCMBuffer chunks as they arrive from AVAudioEngine
try await stream.process(buffer: audioChunk)
// ...
try await stream.finish()
```

**CactusVADSession** — voice activity detection (strips silence before transcription):
```swift
let vadURL = try await CactusModelsDirectory.shared.modelURL(for: .sileroVad())
let vadSession = try CactusVADSession(from: vadURL)

let vad = try await vadSession.vad(request: .init(content: try .pcm(audioBuffer)))
// vad.segments = [{start, end}, ...] — only the speech portions
```

**NPU Acceleration** (Apple Neural Engine):
```swift
// Add pro: .apple for NPU-accelerated models
let modelURL = try await CactusModelsDirectory.shared.modelURL(
    for: .whisperSmall(pro: .apple)   // NPU-accelerated Whisper
)
let lmURL = try await CactusModelsDirectory.shared.modelURL(
    for: .lfm2Vl_450m(pro: .apple)   // NPU-accelerated LLM
)
```

**CactusFunction** — tool/function calling:
```swift
struct QueryRecentIncidents: CactusFunction {
    @JSONSchema
    struct Input: Codable, Sendable {
        @JSONSchemaProperty(description: "Park block name to search in")
        let blockName: String
        @JSONSchemaProperty(description: "Number of days back to look")
        let daysBack: Int
        @JSONSchemaProperty(description: "Incident type filter, e.g. snare, carcass. Empty for all.")
        let incidentType: String
    }
    
    let name = "query_recent_incidents"
    let description = "Get recent poaching incidents from a specific park block."
    
    // systemManager injected at init time
    let systemManager: SystemManager
    
    func invoke(input: Input) async throws -> sending String {
        let sql = """
            SELECT mf.name, mf.description, mf.created_at, s.first_name, s.last_name
            FROM map_features mf
            LEFT JOIN staff s ON s.id = mf.captured_by_staff_id
            JOIN park_blocks pb ON pb.block_name = ?
            WHERE mf.created_at >= datetime('now', '-\(input.daysBack) days')
            \(input.incidentType.isEmpty ? "" : "AND mf.name LIKE '%\(input.incidentType)%'")
            ORDER BY mf.created_at DESC
            LIMIT 20
            """
        let rows = try await systemManager.db.getAll(sql: sql, parameters: [input.blockName])
        if rows.isEmpty { return "No incidents found in \(input.blockName) in the last \(input.daysBack) days." }
        return rows.map { row in
            "\(row["name"] ?? "Unknown") — \(row["description"] ?? "")"
        }.joined(separator: "\n")
    }
}
```

**Hybrid inference** (optional — cloud fallback when offline not sufficient):
```swift
// Set once at app launch (optional, only for cloud handoff)
Cactus.cactusCloudAPIKey = Secrets.cactusCloudKey  // nil = fully offline only
```

**Observable conformance** — `CactusAgentSession` conforms to `Observable`, so in SwiftUI:
```swift
struct RangerCopilotView: View {
    @State var session: CactusAgentSession
    
    var body: some View {
        VStack {
            ForEach(session.transcript) { entry in
                Text(entry.message.content)
            }
            if session.isResponding {
                ProgressView()
            }
        }
    }
}
```

**Model download** — happens once, stored in app container:
```swift
// Show download progress to user
let downloadTask = try await CactusModelsDirectory.shared.downloadTask(for: .whisperSmall())
downloadTask.onProgress = { progress in
    // update UI: "Downloading AI model: 42%"
    print(progress)
}
// modelURL only downloads if model not already present
let modelURL = try await CactusModelsDirectory.shared.modelURL(for: .whisperSmall())
```

---

## 5. Recommended TCA Feature Structure for AI Layer

Add a new feature `RangerCopilotFeature` and integrate it into the existing `MissionFeature`.

### 5.1 New Feature File: `RangerCopilotFeature.swift`

```swift
import ComposableArchitecture
import Cactus

@Reducer
struct RangerCopilotFeature: Reducer {
    @Dependency(\.systemManager) var systemManager
    
    struct State: Equatable {
        var isModelLoaded = false
        var isDownloadingModel = false
        var modelDownloadProgress: Double = 0.0
        var downloadError: String?
        
        // Chat interface
        var messages: [ChatMessage] = []
        var inputText = ""
        var isResponding = false
        
        // Voice input
        var isRecording = false
        var transcriptionPreview = ""  // partial transcription shown while recording
        var voiceError: String?
        
        // Current mission context (set from parent MissionFeature)
        var currentMissionId: UUID?
        var currentMissionName: String = ""
    }
    
    enum Action {
        case onAppear
        case loadModel
        case modelLoaded
        case modelDownloadProgress(Double)
        case modelLoadFailed(String)
        
        // Chat
        case updateInputText(String)
        case sendMessage
        case receivedResponse(String)
        case clearChat
        
        // Voice
        case startRecording
        case stopRecording
        case receivedTranscription(String)
        case transcriptionPreviewUpdated(String)
        case voiceError(String)
        
        // Briefing
        case generateBriefing
        case briefingGenerated(String)
        
        // Mission context
        case setMissionContext(id: UUID, name: String)
    }
    
    var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .loadModel:
                state.isDownloadingModel = true
                return .run { send in
                    // Download/load models — happens once, cached
                    _ = try await CactusModelsDirectory.shared.modelURL(for: .lfm2_5_1_2bThinking())
                    _ = try await CactusModelsDirectory.shared.modelURL(for: .whisperSmall(pro: .apple))
                    await send(.modelLoaded)
                }
            // ... other cases
            }
        }
    }
}
```

### 5.2 Integration into MissionFeature.State
Add to the existing `MissionFeature.State`:
```swift
// In MissionFeature.State
var copilot: RangerCopilotFeature.State = .init()
var showingCopilot = false
```

Add to `MissionFeature.Action`:
```swift
case copilot(RangerCopilotFeature.Action)
case toggleCopilot
```

Add to `MissionFeature` body:
```swift
Scope(state: \.copilot, action: /Action.copilot) {
    RangerCopilotFeature()
}
```

### 5.3 Recommended Function Tools (3-5 max per session)

1. **`query_recent_incidents`** — query `map_features` by block/type/date
2. **`get_block_patrol_status`** — query `park_blocks` for `last_patrolled`, threshold, health
3. **`get_mission_summary`** — query `missions` + `mission_scores` for current mission stats
4. **`log_incident`** — INSERT into `map_features` (called by voice logging flow)
5. **`get_ranger_stats`** — query `map_features` grouped by `captured_by_staff_id` for leaderboard

---

## 6. UI Components to Build

### 6.1 Copilot Chat Sheet
A `.sheet` overlay on the ranger's active mission view:
- Chat bubbles (user messages + AI responses)
- Mic button for voice input with waveform animation while recording
- Partial transcription preview while recording
- "Generate Briefing" button
- Model download progress (first run only)

### 6.2 AI Briefing Card
A dismissable card shown before mission starts:
- Bullet-pointed pre-patrol briefing text
- "Generated from local data — no internet required" badge
- Regenerate button

### 6.3 Voice Logging Indicator
Overlay on the map during patrol:
- Microphone button (hold to speak)
- Shows transcription preview
- Confirms "Incident logged" with spot type when tool call completes

---

## 7. PowerSync Sync Streams Configuration

PowerSync uses **Sync Streams** (configured in the PowerSync dashboard) to control what data syncs to each device. Relevant rules for this project:

```javascript
// In PowerSync dashboard — rangers only see their assigned missions
// Park heads see all missions for their park
// The existing app already has these configured
```

The AI features use the **same local SQLite that PowerSync already populates** — no additional sync configuration needed. The AI reads from tables already synced by the existing rules.

---

## 8. Implementation Order (10-day sprint)

### Days 1-2: Foundation
- [ ] Add `swift-cactus` package to Xcode project
- [ ] Create `AIManager` or extend `SystemManager` with model loading logic
- [ ] Implement `CactusModelsDirectory` download flow with progress UI
- [ ] Define all `CactusFunction` tools (query_recent_incidents, get_block_patrol_status, log_incident)
- [ ] Test function calling against local PowerSync SQLite in isolation

### Days 3-4: Natural Language Query
- [ ] Build `RangerCopilotFeature` TCA reducer (chat state + actions)
- [ ] Build `CopilotChatView` SwiftUI view integrated into existing mission view
- [ ] Wire `CactusAgentSession` with tools into the feature
- [ ] Test with real data from local SQLite

### Days 5-6: Voice Logging
- [ ] Implement `AVAudioEngine` microphone capture (PCM buffer stream)
- [ ] Wire `CactusSTTSession` (Whisper Small, NPU) for transcription
- [ ] Add `CactusVADSession` to pre-filter silence before transcription
- [ ] Connect transcription → agent session → `log_incident` tool call
- [ ] Build voice recording UI overlay

### Days 7-8: Pre-Patrol Briefing
- [ ] Build SQL queries for briefing data (recent incidents, block health, objectives)
- [ ] Create prompt template that injects SQL query results
- [ ] Build `AIBriefingView` — displayed before mission start
- [ ] Add "Generate Briefing" to mission preparation flow

### Days 9-10: Polish + Demo
- [ ] Graceful fallback when models aren't downloaded yet
- [ ] Offline-first status indicator (show "AI running on device" badge)
- [ ] Demo video recording — show: offline mode ON → voice log incident → AI query → briefing
- [ ] Submission form

---

## 9. Critical Implementation Notes

### PowerSync DB Access Pattern
Always go through `systemManager.db`. The `@Dependency(\.systemManager)` is already wired throughout the app:
```swift
// In any TCA Reducer effect:
return .run { send in
    let rows = try await systemManager.db.getAll(
        sql: "SELECT * FROM map_features WHERE mission_id = ? ORDER BY created_at DESC",
        parameters: [missionId.uuidString]
    )
    // map rows to model...
}
```

### Thread Safety — SystemManager is @MainActor
`SystemManager` is annotated `@MainActor`. All database calls must be awaited properly. In TCA `.run` closures this is handled automatically.

### UUID Handling
All IDs are stored as lowercase UUID strings in SQLite. Use `.uuidString` when inserting and `UUID(uuidString: str)` when reading.

### Date Handling
Dates stored as ISO8601 strings. The existing `SystemManager.parseDate()` handles multiple format variants. Use `ISO8601DateFormatter().string(from: date)` when inserting.

### Model Context Window
Keep AI session prompts concise. Each tool call adds to the context. Apple's guidance (applies conceptually to Cactus too): limit to 3-5 tools per session, use short `@JSONSchemaProperty` descriptions. If context fills, create a new `CactusAgentSession`.

### Model Size Recommendations
- **For text queries/briefings:** `lfm2_5_1_2bThinking` (~1.2B) — good balance, thinking mode helps structured reasoning
- **For voice transcription:** `whisperSmall(pro: .apple)` — NPU-accelerated, fast, accurate enough for field English
- **Smaller/faster alternative:** `qwen3_0_6b` for queries + `moonshineBase` for transcription
- Models download once to the app's Application Support directory via `CactusModelsDirectory`

### Permissions Required
- Microphone access: add `NSMicrophoneUsageDescription` to `Info.plist`
- Speech (if using `SpeechAnalyzer` instead): `NSSpeechRecognitionUsageDescription`

### Avoiding Battery Drain
- Load models once, reuse session handles — don't reinit per request
- Call `await session.destroy()` / model `.close()` only when leaving the copilot entirely
- VAD runs before transcription to avoid processing silence

---

## 10. Supabase Role for Hackathon

The app already uses Supabase for:
- **Auth** — Supabase Auth, JWT passed to PowerSync connector
- **Storage** — Incident media (photos, videos) via AttachmentQueue
- **Database** — Postgres with PowerSync sync rules

For the hackathon, the Supabase bonus is already covered by the existing backend. No new Supabase features are required unless you want to add:
- A Supabase Edge Function that receives AI-generated incident summaries after sync and sends push notifications to Park Heads
- A Supabase pgvector table to store embeddings for hybrid RAG (advanced/optional)

---

## 11. Demo Script (for video submission)

1. **Show connectivity OFF** — airplane mode on, demonstrate app still works
2. **Open active mission** (pre-loaded data via PowerSync)
3. **Tap AI Briefing** — briefing generates offline from local data, reads: *"Block 7 has had 3 snare incidents in the past 14 days — above average. Block 3 hasn't been patrolled in 12 days."*
4. **Tap mic, speak:** *"Found a wire snare near the eastern water pan, looks like it's been here about a week"*
5. **Show transcription** → model parses → spot appears on map as a logged incident
6. **Type query:** *"How many incidents this month in Block 7?"* → AI answers from local SQLite
7. **Turn connectivity ON** → show PowerSync syncing the voice-logged incident to Supabase dashboard

---

## 12. File Locations in Codebase

```
eparcs/
├── Managers/
│   ├── SystemManager.swift        ← PowerSync DB, connect(), fetch methods, @MainActor
│   ├── SupabaseConnector.swift    ← fetchCredentials(), uploadData(), Supabase client
│   ├── Schema.swift               ← AppSchema (all PowerSync tables)
│   └── _Secrets.swift             ← Credentials (gitignored)
├── Features/
│   ├── AppFeature.swift           ← Root feature, UserRole, SidebarTab, app state machine
│   ├── MissionFeature.swift       ← Active ranger mission (GPS, spots, scoring)
│   ├── MissionsFeature.swift      ← Mission list, creation, past missions
│   ├── MapFeature.swift           ← Admin map with all layers
│   ├── SpotFeature.swift          ← Spot/incident management
│   ├── StaffFeature.swift         ← Staff management
│   ├── ParkBlocksFeature.swift    ← Park block management
│   ├── AuthFeature.swift          ← Authentication
│   └── [NEW] RangerCopilotFeature.swift  ← Add here
├── Store Structs/
│   ├── Mission.swift              ← Mission, MissionScore, RoutePoint models
│   ├── Spot.swift                 ← Spot model
│   ├── Staff.swift                ← Staff model
│   ├── ParkBlock.swift            ← ParkBlock model
│   └── SpotType.swift             ← SpotType enum (snare, carcass, etc.)
└── Views/
    ├── Ranger/
    │   ├── ActiveMissionView.swift     ← Main ranger mission UI — integrate copilot here
    │   ├── AddSpotView.swift           ← Manual spot logging (copilot voice logging complements this)
    │   └── [NEW] CopilotChatView.swift ← Add here
    └── Admin/
        └── DashboardView.swift         ← Admin overview
```

---

## 13. External Resources

- **PowerSync Swift SDK:** https://github.com/powersync-ja/powersync-swift
- **PowerSync + Supabase guide:** https://docs.powersync.com/integration-guides/supabase
- **PowerSync Sync Streams docs:** https://docs.powersync.com/sync/streams/overview
- **swift-cactus package:** https://github.com/mhayes853/swift-cactus
- **Cactus engine docs:** https://www.cactuscompute.com/docs/v1.7
- **Cactus hybrid AI:** https://www.cactuscompute.com/docs/v1.7/hybrid-ai
- **Hackathon page:** https://www.powersync.com/blog/powersync-ai-hackathon-8k-in-prizes
- **Hackathon registration:** https://form.typeform.com/to/zzswESaj
- **PowerSync Discord #ai-hackathon:** https://discord.gg/powersync
