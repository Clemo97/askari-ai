-- ============================================================
-- Askari AI — Table Definitions + Seed Data
-- Run this first (before indexes.sql, functions.sql, triggers.sql, rls.sql)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ============================================================
-- PARKS
-- ============================================================
CREATE TABLE public.parks (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT        NOT NULL,
    country    TEXT        NOT NULL DEFAULT 'Kenya',
    region     TEXT,
    timezone   TEXT        NOT NULL DEFAULT 'Africa/Nairobi',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- STAFF  (linked to Supabase Auth users via user_id)
-- ============================================================
CREATE TABLE public.staff (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id    UUID        UNIQUE REFERENCES auth.users(id) ON DELETE SET NULL,
    park_id    UUID        REFERENCES public.parks(id) ON DELETE SET NULL,
    email      TEXT        NOT NULL UNIQUE,
    first_name TEXT        NOT NULL,
    last_name  TEXT        NOT NULL,
    rank       TEXT        NOT NULL DEFAULT 'ranger'
                               CHECK (rank IN ('ranger','supervisor','park_head','admin','parks_authority')),
    avatar_url TEXT,
    is_active  BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- SPOT TYPES  (incident categories — global reference data)
-- ============================================================
CREATE TABLE public.spot_types (
    id               UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    code_name        TEXT        NOT NULL UNIQUE,
    display_name     TEXT        NOT NULL,
    color_hex        TEXT        NOT NULL DEFAULT '#FF6B00',
    is_active        BOOLEAN     NOT NULL DEFAULT TRUE,
    sort_order       INTEGER     NOT NULL DEFAULT 0,
    description      TEXT,
    severity_default TEXT        NOT NULL DEFAULT 'medium'
                                     CHECK (severity_default IN ('low','medium','high','critical')),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Seed: all 14 incident categories
INSERT INTO public.spot_types (code_name, display_name, color_hex, sort_order, severity_default) VALUES
    ('snare',              'Wire Snare',           '#FF4444',  1, 'high'),
    ('ditch_trap',         'Ditch Trap',            '#FF6600',  2, 'high'),
    ('poacher_camp',       'Poacher Camp',          '#CC0000',  3, 'critical'),
    ('spent_cartridge',    'Spent Cartridge',       '#FF8800',  4, 'medium'),
    ('arrest',             'Arrest',                '#00AA44',  5, 'high'),
    ('carcass',            'Animal Carcass',        '#990000',  6, 'critical'),
    ('poison',             'Poison/Bait',           '#AA00AA',  7, 'critical'),
    ('charcoal_kiln',      'Charcoal Kiln',         '#555555',  8, 'medium'),
    ('logging_site',       'Illegal Logging',       '#886600',  9, 'high'),
    ('injured_animal',     'Injured Animal',        '#FF9900', 10, 'medium'),
    ('track_footprint',    'Human Tracks',          '#AAAAAA', 11, 'low'),
    ('vandalized_fence',   'Vandalized Fence',      '#FF6644', 12, 'medium'),
    ('suspicious_vehicle', 'Suspicious Vehicle',    '#FF3300', 13, 'high'),
    ('campfire',           'Illegal Campfire',      '#FF7700', 14, 'medium');

-- ============================================================
-- PARK BOUNDARIES  (GeoJSON park polygon per park)
-- ============================================================
CREATE TABLE public.park_boundaries (
    id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    park_id    UUID        NOT NULL REFERENCES public.parks(id) ON DELETE CASCADE,
    name       TEXT        NOT NULL,
    geometry   JSONB       NOT NULL,   -- GeoJSON Polygon / MultiPolygon
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ============================================================
-- MISSION ROLE TYPES  (RLS disabled — read-only reference data)
-- ============================================================
CREATE TABLE public.mission_role_types (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name        TEXT NOT NULL UNIQUE,
    description TEXT
);

-- ============================================================
-- MAP FEATURES  (incidents logged during patrol)
-- ============================================================
CREATE TABLE public.map_features (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    park_id                 UUID        NOT NULL REFERENCES public.parks(id) ON DELETE CASCADE,
    spot_type_id            UUID        REFERENCES public.spot_types(id) ON DELETE SET NULL,
    name                    TEXT        NOT NULL,
    description             TEXT        NOT NULL DEFAULT '',
    geometry                JSONB       NOT NULL,   -- GeoJSON Point
    created_by              UUID        REFERENCES public.staff(id) ON DELETE SET NULL,
    captured_by_staff_id    UUID        REFERENCES public.staff(id) ON DELETE SET NULL,
    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    media_url               JSONB       NOT NULL DEFAULT '[]',   -- attachment IDs
    is_resolved             BOOLEAN     NOT NULL DEFAULT FALSE,
    severity                TEXT        NOT NULL DEFAULT 'medium'
                                            CHECK (severity IN ('low','medium','high','critical')),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    local_media_identifiers TEXT        NOT NULL DEFAULT '[]'   -- PHAsset localIdentifiers (JSON array as text)
);
