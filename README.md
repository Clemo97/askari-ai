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

## Getting Started

### Prerequisites

- **Xcode 16+** (Swift 6 toolchain)
- **iOS 17+ device or simulator** (on-device AI requires a real device for Whisper/LLM inference)
- A **Supabase** project
- A **PowerSync** Cloud instance linked to that Supabase project

---

## 1. Clone and open in Xcode

```bash
git clone https://github.com/Clemo97/askari-ai.git
cd askari-ai
open AskariAI.xcodeproj   # or .xcworkspace if present
```

Swift Package dependencies resolve automatically on first open. If they don't, go to **File → Packages → Resolve Package Versions**.

---

## 2. Configure Secrets

The app reads credentials from `AskariAI/Managers/_Secrets.swift`, which is gitignored. A template is provided at [AskariAI/Managers/_Secrets.template.swift](AskariAI/Managers/_Secrets.template.swift).

**Copy the template:**

```bash
cp AskariAI/Managers/_Secrets.template.swift AskariAI/Managers/_Secrets.swift
```

**Then fill in `_Secrets.swift`:**

```swift
enum Secrets {
    static let supabaseURL      = URL(string: "https://<your-project-ref>.supabase.co")!
    static let supabaseAnonKey  = "<your-supabase-anon-key>"
    static let powerSyncEndpoint = "https://<your-instance-id>.powersync.journeyapps.com"
    // Optional — set to your Supabase Storage bucket name to enable media attachments
    static let supabaseStorageBucket: String? = "incident-media"
    // Optional — set to your Cactus Cloud key for hybrid AI fallback
    static let cactusCloudKey: String? = nil
}
```

You can find these values at:
- **Supabase URL + anon key:** Supabase Dashboard → Project Settings → API
- **PowerSync endpoint:** PowerSync Dashboard → Your Instance → Connection URL

---

## 3. Set up Supabase

The full database definition is split into focused files under `supabase/`:

| File | Purpose |
|------|---------|
| [supabase/schema.dbml](supabase/schema.dbml) | Schema documentation — tables, PKs, FKs, checks (DBML format) |
| [supabase/schema.sql](supabase/schema.sql) | `CREATE TABLE` statements + `spot_types` seed data |
| [supabase/indexes.sql](supabase/indexes.sql) | Performance indexes |
| [supabase/functions.sql](supabase/functions.sql) | Helper functions (`auth_staff_id`, `auth_staff_park_id`, `auth_staff_rank`, `trigger_set_updated_at`, `handle_new_user`) |
| [supabase/triggers.sql](supabase/triggers.sql) | `updated_at` triggers + commented `on_auth_user_created` auth trigger |
| [supabase/rls.sql](supabase/rls.sql) | RLS enables + all policies |
| [supabase/powersync.sql](supabase/powersync.sql) | PowerSync scoping notes (not executed in DB) |

### 3a. Run the setup SQL in order

Open the **Supabase SQL Editor** (Dashboard → SQL Editor → New query) and run each file in the order listed. Each query window is a fresh paste — run them one at a time.

| Step | File | Action |
|------|------|--------|
| 1 | [supabase/schema.sql](supabase/schema.sql) | Creates all tables; seeds 14 `spot_types` rows |
| 2 | [supabase/indexes.sql](supabase/indexes.sql) | Adds performance indexes |
| 3 | [supabase/functions.sql](supabase/functions.sql) | Creates helper functions + `handle_new_user` |
| 4 | [supabase/triggers.sql](supabase/triggers.sql) | Attaches `updated_at` triggers; see note for auth trigger |
| 5 | [supabase/rls.sql](supabase/rls.sql) | Enables RLS and applies all policies |

> **Auth trigger (step 4):** `triggers.sql` includes a commented-out `CREATE TRIGGER on_auth_user_created` on the `auth.users` table. Uncomment and run it in the Supabase SQL Editor (which executes as superuser). This enables automatic `staff` row creation on signup.

### 3b. Create a Storage bucket (optional — for media attachments)

1. Supabase Dashboard → Storage → Create bucket
2. Name it `incident-media` (or whatever you set in `_Secrets.supabaseStorageBucket`)
3. Set it to **Private**
4. Add a storage policy allowing authenticated users to upload/download their own files

### 3c. Set up your first admin/ranger

Sign up via the app — `handle_new_user` automatically creates a `staff` row linked to the first park in the database. To promote an account to admin:

```sql
UPDATE public.staff SET rank = 'admin' WHERE email = 'you@example.com';
```

To assign a ranger to a specific park (if multiple parks exist):

```sql
UPDATE public.staff
SET park_id = (SELECT id FROM public.parks WHERE name = 'Nairobi National Park')
WHERE email = 'ranger@example.com';
```

---

## 4. Set up PowerSync

### 4a. Link your Supabase project

Follow the [PowerSync Supabase integration guide](https://docs.powersync.com/integration-guides/supabase-+-powersync) to connect your PowerSync instance to your Supabase database.

### 4b. Deploy the sync stream config

```bash
npm install -g @powersync/cli
powersync login
powersync link cloud --project-id=<your-project-id>
powersync deploy sync-config
```

The config is at [powersync/sync-config.yaml](powersync/sync-config.yaml).

---

## 5. Build and run

1. Select your target device in Xcode (real device recommended for AI features)
2. **Product → Run** (⌘R)
3. Sign up with an email — `handle_new_user` creates a `staff` row and assigns the default park automatically
4. To promote yourself to admin, run `UPDATE public.staff SET rank = 'admin' WHERE email = 'you@example.com';` in the SQL Editor
5. AI models download on first use (~1.2 GB for LLM, ~150 MB for Whisper)

---

## Swift Package Dependencies (Xcode SPM)

| Package | URL | Version |
|---------|-----|---------|
| PowerSync Swift SDK | `https://github.com/powersync-ja/powersync-swift` | `1.13.0` |
| Supabase Swift | `https://github.com/supabase/supabase-swift` | `>= 2.0.0` |
| TCA | `https://github.com/pointfreeco/swift-composable-architecture` | `>= 1.0.0` |
| swift-cactus | `https://github.com/nicholasnlawson/swift-cactus` | `2.1.1` |

All packages are declared in `Package.swift` and resolve automatically in Xcode.

---

## Backend

- **Supabase Project:** *(set `supabaseURL` and `supabaseAnonKey` in `_Secrets.swift`)*
- **PowerSync Instance:** *(set `powerSyncEndpoint` in `_Secrets.swift`)*
- Schema: see [`supabase/schema.dbml`](supabase/schema.dbml)

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

