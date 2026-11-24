// Playwright UI test for the Emerging Leader Partner view. Supabase is fully
// mocked with SYNTHETIC data; nothing leaves this machine.
// Usage: node tests/el_partner/ui_test.js
const { chromium, devices } = require('playwright');
const http = require('http'), fs = require('fs'), path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SUPA = 'https://odrnxozxiacbqnfhxkqm.supabase.co';
let pass = 0, fail = 0;
const check = (name, cond, detail) => { if (cond) { pass++; console.log('PASS ' + name); } else { fail++; console.log('FAIL ' + name + (detail !== undefined ? '  -> ' + JSON.stringify(detail) : '')); } };

const USERS = {
  'admin@example.test':   { id: '00000000-0000-0000-0000-00000000000a', profile: { linked_id: 'admin_a', role: 'admin', active: true, name: 'Synthetic Admin' } },
  'partner@example.test': { id: '00000000-0000-0000-0000-00000000000d', profile: { linked_id: null, role: 'el_partner', active: true, name: 'Synthetic Partner' } },
};
// Synthetic roster: A/B/C enrolled (C archived), D not enrolled but with history.
const YOUTH = [
  { id: 'yn_a', name: 'Test Youth A', age: 15, workshops: null, active: true, volunteer_hours: 4, el_enrolled: true },
  { id: 'yn_b', name: 'Test Youth B', age: 16, workshops: null, active: true, volunteer_hours: 0, el_enrolled: true },
  { id: 'yn_c', name: 'Test Youth C', age: 14, workshops: null, active: true, volunteer_hours: 0, el_enrolled: false },
  { id: 'yn_d', name: 'Test Youth D', age: 17, workshops: null, active: true, volunteer_hours: 0, el_enrolled: false },
];
const ATT = [];
[1,2,3,4,5,6,7,8].forEach(w => ATT.push({ youth_id: 'yn_a', workshop_id: w }));
[1,2,101].forEach(w => ATT.push({ youth_id: 'yn_b', workshop_id: w }));
[1,3].forEach(w => ATT.push({ youth_id: 'yn_c', workshop_id: w }));
[2,101].forEach(w => ATT.push({ youth_id: 'yn_d', workshop_id: w }));
const ADULTS = [{ id: 'admin_a', name: 'Synthetic Admin', role: 'Administrator', avatar: 'SA', bg: '#123', facilitated: [], volunteered: [],
                  hours: 0, fac_level: 0, grandfathered: false, is_admin: true, active: true, prior_facilitated: 0 }];

async function mockSupabase(page, state) {
  await page.route(/fonts\.(googleapis|gstatic)\.com/, r => r.abort());
  await page.route(SUPA + '/**', async route => {
    const req = route.request(), url = new URL(req.url()), p = url.pathname, m = req.method();
    state.requests.push({ m, p, q: url.search, auth: !!req.headers()['authorization'] && req.headers()['authorization'] !== 'Bearer ' + req.headers()['apikey'], body: req.postData() });
    const json = (body, status = 200) => route.fulfill({ status, contentType: 'application/json', body: JSON.stringify(body) });
    if (p === '/auth/v1/token') {
      const b = JSON.parse(req.postData() || '{}'); const u = USERS[b.email];
      if (!u) return json({ error: 'invalid_grant', error_description: 'Invalid login credentials' }, 400);
      state.who = b.email;
      return json({ access_token: 'tok-' + u.id, refresh_token: 'r', expires_in: 3600, user: { id: u.id, email: b.email } });
    }
    if (p.startsWith('/auth/v1/')) return json({});
    const t = p.replace('/rest/v1/', '');
    if (m !== 'GET' && m !== 'HEAD') {
      if (t === 'site_config' && (req.postData() || '').includes('el_partner_snapshot')) state.snapshotPosts.push(req.postData());
      return route.fulfill({ status: 201, body: '' });
    }
    if (t === 'profiles') return json(state.who ? [USERS[state.who].profile] : []);
    if (t === 'site_config') {
      if (url.search.includes('el_partner_snapshot')) return json(state.snapshot ? [{ value: state.snapshot }] : []);
      return json([]);
    }
    if (state.who === 'admin@example.test') {
      if (t === 'youth') return json(YOUTH);
      if (t === 'workshop_attendance') return json(ATT);
      if (t === 'adults') return json(ADULTS);
      if (t === 'workshop_conducted') return json([{ workshop_id: 101, conducted: true }]);
      if (t === 'program_settings' && url.search.includes('el_youth_archived')) return json([{ cert_notes: JSON.stringify(['Test Youth C']) }]);
    }
    return json([]);
  });
}

