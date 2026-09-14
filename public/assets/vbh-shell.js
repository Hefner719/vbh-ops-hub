/* ═══════════════════════════════════════════════════════════════════════════
   vbh-shell.js — shared site chrome for every hub page · build shell-v1
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
     · the gate on protected pages — one password, one key, 12-hour session
     · document.title
     · VBH.sb()      shared Supabase client (singleton)
     · VBH.toast(msg [, ms])
     · VBH.esc(str)
     · VBH.auth      { ok(), name(), lock(), require(cb) }
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
  function lock() {
    try {
      localStorage.removeItem(AUTH_KEY);
      LEGACY_KEYS.forEach((k) => sessionStorage.removeItem(k));
    } catch (e) { /* ignore */ }
    location.href = VBH.PAGES.find((p) => p.id === 'hub').path;
  }

  const auth = {
    ok: () => !!readAuth(),
    name: () => { const a = readAuth(); return (a && a.name) || (localStorage.getItem(NAME_KEY) || ''); },
    lock,
    /* Run cb now if unlocked, otherwise as soon as the gate clears. */
    require: (cb) => { if (auth.ok() || !(VBH.page && VBH.page.protected)) cb(); else document.addEventListener('vbh:ready', cb, { once: true }); }
  };

  /* ── gate ────────────────────────────────────────────────────────────── */
  function renderGate(page, askName, onDone) {
    const nameIn = askName ? el('input', { id: 'vbhGateName', type: 'text', placeholder: 'Your name', autocomplete: 'name', value: auth.name() }) : null;
    const pwIn = el('input', { id: 'vbhGatePw', type: 'password', placeholder: 'Password', autocomplete: 'current-password' });
    const err = el('div', { class: 'vbh-gate-err', id: 'vbhGateErr' });
    const btn = el('button', { type: 'button', text: 'Unlock' });
    const gate = el('div', { class: 'vbh-gate', role: 'dialog', 'aria-label': 'Sign in' }, [
      el('img', { class: 'vbh-gate-logo', src: '/img/vbh-logo.png', alt: VBH.COMPANY.name }),
      el('div', { class: 'vbh-gate-box' }, [
        el('h2', { text: 'Operations Hub' }),
        el('div', { class: 'vbh-gate-rule' }),
        el('div', { class: 'vbh-gate-sub', text: (page.id === 'hub' ? '' : (page.title || '') + ' · ') + 'Authorized personnel only' }),
        nameIn, pwIn, btn, err
      ]),
      el('div', { class: 'vbh-gate-foot', html: esc(VBH.COMPANY.name) + ' · <a href="/">Work order request</a> · <a href="/intake">Client intake</a>' })
    ]);
    const attempt = () => {
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
    btn.addEventListener('click', attempt);
    gate.addEventListener('keydown', (e) => { if (e.key === 'Enter') attempt(); });
    document.body.prepend(gate);
    setTimeout(() => (nameIn && !nameIn.value ? nameIn : pwIn).focus(), 30);
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
      nav.appendChild(el('button', { class: 'vbh-nav-lock', type: 'button', title: 'Lock the hub on this device', onclick: lock,
        text: (who ? who + ' · ' : '') + 'Lock' }));
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
  function finish(page) {
    html.removeAttribute('data-vbh-pending');
    document.dispatchEvent(new CustomEvent('vbh:ready', { detail: { page, name: auth.name() } }));
  }

  function boot() {
    try {
      const page = currentPage();
      VBH.page = page;
      if (page && page.title && !document.body.hasAttribute('data-vbh-keep-title')) {
        document.title = page.title + ' · ' + (page.protected ? VBH.COMPANY.short + ' Ops Hub' : VBH.COMPANY.name);
      }
      /* data-vbh-chrome: "full" (default) nav + header + footer · "header" header + footer only
         (public forms — no internal nav) · "none" nothing injected. */
      const chrome = document.body.getAttribute('data-vbh-chrome') || 'full';
      if (chrome === 'full') renderNav(page);
      if (chrome !== 'none') { renderHeader(page); renderFooter(page); renderTiles(); }
      const askName = document.body.hasAttribute('data-vbh-ask-name');
      if (page && page.protected && !(auth.ok() && (!askName || auth.name()))) {
        renderGate(page, askName, () => {
          const lockBtn = document.querySelector('.vbh-nav-lock');
          if (lockBtn) lockBtn.textContent = (auth.name() ? auth.name() + ' · ' : '') + 'Lock';
          finish(page);
        });
        html.removeAttribute('data-vbh-pending');   // gate is visible; content stays behind it
        html.setAttribute('data-vbh-gated', '');
      } else {
        finish(page);
      }
    } catch (e) {
      console.error('[vbh-shell]', e);
      html.removeAttribute('data-vbh-pending');
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
