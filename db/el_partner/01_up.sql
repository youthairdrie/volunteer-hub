-- ═══════════════════════════════════════════════════════════════════════════
-- EL-P — Emerging Leader Partner (role 'el_partner'): read-only Workshops access
-- ═══════════════════════════════════════════════════════════════════════════
-- Run AFTER 00_preflight_readonly.sql passes. One transaction; undo with 99_rollback.sql.
-- Safe to run before or after the app deploy: existing roles are unchanged.
--
--   • hub_is_member() / hub_is_admin(): an 'el_partner' profile is never a Hub
--     member or admin, so partners get NO access to any Hub table (all their
--     reads return nothing and all writes fail), whatever the browser sends.
--   • hub_is_el_partner(): new helper (same pattern as the Release 1 helpers).
--   • site_config: active partners may SELECT exactly one row,
--     'el_partner_snapshot'. Only admins can write it (existing admin policy).
--   • Partners still read only their own profiles row (existing policy) and
--     cannot change it (only admins write profiles).
--   • Follow-up: 03_gcc_quarters_partner_exclusion.sql (also applied in production)
--     hides gcc_quarters from partners.
-- The migration stops (and changes nothing) if the helpers differ from the
-- Release 1 definitions it expects, or if profiles has a role CHECK constraint.
-- ═══════════════════════════════════════════════════════════════════════════
begin;

do $$
declare
  want_member text := 'select exists ( select 1 from public.profiles p where lower(p.email) = public.hub_confirmed_email() and coalesce(p.active, true))';
  want_admin  text := 'select exists ( select 1 from public.profiles p where lower(p.email) = public.hub_confirmed_email() and coalesce(p.active, true) and (p.role = ''admin'' or exists (select 1 from public.adults a where a.id = p.linked_id and coalesce(a.is_admin, false))))';
  have text;
begin
  if to_regclass('hub_private.sec2_backup') is null then
    raise exception 'EL-P: Release 1 (SEC-2) is not applied';
  end if;
  if to_regclass('hub_private.elp_backup') is not null then
    raise exception 'EL-P: already applied (run 99_rollback.sql first to re-apply)';
  end if;
  select btrim(regexp_replace(prosrc, '\s+', ' ', 'g')) into have
    from pg_proc where oid = 'public.hub_is_member()'::regprocedure;
  if have is distinct from want_member then
    raise exception 'EL-P: public.hub_is_member() differs from Release 1 — review before applying. Found: %', have;
  end if;
  select btrim(regexp_replace(prosrc, '\s+', ' ', 'g')) into have
    from pg_proc where oid = 'public.hub_is_admin()'::regprocedure;
  if have is distinct from want_admin then
    raise exception 'EL-P: public.hub_is_admin() differs from Release 1 — review before applying. Found: %', have;
  end if;
  if exists (select 1 from pg_constraint
              where conrelid = 'public.profiles'::regclass and contype = 'c'
                and pg_get_constraintdef(oid) ilike '%role%') then
    raise exception 'EL-P: public.profiles has a CHECK constraint on role — review before applying';
  end if;
end $$;

-- Back up the two helper definitions for 99_rollback.sql.
create table hub_private.elp_backup (
  fn       text primary key,
  def      text not null,
  taken_at timestamptz not null default now()
);
revoke all on hub_private.elp_backup from public;
insert into hub_private.elp_backup(fn, def)
select p.proname, pg_get_functiondef(p.oid)
  from pg_proc p
 where p.oid in ('public.hub_is_member()'::regprocedure, 'public.hub_is_admin()'::regprocedure);

-- ── Helpers: partners are never members or admins ──────────────────────────
create or replace function public.hub_is_member()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where lower(p.email) = public.hub_confirmed_email()
       and coalesce(p.active, true)
       and p.role is distinct from 'el_partner')
$$;

create or replace function public.hub_is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where lower(p.email) = public.hub_confirmed_email()
       and coalesce(p.active, true)
       and p.role is distinct from 'el_partner'
       and (p.role = 'admin'
            or exists (select 1 from public.adults a
                        where a.id = p.linked_id and coalesce(a.is_admin, false))))
$$;

create or replace function public.hub_is_el_partner()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
     where lower(p.email) = public.hub_confirmed_email()
       and coalesce(p.active, true)
       and p.role = 'el_partner')
$$;

revoke all on function public.hub_is_el_partner() from public, anon;
grant execute on function public.hub_is_el_partner() to authenticated;

-- ── The one row partners may read ──────────────────────────────────────────
create policy elp_site_config_partner_read on public.site_config
  for select to authenticated
  using (id = 'el_partner_snapshot' and (select public.hub_is_el_partner()));

-- Self-test: fails (and rolls back) if the helpers cannot run.
do $$ begin perform public.hub_is_member(); perform public.hub_is_admin(); perform public.hub_is_el_partner(); end $$;

commit;
