# Askari AI — Ranger Intelligence Copilot

> PowerSync AI Hackathon 2026 · Local-First & Offline-Capable AI

An on-device AI assistant for wildlife park rangers. All AI inference runs locally using **swift-cactus** — no connectivity required. Data syncs to Supabase via **PowerSync** when back in range.

---

## Features

| Feature | Stack |
|---------|-------|
| Natural language patrol queries | Pure Swift NL parser + CactusFunction SQL tools |
| Voice incident note dictation (STT) | AVAudioRecorder + CactusSTTSession (Whisper Small) |
| Pre-patrol AI briefing | CactusAgentSession + local SQLite |
| Offline-first sync | PowerSync Sync Streams → Supabase |
| Reactive UI | SwiftUI + The Composable Architecture |

---

## Project Structure

```
AskariAI/
├── App/                    # App entry point, root navigation
├── Managers/               # SystemManager, SupabaseConnector, Schema
│   ├── Schema.swift        # PowerSync local SQLite schema
│   ├── SystemManager.swift # PowerSync database + sync stream subscriptions + TCA dependency
│   ├── SupabaseConnector.swift
│   └── _Secrets.swift      # ← gitignored, copy from template
├── Features/               # TCA Reducers + Views (co-located)
│   ├── App/                # AppFeature, MainFeature
│   ├── Auth/               # AuthFeature
│   ├── Missions/           # MissionsFeature
│   ├── ActiveMission/      # ActiveMissionFeature (GPS tracking)
│   ├── Dashboard/          # DashboardFeature (AI query + intel overview)
│   └── Incidents/          # LogIncidentFeature (voice dictation + media)
├── Models/                 # Codable data models
├── Views/                  # SwiftUI views
│   └── Copilot/            # CopilotChatView, AIBriefingView
└── AI/
    ├── AIManager.swift     # CactusAgentSession / STT / VAD lifecycle
    └── Tools/
        └── CactusTools.swift  # CactusFunction implementations

supabase/
└── migrations/
    ├── 001_initial_schema.sql   # Applied ✓
    └── 002_rls_policies.sql     # RLS policies

powersync/
└── sync-config.yaml  # Sync Streams config (edition 3)
```

---

## Setup

### 1. Swift Package Dependencies (Xcode SPM)

| Package | URL | Version |
|---------|-----|---------|
| PowerSync Swift SDK | `https://github.com/powersync-ja/powersync-swift` | `1.13.0` |
| Supabase Swift | `https://github.com/supabase/supabase-swift` | `>= 2.0.0` |
| TCA | `https://github.com/pointfreeco/swift-composable-architecture` | `>= 1.0.0` |
| swift-cactus | `https://github.com/nicholasnlawson/swift-cactus` | `2.1.1` |

### 2. Secrets

Copy `_Secrets.template.swift` to `AskariAI/Managers/_Secrets.swift` and fill in:
- `supabaseURL`
- `supabaseAnonKey`
- `powerSyncEndpoint`
- `supabaseStorageBucket` (optional — disables media attachments if absent)

### 3. Info.plist Permissions

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Used for voice incident logging in the field</string>
```

### 4. PowerSync Sync Config

Deploy the sync stream config via the PowerSync CLI:

```bash
npm install -g powersync
powersync login
powersync link cloud --instance-id=69b5b2687c4f8b306a1b8255 --project-id=<project-id>
powersync deploy sync-config
```

---

## Backend

- **Supabase Project:** `zingetplhjqubtydzfpo`
- **PowerSync Instance:** `https://69b5b2687c4f8b306a1b8255.powersync.journeyapps.com`
- Schema: see `supabase/migrations/`

---

## PowerSync Sync Streams

Migrated from sync rules (`bucket_definitions`) to **sync streams** (`streams`). All four streams use `auto_subscribe: true` and filter server-side using `auth.user_id()` — no client-side parameters required.

