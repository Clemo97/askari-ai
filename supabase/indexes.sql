-- ============================================================
-- Askari AI — Indexes
-- Run after schema.sql
-- ============================================================

-- map_features
CREATE UNIQUE INDEX IF NOT EXISTS map_features_pkey             ON public.map_features (id);
CREATE INDEX        IF NOT EXISTS idx_map_features_severity     ON public.map_features (severity);
CREATE INDEX        IF NOT EXISTS idx_map_features_created_at   ON public.map_features (created_at DESC);
CREATE INDEX        IF NOT EXISTS idx_map_features_spot_type    ON public.map_features (spot_type_id);
CREATE INDEX        IF NOT EXISTS idx_map_features_park_id      ON public.map_features (park_id);

-- mission_role_types
CREATE UNIQUE INDEX IF NOT EXISTS mission_role_types_name_key   ON public.mission_role_types (name);
CREATE UNIQUE INDEX IF NOT EXISTS mission_role_types_pkey       ON public.mission_role_types (id);

-- park_boundaries
CREATE UNIQUE INDEX IF NOT EXISTS park_boundaries_pkey          ON public.park_boundaries (id);
CREATE INDEX        IF NOT EXISTS idx_park_boundaries_park_id   ON public.park_boundaries (park_id);

-- parks
CREATE UNIQUE INDEX IF NOT EXISTS parks_pkey                    ON public.parks (id);

-- spot_types
CREATE UNIQUE INDEX IF NOT EXISTS spot_types_pkey               ON public.spot_types (id);
CREATE UNIQUE INDEX IF NOT EXISTS spot_types_code_name_key      ON public.spot_types (code_name);

-- staff
CREATE INDEX        IF NOT EXISTS idx_staff_user_id             ON public.staff (user_id);
CREATE UNIQUE INDEX IF NOT EXISTS staff_email_key               ON public.staff (email);
CREATE INDEX        IF NOT EXISTS idx_staff_rank                ON public.staff (rank);
CREATE UNIQUE INDEX IF NOT EXISTS staff_pkey                    ON public.staff (id);
CREATE UNIQUE INDEX IF NOT EXISTS staff_user_id_key             ON public.staff (user_id);
CREATE INDEX        IF NOT EXISTS idx_staff_park_id             ON public.staff (park_id);
