-- ═══════════════════════════════════════════════════════════════════════════
-- SEC-2 Release 1 — close anonymous access to private Hub data
-- ═══════════════════════════════════════════════════════════════════════════
-- Run ONLY after the Release 1 app is live and verified (it sends the signed-in
-- user's token for every private request). Runs as ONE transaction: any error
-- rolls everything back. Undo with 99_rollback.sql.
--
-- After this migration:
--   • anon: no access to any Hub table, except SELECT on the two public
--     site_config rows ('home_content', 'public_summary').
--   • authenticated: Hub tables only when the user is a Hub member — a
--     confirmed Supabase Auth user whose email matches an active profiles row.
--   • profiles: each member reads only their own row; admins manage all rows.
--   • site_config: public rows readable by anyone; writes by admins only.
--   • gcc_* tables: their existing editor policies are left unchanged; only
--     anon table privileges are removed.
-- Known temporary risk (next phase): any signed-in member can still read all
-- Hub records through the API, because the app filters data in the browser.
-- ═══════════════════════════════════════════════════════════════════════════
begin;

create schema if not exists hub_private;

create table hub_private.sec2_backup (
  kind     text not null,         -- 'rls' | 'policy' | 'grant'
  tbl      text not null,
  data     jsonb not null,
  taken_at timestamptz not null default now()
);
revoke all on hub_private.sec2_backup from public;
-- (create table fails if Release 1 was already applied: run 99_rollback.sql first)

-- ── Identity helpers (same pattern as public.gcc_is_editor) ────────────────
create or replace function public.hub_confirmed_email()
returns text language sql stable security definer set search_path = ''
as $$
  select lower(u.email) from auth.users u
   where u.id = auth.uid() and u.email_confirmed_at is not null
$$;

create or replace function public.hub_is_member()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where lower(p.email) = public.hub_confirmed_email()
       and coalesce(p.active, true))
$$;

create or replace function public.hub_is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where lower(p.email) = public.hub_confirmed_email()
       and coalesce(p.active, true)
       and (p.role = 'admin'
            or exists (select 1 from public.adults a
                        where a.id = p.linked_id and coalesce(a.is_admin, false))))
$$;

revoke all on function public.hub_confirmed_email() from public, anon;
revoke all on function public.hub_is_member()       from public, anon;
revoke all on function public.hub_is_admin()        from public, anon;
grant execute on function public.hub_confirmed_email() to authenticated;
grant execute on function public.hub_is_member()       to authenticated;
grant execute on function public.hub_is_admin()        to authenticated;

-- Self-test: fails (and rolls back) if the helpers cannot read auth.users.
do $$ begin perform public.hub_is_member(); perform public.hub_is_admin(); end $$;

-- ── Lock down tables ───────────────────────────────────────────────────────
do $$
declare
  hub_tables text[] := array[
    'adult_compliance','adult_scrabble_sessions','adults','event_registrations',
    'event_volunteers','name_aliases','pending_entries','program_attendance',
    'program_cancellations','program_session_meta','program_settings',
    'program_volunteers','scrabble_scores','scrabble_sessions','scrabble_state',
    'service_project_participants','service_projects','workshop_attendance',
    'workshop_cancellations','workshop_conducted','youth','youth_compliance'];
  gcc_tables text[] := array['gcc_quarters','gcc_roster','gcc_session_results','gcc_volunteer_hours'];
  special    text[] := array['profiles','site_config'];
  t text; rel oid; pol record; missing text[] := '{}';
begin
  foreach t in array hub_tables || gcc_tables || special loop
    select c.oid into rel from pg_class c
     where c.relname = t and c.relnamespace = 'public'::regnamespace and c.relkind in ('r','p');
    if rel is null then missing := missing || t; continue; end if;

    -- Back up RLS flags and the anon/authenticated table grants.
    insert into hub_private.sec2_backup(kind, tbl, data)
    select 'rls', t, jsonb_build_object('enabled', c.relrowsecurity, 'forced', c.relforcerowsecurity)
      from pg_class c where c.oid = rel;
    insert into hub_private.sec2_backup(kind, tbl, data)
    select 'grant', t, jsonb_build_object('role', r.rolname, 'privilege', a.privilege_type,
                                          'grantable', a.is_grantable)
      from pg_class c
      cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) a
      join pg_roles r on r.oid = a.grantee
     where c.oid = rel and r.rolname in ('anon', 'authenticated');

    -- Nobody signed out reads or writes Hub tables.
    execute format('revoke all on public.%I from anon', t);

    if t = any (gcc_tables) then
      continue;   -- keep the Games & Crafts editor policies exactly as they are
    end if;

    -- Back up, then remove, the existing (permissive) policies.
    for pol in select * from pg_policies where schemaname = 'public' and tablename = t loop
      insert into hub_private.sec2_backup(kind, tbl, data) values ('policy', t, to_jsonb(pol));
      execute format('drop policy %I on public.%I', pol.policyname, t);
    end loop;

    execute format('alter table public.%I enable row level security', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);

    if t = 'profiles' then
      execute $p$create policy sec2_profiles_self_select on public.profiles
                 for select to authenticated
                 using (lower(email) = (select public.hub_confirmed_email()))$p$;
      execute $p$create policy sec2_profiles_admin_all on public.profiles
                 for all to authenticated
                 using ((select public.hub_is_admin())) with check ((select public.hub_is_admin()))$p$;
    elsif t = 'site_config' then
      execute 'grant select on public.site_config to anon';
      execute $p$create policy sec2_site_config_public_read on public.site_config
                 for select to anon, authenticated
                 using (id in ('home_content', 'public_summary'))$p$;
      execute $p$create policy sec2_site_config_admin_all on public.site_config
                 for all to authenticated
                 using ((select public.hub_is_admin())) with check ((select public.hub_is_admin()))$p$;
    else
      execute format($p$create policy sec2_hub_member_all on public.%I
                        for all to authenticated
                        using ((select public.hub_is_member()))
                        with check ((select public.hub_is_member()))$p$, t);
    end if;
  end loop;

  if array_length(missing, 1) > 0 then
    raise notice 'SEC-2: tables not found (skipped): %', array_to_string(missing, ', ');
  end if;
end $$;

commit;
