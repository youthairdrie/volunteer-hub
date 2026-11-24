#!/usr/bin/env python3
"""Local RLS tests for db/el_partner on a throwaway PostgreSQL 16 cluster (synthetic data only).
Usage: python3 tests/el_partner/db_test.py   (needs PostgreSQL 16 binaries; never touches production)"""
import os, subprocess, sys, tempfile, shutil, time

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
BIN = '/usr/lib/postgresql/16/bin'
tmp = tempfile.mkdtemp(prefix='elp_pg_')
PORT = '54329'
os.chown(tmp, *(lambda p: (p.pw_uid, p.pw_gid))(__import__('pwd').getpwnam('postgres'))) if os.geteuid() == 0 else None

def as_pg(cmd):
    return (['su', 'postgres', '-c', ' '.join(cmd)] if os.geteuid() == 0 else cmd)

def psql(sql=None, file=None):
    cmd = ['psql', '-h', tmp, '-p', PORT, '-U', 'postgres', '-d', 'postgres', '-X', '-q', '-tA', '-v', 'ON_ERROR_STOP=1']
    cmd += ['-f', file] if file else ['-c', sql]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode == 0, (r.stdout + r.stderr).strip()

UID = {'admin': 'a', 'adult': 'b', 'youth': 'c', 'partner': 'd', 'partner2': 'e', 'partnerx': 'f'}
def as_user(user, sql):
    if user == 'anon':
        pre = "select set_config('request.jwt.claim.sub','',true); set local role anon;"
    else:
        pre = ("select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000%s',true); "
               "set local role authenticated;" % UID[user])
    ok, out = psql("begin; " + pre + " " + sql + "; rollback;")
    lines = [l for l in out.splitlines() if l and l != '00000000-0000-0000-0000-00000000000' + UID.get(user, '') and l not in ('BEGIN', 'ROLLBACK', 'SET')]
    return ok, '\n'.join(lines)

results = []
def check(name, cond, detail=''):
    results.append((name, bool(cond), detail))
    print(('PASS ' if cond else 'FAIL ') + name + ('' if cond else '  -> ' + str(detail)))

def expect(user, sql, want=None, error=None):
    ok, out = as_user(user, sql)
    name = '%s: %s' % (user, sql)
    if error:
        check(name + '  [denied]', (not ok) and error in out, out)
    else:
        check(name + '  = ' + repr(want), ok and out == want, out)

