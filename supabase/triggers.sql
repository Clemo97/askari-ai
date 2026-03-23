-- ============================================================
-- Askari AI — Triggers
-- Run after functions.sql
-- ============================================================

-- Keep updated_at current on map_features
CREATE TRIGGER set_map_features_updated_at
    BEFORE UPDATE ON public.map_features
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- Keep updated_at current on parks
CREATE TRIGGER set_parks_updated_at
    BEFORE UPDATE ON public.parks
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- Keep updated_at current on staff
CREATE TRIGGER set_staff_updated_at
    BEFORE UPDATE ON public.staff
    FOR EACH ROW EXECUTE FUNCTION public.trigger_set_updated_at();

-- Auto-create a staff record whenever a new auth user signs up.
-- Requires a privileged role (service role / superuser).
-- The Supabase dashboard SQL editor runs as superuser — paste this there.
-- CREATE TRIGGER on_auth_user_created
--     AFTER INSERT ON auth.users
--     FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
