-- ============================================================
-- Migration 001: Initial Askari AI Schema
-- Remote backend on Supabase (PostgreSQL)
-- PowerSync syncs all tables to iOS SQLite via Sync Streams
-- ============================================================

-- Enable UUID generation
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- PARKS
-- ============================================================
CREATE TABLE parks (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL,
    country     TEXT NOT NULL DEFAULT 'Kenya',
    region      TEXT,
    timezone    TEXT NOT NULL DEFAULT 'Africa/Nairobi',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- STAFF (extends Supabase Auth users)
-- ============================================================
CREATE TABLE staff (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id     UUID UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    park_id     UUID REFERENCES parks(id) ON DELETE SET NULL,
    email       TEXT NOT NULL UNIQUE,
    first_name  TEXT NOT NULL,
    last_name   TEXT NOT NULL,
    rank        TEXT NOT NULL DEFAULT 'ranger'
                    CHECK (rank IN ('ranger','supervisor','park_head','admin','parks_authority')),
    avatar_url  TEXT,
    is_active   BOOLEAN NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_staff_user_id  ON staff(user_id);
CREATE INDEX idx_staff_park_id  ON staff(park_id);
CREATE INDEX idx_staff_rank     ON staff(rank);

-- ============================================================
-- SPOT TYPES (incident categories)
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

-- Seed default spot types
INSERT INTO spot_types (code_name, display_name, color_hex, sort_order, severity_default) VALUES
    ('snare',             'Wire Snare',          '#FF4444', 1,  'high'),
    ('ditch_trap',        'Ditch Trap',           '#FF6600', 2,  'high'),
    ('poacher_camp',      'Poacher Camp',         '#CC0000', 3,  'critical'),
    ('spent_cartridge',   'Spent Cartridge',      '#FF8800', 4,  'medium'),
    ('arrest',            'Arrest',               '#00AA44', 5,  'high'),
    ('carcass',           'Animal Carcass',       '#990000', 6,  'critical'),
    ('poison',            'Poison/Bait',          '#AA00AA', 7,  'critical'),
    ('charcoal_kiln',     'Charcoal Kiln',        '#555555', 8,  'medium'),
    ('logging_site',      'Illegal Logging',      '#886600', 9,  'high'),
    ('injured_animal',    'Injured Animal',       '#FF9900', 10, 'medium'),
    ('track_footprint',   'Human Tracks',         '#AAAAAA', 11, 'low'),
    ('vandalized_fence',  'Vandalized Fence',     '#FF6644', 12, 'medium'),
    ('suspicious_vehicle','Suspicious Vehicle',   '#FF3300', 13, 'high'),
    ('campfire',          'Illegal Campfire',     '#FF7700', 14, 'medium');

-- ============================================================
-- PARK BOUNDARIES (geofence for each park)
-- ============================================================
CREATE TABLE park_boundaries (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    park_id    UUID NOT NULL REFERENCES parks(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    geometry   JSONB NOT NULL,    -- GeoJSON Polygon/MultiPolygon
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_park_boundaries_park_id ON park_boundaries(park_id);

-- ============================================================
-- PARK BLOCKS (patrol zones within a park)
-- ============================================================
CREATE TABLE park_blocks (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    park_id        UUID NOT NULL REFERENCES parks(id) ON DELETE CASCADE,
    block_name     TEXT NOT NULL,
    coordinates    JSONB NOT NULL,     -- [[lon,lat],...]  polygon ring
    threshold      NUMERIC(5,4) NOT NULL DEFAULT 0.7,  -- 70% coverage target
    visibility     NUMERIC(8,2) NOT NULL DEFAULT 200,  -- meters
    rate_of_decay  NUMERIC(6,2) NOT NULL DEFAULT 7,    -- days
    last_patrolled TIMESTAMPTZ,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(park_id, block_name)
);

CREATE INDEX idx_park_blocks_park_id ON park_blocks(park_id);

-- ============================================================
-- MISSION ROLE TYPES
-- ============================================================
CREATE TABLE mission_role_types (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL UNIQUE,
    description TEXT
);

INSERT INTO mission_role_types (name, description) VALUES
    ('leader',   'Mission commander / team leader'),
    ('ranger',   'Field ranger'),
    ('tracker',  'Specialist tracker'),
    ('medic',    'Field medic'),
    ('driver',   'Vehicle driver');

-- ============================================================
-- MISSIONS
-- ============================================================
CREATE TABLE missions (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    park_id             UUID NOT NULL REFERENCES parks(id) ON DELETE CASCADE,
    name                TEXT NOT NULL,
    objectives          TEXT NOT NULL DEFAULT '',
    start_date          TIMESTAMPTZ NOT NULL,
    end_date            TIMESTAMPTZ NOT NULL,
    patrol_type         TEXT NOT NULL DEFAULT 'Local'
                            CHECK (patrol_type IN ('Fence/Boundary','Local','Mobile','Aerial','Waterway')),
    status              TEXT NOT NULL DEFAULT 'future'
                            CHECK (status IN ('current','future','past')),
    mission_state       TEXT NOT NULL DEFAULT 'not_started'
                            CHECK (mission_state IN ('not_started','active','paused','completed')),
    staff_ids           JSONB NOT NULL DEFAULT '[]',        -- denormalized for fast iOS reads
    leader_id           UUID REFERENCES staff(id) ON DELETE SET NULL,
    selected_block_ids  JSONB NOT NULL DEFAULT '[]',
    created_by          UUID REFERENCES staff(id) ON DELETE SET NULL,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_missions_park_id      ON missions(park_id);
CREATE INDEX idx_missions_status       ON missions(status);
CREATE INDEX idx_missions_start_date   ON missions(start_date);
CREATE INDEX idx_missions_leader_id    ON missions(leader_id);

-- ============================================================
-- STAFF ↔ MISSION (normalized join table)
-- ============================================================
CREATE TABLE staff_mission (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    staff_id    UUID NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
    mission_id  UUID NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    role_type_id UUID REFERENCES mission_role_types(id) ON DELETE SET NULL,
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(staff_id, mission_id)
);

CREATE INDEX idx_staff_mission_staff   ON staff_mission(staff_id);
CREATE INDEX idx_staff_mission_mission ON staff_mission(mission_id);

-- ============================================================
-- MAP FEATURES (incidents / spots logged during patrol)
-- ============================================================
CREATE TABLE map_features (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    park_id               UUID NOT NULL REFERENCES parks(id) ON DELETE CASCADE,
    mission_id            UUID REFERENCES missions(id) ON DELETE SET NULL,
    spot_type_id          UUID REFERENCES spot_types(id) ON DELETE SET NULL,
    name                  TEXT NOT NULL,                   -- spot type label at time of logging
    description           TEXT NOT NULL DEFAULT '',
    geometry              JSONB NOT NULL,                  -- GeoJSON Point {type, coordinates}
    created_by            UUID REFERENCES staff(id) ON DELETE SET NULL,
    captured_by_staff_id  UUID REFERENCES staff(id) ON DELETE SET NULL,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    media_url             JSONB NOT NULL DEFAULT '[]',     -- [attachment_id, ...]
    is_resolved           BOOLEAN NOT NULL DEFAULT FALSE,
    resolved_at           TIMESTAMPTZ,
    resolved_by           UUID REFERENCES staff(id) ON DELETE SET NULL,
    severity              TEXT NOT NULL DEFAULT 'medium'
                              CHECK (severity IN ('low','medium','high','critical')),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_map_features_park_id     ON map_features(park_id);
CREATE INDEX idx_map_features_mission_id  ON map_features(mission_id);
CREATE INDEX idx_map_features_spot_type   ON map_features(spot_type_id);
CREATE INDEX idx_map_features_created_at  ON map_features(created_at DESC);
CREATE INDEX idx_map_features_severity    ON map_features(severity);

-- ============================================================
-- MISSION TRACK (GPS path recorded during patrol)
-- ============================================================
CREATE TABLE mission_track (
    id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mission_id            UUID NOT NULL REFERENCES missions(id) ON DELETE CASCADE,
    staff_id              UUID REFERENCES staff(id) ON DELETE SET NULL,
    path_geometry         JSONB,      -- GeoJSON FeatureCollection of route segments
    coverage_geometry     JSONB,      -- GeoJSON Polygon/MultiPolygon — area covered
    distance_traveled_km  NUMERIC(10,3) NOT NULL DEFAULT 0,
    created_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_mission_track_mission_id ON mission_track(mission_id);

-- ============================================================
-- MISSION SCORES
-- ============================================================
CREATE TABLE mission_scores (
    id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    mission_id           UUID NOT NULL UNIQUE REFERENCES missions(id) ON DELETE CASCADE,
    distance_traveled_km NUMERIC(10,3) NOT NULL DEFAULT 0,
    buffer_points        NUMERIC(10,2) NOT NULL DEFAULT 0,
    incident_points      NUMERIC(10,2) NOT NULL DEFAULT 0,
    mission_completed    BOOLEAN NOT NULL DEFAULT FALSE,
    completed_at         TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- TERRAINS (habitat/landscape layers)
-- ============================================================
CREATE TABLE terrains (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    park_id      UUID NOT NULL REFERENCES parks(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    geometry     JSONB NOT NULL,
    terrain_type TEXT NOT NULL
                    CHECK (terrain_type IN ('forest','savanna','wetland','river','mountain','grassland')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_terrains_park_id ON terrains(park_id);

-- ============================================================
-- FILTER PRESETS (saved map filter configurations per user)
-- ============================================================
CREATE TABLE filter_presets (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id   UUID NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    filters    JSONB NOT NULL DEFAULT '{}',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_filter_presets_owner ON filter_presets(owner_id);

-- ============================================================
-- ATTACHMENTS (PowerSync AttachmentQueue table)
-- ============================================================
CREATE TABLE attachments (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    filename     TEXT NOT NULL,
    media_type   TEXT,
    state        INTEGER NOT NULL DEFAULT 0,   -- AttachmentState enum
    local_uri    TEXT,
    remote_uri   TEXT,
    size         INTEGER,
    timestamp    TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- updated_at triggers
-- ============================================================
CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER set_parks_updated_at
    BEFORE UPDATE ON parks
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_staff_updated_at
    BEFORE UPDATE ON staff
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_missions_updated_at
    BEFORE UPDATE ON missions
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_park_blocks_updated_at
    BEFORE UPDATE ON park_blocks
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_map_features_updated_at
    BEFORE UPDATE ON map_features
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();

CREATE TRIGGER set_mission_track_updated_at
    BEFORE UPDATE ON mission_track
    FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();