async function signIn(page, email) {
  await page.evaluate(() => showLogin());
  await page.fill('#login-email', email);
  await page.fill('#login-password', 'synthetic-password');
  await page.click('#login-submit-btn');
  await page.waitForFunction(() => document.getElementById('app').style.display === 'block', null, { timeout: 30000 });
}

const readView = page => page.evaluate(() => {
  const txt = id => (document.getElementById(id) || {}).textContent;
  const bars = [...document.querySelectorAll('#admin-ws-bars details')].map(d => ({
    summary: d.querySelector('summary').textContent.trim(),
    rows: [...d.querySelectorAll('.prog-label')].map(l => l.textContent.trim()),
    widths: [...d.querySelectorAll('.prog-fill')].map(f => f.style.width) }));
  const head = [...document.querySelectorAll('#youth-ws-att-thead th')].map(th => th.textContent.trim());
  const rows = [...document.querySelectorAll('#youth-ws-att-tbody tr')].map(tr => [...tr.children].map((td, i) => i === 0 ? td.querySelector('strong').textContent : td.textContent.trim()));
  return { cards: [txt('admin-el-members-count'), txt('admin-el-members-meta'), txt('admin-total-att'), txt('admin-total-att-meta'),
                   txt('a-lvl1'), txt('admin-ws-done-count'), txt('admin-ws-done-meta')],
           bars, head, rows, pill: txt('youth-att-summary-pill') };
});
const visible = (page, sel) => page.evaluate(s => { const e = document.querySelector(s); return !!e && e.offsetParent !== null && getComputedStyle(e).display !== 'none'; }, sel);

