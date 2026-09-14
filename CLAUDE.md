# VBH Ops Hub

Internal operations hub for Van Buskirk Homes (VBH), a custom home builder in Sioux Falls, SD. Owner: Jordan Hefner, Director of Operations. This file describes the hub **as it actually is**; the "Roadmap" section is what's planned. Update the two together when something ships.

## Repo layout

- `public/` — the deployed site, exactly what Netlify serves. Vanilla HTML/CSS/JS, one file per page.
- `supabase/migrations/` — numbered SQL, run in order in the Supabase SQL editor (or `supabase db push`). Idempotent.
- `supabase/seed/` — generated test data (Buildertrend samples). Never run against production tables other than `bt_emails`.
- `supabase/functions/` — Edge Functions (Deno). Plain JS, no TypeScript.
- `samples/` — real Buildertrend notification emails (Outlook CSV export). Source of truth for parser templates.
- `tools/` — PowerShell helpers (sample seed builder, etc.).
- `docs/` — runbooks and requests to other teams (IT, etc.).

## Stack

- Vanilla HTML/CSS/JS. No frameworks, no bundler, no TypeScript in `public/`. Edge Functions are plain JS on Deno.
- Hosted on Netlify at vbchomes.net; `netlify.toml` declares publish dir, pretty URLs (`/projects` serves `projects.html` — always link extensionless), and headers. PWA manifests: `manifest.json` (hub) plus per-app ones for the work-order form, dashboard, and intake.
- Backend is Supabase, project ref `bppirsahciuxrqzitfxa`. The anon key is public by design and lives only in `public/vbh-config.js` (`VBH.SUPABASE_KEY`). **Never** put a service-role key, a Graph client secret, or any other secret in this repo. Secrets go in Supabase Edge Function secrets or Netlify env vars.
- Supabase tables in use: `projects` (+ view `v_active_projects`), `project_updates`, `leads`, `meetings`, `work_orders`, `assets`, and the `bt_*` bridge tables below.

## The shell (build `shell-v1`) — how every page is put together

Three shared files, loaded in this order in `<head>`: `/vbh-config.js` → `/assets/vbh.css` → `/assets/vbh-shell.js`. Then the page's own `<style>` and script.

- **`vbh-config.js`** is the one config file. `VBH.PAGES` is the page registry: id, path, nav label, group, title/subtitle, hub tile, `protected`. Adding a page = one entry here + a body attribute on the page. Also holds `VBH.ROLES` (opsDirector, ceo, coo), `VBH.WORK_ORDERS`, `VBH.MEETING`, `VBH.EXEC_UPDATE`, the option lists, and `window.VBH_CONFIG` for `meeting.html`.
- **`assets/vbh.css`** owns design tokens and the chrome (`.vbh-nav`, `.vbh-header`, `.vbh-foot`, `.vbh-gate`) plus opt-in components namespaced `vbh-btn` / `vbh-badge` / `vbh-card`. Pages keep their own layout CSS and may still define their own `.btn`/`.card` — no collision.
- **`assets/vbh-shell.js`** reads `<body data-vbh-page="id">`, injects the nav (active page marked, Lock button), fills `<div data-vbh-header>` (children become header actions; `data-title`/`data-sub` override), fills `<div data-vbh-foot>`, renders hub tiles into `[data-vbh-tiles]`, sets `document.title`, and shows the gate on protected pages. `data-vbh-chrome="header"` = header + footer only (public forms); `data-vbh-ask-name` also asks the editor's name (meeting). Exposes `VBH.auth.require(cb)`, `VBH.sb()`, `VBH.toast()`, `VBH.esc()`, and fires `vbh:ready`. Fails open: content is never left hidden if the script errors.
- Page-specific init that must wait for the gate: `VBH.auth.require(init)`.

## Auth (current state — interim)

One shared password, `VBH.PASSWORD`, checked by the shell gate and remembered in `localStorage` (`vbh_auth`, 12-hour TTL, cleared by the nav Lock button). One key for the whole hub — unlocking any page unlocks all. Legacy `sessionStorage` flags are migrated on first load. There is **no** Netlify Identity, no role matrix. Real login is on the roadmap. `index.html` (work-order request form) and `intake.html` (client intake) are public on purpose (`protected:false` in the registry).

## Pages (all in `public/`)

- `hub.html` — landing page; tiles render from `VBH.PAGES`
- `meeting.html` — weekly production meeting agenda (build `meeting-v6`), Supabase-backed (`meetings` JSON snapshots, `project_updates` history). Keeps its own toolbar under the shared nav. State object `S` is the only source of truth; the DOM is a projection. Read its architecture comment before touching it.
- `projects.html` — project tracker (`projects`)
- `leads.html` — pipeline with probability pills and archive (`leads`)
- `weeklyupdate.html` — exec briefing for ownership (no hyphen in the filename); recipients/sender come from `VBH.EXEC_UPDATE`
- `gantt.html`, `equipment.html` (`assets`), `raci.html`, `standards.html`
- `index.html` + `dashboard.html` — development-maintenance work-order request form and dispatch board (`work_orders`, helper `db.js`)
- `intake.html` — client intake form (writes to `leads`)
- `archive/` (repo root, not deployed) — retired one-time migration tools.