```yaml
config:
  edition: 3

streams:
  ranger_own_features:
    auto_subscribe: true
    query: |
      SELECT map_features.*
      FROM map_features
      JOIN staff ON map_features.created_by = staff.id
      WHERE staff.user_id = auth.user_id()
        AND staff.rank = 'ranger'
        AND staff.is_active = true

  ranger_park_data:
    auto_subscribe: true
    queries:
      - |
        SELECT parks.*
        FROM parks
        JOIN staff ON parks.id = staff.park_id
        WHERE staff.user_id = auth.user_id()
          AND staff.rank = 'ranger'
          AND staff.is_active = true
      - |
        SELECT park_boundaries.*
        FROM park_boundaries
        JOIN staff ON park_boundaries.park_id = staff.park_id
        WHERE staff.user_id = auth.user_id()
          AND staff.rank = 'ranger'
          AND staff.is_active = true
      - |
        SELECT s.*
        FROM staff s
        JOIN staff user_staff ON s.park_id = user_staff.park_id
        WHERE user_staff.user_id = auth.user_id()
          AND user_staff.rank = 'ranger'
          AND user_staff.is_active = true
          AND s.is_active = true

  admin_map_features:
    auto_subscribe: true
    queries:
      - |
        SELECT map_features.*
        FROM map_features
        JOIN staff ON map_features.park_id = staff.park_id
        WHERE staff.user_id = auth.user_id()
          AND staff.rank = 'admin'
          AND staff.is_active = true
      - |
        SELECT parks.*
        FROM parks
        JOIN staff ON parks.id = staff.park_id
        WHERE staff.user_id = auth.user_id()
          AND staff.rank = 'admin'
          AND staff.is_active = true
      - |
        SELECT park_boundaries.*
        FROM park_boundaries
        JOIN staff ON park_boundaries.park_id = staff.park_id
        WHERE staff.user_id = auth.user_id()
          AND staff.rank = 'admin'
          AND staff.is_active = true
      - |
        SELECT s.*
        FROM staff s
        JOIN staff user_staff ON s.park_id = user_staff.park_id
        WHERE user_staff.user_id = auth.user_id()
          AND user_staff.rank = 'admin'
          AND user_staff.is_active = true
          AND s.is_active = true

  global_reference:
    auto_subscribe: true
    queries:
      - SELECT * FROM spot_types WHERE is_active = true
      - SELECT * FROM mission_role_types
```

On the client, `SystemManager.connect()` explicitly subscribes to all four streams and awaits their first sync in parallel:

```swift
let subs = try await withThrowingTaskGroup(of: (any SyncStreamSubscription).self) { ... }
try await withThrowingTaskGroup(of: Void.self) { group in
    for sub in syncSubscriptions { group.addTask { try await sub.waitForFirstSync() } }
    try await group.waitForAll()
}
```

Non-matching role streams (e.g. a ranger subscribing to `admin_map_features`) resolve immediately with 0 rows — no unauthorised data is returned.

---

## AI Models (swift-cactus 2.1.1)

| Model | Use | Notes |
|-------|-----|-------|
| `lfm2_5_1_2bThinking` | LLM for briefing + Copilot chat | ~1.2 GB, downloaded once |
| `whisperSmall()` | STT for voice note dictation | ~150 MB — use standard variant, not `pro:` |
| `sileroVad` | Voice activity detection (Copilot) | ~5 MB |

Models are downloaded once to Application Support via `CactusModelsDirectory.shared.modelURL(for:)`.

> **Note:** `whisperSmall(pro: .apple)` requires CoreML entitlements and crashes on load as GGUF. Always use `whisperSmall()` (standard).

### Voice Note Dictation Flow

The `CactusSTTSession` is created **after** `AVAudioRecorder` has fully stopped and the audio session is deactivated. Creating a session before recording starts activates Cactus audio infrastructure that conflicts with `AVAudioRecorder`, producing a corrupt WAV file. The sequence is:

1. User taps **Dictate** → `loadSTTIfNeeded()` downloads the model file only (no session created)
2. `AVAudioRecorder` records to a 16 kHz mono PCM `.wav` temp file
3. User taps **Stop** → recorder stops, audio session deactivated
4. `CactusSTTSession` is created from the on-disk model, `transcribe(request:)` called with the file URL
5. Transcription appended to the incident notes field; temp file deleted

