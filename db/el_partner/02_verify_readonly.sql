-- EL-P — VERIFY (read-only; run after 01_up.sql). Every row should show ok = true.
-- Part A: static checks. Part B (only once a partner account exists): acts as the
-- first active partner inside a transaction that is always rolled back, and
-- counts what that account can see. Only counts are returned — no names.

-- ── Part A ─────────────────────────────────────────────────────────────────
select 'helpers_exclude_el_partner' as check,
       (select prosrc from pg_proc where oid = 'public.hub_is_member()'::regprocedure) like '%el_partner%'
   and (select prosrc from pg_proc where oid = 'public.hub_is_admin()'::regprocedure)  like '%el_partner%' as ok,
       'hub_is_member() and hub_is_admin() exclude el_partner' as detail
union all
select 'hub_is_el_partner_locked', p.prosecdef
   and array_to_string(p.proconfig, ',') = 'search_path=""'
   and not has_function_privilege('anon', p.oid, 'EXECUTE')
   and has_function_privilege('authenticated', p.oid, 'EXECUTE'),
       'security definer, empty search_path, authenticated only'
  from pg_proc p where p.oid = 'public.hub_is_el_partner()'::regprocedure
union all
select 'partner_policy', count(*) = 1, string_agg(policyname || ' USING ' || qual, '; ')
  from pg_policies where schemaname = 'public' and tablename = 'site_config' and policyname = 'elp_site_config_partner_read'
union all
select 'anon_cannot_read_snapshot', not exists (
         select 1 from pg_policies where schemaname = 'public' and tablename = 'site_config'
            and 'anon' = any (roles) and qual like '%el_partner_snapshot%'),
       'public site_config policy does not include el_partner_snapshot'
union all
select 'partner_accounts', true, count(*)::text || ' active el_partner profile(s)'
  from public.profiles where role = 'el_partner' and coalesce(active, true)
order by 1;

-- ── Part B ─────────────────────────────────────────────────────────────────
begin;
create temp table elp_check (check_name text, ok boolean, detail text) on commit drop;
grant insert, select on elp_check to authenticated;
select set_config('request.jwt.claim.sub', coalesce((
         select u.id::text from auth.users u join public.profiles p on lower(p.email) = lower(u.email)
          where p.role = 'el_partner' and coalesce(p.active, true) and u.email_confirmed_at is not null
          order by u.created_at limit 1), ''), true);
select set_config('request.jwt.claims', json_build_object(
         'sub', current_setting('request.jwt.claim.sub', true), 'role', 'authenticated')::text, true);
set local role authenticated;
do $$
declare t text; n bigint; tables text[] := array[
  'adult_compliance','adult_scrabble_sessions','adults','event_registrations','event_volunteers',
  'name_aliases','pending_entries','program_attendance','program_cancellations','program_session_meta',
  'program_settings','program_volunteers','scrabble_scores','scrabble_sessions','scrabble_state',
  'service_project_participants','service_projects','workshop_attendance','workshop_cancellations',
  'workshop_conducted','youth','youth_compliance','gcc_quarters','gcc_roster','gcc_session_results',
  'gcc_volunteer_hours'];
begin
  if current_setting('request.jwt.claim.sub', true) = '' then
    insert into elp_check values ('as_partner', null, 'no confirmed active partner account yet — rerun Part B after creating it');
    return;
  end if;
  insert into elp_check values
    ('as_partner_is_el_partner', public.hub_is_el_partner(), 'hub_is_el_partner() = true'),
    ('as_partner_not_member',    not public.hub_is_member(), 'hub_is_member() = false'),
    ('as_partner_not_admin',     not public.hub_is_admin(),  'hub_is_admin() = false');
  begin
    insert into elp_check select 'as_partner_not_gcc_editor', not public.gcc_is_editor(), 'gcc_is_editor() = false';
  exception when undefined_function then
    insert into elp_check values ('as_partner_not_gcc_editor', true, 'gcc_is_editor() not present');
  end;
  foreach t in array tables loop
    begin
      execute format('select count(*) from public.%I', t) into n;
      insert into elp_check values ('as_partner_rows_' || t, n = 0, n || ' row(s) visible');
    exception when undefined_table then null;
              when insufficient_privilege then insert into elp_check values ('as_partner_rows_' || t, true, 'no privilege');
    end;
  end loop;
  select count(*) into n from public.profiles;
  insert into elp_check values ('as_partner_profiles', n = 1, n || ' profile row(s) visible (own row only)');
  select count(*) into n from public.site_config where id not in ('home_content','public_summary','el_partner_snapshot');
  insert into elp_check values ('as_partner_site_config_other', n = 0, n || ' other site_config row(s) visible');
  select count(*) into n from public.site_config where id = 'el_partner_snapshot';
  insert into elp_check values ('as_partner_snapshot', true, n || ' snapshot row visible (1 once an admin has signed in on the new app)');
end $$;
select * from elp_check order by ok nulls first, check_name;
rollback;
