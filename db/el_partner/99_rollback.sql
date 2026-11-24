-- ═══════════════════════════════════════════════════════════════════════════
-- EL-P — ROLLBACK of 01_up.sql
-- ═══════════════════════════════════════════════════════════════════════════
-- Restores hub_is_member() / hub_is_admin() exactly as backed up, removes the
-- partner policy and helper, and deletes the partner snapshot row.
-- Redeploy the previous app first (or at the same time) so admins stop
-- republishing the snapshot. Partner profiles should be deactivated or deleted
-- first: after rollback an active 'el_partner' profile would count as a member.
-- One transaction: any error rolls everything back.
-- ═══════════════════════════════════════════════════════════════════════════
begin;

do $$
declare b record;
begin
  if to_regclass('hub_private.elp_backup') is null then
    raise exception 'EL-P backup not found: 01_up.sql is not applied (nothing to roll back)';
  end if;
  if exists (select 1 from public.profiles where role = 'el_partner' and coalesce(active, true)) then
    raise exception 'EL-P: deactivate or delete the active el_partner profile(s) before rolling back';
  end if;
  for b in select def from hub_private.elp_backup loop
    execute b.def;
  end loop;
end $$;

drop policy if exists elp_site_config_partner_read on public.site_config;
drop function if exists public.hub_is_el_partner();
delete from public.site_config where id = 'el_partner_snapshot';
drop table hub_private.elp_backup;

commit;