try:
    subprocess.run(as_pg([BIN + '/initdb', '-D', tmp + '/data', '-U', 'postgres', '--auth=trust']), check=True, capture_output=True)
    subprocess.run(as_pg([BIN + '/pg_ctl', '-D', tmp + '/data', '-l', tmp + '/pg.log',
                          '-o', '"-p %s -k %s -c listen_addresses=\'\'"' % (PORT, tmp), '-w', 'start']),
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for f in ['tests/el_partner/supabase_stub.sql', 'db/release1/01_up.sql']:
        ok, out = psql(file=os.path.join(ROOT, f)); check('apply ' + f, ok, out)

    ok, out = psql(file=os.path.join(ROOT, 'db/el_partner/00_preflight_readonly.sql'))
    check('preflight runs', ok, out)
    for row in out.splitlines():
        if row.split('|')[0] in ('release1_applied', 'el_partner_not_applied', 'hub_is_member_is_release1', 'hub_is_admin_is_release1'):
            check('preflight ' + row.split('|')[0], row.split('|')[1] == 't', row)
        if row.startswith('profiles_role_check_constraint'): check('preflight no role CHECK', False, row)

    # Before EL-P: a partner profile would be a full Hub member (the gap this feature closes)
    expect('partner', 'select public.hub_is_member()', 't')

    ok, out = psql(file=os.path.join(ROOT, 'db/el_partner/01_up.sql')); check('apply db/el_partner/01_up.sql', ok, out)
    ok, out = psql(file=os.path.join(ROOT, 'db/el_partner/01_up.sql')); check('01_up refuses a second run', not ok and 'already applied' in out, out)

    ok, out = psql(file=os.path.join(ROOT, 'db/el_partner/02_verify_readonly.sql'))
    check('verify runs', ok, out)
    bad = [l for l in out.splitlines() if '|f|' in l or l.split('|')[1:2] == ['']]
    check('verify: every check ok', ok and not bad and 'as_partner_not_member|t' in out, bad or out)

    # ── Partner: least privilege ────────────────────────────────────────────
    for t in ['youth', 'workshop_attendance', 'youth_compliance', 'adult_compliance', 'adults',
              'program_settings', 'event_volunteers', 'gcc_roster']:
        expect('partner', 'select count(*) from public.' + t, '0')
    expect('partner', "select string_agg(role, ',') from public.profiles", 'el_partner')
    expect('partner', "select string_agg(id, ',' order by id) from public.site_config", 'el_partner_snapshot,home_content,public_summary')
    expect('partner', "select public.hub_is_member()::text || public.hub_is_admin()::text || public.hub_is_el_partner()::text || public.gcc_is_editor()::text", 'falsefalsetruefalse')
    expect('partner', "insert into public.workshop_attendance(youth_id, workshop_id) values ('yn_test', 2)", error='row-level security')
    expect('partner', "with u as (update public.workshop_attendance set workshop_id = 3 returning 1) select count(*) from u", '0')
    expect('partner', "with d as (delete from public.youth returning 1) select count(*) from d", '0')
    expect('partner', "with u as (update public.profiles set role = 'admin' returning 1) select count(*) from u", '0')
    expect('partner', "insert into public.profiles(email, name, role) values ('evil@example.test', 'x', 'admin')", error='row-level security')
    expect('partner', "with u as (update public.site_config set value = '{}' where id = 'el_partner_snapshot' returning 1) select count(*) from u", '0')
    expect('partner', "insert into public.site_config values ('el_partner_snapshot', '{}') on conflict (id) do update set value = excluded.value", error='row-level security')
    expect('partner', "insert into public.site_config values ('public_summary_x', '{}')", error='row-level security')
    expect('partner', "insert into public.gcc_roster(name) values ('x')", error='row-level security')
    # partner linked to an admin adult record still gets nothing
    expect('partner2', "select public.hub_is_member()::text || public.hub_is_admin()::text || public.hub_is_el_partner()::text", 'falsefalsetrue')
    expect('partner2', 'select count(*) from public.youth', '0')
    # unconfirmed or deactivated partner: not even the snapshot
    expect('partnerx', "select count(*) from public.site_config where id = 'el_partner_snapshot'", '0')
    expect('partner', "select set_config('request.jwt.claim.sub','',true); reset role; update public.profiles set active = false where email = 'partner@example.test'; "
                      "select set_config('request.jwt.claim.sub','00000000-0000-0000-0000-00000000000d',true); set local role authenticated; "
                      "select count(*) from public.site_config where id = 'el_partner_snapshot'", '0')

    # ── Anonymous ───────────────────────────────────────────────────────────
    expect('anon', "select string_agg(id, ',' order by id) from public.site_config", 'home_content,public_summary')
    expect('anon', 'select count(*) from public.youth', error='permission denied')
    expect('anon', 'select public.hub_is_el_partner()', error='permission denied')

    # ── Existing roles unchanged; none gain partner access ─────────────────
    expect('admin', "select public.hub_is_member()::text || public.hub_is_admin()::text || public.hub_is_el_partner()::text", 'truetruefalse')
    expect('admin', 'select count(*) from public.youth', '2')
    expect('admin', "select count(*) from public.site_config", '4')
    expect('admin', "with u as (insert into public.site_config values ('el_partner_snapshot', '{\"v\":1}') on conflict (id) do update set value = excluded.value returning 1) select count(*) from u", '1')
    expect('admin', "with u as (update public.workshop_attendance set workshop_id = 2 returning 1) select count(*) from u", '2')
    for u in ['adult', 'youth']:
        expect(u, "select public.hub_is_member()::text || public.hub_is_admin()::text || public.hub_is_el_partner()::text", 'truefalsefalse')
        expect(u, "select count(*) from public.site_config where id = 'el_partner_snapshot'", '0')
        expect(u, 'select count(*) from public.youth', '2')   # pre-existing broad member access (out of scope)

    # ── Rollback ─────────────────────────────────────────────────────────────
    ok, out = psql(file=os.path.join(ROOT, 'db/el_partner/99_rollback.sql'))
    check('rollback refuses while partners are active', not ok and 'deactivate' in out, out)
    psql("update public.profiles set active = false where role = 'el_partner'")
    ok, out = psql(file=os.path.join(ROOT, 'db/el_partner/99_rollback.sql')); check('rollback applies', ok, out)
    ok, out = psql("select count(*) from pg_policies where policyname = 'elp_site_config_partner_read'"); check('rollback removed policy', out == '0', out)
    ok, out = psql("select count(*) from public.site_config where id = 'el_partner_snapshot'"); check('rollback removed snapshot', out == '0', out)
    ok, out = psql(file=os.path.join(ROOT, 'db/el_partner/00_preflight_readonly.sql'))
    check('rollback restored Release 1 helpers', 'hub_is_member_is_release1|t' in out and 'hub_is_admin_is_release1|t' in out, out)
    ok, out = psql(file=os.path.join(ROOT, 'db/el_partner/01_up.sql')); check('re-apply after rollback', ok, out)
finally:
    subprocess.run(as_pg([BIN + '/pg_ctl', '-D', tmp + '/data', '-m', 'immediate', 'stop']), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    shutil.rmtree(tmp, ignore_errors=True)

failed = [r for r in results if not r[1]]
print('\n%d passed, %d failed' % (len(results) - len(failed), len(failed)))
sys.exit(1 if failed else 0)
