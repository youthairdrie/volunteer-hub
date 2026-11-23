-- SEC-2 Release 1 — VERIFY (read-only; run after 01_up.sql)
-- One row per table. Expected: anon_can is empty everywhere except
-- site_config = 'SELECT'; rls_enabled = true; policies are the sec2_* ones
-- (gcc_* tables keep their original policies).
with t(name) as (values
  ('adult_compliance'),('adult_scrabble_sessions'),('adults'),('event_registrations'),
  ('event_volunteers'),('name_aliases'),('pending_entries'),('program_attendance'),
  ('program_cancellations'),('program_session_meta'),('program_settings'),
  ('program_volunteers'),('scrabble_scores'),('scrabble_sessions'),('scrabble_state'),
  ('service_project_participants'),('service_projects'),('workshop_attendance'),
  ('workshop_cancellations'),('workshop_conducted'),('youth'),('youth_compliance'),
  ('gcc_quarters'),('gcc_roster'),('gcc_session_results'),('gcc_volunteer_hours'),
  ('profiles'),('site_config'))
select
  t.name as table_name,
  c.relrowsecurity as rls_enabled,
  concat_ws(', ',
    case when has_table_privilege('anon', c.oid, 'SELECT') then 'SELECT' end,
    case when has_table_privilege('anon', c.oid, 'INSERT') then 'INSERT' end,
    case when has_table_privilege('anon', c.oid, 'UPDATE') then 'UPDATE' end,
    case when has_table_privilege('anon', c.oid, 'DELETE') then 'DELETE' end) as anon_can,
  (select string_agg(p.policyname || ' [' || p.cmd || '] ' || array_to_string(p.roles, ','), E'\n'
                     order by p.policyname)
     from pg_policies p where p.schemaname = 'public' and p.tablename = t.name) as policies,
  case
    when c.oid is null then 'SKIPPED (table not found)'
    when t.name = 'site_config' and has_table_privilege('anon', c.oid, 'SELECT')
         and not has_table_privilege('anon', c.oid, 'INSERT') and c.relrowsecurity then 'PASS'
    when t.name <> 'site_config' and not has_table_privilege('anon', c.oid, 'SELECT')
         and not has_table_privilege('anon', c.oid, 'INSERT')
         and not has_table_privilege('anon', c.oid, 'UPDATE')
         and not has_table_privilege('anon', c.oid, 'DELETE') then 'PASS'
    else 'FAIL'
  end as result
from t
left join pg_class c on c.relname = t.name and c.relnamespace = 'public'::regnamespace
order by (case when c.oid is null then 1 else 0 end), t.name;
