-- ═══════════════════════════════════════════════════════════════════════════
-- EL-P addendum — Emerging Leader Partners cannot read gcc_quarters
-- ═══════════════════════════════════════════════════════════════════════════
-- Applied in production after 01_up.sql (2026-11-25). Run after 01_up.sql.
-- gcc_quarters_read let every signed-in user read gcc_quarters, which includes
-- status_changed_by_email (staff email). This keeps that access for everyone
-- except active el_partner accounts. Partners could already not write it
-- (insert/update require gcc_is_editor()). One transaction; undone by 99_rollback.sql.
-- ═══════════════════════════════════════════════════════════════════════════
begin;
do $$ begin
  if not exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'gcc_quarters'
                  and policyname = 'gcc_quarters_read' and cmd = 'SELECT' and qual = 'true') then
    raise exception 'Stopped: gcc_quarters_read is not the expected "USING true" policy (nothing changed)';
  end if;
end $$;
alter policy gcc_quarters_read on public.gcc_quarters
  using (not (select public.hub_is_el_partner()));
commit;
select policyname, qual from pg_policies where schemaname = 'public' and tablename = 'gcc_quarters' and policyname = 'gcc_quarters_read';