Don't restructure a page's working area unless the task says so; chrome changes go in the shell, not in pages.

## Meeting cadence

Production meeting: **Tuesdays, 9:00–10:00 AM Central.** `VBH_CONFIG.meetingTime` drives every section clock on `meeting.html`. Agenda is staged Monday morning; a digest goes out Friday afternoon (both part of the bridge roadmap).

## Brand

- Colors: Navy `#1B3564`, Steel Blue `#6B8EB5`, Light `#EBF0F7`, Gold `#C9A84C`
- Fonts: Cormorant Garamond for headers, Lato for body
- Add or bump a build stamp comment on any deployed page you touch, e.g. `<!-- build:bridge-v1 -->`, so the live version can be verified with a fetch.

## How Jordan works

- Challenge before building. If something is inconsistent or underspecified, say so first. Batch the questions, don't drip them.
- Production-ready output only. No placeholder content, no "TODO: fill in later."
- Small scoped changes. Propose, show the diff, wait for review, then widen. Once a direction is approved ("go for it"), keep momentum — don't re-ask settled questions.
- One home for each type of data. Buildertrend is the source of truth for schedule, selections, pricing, and client updates. Supabase holds the operational layer on top. Don't create a second copy of something that already has a home — read it where it lives (e.g. the meeting page reads `bt_events` live rather than copying it into the meeting JSON).
- Role-based, not person-based. Name roles in code and data, not individuals. Team rosters are config data, not logic.
- Verify against disk and the live site before trusting docs (including this one).

## Buildertrend email bridge

### Why

Buildertrend has no public API. Its notification emails are templated, so they're a reliable data source we control. The goal: Buildertrend feeds Supabase automatically, `meeting.html` job cards and a digest render themselves, and the Tuesday meeting spends its time on what's ahead instead of recapping last week.

### What exists (migration `001_bt_bridge.sql`, build `bt-bridge-v1`)

- `bt_emails` — every message raw, unique on `message_id`. Never dropped.
- `bt_events` — one parsed record per email: `event_type`, `job_number` (e.g. `R26009`), `actor`, `title`, `amount`, `period_start/end`, `summary`, `link`, `fields` jsonb, `parser_version`.
- `bt_ingest_runs` — audit log per run. `bt_settings` — ingest secret (RLS, no anon policy).
- Parser is plpgsql (`bt_parse_email`) fired by an insert trigger; per-email error isolation; `bt_reparse_all()` re-runs the current parser over all raw mail.
- Entry point `bt_ingest_email(...)` — idempotent, returns `inserted`/`duplicate`.
- Read views: `v_bt_events`, `v_bt_job_activity` (14-day per-job roll-up for job cards), `v_bt_unclassified`.

### Notification types (from real samples, 2026-09-14)

Present and parsed: `client_update` (weekly PM update — **body is a ~170-char teaser ending in `..."`, full text is behind the login link**), `change_order_added`, `change_order_approved` (credits arrive as `($102,500.00)` → negative), `change_order_file`, `document_comment`. Not present in samples (all notifications were turned on 2026-09-14, so they'll start arriving): schedule changes, selections, daily logs, client messages. Add a parser only once a real sample is in `samples/`; until then they land as `unclassified`.

Notification sender is `vanbuskirkhomes@buildertrend.com`. Other `@buildertrend.com` senders are sales/marketing and stay `unclassified`.

### Ingest path

Microsoft Graph poll of Jordan's Outlook **Buildertrend** folder from a Supabase Edge Function on a `pg_cron` schedule. Requires an Azure app registration (application permission `Mail.Read`, restricted to Jordan's mailbox by an application access policy) — IT request in `docs/`. Until IT grants it, the manual bridge is: export the Outlook folder to CSV → `tools/build-bt-sample-seed.ps1` → run the seed SQL.

### Constraints

- Job number `R#####`/`M#####` is the key everywhere and matches `projects.job_number`.
- Tolerant parsing: unknown template → `unclassified` with raw body. Never fail a batch on one email.
- Log parsed vs skipped per run (`bt_ingest_runs`).
- Idempotent on Message-ID.
- Schema → parser → ingest → digest. Don't build the digest before parsing is solid on live mail.

## Roadmap (in order)

1. Bridge live: IT approves Graph app → Edge Function deployed → `pg_cron` every 15 min → parser tuned on live mail.
2. ~~meeting.html integration~~ — done in `meeting-v6`: auto roll-forward to the coming meeting day on open; every solds/escrow/model tracker project gets a card (`ensureActiveProjectCards`); read-only Buildertrend strip per card from `v_bt_events`; unmatched-jobs banner from `v_bt_unmatched_jobs`. Buildertrend data is read live, never stored in the meeting JSON.
3. `digest.html` in the hub + Friday/Monday email.
4. Real login: Supabase Auth (magic link) + `profiles.role` with roles Owner, Ops Admin, Manager, Field, Labor; RLS on every table; retire the shared password. The shell gate is the single swap point.
5. ~~Hub cleanup~~ — done in `cleanup-v1` / `shell-v1` (shared logo, migration pages archived, one config, shared chrome, build stamps).
