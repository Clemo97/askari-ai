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

- **Supabase Project:** *(set `supabaseURL` and `supabaseAnonKey` in `_Secrets.swift`)*
- **PowerSync Instance:** *(set `powerSyncEndpoint` in `_Secrets.swift`)*
- Schema: see `supabase/migrations/`

---

## PowerSync Sync Streams

Migrated from sync rules (`bucket_definitions`) to a single consolidated **sync stream** (`migrated_to_streams`). CTE-style `with:` parameters resolve per-user via `auth.user_id()` — ranger and admin data are filtered server-side, no client-side parameters required.

```yaml
config:
  edition: 3

streams:
  migrated_to_streams:
    auto_subscribe: true
    with:
      ranger_own_features_param: >-
        SELECT staff.id AS staff_id FROM staff
        WHERE staff.user_id = auth.user_id()
          AND staff.rank = 'ranger' AND staff.is_active = TRUE
      ranger_park_data_param: >-
        SELECT staff.park_id AS park_id FROM staff
        WHERE staff.user_id = auth.user_id()
          AND staff.rank = 'ranger' AND staff.is_active = TRUE
      admin_map_features_param: >-
        SELECT staff.park_id AS park_id FROM staff
        WHERE staff.user_id = auth.user_id()
          AND staff.rank = 'admin' AND staff.is_active = TRUE
    queries:
      # Ranger: own incidents
      - "SELECT map_features.* FROM map_features, ranger_own_features_param AS bucket WHERE map_features.created_by = bucket.staff_id"
      # Ranger: park context
      - "SELECT parks.* FROM parks, ranger_park_data_param AS bucket WHERE parks.id = bucket.park_id"
      - "SELECT park_boundaries.* FROM park_boundaries, ranger_park_data_param AS bucket WHERE park_boundaries.park_id = bucket.park_id"
      - "SELECT staff.* FROM staff, ranger_park_data_param AS bucket WHERE staff.park_id = bucket.park_id AND staff.is_active = TRUE"
      # Admin: all park map features + context
      - "SELECT map_features.* FROM map_features, admin_map_features_param AS bucket WHERE map_features.park_id = bucket.park_id"
      - "SELECT parks.* FROM parks, admin_map_features_param AS bucket WHERE parks.id = bucket.park_id"
      - "SELECT park_boundaries.* FROM park_boundaries, admin_map_features_param AS bucket WHERE park_boundaries.park_id = bucket.park_id"
      - "SELECT staff.* FROM staff, admin_map_features_param AS bucket WHERE staff.park_id = bucket.park_id AND staff.is_active = TRUE"
      # Global reference (all users)
      - SELECT * FROM spot_types WHERE spot_types.is_active = TRUE
      - SELECT * FROM mission_role_types
```

On the client, `SystemManager.connect()` subscribes to the single stream and awaits its first sync:

```swift
let sub = try await db.syncStream(name: "migrated_to_streams", params: nil).subscribe()
try await sub.waitForFirstSync()
```

`auto_subscribe: true` means the server begins syncing immediately on connection — the explicit subscribe call is used only to obtain a handle for `waitForFirstSync()`, which blocks until the local SQLite database has received its initial data.

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

