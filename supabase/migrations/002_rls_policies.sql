-- ============================================================
-- Migration 002: Row Level Security (RLS) Policies
-- PowerSync reads through these policies via its service role
-- ============================================================

-- Enable RLS on all user-facing tables
ALTER TABLE parks           ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff           ENABLE ROW LEVEL SECURITY;
ALTER TABLE spot_types      ENABLE ROW LEVEL SECURITY;
ALTER TABLE park_boundaries ENABLE ROW LEVEL SECURITY;
ALTER TABLE park_blocks     ENABLE ROW LEVEL SECURITY;
ALTER TABLE missions        ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff_mission   ENABLE ROW LEVEL SECURITY;
ALTER TABLE map_features    ENABLE ROW LEVEL SECURITY;
ALTER TABLE mission_track   ENABLE ROW LEVEL SECURITY;
ALTER TABLE mission_scores  ENABLE ROW LEVEL SECURITY;
ALTER TABLE terrains        ENABLE ROW LEVEL SECURITY;
ALTER TABLE filter_presets  ENABLE ROW LEVEL SECURITY;
ALTER TABLE attachments     ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- Helper: get current staff record
-- ============================================================
CREATE OR REPLACE FUNCTION auth_staff_id() RETURNS UUID AS $$
    SELECT id FROM staff WHERE user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION auth_staff_rank() RETURNS TEXT AS $$
    SELECT rank FROM staff WHERE user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION auth_staff_park_id() RETURNS UUID AS $$
    SELECT park_id FROM staff WHERE user_id = auth.uid() LIMIT 1;
$$ LANGUAGE sql STABLE SECURITY DEFINER;

-- ============================================================
-- PARKS — all authenticated staff can read their own park
-- ============================================================
CREATE POLICY "parks: read own park"
    ON parks FOR SELECT
    USING (id = auth_staff_park_id());

CREATE POLICY "parks: admins/park_authority can read all"
    ON parks FOR SELECT
    USING (auth_staff_rank() IN ('admin', 'parks_authority'));

CREATE POLICY "parks: admins can insert/update"
    ON parks FOR ALL
    USING (auth_staff_rank() = 'admin');

-- ============================================================
-- STAFF — staff can read all colleagues in their park
-- ============================================================
CREATE POLICY "staff: read own park staff"
    ON staff FOR SELECT
    USING (
        park_id = auth_staff_park_id()
        OR auth_staff_rank() IN ('admin', 'parks_authority')
    );

CREATE POLICY "staff: own record full access"
    ON staff FOR ALL
    USING (user_id = auth.uid());

CREATE POLICY "staff: admins full access"
    ON staff FOR ALL
    USING (auth_staff_rank() = 'admin');

-- ============================================================
-- SPOT TYPES — global reference data, all users read
-- ============================================================
CREATE POLICY "spot_types: all authenticated read"
    ON spot_types FOR SELECT
    USING (auth.role() = 'authenticated');

CREATE POLICY "spot_types: admins manage"
    ON spot_types FOR ALL
    USING (auth_staff_rank() = 'admin');

-- ============================================================
-- PARK BOUNDARIES — read by all staff in that park
-- ============================================================
CREATE POLICY "park_boundaries: read own park"
    ON park_boundaries FOR SELECT
    USING (
        park_id = auth_staff_park_id()
        OR auth_staff_rank() IN ('admin', 'parks_authority')
    );

CREATE POLICY "park_boundaries: park_head/admin write"
    ON park_boundaries FOR ALL
    USING (auth_staff_rank() IN ('admin', 'park_head'));

-- ============================================================
-- PARK BLOCKS — read by all staff; park heads/admins write
-- ============================================================
CREATE POLICY "park_blocks: read own park"
    ON park_blocks FOR SELECT
    USING (
        park_id = auth_staff_park_id()
        OR auth_staff_rank() IN ('admin', 'parks_authority')
    );

CREATE POLICY "park_blocks: park_head/admin write"
    ON park_blocks FOR ALL
    USING (auth_staff_rank() IN ('admin', 'park_head'));

