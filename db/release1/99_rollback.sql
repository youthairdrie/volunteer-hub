-- ═══════════════════════════════════════════════════════════════════════════
-- SEC-2 Release 1 — ROLLBACK of 01_up.sql
-- ═══════════════════════════════════════════════════════════════════════════
-- Restores, from hub_private.sec2_backup, exactly what 01_up.sql changed:
-- the original policies, RLS flags and anon/authenticated table grants. Then
-- removes the SEC-2 policies, helper functions and backup table.
-- WARNING: this re-opens anonymous access to private data. Use only to restore
-- service, and only together with redeploying the previous app if needed
-- (the Release 1 app keeps working either way).
-- One transaction: any error rolls everything back.
-- ═══════════════════════════════════════════════════════════════════════════
begin;

do $$
declare
  b record; t text; pol jsonb; roles text; stmt text;
begin
  if to_regclass('hub_private.sec2_backup') is null then
    raise exception 'SEC-2 backup not found: Release 1 is not applied (nothing to roll back)';
  end if;

  for t in select distinct tbl from hub_private.sec2_backup loop
    if to_regclass(format('public.%I', t)) is null then continue; end if;

    -- 1. Remove the policies SEC-2 created.
    for b in select policyname from pg_policies
              where schemaname = 'public' and tablename = t and policyname like 'sec2\_%' loop
      execute format('drop policy %I on public.%I', b.policyname, t);
    end loop;

    -- 2. Restore the original policies.
    for pol in select data from hub_private.sec2_backup where kind = 'policy' and tbl = t loop
      select string_agg(case when r = 'public' then 'public' else quote_ident(r) end, ', ')
        into roles from jsonb_array_elements_text(pol->'roles') r;
      stmt := format('create policy %I on public.%I as %s for %s to %s',
                     pol->>'policyname', t, pol->>'permissive', pol->>'cmd', roles);
      if pol->>'qual'       is not null then stmt := stmt || ' using (' || (pol->>'qual') || ')'; end if;
      if pol->>'with_check' is not null then stmt := stmt || ' with check (' || (pol->>'with_check') || ')'; end if;
      execute stmt;
    end loop;

    -- 3. Restore the original anon/authenticated table grants.
    execute format('revoke all on public.%I from anon, authenticated', t);
    for b in select data from hub_private.sec2_backup where kind = 'grant' and tbl = t loop
      execute format('grant %s on public.%I to %I%s', b.data->>'privilege', t, b.data->>'role',
                     case when (b.data->>'grantable')::boolean then ' with grant option' else '' end);
    end loop;

    -- 4. Restore the original RLS flags.
    for b in select data from hub_private.sec2_backup where kind = 'rls' and tbl = t loop
      execute format('alter table public.%I %s row level security', t,
                     case when (b.data->>'enabled')::boolean then 'enable' else 'disable' end);
      execute format('alter table public.%I %s row level security', t,
                     case when (b.data->>'forced')::boolean then 'force' else 'no force' end);
    end loop;
  end loop;
end $$;

drop function if exists public.hub_is_admin();
drop function if exists public.hub_is_member();
drop function if exists public.hub_confirmed_email();
drop table hub_private.sec2_backup;

commit;
