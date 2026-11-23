-- SEC-2 Release 1 — PREFLIGHT (read-only; run in the Supabase SQL Editor before 01_up.sql)
-- Returns one row per check. Every row should show ok = true, or be reviewed.
-- No youth or volunteer data is returned: counts and object names only.
with hub(t) as (values
  ('adult_compliance'),('adult_scrabble_sessions'),('adults'),('event_registrations'),
  ('event_volunteers'),('name_aliases'),('pending_entries'),('program_attendance'),
  ('program_cancellations'),('program_session_meta'),('program_settings'),
  ('program_volunteers'),('scrabble_scores'),('scrabble_sessions'),('scrabble_state'),
  ('service_project_participants'),('service_projects'),('workshop_attendance'),
  ('workshop_cancellations'),('workshop_conducted'),('youth'),('youth_compliance'),
  ('gcc_quarters'),('gcc_roster'),('gcc_session_results'),('gcc_volunteer_hours'),
  ('profiles'),('site_config')),
need(t, col) as (values
  ('profiles','email'),('profiles','role'),('profiles','linked_id'),('profiles','active'),
  ('adults','id'),('adults','is_admin'),('site_config','id'),('site_config','value'))
-- 1. Release 1 not already applied
select 'release1_not_applied' as check, (to_regclass('hub_private.sec2_backup') is null) as ok,
       'hub_private.sec2_backup must not exist yet' as detail
union all
-- 2. Tables the migration covers that do not exist (skipped by the migration)
select 'missing_table', false, t from hub where to_regclass('public.' || quote_ident(t)) is null
union all
-- 3. Columns the helper functions and policies rely on
select 'required_column', exists (select 1 from information_schema.columns c
        where c.table_schema = 'public' and c.table_name = need.t and c.column_name = need.col),
       need.t || '.' || need.col from need
union all
-- 4. OTHER public tables/views that anon can read today (not covered by this migration)
select 'other_anon_readable_object', false, c.relname || ' (' || c.relkind::text || ')'
  from pg_class c
 where c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p','v','m','f')
   and c.relname not in (select t from hub)
   and has_table_privilege('anon', c.oid, 'SELECT')
union all
-- 5. At least one admin will be able to sign in afterwards
select 'confirmed_active_admins',
       count(*) > 0, count(*)::text || ' confirmed, active admin account(s)'
  from public.profiles p join auth.users u on lower(u.email) = lower(p.email)
 where u.email_confirmed_at is not null and coalesce(p.active, true)
   and (p.role = 'admin' or exists (select 1 from public.adults a
                                     where a.id = p.linked_id and coalesce(a.is_admin, false)))
union all
-- 6. Active profiles with no confirmed sign-in account (cannot sign in; and if
--    public sign-ups are enabled without email confirmation, someone could claim one)
select 'profiles_without_confirmed_login', count(*) = 0,
       count(*)::text || ' active profile(s) without a confirmed Auth user'
  from public.profiles p
 where coalesce(p.active, true)
   and not exists (select 1 from auth.users u
                    where lower(u.email) = lower(p.email) and u.email_confirmed_at is not null)
union all
-- 7. Duplicate profile emails (one person must map to one profile)
select 'duplicate_profile_emails', count(*) = 0, count(*)::text || ' duplicated email(s)'
  from (select lower(email) from public.profiles group by 1 having count(*) > 1) d
order by 1, 3;