-- ============================================================
-- MISSIONS — rangers read assigned missions; park heads read all
-- ============================================================
CREATE POLICY "missions: rangers read assigned"
    ON missions FOR SELECT
    USING (
        (
            park_id = auth_staff_park_id()
            AND staff_ids @> to_jsonb(auth_staff_id()::TEXT)
        )
        OR auth_staff_rank() IN ('admin', 'park_head', 'parks_authority')
    );

CREATE POLICY "missions: park_head/admin write"
    ON missions FOR ALL
    USING (auth_staff_rank() IN ('admin', 'park_head'));

-- ============================================================
-- STAFF_MISSION
-- ============================================================
CREATE POLICY "staff_mission: read own park"
    ON staff_mission FOR SELECT
    USING (
        staff_id = auth_staff_id()
        OR auth_staff_rank() IN ('admin', 'park_head')
    );

CREATE POLICY "staff_mission: park_head/admin write"
    ON staff_mission FOR ALL
    USING (auth_staff_rank() IN ('admin', 'park_head'));

-- ============================================================
-- MAP FEATURES (incidents)
-- Rangers: read/write incidents for their missions
-- Park heads/admins: read all for their park
-- ============================================================
CREATE POLICY "map_features: rangers read own mission incidents"
    ON map_features FOR SELECT
    USING (
        (
            park_id = auth_staff_park_id()
            AND mission_id IN (
                SELECT id FROM missions
                WHERE staff_ids @> to_jsonb(auth_staff_id()::TEXT)
            )
        )
        OR auth_staff_rank() IN ('admin', 'park_head', 'parks_authority')
    );

CREATE POLICY "map_features: rangers insert into own missions"
    ON map_features FOR INSERT
    WITH CHECK (
        created_by = auth_staff_id()
        AND park_id = auth_staff_park_id()
    );

CREATE POLICY "map_features: rangers update own incidents"
    ON map_features FOR UPDATE
    USING (
        created_by = auth_staff_id()
        OR auth_staff_rank() IN ('admin', 'park_head')
    );

CREATE POLICY "map_features: park_head/admin delete"
    ON map_features FOR DELETE
    USING (auth_staff_rank() IN ('admin', 'park_head'));

-- ============================================================
-- MISSION TRACK
-- ============================================================
CREATE POLICY "mission_track: rangers read own"
    ON mission_track FOR SELECT
    USING (
        staff_id = auth_staff_id()
        OR auth_staff_rank() IN ('admin', 'park_head')
    );

CREATE POLICY "mission_track: rangers insert/update own"
    ON mission_track FOR ALL
    USING (
        staff_id = auth_staff_id()
        OR auth_staff_rank() IN ('admin', 'park_head')
    );

-- ============================================================
-- MISSION SCORES
-- ============================================================
CREATE POLICY "mission_scores: all park staff read"
    ON mission_scores FOR SELECT
    USING (
        mission_id IN (
            SELECT id FROM missions WHERE park_id = auth_staff_park_id()
        )
        OR auth_staff_rank() IN ('admin', 'parks_authority')
    );

CREATE POLICY "mission_scores: system/admin write"
    ON mission_scores FOR ALL
    USING (auth_staff_rank() IN ('admin', 'park_head'));

-- ============================================================
-- TERRAINS
-- ============================================================
CREATE POLICY "terrains: read own park"
    ON terrains FOR SELECT
    USING (
        park_id = auth_staff_park_id()
        OR auth_staff_rank() IN ('admin', 'parks_authority')
    );

-- ============================================================
-- FILTER PRESETS — personal, owned per staff member
-- ============================================================
CREATE POLICY "filter_presets: own records"
    ON filter_presets FOR ALL
    USING (owner_id = auth_staff_id());

-- ============================================================
-- ATTACHMENTS — staff in same park
-- ============================================================
CREATE POLICY "attachments: all authenticated"
    ON attachments FOR ALL
    USING (auth.role() = 'authenticated');

-- ============================================================
-- PowerSync replication user (service role bypasses RLS)
-- The PowerSync service role key is used in the sync config;
-- it bypasses all RLS automatically.
-- ============================================================
