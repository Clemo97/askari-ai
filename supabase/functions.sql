-- ============================================================
-- Askari AI — Helper Functions
-- Run after schema.sql and indexes.sql
-- ============================================================

-- Returns the staff row id for the currently authenticated user
CREATE OR REPLACE FUNCTION public.auth_staff_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT id FROM public.staff WHERE user_id = auth.uid() LIMIT 1;
$$;

-- Returns the park_id for the currently authenticated user
CREATE OR REPLACE FUNCTION public.auth_staff_park_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT park_id FROM public.staff WHERE user_id = auth.uid() LIMIT 1;
$$;

-- Returns the rank for the currently authenticated user
CREATE OR REPLACE FUNCTION public.auth_staff_rank()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
AS $$
  SELECT rank FROM public.staff WHERE user_id = auth.uid() LIMIT 1;
$$;

-- Generic updated_at helper (used by multiple triggers)
CREATE OR REPLACE FUNCTION public.trigger_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

-- On new auth.users row: create a staff record with safe defaults.
-- Reads optional metadata: first_name, last_name, rank.
-- Assigns the earliest-created park as default park_id.
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  requested_rank TEXT;
  allowed_ranks  TEXT[] := ARRAY['ranger','supervisor','park_head','admin','parks_authority'];
  default_park   UUID;
BEGIN
  requested_rank := COALESCE(NEW.raw_user_meta_data->>'rank', 'ranger');
  IF requested_rank != ALL(allowed_ranks) THEN
    requested_rank := 'ranger';
  END IF;

  SELECT id INTO default_park FROM public.parks ORDER BY created_at LIMIT 1;

  INSERT INTO public.staff (user_id, email, first_name, last_name, rank, park_id, is_active)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'first_name', 'Ranger'),
    COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
    requested_rank,
    default_park,
    TRUE
  )
  ON CONFLICT (email) DO NOTHING;

  RETURN NEW;
END;
$$;
