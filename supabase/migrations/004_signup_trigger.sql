-- ============================================================
-- Migration 004: Auto-create staff row on auth user sign-up
-- Runs as SECURITY DEFINER (superuser) — bypasses RLS.
-- ============================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
BEGIN
    INSERT INTO public.staff (user_id, email, first_name, last_name, rank, is_active)
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'first_name', 'Ranger'),
        COALESCE(NEW.raw_user_meta_data->>'last_name', ''),
        'ranger',
        true
    )
    ON CONFLICT (email) DO NOTHING;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Drop existing trigger if re-running
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();