(async () => {
  const server = http.createServer((req, res) => {
    const f = path.join(ROOT, decodeURIComponent(req.url.split('?')[0]) === '/' ? 'index.html' : decodeURIComponent(req.url.split('?')[0]));
    if (!f.startsWith(ROOT) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
    res.writeHead(200, { 'Content-Type': f.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream' }); fs.createReadStream(f).pipe(res);
  }).listen(0);
  const base = 'http://127.0.0.1:' + server.address().port + '/';
  const browser = await chromium.launch();
  const errors = [];
  try {
    // ── 1. Administrator (regression + publishes the snapshot) ─────────────
    const adminState = { requests: [], snapshotPosts: [], who: null };
    const actx = await browser.newContext({ viewport: { width: 1400, height: 1000 } });
    const admin = await actx.newPage();
    admin.on('pageerror', e => errors.push('admin: ' + e.message));
    await mockSupabase(admin, adminState);
    await admin.goto(base);
    await signIn(admin, 'admin@example.test');
    check('admin signs in as admin', await admin.evaluate(() => currentRole) === 'admin');
    await admin.evaluate(() => { toggleAdminVolunteerView(); });
    await admin.waitForTimeout(300);
    check('admin dashboard with full tab bar', await visible(admin, '#page-admin-dashboard .tab-bar'));
    check('admin edit controls present', await visible(admin, '#ws-att-edit-btn') || await admin.evaluate(() => !!document.getElementById('ws-att-edit-btn')));
    const adminView = await readView(admin);
    check('admin cards populated', adminView.cards[0] === '3' && adminView.cards[2] !== '—', adminView.cards);
    await admin.waitForFunction(() => true);
    for (let i = 0; i < 40 && !adminState.snapshotPosts.length; i++) await admin.waitForTimeout(250);
    check('admin publishes el_partner_snapshot', adminState.snapshotPosts.length > 0);
    const snapRow = JSON.parse(adminState.snapshotPosts.at(-1) || '{}');
    const snap = snapRow.value || '{}', snapObj = JSON.parse(snap);
    check('snapshot has no ages / hours / non-roster names',
      !/"age"|volunteer_hours|hours"|Test Youth C|Test Youth D/.test(snap) && Object.keys(snapObj.attendance || {}).some(k => k.startsWith('~')), snap);
    check('snapshot active roster', JSON.stringify(snapObj.active) === JSON.stringify(['Test Youth A', 'Test Youth B']), snapObj.active);
    // admin attendance editing still works (writes to workshop_attendance)
    await admin.evaluate(() => { document.getElementById('youth-att-details').open = true; toggleWsAttEditMode(); });
    const before = adminState.requests.length;
    await admin.click('#youth-ws-att-tbody tr:first-child td.ws-att-cell');
    await admin.waitForTimeout(500);
    check('admin can still toggle attendance', adminState.requests.slice(before).some(r => r.p.endsWith('workshop_attendance') && r.m !== 'GET'));
    await admin.evaluate(() => { toggleYouthWsAdmin && document.querySelector('#youth-ws-att-tbody tr:first-child td.ws-att-cell').click(); toggleWsAttEditMode(); });
    await admin.waitForTimeout(500);
    const adminFinal = await readView(admin);
    await actx.close();

    // ── 2. Emerging Leader Partner ─────────────────────────────────────────
    const pState = { requests: [], snapshotPosts: [], who: null, snapshot: snap };
    const pctx = await browser.newContext({ viewport: { width: 1400, height: 1000 } });
    const partner = await pctx.newPage();
    partner.on('pageerror', e => errors.push('partner: ' + e.message));
    await mockSupabase(partner, pState);
    await partner.goto(base);
    await signIn(partner, 'partner@example.test');
    await partner.waitForTimeout(500);
    check('1 partner routes straight to Workshops', await partner.evaluate(() => currentRole === 'el_partner' && document.getElementById('page-admin-dashboard').classList.contains('active')));
    check('1 partner nav has only Workshops', await partner.evaluate(() => [...document.querySelectorAll('#nav-links .nav-item')].map(n => n.textContent).join('|')) === '📚Workshops');
    check('1 partner badge', await partner.evaluate(() => document.getElementById('user-role-badge').textContent) === 'Emerging Leader Partner');
    check('1 admin tab bar hidden', !(await visible(partner, '#page-admin-dashboard .tab-bar')));
    check('1 sign-out visible', await visible(partner, '.logout-btn'));
    const pView = await readView(partner);
    check('2 four overview cards match admin', JSON.stringify(pView.cards) === JSON.stringify(adminFinal.cards), [pView.cards, adminFinal.cards]);
    check('3 attendance bars match admin', JSON.stringify(pView.bars) === JSON.stringify(adminFinal.bars), [pView.bars, adminFinal.bars]);
    check('3 Winter and Fall series listed', pView.bars.map(b => b.summary).join('|').includes('Winter 2026') && pView.bars.map(b => b.summary).join('|').includes('Fall 2026'), pView.bars.map(b => b.summary));
    const expand = await partner.evaluate(() => { const d = document.querySelector('#admin-ws-bars details'); const s = d.querySelector('summary');
      s.click(); const o1 = d.open; s.click(); return [o1, d.open]; });
    check('3 series expand and collapse', expand[0] === true && expand[1] === false, expand);
    check('4 grid header matches admin', JSON.stringify(pView.head) === JSON.stringify(adminFinal.head.filter(h => h !== 'Archive')), [pView.head, adminFinal.head]);
    check('4 grid rows match admin (names, counts, status, cells, totals)', JSON.stringify(pView.rows) === JSON.stringify(adminFinal.rows.map(r => r)), [pView.rows, adminFinal.rows]);
    check('4 grid visible & horizontally scrollable container', await visible(partner, '#youth-ws-att-table') && await partner.evaluate(() => getComputedStyle(document.getElementById('youth-ws-att-table').parentElement).overflowX) === 'auto');
    check('4 no ages or volunteer hours shown', !(await partner.evaluate(() => /vol hrs|Age /.test(document.getElementById('youth-ws-att-tbody').textContent))));
    check('4 summary pill matches admin', pView.pill === adminFinal.pill, [pView.pill, adminFinal.pill]);
    for (const sel of ['#ws-att-edit-btn', '#add-el-youth-btn', '#ws-att-archive-btn', '#ws-template-details', '#tab-scrabble-admin', '#adult-ws-next-alert'])
      check('5 hidden: ' + sel, !(await visible(partner, sel)));
    await partner.evaluate(() => { toggleWsAttEditMode(); toggleWsAttArchiveMode(); });
    const cellBefore = await partner.evaluate(() => document.querySelector('#youth-ws-att-tbody td.ws-att-cell').textContent);
    await partner.click('#youth-ws-att-tbody td.ws-att-cell', { force: true });
    await partner.evaluate(() => toggleYouthWsAdmin('Test Youth A', 1, document.querySelector('#youth-ws-att-tbody td.ws-att-cell')));
    check('5 attendance cannot be toggled', await partner.evaluate(() => wsAttEditMode === false && wsAttArchiveMode === false) &&
      cellBefore === await partner.evaluate(() => document.querySelector('#youth-ws-att-tbody td.ws-att-cell').textContent));
    const pReq = pState.requests.filter(r => r.p.startsWith('/rest/'));
    check('6 partner made no write requests', !pState.requests.some(r => r.m !== 'GET' && r.m !== 'HEAD' && !r.p.startsWith('/auth/')), pState.requests.filter(r => r.m !== 'GET'));
    const signedIn = pReq.filter(r => r.auth);
    check('6 partner reads only profiles + snapshot (no full loader)',
      signedIn.length === 2 && signedIn.every(r => r.p === '/rest/v1/profiles' || (r.p === '/rest/v1/site_config' && r.q.includes('el_partner_snapshot'))), signedIn);

    // Partner on a phone: Workshops + Sign Out in the bottom bar, no page-wide horizontal scroll
    const mctx = await browser.newContext({ ...devices['iPhone 13'] });
    const mob = await mctx.newPage();
    mob.on('pageerror', e => errors.push('mobile: ' + e.message));
    await mockSupabase(mob, { requests: [], snapshotPosts: [], who: null, snapshot: snap });
    await mob.goto(base);
    await signIn(mob, 'partner@example.test');
    await mob.waitForTimeout(500);
    check('mobile partner tab bar', (await mob.evaluate(() => document.getElementById('mobile-tab-bar').textContent)).replace(/\s/g, '') === '📚Workshops↩SignOut');
    check('mobile no page-wide horizontal scroll', await mob.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1));
    await mob.screenshot({ path: path.join(process.env.ELP_SHOTS || '/tmp', 'elp-partner-mobile.png') });
    await partner.screenshot({ path: path.join(process.env.ELP_SHOTS || '/tmp', 'elp-partner-desktop.png'), fullPage: true });
    await mctx.close(); await pctx.close();

    // ── 3. Signed-out visitor ───────────────────────────────────────────────
    const aState = { requests: [], snapshotPosts: [], who: null, snapshot: snap };
    const vctx = await browser.newContext();
    const visitor = await vctx.newPage();
    visitor.on('pageerror', e => errors.push('anon: ' + e.message));
    await mockSupabase(visitor, aState);
    await visitor.goto(base);
    await visitor.waitForTimeout(800);
    await visitor.evaluate(s => { try { enterElPartnerView({ name: 'x' }, JSON.parse(s)); } catch (e) {} }, snap);
    check('7 signed-out visitor cannot open partner view', await visitor.evaluate(() => document.getElementById('app').style.display !== 'block' && currentRole === null));
    check('7 signed-out visitor never requests the snapshot', !aState.requests.some(r => (r.q || '').includes('el_partner_snapshot')));
    check('7 page source has no synthetic names', !fs.readFileSync(path.join(ROOT, 'index.html'), 'utf8').match(/Test Youth [A-D]/));
    await vctx.close();
  } finally {
    await browser.close(); server.close();
  }
  check('no uncaught page errors', errors.length === 0, errors);
  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  process.exit(fail ? 1 : 0);
})().catch(e => { console.error(e); process.exit(1); });
