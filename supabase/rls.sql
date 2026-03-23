-- ============================================================
-- Askari AI — Row Level Security
-- Run last (after triggers.sql)
-- ============================================================

-- Enable RLS
ALTER TABLE public.parks            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.staff            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.spot_types       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.park_boundaries  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.map_features     ENABLE ROW LEVEL SECURITY;
-- mission_role_types intentionally has RLS disabled (read-only reference data)

-- ============================================================
-- parks
-- ============================================================
CREATE POLICY "parks: read own park"
    ON public.parks FOR SELECT TO public
    USING (id = public.auth_staff_park_id());

CREATE POLICY "parks: admins/parks_authority can read all"
    ON public.parks FOR SELECT TO public
    USING (public.auth_staff_rank() = ANY(ARRAY['admin','parks_authority']));

CREATE POLICY "parks: admins can insert/update"
    ON public.parks FOR ALL TO public
    USING (public.auth_staff_rank() = 'admin');

-- ============================================================
-- staff
-- ============================================================
CREATE POLICY "staff: read own park staff"
    ON public.staff FOR SELECT TO public
    USING (
        park_id = public.auth_staff_park_id()
        OR public.auth_staff_rank() = ANY(ARRAY['admin','parks_authority'])
    );

CREATE POLICY "staff: own record full access"
    ON public.staff FOR ALL TO public
    USING (user_id = auth.uid());

CREATE POLICY "staff: admins full access"
    ON public.staff FOR ALL TO public
    USING (public.auth_staff_rank() = 'admin');

-- ============================================================
-- spot_types
-- ============================================================
CREATE POLICY "spot_types: all authenticated read"
    ON public.spot_types FOR SELECT TO public
    USING (auth.role() = 'authenticated');

CREATE POLICY "spot_types: admins manage"
    ON public.spot_types FOR ALL TO public
    USING (public.auth_staff_rank() = 'admin');

-- ============================================================
-- park_boundaries
-- ============================================================
CREATE POLICY "park_boundaries: read own park"
    ON public.park_boundaries FOR SELECT TO public
    USING (
        park_id = public.auth_staff_park_id()
        OR public.auth_staff_rank() = ANY(ARRAY['admin','parks_authority'])
    );

CREATE POLICY "park_boundaries: park_head/admin write"
    ON public.park_boundaries FOR ALL TO public
    USING (public.auth_staff_rank() = ANY(ARRAY['admin','park_head']));

-- ============================================================
-- map_features
-- ============================================================
CREATE POLICY "map_features: rangers read"
    ON public.map_features FOR SELECT TO public
    USING (
        created_by = public.auth_staff_id()
        OR (public.auth_staff_park_id() IS NOT NULL AND park_id = public.auth_staff_park_id())
        OR public.auth_staff_rank() = ANY(ARRAY['admin','park_head','parks_authority'])
    );

CREATE POLICY "map_features: rangers insert"
    ON public.map_features FOR INSERT TO public
    WITH CHECK (created_by = public.auth_staff_id());

CREATE POLICY "map_features: rangers update own incidents"
    ON public.map_features FOR UPDATE TO public
    USING (
        created_by = public.auth_staff_id()
        OR public.auth_staff_rank() = ANY(ARRAY['admin','park_head'])
    );

CREATE POLICY "map_features: park_head/admin delete"
    ON public.map_features FOR DELETE TO public
    USING (public.auth_staff_rank() = ANY(ARRAY['admin','park_head']));
