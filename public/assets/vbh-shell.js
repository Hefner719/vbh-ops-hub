/* ═══════════════════════════════════════════════════════════════════════════
   vbh-shell.js — shared site chrome for every hub page · build shell-v3
   ───────────────────────────────────────────────────────────────────────────
   Load order in <head>:  vbh-config.js → assets/vbh.css → assets/vbh-shell.js

   A page opts in with attributes; the shell does the rest:

     <body data-vbh-page="projects">          which PAGES entry this is
       <div data-vbh-header>                  ← becomes the title band; any
         <button …>Page action</button>          children move into its actions slot
       </div>
       …page…
       <div data-vbh-foot></div>              ← becomes the footer
     </body>

   What the shell provides
     · site nav (from VBH.PAGES) with the active page marked, plus a Lock button
     · page header (title/sub from VBH.PAGES, overridable with data-title / data-sub)
     · footer (values, address, public-form links, build stamp)
     · the gate on protected pages — Supabase magic-link sign-in, with the shared
       password still accepted during the Phase A transition
     · document.title
     · VBH.sb()      shared Supabase client (singleton)
     · VBH.toast(msg [, ms])
     · VBH.esc(str)
     · VBH.auth      { ok(), name(), user(), profile(), role(), canWrite(),
                       canDelete(), signIn(email), lock(), require(cb) }
     · VBH.page      the current PAGES record
     · 'vbh:ready' event on document once the page is unlocked (immediately if already)

   Fails open on script error: content is never left hidden.
   ═══════════════════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  if (typeof VBH === 'undefined') { console.error('[vbh-shell] vbh-config.js must load first'); return; }

  const AUTH_KEY = 'vbh_auth';            // localStorage: {"t":<ms>,"name":"…"}
  const LEGACY_KEYS = ['vbh_auth_ok', 'vbh'];  // old sessionStorage flags — honoured once, then migrated
  const NAME_KEY = 'vbh_editor_name';     // meeting.html has always stored the editor name here
  const EMAIL_KEY = 'vbh_signin_email';   // remembered so the gate pre-fills next time
  const html = document.documentElement;

  /* Hide content until we know whether to show the gate. Cleared in finish(). */
  html.setAttribute('data-vbh-pending', '');
  const style = document.createElement('style');
  style.textContent = 'html[data-vbh-pending] body > :not(.vbh-gate){visibility:hidden}';
  document.head.appendChild(style);

  /* ── helpers ─────────────────────────────────────────────────────────── */
  const esc = (s) => String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  const el = (tag, attrs, children) => {
    const n = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      if (k === 'class') n.className = attrs[k];
      else if (k === 'html') n.innerHTML = attrs[k];
      else if (k === 'text') n.textContent = attrs[k];
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), attrs[k]);
      else n.setAttribute(k, attrs[k]);
    }
    (children || []).forEach((c) => c && n.appendChild(c));
    return n;
  };

  function currentPage() {
    const id = document.body && document.body.getAttribute('data-vbh-page');
    if (id) return VBH.PAGES.find((p) => p.id === id) || null;
    const path = location.pathname.replace(/\.html$/, '').replace(/\/index$/, '/') || '/';
    return VBH.PAGES.find((p) => p.path === path) || null;
  }

  /* ── auth ────────────────────────────────────────────────────────────── */
  function readAuth() {
    try {
      const raw = localStorage.getItem(AUTH_KEY);
      if (raw) {
        const a = JSON.parse(raw);
        const ttl = (VBH.AUTH_TTL_HOURS || 12) * 3600000;
        if (a && a.t && Date.now() - a.t < ttl) return a;
        localStorage.removeItem(AUTH_KEY);
      }
      // One-time migration from the per-page sessionStorage flags.
      if (LEGACY_KEYS.some((k) => sessionStorage.getItem(k) === '1')) {
        const a = { t: Date.now(), name: localStorage.getItem(NAME_KEY) || '' };
        localStorage.setItem(AUTH_KEY, JSON.stringify(a));
        LEGACY_KEYS.forEach((k) => sessionStorage.removeItem(k));
        return a;
      }
    } catch (e) { /* storage blocked — treat as signed out */ }
    return null;
  }
  function writeAuth(name) {
    try {
      localStorage.setItem(AUTH_KEY, JSON.stringify({ t: Date.now(), name: name || '' }));
      if (name) localStorage.setItem(NAME_KEY, name);
      // Keep the legacy flags in step for any page not yet on the shell.
      LEGACY_KEYS.forEach((k) => sessionStorage.setItem(k, '1'));
    } catch (e) { /* ignore */ }
  }
  /* ── real accounts ─────────────────────────────────────────────────────
     Supabase Auth with magic links. The shared password still works during
     the transition (see PHASE A in migration 006) so nobody is locked out
     mid-week, but a real session is what the database will trust once the
     anon policies come off.

     Security note: this gate is convenience, not protection. Row-level
     security is what actually guards the data — a broken gate should reveal
     an empty page, never someone else's records. */
  let sbUser = null, sbProfile = null;

  /* supabase-js is on most pages but not all; load it on demand so auth works
     everywhere without touching every file. */
  function ensureSupabase() {
    if (window.supabase && window.supabase.createClient) return Promise.resolve(true);
    if (ensureSupabase._p) return ensureSupabase._p;
    ensureSupabase._p = new Promise((resolve) => {
      const s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2';
      s.onload = () => resolve(!!(window.supabase && window.supabase.createClient));
      s.onerror = () => resolve(false);
      document.head.appendChild(s);
    });
    return ensureSupabase._p;
  }

  async function loadSession() {
    if (!(await ensureSupabase())) return null;
    try {
      const { data } = await VBH.sb().auth.getSession();
      sbUser = (data && data.session && data.session.user) || null;
      if (!sbUser) { sbProfile = null; return null; }
      const { data: prof } = await VBH.sb()
        .from('profiles').select('id,email,full_name,role,active').eq('id', sbUser.id).maybeSingle();
      sbProfile = prof || null;
      return sbProfile;
    } catch (e) { console.warn('[vbh-shell] session load failed:', e); return null; }
  }

  async function lock() {
    try {
      localStorage.removeItem(AUTH_KEY);
      LEGACY_KEYS.forEach((k) => sessionStorage.removeItem(k));
      if (window.supabase && window.supabase.createClient) await VBH.sb().auth.signOut();
    } catch (e) { /* ignore */ }
    location.href = VBH.PAGES.find((p) => p.id === 'hub').path;
  }

  const auth = {
    /* Signed in for real, or holding a valid shared-password session. */
    ok: () => !!(sbProfile && sbProfile.active) || !!readAuth(),
    name: () => (sbProfile && (sbProfile.full_name || sbProfile.email))
             || (readAuth() || {}).name
             || localStorage.getItem(NAME_KEY) || '',
    user: () => sbUser,
    profile: () => sbProfile,
    role: () => (sbProfile && sbProfile.active) ? sbProfile.role : null,
    /* Coarse capability checks, mirroring the SQL helpers in migration 006.
       Convenience for hiding controls — the database enforces the real rule. */
    canWrite:  () => ['owner', 'ops_admin', 'manager', 'field'].indexOf(auth.role()) >= 0 || (!sbProfile && !!readAuth()),
    canDelete: () => ['owner', 'ops_admin'].indexOf(auth.role()) >= 0 || (!sbProfile && !!readAuth()),
    signIn: async (email) => {
      if (!(await ensureSupabase())) throw new Error('Could not load the sign-in library.');
      const { error } = await VBH.sb().auth.signInWithOtp({
        email: String(email || '').trim().toLowerCase(),
        options: { emailRedirectTo: location.origin + location.pathname }
      });
      if (error) throw error;
    },
    lock,
    /* Run cb now if unlocked, otherwise as soon as the gate clears. */
    require: (cb) => { if (auth.ok() || !(VBH.page && VBH.page.protected)) cb(); else document.addEventListener('vbh:ready', cb, { once: true }); }
  };

  /* ── gate ──────────────────────────────────────────────────────────────
     Two ways in: a sign-in link to a work address (the real one), or the
     shared password (kept working until everyone has signed in once). */
  function renderGate(page, askName, onDone) {
    const err  = el('div', { class: 'vbh-gate-err', id: 'vbhGateErr' });
    const note = el('div', { class: 'vbh-gate-note', id: 'vbhGateNote' });

    /* — sign-in link — */
    const mailIn  = el('input', { id: 'vbhGateEmail', type: 'email', placeholder: 'you@vanbuskirkco.com',
                                  autocomplete: 'email', value: (localStorage.getItem(EMAIL_KEY) || '') });
    const mailBtn = el('button', { type: 'button', text: 'Email me a sign-in link' });

    /* — shared password (transition) — */
    const nameIn = askName ? el('input', { id: 'vbhGateName', type: 'text', placeholder: 'Your name', autocomplete: 'name', value: auth.name() }) : null;
    const pwIn   = el('input', { id: 'vbhGatePw', type: 'password', placeholder: 'Shared password', autocomplete: 'current-password' });
    const pwBtn  = el('button', { class: 'vbh-gate-alt-btn', type: 'button', text: 'Unlock' });
    const pwBox  = el('div', { class: 'vbh-gate-alt', hidden: 'hidden' }, [nameIn, pwIn, pwBtn]);
    const pwToggle = el('button', { class: 'vbh-gate-link', type: 'button', text: 'Use the shared password instead' });
    pwToggle.addEventListener('click', () => {
      pwBox.hidden = !pwBox.hidden;
      pwToggle.textContent = pwBox.hidden ? 'Use the shared password instead' : 'Use a sign-in link instead';
      if (!pwBox.hidden) setTimeout(() => (nameIn && !nameIn.value ? nameIn : pwIn).focus(), 20);
    });

    const gate = el('div', { class: 'vbh-gate', role: 'dialog', 'aria-label': 'Sign in' }, [
      el('img', { class: 'vbh-gate-logo', src: '/img/vbh-logo.png', alt: VBH.COMPANY.name }),
      el('div', { class: 'vbh-gate-box' }, [
        el('h2', { text: 'Operations Hub' }),
        el('div', { class: 'vbh-gate-rule' }),
        el('div', { class: 'vbh-gate-sub', text: (page.id === 'hub' ? '' : (page.title || '') + ' · ') + 'Van Buskirk Homes staff' }),
        mailIn, mailBtn, err, note, pwToggle, pwBox
      ]),
      el('div', { class: 'vbh-gate-foot', html: esc(VBH.COMPANY.name) + ' · <a href="/">Work order request</a> · <a href="/intake">Client intake</a>' })
    ]);

    const sendLink = async () => {
      const email = mailIn.value.trim().toLowerCase();
      err.textContent = ''; note.textContent = '';
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) { err.textContent = 'Enter your work email address.'; mailIn.focus(); return; }
      mailBtn.disabled = true; mailBtn.textContent = 'Sending…';
      try {
        await auth.signIn(email);
        try { localStorage.setItem(EMAIL_KEY, email); } catch (e) {}
        note.textContent = 'Check ' + email + ' — the link signs you in on this device. It expires in an hour.';
        mailBtn.textContent = 'Sent · send again';
      } catch (e) {
        err.textContent = (e && e.message) || 'Could not send the link. Try the shared password below.';
        mailBtn.textContent = 'Email me a sign-in link';
      } finally { mailBtn.disabled = false; }
    };

    const attemptPw = () => {
      const name = nameIn ? nameIn.value.trim() : auth.name();
      if (askName && !name) { err.textContent = 'Enter your name.'; nameIn.focus(); return; }
      if (pwIn.value === VBH.PASSWORD) {
        writeAuth(name);
        gate.remove();
        onDone();
      } else {
        err.textContent = 'Incorrect password.';
        pwIn.value = ''; pwIn.focus();
      }
    };

    mailBtn.addEventListener('click', sendLink);
    pwBtn.addEventListener('click', attemptPw);
    gate.addEventListener('keydown', (e) => {
      if (e.key !== 'Enter') return;
      if (!pwBox.hidden && (e.target === pwIn || e.target === nameIn)) attemptPw();
      else if (e.target === mailIn) sendLink();
    });
    document.body.prepend(gate);
    setTimeout(() => mailIn.focus(), 30);
  }

  /* Signed in, but not on the roster (or deactivated). */
  function renderNoAccess(email) {
    const gate = el('div', { class: 'vbh-gate', role: 'dialog' }, [
      el('img', { class: 'vbh-gate-logo', src: '/img/vbh-logo.png', alt: VBH.COMPANY.name }),
      el('div', { class: 'vbh-gate-box' }, [
        el('h2', { text: 'No access' }),
        el('div', { class: 'vbh-gate-rule' }),
        el('div', { class: 'vbh-gate-sub', text: esc(email || '') + ' is signed in but not set up for the hub.' }),
        el('div', { class: 'vbh-gate-note', text: 'Ask the Director of Operations to add you, then sign in again.' }),
        el('button', { type: 'button', text: 'Sign out', onclick: lock })
      ])
    ]);
    document.body.prepend(gate);
  }

  /* ── nav ─────────────────────────────────────────────────────────────── */
  function renderNav(page) {
    if (document.querySelector('.vbh-nav')) return;
    const nav = el('nav', { class: 'vbh-nav', 'aria-label': 'Site' });
    const hub = VBH.PAGES.find((p) => p.id === 'hub');
    nav.appendChild(el('a', { class: 'vbh-nav-brand', href: hub.path, title: 'Operations Hub' }, [
      el('img', { src: '/img/vbh-logo.svg', alt: VBH.COMPANY.short })
    ]));
    let lastGroup = null;
    VBH.PAGES.filter((p) => p.nav).forEach((p) => {
      if (lastGroup && p.group !== lastGroup) nav.appendChild(el('span', { class: 'vbh-nav-gap' }));
      lastGroup = p.group;
      nav.appendChild(el('a', { href: p.path, text: p.nav, class: page && page.id === p.id ? 'active' : '' }));
    });
    nav.appendChild(el('span', { class: 'vbh-nav-spacer' }));
    if (page && page.protected) {
      const who = auth.name();
      nav.appendChild(el('button', { class: 'vbh-nav-lock', type: 'button', title: 'Sign out on this device', onclick: lock,
        text: (who ? who.split(' ')[0] + ' · ' : '') + 'Sign out' }));
    }
    document.body.prepend(nav);
  }

  /* ── header ──────────────────────────────────────────────────────────── */
  function renderHeader(page) {
    const slot = document.querySelector('[data-vbh-header]');
    if (!slot) return;
    const title = slot.getAttribute('data-title') || (page && page.title) || document.title;
    const sub = slot.getAttribute('data-sub') || (page && page.sub) || '';
    const actions = el('div', { class: 'vbh-header-actions' });
    while (slot.firstChild) actions.appendChild(slot.firstChild);
    slot.className = (slot.className ? slot.className + ' ' : '') + 'vbh-header';
    slot.setAttribute('role', 'banner');
    slot.appendChild(el('img', { class: 'vbh-header-logo', src: '/img/vbh-logo.svg', alt: VBH.COMPANY.name }));
    slot.appendChild(el('div', { class: 'vbh-header-div' }));
    slot.appendChild(el('div', {}, [
      el('h1', { text: title }),
      sub ? el('div', { class: 'vbh-header-sub', text: sub }) : null
    ]));
    if (actions.childNodes.length) slot.appendChild(actions);
  }

  /* ── footer ──────────────────────────────────────────────────────────── */
  function renderFooter(page) {
    const slot = document.querySelector('[data-vbh-foot]');
    if (!slot) return;
    slot.className = (slot.className ? slot.className + ' ' : '') + 'vbh-foot';
    slot.setAttribute('role', 'contentinfo');
    const c = VBH.COMPANY;
    slot.appendChild(el('span', { class: 'vbh-foot-values', text: c.values.join(' · ') }));
    slot.appendChild(el('span', { text: c.name + ' · ' + c.address + ' · ' + c.phone }));
    VBH.PAGES.filter((p) => p.footer).forEach((p) => slot.appendChild(el('a', { href: p.path, text: p.footer })));
    slot.appendChild(el('span', { class: 'vbh-foot-spacer' }));
    const pageBuild = document.body.getAttribute('data-vbh-build');
    slot.appendChild(el('span', { class: 'vbh-foot-build', text: 'build ' + VBH.BUILD + (pageBuild ? ' · ' + pageBuild : '') }));
  }

  /* ── hub tiles (only the hub page has the slot) ──────────────────────── */
  function renderTiles() {
    const slot = document.querySelector('[data-vbh-tiles]');
    if (!slot) return;
    VBH.PAGES.filter((p) => p.tile).forEach((p) => {
      slot.appendChild(el('a', { class: 'hub-card', href: p.path, 'data-accent': p.tile.accent || 'steel' }, [
        el('div', { class: 'hub-icon', text: p.tile.icon }),
        el('h3', { text: p.tile.title || p.title }),
        el('p', { text: p.tile.blurb }),
        el('div', { class: 'open-cta', text: 'Open ' + (p.nav || '') })
      ]));
    });
  }

  /* ── shared utilities ────────────────────────────────────────────────── */
  let sbClient = null;
  VBH.sb = function () {
    if (sbClient) return sbClient;
    if (!window.supabase || !window.supabase.createClient) throw new Error('supabase-js is not loaded on this page');
    sbClient = window.supabase.createClient(VBH.SUPABASE_URL, VBH.SUPABASE_KEY);
    return sbClient;
  };
  let toastEl = null, toastT = null;
  VBH.toast = function (msg, ms) {
    if (!toastEl) { toastEl = el('div', { class: 'vbh-toast', role: 'status' }); document.body.appendChild(toastEl); }
    toastEl.textContent = msg; toastEl.classList.add('show');
    clearTimeout(toastT); toastT = setTimeout(() => toastEl.classList.remove('show'), ms || 2600);
  };
  VBH.esc = esc;
  VBH.auth = auth;

  /* ── boot ────────────────────────────────────────────────────────────── */
  /* ── bridge health banner ──────────────────────────────────────────────
     The Buildertrend ingest fails quietly: if the Graph secret expires or the
     mailbox folder is renamed, polling just stops and the agenda goes stale
     without anyone being told. Rather than wait for a mail sender, say so on
     every page. Silent when healthy. */
  async function renderHealth(page) {
    if (!page || !page.protected || page.id === 'digest') return;   // digest has its own section
    try {
      if (!(await ensureSupabase())) return;
      const { data, error } = await VBH.sb()
        .from('v_bt_health').select('status,message,minutes_since_run').maybeSingle();
      if (error || !data || data.status === 'ok') return;
      const bad = data.status === 'down' || data.status === 'never_run' || data.status === 'erroring';
      const bar = el('div', { class: 'vbh-alert' + (bad ? ' bad' : ''), role: 'status' }, [
        el('span', { class: 'vbh-alert-tag', text: bad ? 'Buildertrend feed down' : 'Buildertrend feed lagging' }),
        el('span', { text: data.message || '' }),
        el('a', { class: 'vbh-alert-link', href: '/digest', text: 'Bridge health →' })
      ]);
      const nav = document.querySelector('.vbh-nav');
      if (nav && nav.nextSibling) nav.parentNode.insertBefore(bar, nav.nextSibling);
      else document.body.prepend(bar);
    } catch (e) { /* never let a health check break a page */ }
  }

  function finish(page) {
    html.removeAttribute('data-vbh-pending');
    document.dispatchEvent(new CustomEvent('vbh:ready', { detail: { page, name: auth.name() } }));
    renderHealth(page);
  }

  function refreshLockLabel() {
    const btn = document.querySelector('.vbh-nav-lock');
    if (!btn) return;
    const who = auth.name();
    const r = auth.role();
    btn.textContent = (who ? who.split(' ')[0] + ' · ' : '') + 'Sign out';
    btn.title = r ? 'Signed in as ' + who + ' (' + r.replace('_', ' ') + ') — sign out'
                  : 'Signed in with the shared password — sign out';
  }

  async function boot() {
    let page = null;
    try {
      page = currentPage();
      VBH.page = page;
      if (page && page.title && !document.body.hasAttribute('data-vbh-keep-title')) {
        document.title = page.title + ' · ' + (page.protected ? VBH.COMPANY.short + ' Ops Hub' : VBH.COMPANY.name);
      }
      /* data-vbh-chrome: "full" (default) nav + header + footer · "header" header + footer only
         (public forms — no internal nav) · "none" nothing injected. */
      const chrome = document.body.getAttribute('data-vbh-chrome') || 'full';
      if (chrome === 'full') renderNav(page);
      if (chrome !== 'none') { renderHeader(page); renderFooter(page); renderTiles(); }

      if (!page || !page.protected) { finish(page); return; }

      /* A magic-link return arrives as a URL fragment; creating the client
         consumes it. Tidy the address bar afterwards so the token is not left
         sitting in history or copied into a shared link. */
      const hadAuthHash = /access_token=|type=magiclink|error_code=/.test(location.hash || '');
      await loadSession();
      if (hadAuthHash) {
        try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
      }

      const askName = document.body.hasAttribute('data-vbh-ask-name');
      if (sbUser && !(sbProfile && sbProfile.active)) {
        /* Signed in, but not on the roster or deactivated. */
        renderNoAccess(sbUser.email);
        html.removeAttribute('data-vbh-pending');
        html.setAttribute('data-vbh-gated', '');
        return;
      }
      if (auth.ok() && (!askName || auth.name())) { refreshLockLabel(); finish(page); return; }

      renderGate(page, askName, () => { refreshLockLabel(); finish(page); });
      html.removeAttribute('data-vbh-pending');   // gate is visible; content stays behind it
      html.setAttribute('data-vbh-gated', '');
    } catch (e) {
      console.error('[vbh-shell]', e);
      /* Fail open on chrome only. With row-level security in force a stray
         page shows nothing rather than someone else's data. */
      html.removeAttribute('data-vbh-pending');
      finish(page);
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
