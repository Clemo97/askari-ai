-- ============================================================
-- Askari AI — Seed data only
-- All tables/columns already exist in the e-parcs schema.
-- Run this in the Supabase Dashboard → SQL Editor
-- ============================================================

-- ── Seed spot_types ────────────────────────────────────────────────────────
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

