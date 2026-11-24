-- EL-P — PREFLIGHT (read-only; run in the Supabase SQL Editor before 01_up.sql)
-- One row per check. Every row should show ok = true, or be reviewed.
-- No youth or volunteer data is returned: counts and object definitions only.
select 'release1_applied' as check, (to_regclass('hub_private.sec2_backup') is not null) as ok,
       'hub_private.sec2_backup must exist' as detail
union all
select 'el_partner_not_applied', to_regclass('hub_private.elp_backup') is null,
       'hub_private.elp_backup must not exist yet'
union all
-- 01_up.sql refuses to run if these differ from Release 1; review "detail" if ok = false.
select 'hub_is_member_is_release1',
       btrim(regexp_replace(prosrc, '\s+', ' ', 'g')) =
       'select exists ( select 1 from public.profiles p where lower(p.email) = public.hub_confirmed_email() and coalesce(p.active, true))',
       btrim(regexp_replace(prosrc, '\s+', ' ', 'g'))
  from pg_proc where oid = to_regprocedure('public.hub_is_member()')
union all
select 'hub_is_admin_is_release1',
       btrim(regexp_replace(prosrc, '\s+', ' ', 'g')) =
       'select exists ( select 1 from public.profiles p where lower(p.email) = public.hub_confirmed_email() and coalesce(p.active, true) and (p.role = ''admin'' or exists (select 1 from public.adults a where a.id = p.linked_id and coalesce(a.is_admin, false))))',
       btrim(regexp_replace(prosrc, '\s+', ' ', 'g'))
  from pg_proc where oid = to_regprocedure('public.hub_is_admin()')
union all
select 'profiles_role_check_constraint', false, conname || ': ' || pg_get_constraintdef(oid)
  from pg_constraint
 where conrelid = 'public.profiles'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%role%'
union all
select 'existing_roles', true, coalesce(string_agg(role || ' = ' || n, ', ' order by role), 'none')
  from (select role, count(*) n from public.profiles group by role) r
union all
-- REVIEW: Games & Crafts tables keep their own editor policies (not Hub-member based).
-- Confirm this definition does NOT treat any active profile as an editor.
select 'review_gcc_is_editor', null,
       coalesce((select pg_get_functiondef(p.oid) from pg_proc p
                  where p.pronamespace = 'public'::regnamespace and p.proname = 'gcc_is_editor' limit 1),
                'not found')
union all
-- REVIEW: every policy that is not one of the Release 1 / gcc ones. Partners must not match any.
select 'review_other_policy', null, tablename || '.' || policyname || ' [' || cmd || '] ' ||
       array_to_string(roles, ',') || ' USING ' || coalesce(qual, '-') || ' CHECK ' || coalesce(with_check, '-')
  from pg_policies
 where schemaname = 'public' and policyname not like 'sec2\_%' and tablename not like 'gcc\_%'
union all
-- REVIEW: SECURITY DEFINER functions signed-in users can call (partners can call them too).
select 'review_definer_function_callable_by_authenticated', null, p.oid::regprocedure::text
  from pg_proc p
 where p.pronamespace = 'public'::regnamespace and p.prosecdef
   and has_function_privilege('authenticated', p.oid, 'EXECUTE')
   and p.proname not in ('hub_confirmed_email','hub_is_member','hub_is_admin','gcc_is_editor')
order by 1, 3;
