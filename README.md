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

### 3a. Run the setup SQL

Open the **Supabase SQL Editor** (Dashboard → SQL Editor → New query), paste the entire block below, and click **Run**. This creates all tables, functions, triggers, and seeds reference data to match the current production schema.

```sql
-- ============================================================
-- Askari AI — Full Database Setup
-- Run this once in the Supabase SQL Editor on a fresh project.
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- SPOT TYPES (incident categories — global reference data)
-- ============================================================
CREATE TABLE spot_types (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code_name        TEXT NOT NULL UNIQUE,
    display_name     TEXT NOT NULL,
    color_hex        TEXT NOT NULL DEFAULT '#FF6B00',
    is_active        BOOLEAN NOT NULL DEFAULT TRUE,
    sort_order       INTEGER NOT NULL DEFAULT 0,
    description      TEXT,
    severity_default TEXT NOT NULL DEFAULT 'medium'
                         CHECK (severity_default IN ('low','medium','high','critical')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO spot_types (code_name, display_name, color_hex, sort_order, severity_default) VALUES
    ('snare',              'Wire Snare',          '#FF4444',  1, 'high'),
    ('ditch_trap',         'Ditch Trap',           '#FF6600',  2, 'high'),
    ('poacher_camp',       'Poacher Camp',         '#CC0000',  3, 'critical'),
    ('spent_cartridge',    'Spent Cartridge',      '#FF8800',  4, 'medium'),
    ('arrest',             'Arrest',               '#00AA44',  5, 'high'),
    ('carcass',            'Animal Carcass',       '#990000',  6, 'critical'),
    ('poison',             'Poison/Bait',          '#AA00AA',  7, 'critical'),
    ('charcoal_kiln',      'Charcoal Kiln',        '#555555',  8, 'medium'),
    ('logging_site',       'Illegal Logging',      '#886600',  9, 'high'),
    ('injured_animal',     'Injured Animal',       '#FF9900', 10, 'medium'),
    ('track_footprint',    'Human Tracks',         '#AAAAAA', 11, 'low'),
    ('vandalized_fence',   'Vandalized Fence',     '#FF6644', 12, 'medium'),
    ('suspicious_vehicle', 'Suspicious Vehicle',   '#FF3300', 13, 'high'),
    ('campfire',           'Illegal Campfire',     '#FF7700', 14, 'medium');

-- ============================================================
-- STAFF (linked to Supabase Auth users)
-- ============================================================
CREATE TABLE staff (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email        TEXT NOT NULL UNIQUE,
    staff_number TEXT UNIQUE,
    first_name   TEXT NOT NULL,
    last_name    TEXT NOT NULL,
    rank         TEXT NOT NULL DEFAULT 'ranger',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    user_id      UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    photo_url    TEXT
);

CREATE INDEX idx_staff_user_id ON staff(user_id);
CREATE INDEX idx_staff_rank    ON staff(rank);

-- ============================================================
-- PARK BOUNDARIES
-- ============================================================
CREATE TABLE park_boundaries (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    park_name   TEXT NOT NULL,
    country     TEXT NOT NULL,
    coordinates JSONB NOT NULL,   -- GeoJSON Polygon/MultiPolygon
    created_at  TIMESTAMPTZ DEFAULT NOW(),
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- PARK BLOCKS (patrol zones)
-- ============================================================
CREATE TABLE park_blocks (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    block_name     VARCHAR NOT NULL,
    coordinates    TEXT NOT NULL,         -- WKT or serialized polygon
    threshold      NUMERIC NOT NULL DEFAULT 80.0,
    visibility     NUMERIC NOT NULL DEFAULT 50.0,
    rate_of_decay  NUMERIC NOT NULL DEFAULT 30.0,
    last_patrolled TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- MISSION ROLE TYPES
-- ============================================================
CREATE TABLE mission_role_types (
    id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    role_name TEXT NOT NULL,
    user_id   UUID REFERENCES auth.users(id) ON DELETE SET NULL
);

-- ============================================================
-- MISSIONS
-- ============================================================
CREATE TABLE missions (
    id                      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                    TEXT NOT NULL,
    objectives              TEXT NOT NULL DEFAULT '',
    start_date              TIMESTAMPTZ NOT NULL,
    end_date                TIMESTAMPTZ NOT NULL,
    patrol_type             TEXT NOT NULL DEFAULT 'Local',
    route_points            JSONB NOT NULL DEFAULT '[]',
    staff_ids               UUID[] NOT NULL DEFAULT '{}',
    leader_id               UUID,
    instruction_video_url   TEXT,
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    user_id                 UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    status                  TEXT DEFAULT 'future',
    patrol_actions          TEXT,
    mission_state           TEXT DEFAULT 'not_started'
                                COMMENT ON COLUMN missions.mission_state IS 'Current execution state: not_started, active, or paused',
    total_active_time       DOUBLE PRECISION,   -- total seconds in active state
    last_state_change       TIMESTAMPTZ,        -- timestamp of last state change
    selected_block_ids      JSONB NOT NULL DEFAULT '[]',
    updated_at              TIMESTAMPTZ DEFAULT NOW(),
    current_transport_mode  TEXT,
    transport_mode_history  TEXT
);

CREATE INDEX idx_missions_status     ON missions(status);
CREATE INDEX idx_missions_start_date ON missions(start_date);
CREATE INDEX idx_missions_leader_id  ON missions(leader_id);

-- ============================================================
-- STAFF ↔ MISSION
-- ============================================================
CREATE TABLE staff_mission (
    staff_id           UUID NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
    mission_id         UUID NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    staff_mission_role UUID REFERENCES mission_role_types(id) ON DELETE SET NULL,
    user_id            UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    PRIMARY KEY (staff_id, mission_id)
);

-- ============================================================
-- MAP FEATURES (incidents logged during patrol)
-- ============================================================
CREATE TABLE map_features (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name                 TEXT NOT NULL,
    description          TEXT,
    geometry             JSONB NOT NULL,   -- GeoJSON Point
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by           UUID REFERENCES auth.users(id) ON DELETE SET NULL,
    media_url            TEXT,             -- JSON array of attachment IDs stored as text
    decay_rate           DOUBLE PRECISION,
    threshold            DOUBLE PRECISION,
    buffer_distance      DOUBLE PRECISION,
    last_patrolled       TIMESTAMPTZ,
    mission_id           UUID REFERENCES missions(id) ON DELETE SET NULL,
    captured_by_staff_id UUID REFERENCES staff(id) ON DELETE SET NULL,
    updated_at           TIMESTAMPTZ,
    local_media_identifiers TEXT[],        -- PhotoKit PHAsset localIdentifiers
    spot_type_id         UUID REFERENCES spot_types(id) ON DELETE SET NULL,
    is_resolved          BOOLEAN NOT NULL DEFAULT FALSE,
    resolved_at          TIMESTAMPTZ,
    resolved_by          UUID,
    severity             TEXT NOT NULL DEFAULT 'medium'
                             CHECK (severity IN ('low','medium','high','critical'))
);

CREATE INDEX idx_map_features_spot_type   ON map_features(spot_type_id);
CREATE INDEX idx_map_features_mission_id  ON map_features(mission_id);
CREATE INDEX idx_map_features_created_at  ON map_features(created_at DESC);
CREATE INDEX idx_map_features_severity    ON map_features(severity);

-- ============================================================
-- MAP FEATURES ↔ MISSIONS (many-to-many join)
-- ============================================================
CREATE TABLE map_features_missions (
    id             UUID DEFAULT gen_random_uuid(),
    map_feature_id UUID NOT NULL REFERENCES map_features(id) ON DELETE CASCADE,
    mission_id     UUID NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    PRIMARY KEY (map_feature_id, mission_id)
);

-- ============================================================
-- MISSION TRACK (patrol coverage + route geometry per mission)
-- ============================================================
CREATE TABLE mission_track (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mission_id           UUID UNIQUE REFERENCES missions(id) ON DELETE CASCADE,
    coverage_geometry    JSONB,            -- patrol coverage area polygon
    path_geometry        JSONB,            -- route with vehicle/foot segments
    distance_traveled_km DOUBLE PRECISION DEFAULT 0.0,
    created_at           TIMESTAMPTZ DEFAULT NOW()
) COMMENT ON TABLE mission_track IS 'Stores mission tracking data: coverage_geometry (patrol coverage area) and path_geometry (route with vehicle/foot segments)';

-- ============================================================
-- MISSION SCORES
-- ============================================================
CREATE TABLE mission_scores (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mission_id           UUID UNIQUE NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    distance_traveled_km REAL NOT NULL DEFAULT 0.0,
    buffer_points        REAL NOT NULL DEFAULT 0.0,
    mission_completed    BOOLEAN NOT NULL DEFAULT FALSE,
    completed_at         TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
) COMMENT ON TABLE mission_scores IS 'Mission-level aggregated scores (one record per mission)';

-- ============================================================
-- GREEN TRACK (patrol route buffer polygons)
-- ============================================================
CREATE TABLE green_track (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    geometry             JSONB NOT NULL
                             CHECK ((geometry ->> 'type') = ANY (ARRAY['Polygon','MultiPolygon'])),
    mission_id           UUID NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    created_at           TIMESTAMPTZ DEFAULT NOW(),
    distance_traveled_km DOUBLE PRECISION DEFAULT 0.0
);

-- ============================================================
-- TERRAINS
-- ============================================================
CREATE TABLE terrains (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name         TEXT NOT NULL,
    geometry     JSONB NOT NULL,
    terrain_type TEXT NOT NULL
                     CHECK (terrain_type IN ('forest','savanna','wetland','river','mountain','grassland')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- FILTER PRESETS (saved map filter configs)
-- ============================================================
CREATE TABLE filter_presets (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name            TEXT NOT NULL,
    description     TEXT,
    spot_types      TEXT[] NOT NULL,
    is_system_preset BOOLEAN DEFAULT FALSE,
    created_by      UUID REFERENCES staff(id) ON DELETE SET NULL,
    days_back       INTEGER NOT NULL,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- ATTACHMENTS (PowerSync media queue)
-- ============================================================
CREATE TABLE attachments (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename   TEXT NOT NULL,
    media_type TEXT,
    state      INTEGER NOT NULL DEFAULT 0,
    local_uri  TEXT,
    remote_uri TEXT,
    size       INTEGER,
    timestamp  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- MISSION STATUS LOGS (automated scheduler audit trail)
-- ============================================================
CREATE TABLE mission_status_logs (
    id               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    executed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    missions_updated INTEGER NOT NULL DEFAULT 0
);

-- ============================================================
-- FUNCTIONS
-- ============================================================

-- Auto-populate user_id on staff insert by matching email to auth.users
CREATE OR REPLACE FUNCTION populate_user_id()
RETURNS TRIGGER AS $$
BEGIN
    NEW.user_id := (SELECT id FROM auth.users WHERE email = NEW.email);
    IF NEW.user_id IS NULL THEN
        RAISE EXCEPTION 'No auth user found with email %', NEW.email;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Generic updated_at updater
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- When a mission_score is marked completed, flip the mission status to 'past'
CREATE OR REPLACE FUNCTION auto_update_mission_status_on_completion()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.mission_completed IS TRUE THEN
        UPDATE public.missions
        SET status = 'past'
        WHERE id = NEW.mission_id
          AND status IS DISTINCT FROM 'past';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- TRIGGERS
-- ============================================================

-- Populate user_id when a staff row is inserted
CREATE TRIGGER set_user_id
    BEFORE INSERT ON staff
    FOR EACH ROW EXECUTE FUNCTION populate_user_id();

-- Keep mission_scores.updated_at current
CREATE TRIGGER update_mission_scores_updated_at
    BEFORE UPDATE ON mission_scores
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Auto-close mission when scores mark it complete
CREATE TRIGGER trigger_update_mission_status_on_completion
    AFTER INSERT OR UPDATE ON mission_scores
    FOR EACH ROW EXECUTE FUNCTION auto_update_mission_status_on_completion();

-- ============================================================
-- ROW LEVEL SECURITY
-- Enable RLS on tables that need per-user access control.
-- The sync stream handles data scoping for PowerSync;
-- RLS here protects direct Supabase API access.
-- ============================================================
ALTER TABLE spot_types         ENABLE ROW LEVEL SECURITY;
ALTER TABLE filter_presets     ENABLE ROW LEVEL SECURITY;
ALTER TABLE terrains           ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments        ENABLE ROW LEVEL SECURITY;
ALTER TABLE mission_status_logs ENABLE ROW LEVEL SECURITY;

-- All authenticated users can read spot_types
CREATE POLICY "spot_types: authenticated read"
    ON spot_types FOR SELECT USING (auth.role() = 'authenticated');

-- Staff can read/write their own filter presets; system presets are readable by all
CREATE POLICY "filter_presets: read own + system"
    ON filter_presets FOR SELECT
    USING (is_system_preset = TRUE OR created_by = (SELECT id FROM staff WHERE user_id = auth.uid() LIMIT 1));

CREATE POLICY "filter_presets: write own"
    ON filter_presets FOR ALL
    USING (created_by = (SELECT id FROM staff WHERE user_id = auth.uid() LIMIT 1));
```

> **Note:** The `populate_user_id` trigger requires that you create the Supabase Auth user **before** inserting the corresponding `staff` row. The easiest flow is to sign up via the app first, then update the `staff` row's `rank` in the SQL editor.

### 3b. Create a Storage bucket (optional — for media attachments)

1. Supabase Dashboard → Storage → Create bucket
2. Name it `incident-media` (or whatever you set in `_Secrets.supabaseStorageBucket`)
3. Set it to **Private**
4. Add a storage policy allowing authenticated users to upload/download their own files

### 3c. Set up your first admin/ranger

Sign up via the app (this creates an `auth.users` entry). Then set your rank and link to a park boundary in the SQL editor:

```sql
UPDATE staff SET rank = 'admin' WHERE email = 'you@example.com';
```

Rangers are scoped to data by the PowerSync sync stream — there is no `park_id` column on `staff` in the current schema. Boundary data is stored in `park_boundaries` and the app loads whichever boundary record exists.

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
3. Sign up with an email — a `staff` row is created automatically for you
4. An admin must assign you to a `park_id` and set your `rank` in Supabase before map data appears
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

