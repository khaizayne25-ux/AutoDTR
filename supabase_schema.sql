-- =============================================================================
-- AutoDTR by: Juan Database Schema, Storage Bucket & Row Level Security Policies
-- Copy and paste this entire script into your Supabase SQL Editor and run it.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -----------------------------------------------------------------------------
-- 1. Tables
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  employee_id TEXT UNIQUE NOT NULL,
  full_name TEXT NOT NULL,
  email TEXT NOT NULL,
  department TEXT NOT NULL DEFAULT 'Operations',
  role TEXT NOT NULL DEFAULT 'employee' CHECK (role IN ('admin', 'employee')),
  shift_start TIME NOT NULL DEFAULT '08:00:00',
  shift_end TIME NOT NULL DEFAULT '17:00:00',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.dtr_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  log_date DATE NOT NULL,
  time_in TIME,
  break_out TIME,
  break_in TIME,
  time_out TIME,
  total_hours NUMERIC(5, 2) NOT NULL DEFAULT 0,
  undertime_minutes INTEGER NOT NULL DEFAULT 0,
  overtime_minutes INTEGER NOT NULL DEFAULT 0,
  photo_url TEXT,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'verified', 'flagged')),
  admin_notes TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE public.dtr_logs
  ADD COLUMN IF NOT EXISTS overtime_minutes INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS public.company_settings (
  id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  company_name TEXT NOT NULL DEFAULT 'Apex Corporate Operations Inc.',
  break_rule_mode TEXT NOT NULL DEFAULT 'auto_threshold'
    CHECK (break_rule_mode IN ('auto_threshold', 'explicit_only', 'fixed_deduction')),
  break_deduction_minutes INTEGER NOT NULL DEFAULT 60,
  auto_break_threshold_hours NUMERIC(4, 2) NOT NULL DEFAULT 6.00,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO public.company_settings (
  id,
  company_name,
  break_rule_mode,
  break_deduction_minutes,
  auto_break_threshold_hours
)
VALUES (1, 'Apex Corporate Operations Inc.', 'auto_threshold', 60, 6.00)
ON CONFLICT (id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_dtr_logs_user_date ON public.dtr_logs (user_id, log_date DESC);
CREATE INDEX IF NOT EXISTS idx_dtr_logs_status ON public.dtr_logs (status, log_date DESC);
CREATE INDEX IF NOT EXISTS idx_profiles_department ON public.profiles (department);

-- -----------------------------------------------------------------------------
-- 2. Admin Helper & Auto-Profile Trigger on Sign Up
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN
LANGUAGE SQL
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = auth.uid() AND role = 'admin'
  );
$$;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  generated_emp_id TEXT;
BEGIN
  generated_emp_id := COALESCE(
    NULLIF(TRIM(NEW.raw_user_meta_data->>'employee_id'), ''),
    'EMP-' || UPPER(SUBSTRING(REPLACE(NEW.id::TEXT, '-', '') FROM 1 FOR 6))
  );

  INSERT INTO public.profiles (
    id,
    employee_id,
    full_name,
    email,
    department,
    role,
    shift_start,
    shift_end
  )
  VALUES (
    NEW.id,
    generated_emp_id,
    COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'full_name'), ''), SPLIT_PART(NEW.email, '@', 1)),
    NEW.email,
    COALESCE(NULLIF(TRIM(NEW.raw_user_meta_data->>'department'), ''), 'Operations'),
    'employee',
    '08:00:00',
    '17:00:00'
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user();

-- -----------------------------------------------------------------------------
-- 3. Row Level Security (RLS) Policies
-- -----------------------------------------------------------------------------

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dtr_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_settings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile"
  ON public.profiles FOR SELECT
  TO authenticated
  USING (auth.uid() = id OR public.is_admin());

DROP POLICY IF EXISTS "Users can update own non-role profile fields" ON public.profiles;
CREATE POLICY "Users can update own non-role profile fields"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND role = (SELECT role FROM public.profiles WHERE id = auth.uid())
  );

DROP POLICY IF EXISTS "Admins can update any profile" ON public.profiles;
CREATE POLICY "Admins can update any profile"
  ON public.profiles FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "Employees view own logs and admins view all" ON public.dtr_logs;
CREATE POLICY "Employees view own logs and admins view all"
  ON public.dtr_logs FOR SELECT
  TO authenticated
  USING (auth.uid() = user_id OR public.is_admin());

DROP POLICY IF EXISTS "Employees can insert own pending logs" ON public.dtr_logs;
CREATE POLICY "Employees can insert own pending logs"
  ON public.dtr_logs FOR INSERT
  TO authenticated
  WITH CHECK (
    auth.uid() = user_id
    AND status = 'pending'
  );

DROP POLICY IF EXISTS "Employees can flag their own logs for review" ON public.dtr_logs;
CREATE POLICY "Employees can flag their own logs for review"
  ON public.dtr_logs FOR UPDATE
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (
    auth.uid() = user_id
    AND status IN ('pending', 'flagged')
  );

DROP POLICY IF EXISTS "Admins can update all DTR logs" ON public.dtr_logs;
CREATE POLICY "Admins can update all DTR logs"
  ON public.dtr_logs FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "Admins can delete DTR logs" ON public.dtr_logs;
CREATE POLICY "Admins can delete DTR logs"
  ON public.dtr_logs FOR DELETE
  TO authenticated
  USING (public.is_admin());

DROP POLICY IF EXISTS "Authenticated users can read company settings" ON public.company_settings;
CREATE POLICY "Authenticated users can read company settings"
  ON public.company_settings FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "Admins can update company settings" ON public.company_settings;
CREATE POLICY "Admins can update company settings"
  ON public.company_settings FOR UPDATE
  TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

DROP POLICY IF EXISTS "Admins can insert company settings" ON public.company_settings;
CREATE POLICY "Admins can insert company settings"
  ON public.company_settings FOR INSERT
  TO authenticated
  WITH CHECK (public.is_admin());

-- -----------------------------------------------------------------------------
-- 4. Supabase Storage Bucket ('dtr-photos') & Policies
-- -----------------------------------------------------------------------------

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'dtr-photos',
  'dtr-photos',
  false,
  524288,
  ARRAY['image/jpeg', 'image/png', 'image/webp']
)
ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

DROP POLICY IF EXISTS "Authenticated users can view dtr-photos" ON storage.objects;
CREATE POLICY "Authenticated users can view dtr-photos"
  ON storage.objects FOR SELECT
  TO authenticated
  USING (bucket_id = 'dtr-photos');

DROP POLICY IF EXISTS "Authenticated users can upload own dtr-photos" ON storage.objects;
CREATE POLICY "Authenticated users can upload own dtr-photos"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (
    bucket_id = 'dtr-photos'
    AND (storage.foldername(name))[1] = auth.uid()::TEXT
  );

DROP POLICY IF EXISTS "Admins or owners can delete dtr-photos" ON storage.objects;
CREATE POLICY "Admins or owners can delete dtr-photos"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (
    bucket_id = 'dtr-photos'
    AND ((storage.foldername(name))[1] = auth.uid()::TEXT OR public.is_admin())
  );

-- Optional: Promote your first user to Admin after signing up:
-- UPDATE public.profiles SET role = 'admin' WHERE email = 'you@company.com';
