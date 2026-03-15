-- ============================================================
-- Askari AI — Schema additions for Supabase (e-parcs database)
-- Safe to run multiple times (IF NOT EXISTS / ADD COLUMN IF NOT EXISTS)
-- Run this in the Supabase Dashboard → SQL Editor
-- ============================================================

-- ── 1. spot_types ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.spot_types (
    id               uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    code_name        text NOT NULL UNIQUE,
    display_name     text NOT NULL,
    color_hex        text,
    is_active        boolean DEFAULT true,
    sort_order       integer DEFAULT 0,
    description      text,
    severity_default text DEFAULT 'medium',
    created_at       timestamptz DEFAULT now()
);

-- ── 2. terrains ────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.terrains (
    id           uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name         text NOT NULL,
    geometry     jsonb,
    terrain_type text,
    created_at   timestamptz DEFAULT now()
);

-- ── 3. filter_presets ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.filter_presets (
    id               uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    name             text NOT NULL,
    description      text,
    spot_types       jsonb DEFAULT '[]'::jsonb,
    is_system_preset boolean DEFAULT false,
    created_by       uuid,
    created_at       timestamptz DEFAULT now(),
    updated_at       timestamptz DEFAULT now(),
    days_back        integer DEFAULT 7
);

-- ── 4. map_features additions (incident columns) ───────────────────────────
ALTER TABLE public.map_features
    ADD COLUMN IF NOT EXISTS spot_type_id  uuid REFERENCES public.spot_types(id),
    ADD COLUMN IF NOT EXISTS is_resolved   boolean DEFAULT false,
    ADD COLUMN IF NOT EXISTS resolved_at   timestamptz,
    ADD COLUMN IF NOT EXISTS resolved_by   uuid,
    ADD COLUMN IF NOT EXISTS severity      text DEFAULT 'medium',
    ADD COLUMN IF NOT EXISTS park_id       uuid;

-- ── 5. missions addition ───────────────────────────────────────────────────
ALTER TABLE public.missions
    ADD COLUMN IF NOT EXISTS selected_block_ids jsonb DEFAULT '[]'::jsonb;

-- ── 6. park_blocks addition ────────────────────────────────────────────────
ALTER TABLE public.park_blocks
    ADD COLUMN IF NOT EXISTS park_id uuid;

-- ── 7. Seed spot_types ─────────────────────────────────────────────────────
INSERT INTO public.spot_types (code_name, display_name, color_hex, sort_order, severity_default) VALUES
    ('snare',           'Snare',               '#FF4444', 1,  'high'),
    ('carcass',         'Animal Carcass',       '#FF8800', 2,  'high'),
    ('poacher_camp',    'Poacher Camp',         '#CC0000', 3,  'critical'),
    ('wire_fence',      'Damaged Fence/Wire',   '#FFCC00', 4,  'medium'),
    ('footprint',       'Human Footprint',      '#FF6600', 5,  'medium'),
    ('vehicle_track',   'Vehicle Track',        '#AA44FF', 6,  'low'),
    ('fire',            'Fire / Burn Area',     '#FF2200', 7,  'high'),
    ('illegal_logging', 'Illegal Logging',      '#884400', 8,  'high'),
    ('water_source',    'Water Source',         '#0088FF', 9,  'low'),
    ('animal_sighting', 'Wildlife Sighting',    '#00AA44', 10, 'low')
ON CONFLICT (code_name) DO NOTHING;

-- ── 8. RLS ─────────────────────────────────────────────────────────────────
ALTER TABLE public.spot_types    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.terrains      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.filter_presets ENABLE ROW LEVEL SECURITY;

-- spot_types: public read, admin write
CREATE POLICY IF NOT EXISTS "spot_types_read"
    ON public.spot_types FOR SELECT USING (true);

-- terrains: public read
CREATE POLICY IF NOT EXISTS "terrains_read"
    ON public.terrains FOR SELECT USING (true);

-- filter_presets: public read
CREATE POLICY IF NOT EXISTS "filter_presets_read"
    ON public.filter_presets FOR SELECT USING (true);

-- ── 9. PowerSync publication ───────────────────────────────────────────────
-- Add new tables to the existing powersync publication so they replicate.
-- Only needed if your Supabase instance uses a named publication.
-- Run only if the publication exists:
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_publication WHERE pubname = 'powersync'
    ) THEN
        ALTER PUBLICATION powersync ADD TABLE
            public.spot_types,
            public.terrains,
            public.filter_presets;
    END IF;
END $$;
