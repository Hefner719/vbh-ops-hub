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
- Hosted on Netlify at vbchomes.net; `netlify.toml` declares publish dir, pretty URLs (`/projects` serves `projects.html` — always link extensionless), and headers. PWA manifests: `manifest.json` (hub) plus `manifest-intake.json`. The site root `/` is a 302 to `/hub` — there is no index.html.
- Backend is Supabase, project ref `bppirsahciuxrqzitfxa`. The anon key is public by design and lives only in `public/vbh-config.js` (`VBH.SUPABASE_KEY`). **Never** put a service-role key, a Graph client secret, or any other secret in this repo. Secrets go in Supabase Edge Function secrets or Netlify env vars.
- Supabase tables in use: `projects` (+ view `v_active_projects`), `project_updates`, `leads`, `meetings`, `assets`, `action_items`, and the `bt_*` bridge tables below.

## The shell (build `shell-v1`) — how every page is put together

Three shared files, loaded in this order in `<head>`: `/vbh-config.js` → `/assets/vbh.css` → `/assets/vbh-shell.js`. Then the page's own `<style>` and script.

- **`vbh-config.js`** is the one config file. `VBH.PAGES` is the page registry: id, path, nav label, group, title/subtitle, hub tile, `protected`. Adding a page = one entry here + a body attribute on the page. Also holds `VBH.ROLES` (opsDirector, ceo, coo), `VBH.WORK_ORDERS`, `VBH.MEETING`, `VBH.EXEC_UPDATE`, the option lists, and `window.VBH_CONFIG` for `meeting.html`.
- **`assets/vbh.css`** owns design tokens and the chrome (`.vbh-nav`, `.vbh-header`, `.vbh-foot`, `.vbh-gate`) plus opt-in components namespaced `vbh-btn` / `vbh-badge` / `vbh-card`. Pages keep their own layout CSS and may still define their own `.btn`/`.card` — no collision.
- **`assets/vbh-shell.js`** reads `<body data-vbh-page="id">`, injects the nav (active page marked, Lock button), fills `<div data-vbh-header>` (children become header actions; `data-title`/`data-sub` override), fills `<div data-vbh-foot>`, renders hub tiles into `[data-vbh-tiles]`, sets `document.title`, and shows the gate on protected pages. `data-vbh-chrome="header"` = header + footer only (public forms); `data-vbh-ask-name` also asks the editor's name (meeting). Exposes `VBH.auth.require(cb)`, `VBH.sb()`, `VBH.toast()`, `VBH.esc()`, and fires `vbh:ready`. Fails open: content is never left hidden if the script errors.
- Page-specific init that must wait for the gate: `VBH.auth.require(init)`.

## Auth (current state — interim)

One shared password, `VBH.PASSWORD`, checked by the shell gate and remembered in `localStorage` (`vbh_auth`, 12-hour TTL, cleared by the nav Lock button). One key for the whole hub — unlocking any page unlocks all. Legacy `sessionStorage` flags are migrated on first load. There is **no** Netlify Identity, no role matrix. Real login is on the roadmap. `intake.html` (client intake) is public on purpose (`protected:false` in the registry) — it is now the only unauthenticated page.

## Pages (all in `public/`)

- `hub.html` — landing page; tiles render from `VBH.PAGES`
- `meeting.html` — weekly production meeting agenda (build `meeting-v10`), Supabase-backed (`meetings` JSON snapshots, `project_updates` history). Keeps its own toolbar under the shared nav. State object `S` is the only source of truth; the DOM is a projection. Read its architecture comment before touching it.
  - **Concurrent editing (v10).** Several people have this open during the meeting. Saves are a compare-and-swap on `meetings.rev`; a failed swap is resolved by a three-way merge against `mtg.base` (the state this tab shares with the server), not by asking someone to discard their work. Every tab also polls for a newer revision every 8s and folds it in. Anything added to the state object needs a merge rule in `mergeStates()`, or it will silently take the server's copy.
  - **Removing a job card is remembered.** `ensureActiveProjectCards()` adds a card for every tracker project in a `solds`/`escrow`/`model` stage, so a removal used to last only until the next page load. Removals are now recorded in `state.dropped` against the project plus the stage it was in, and the card returns only when that project changes stage.
- `projects.html` — project tracker (`projects`)
- `leads.html` — pipeline with probability pills and archive (`leads`)
- `weeklyupdate.html` — exec briefing for ownership (no hyphen in the filename); recipients/sender come from `VBH.EXEC_UPDATE`
- `gantt.html`, `equipment.html` (`assets`), `raci.html`, `standards.html`
- `intake.html` — client intake form (writes to `leads`)
- `archive/` (repo root, not deployed) — retired one-time migration tools, and `work-orders-retired-2026-10-05/` holding the 34 exported work-order records.

**Retired 2026-10-05/06:** the development-maintenance work-order form (`index.html`), dispatch board (`dashboard.html`), `db.js`, their manifests and icons, the `VBH.WORK_ORDERS` roster, and the `work_orders` table (migration 022) — that side of the business wound down. Records are in `archive/`. Dropping the table also removed the last three `Public insert/read/update` policies on the project. The 24 `dev_maint` projects were then moved to `closed` (migration 023, exported first); `projects.stage` now holds only `solds`, `model` and `closed`, and `dev_maint` is a dead category kept in `projects.html`'s UI the same way `escrow` is — it simply counts 0.

`projects.stage` drives what counts as active: `ensureActiveProjectCards()` on the meeting page, `v_bt_client_update_cadence` and `v_bt_daily_log_cadence` all read `solds` / `escrow` / `model`. Note that **`v_active_projects` does not filter by stage despite its name** — it is `projects` plus each project's most recent `project_updates` row, and `projects.html` filters by stage client-side.

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

### What exists (migrations 001-005, build `bt-bridge-v2`)

- `bt_emails` — every message raw, unique on `message_id`. Never dropped.
- `bt_events` — one parsed record per email: `event_type`, `job_number` (e.g. `R26009`), `actor`, `title`, `amount`, `period_start/end`, `summary`, `link`, `fields` jsonb, `parser_version`.
- `bt_ingest_runs` — audit log per run. `bt_settings` — ingest secret (RLS, no anon policy).
- Parser is plpgsql (`bt_parse_email`) fired by an insert trigger; per-email error isolation; `bt_reparse_all()` re-runs the current parser over all raw mail.
- Entry point `bt_ingest_email(...)` — idempotent, returns `inserted`/`duplicate`.
- Read views: `v_bt_events`, `v_bt_job_activity`, `v_bt_unclassified`, `v_bt_unmatched_jobs`, `v_bt_job_finance`, `v_bt_open_todos`, `v_bt_health`, and from v4 `v_bt_job_invoices` (event log), `v_bt_invoice_status` (one row per invoice, newest notification wins — use this one for "what is still in draft"), `v_bt_awaiting_approval`, `v_bt_client_update_gap`.
- An invoice's `status` is only as current as the last email about it. Buildertrend notifies on create and update, so "Draft" means *draft as of the last notification*, not confirmed-still-draft.
- From v5 (migration 020): `v_bt_bill_status` (every bill, ready → paid lifecycle), `v_bt_bills_outstanding` (only what is still owed), `v_bt_client_update_cadence` (Fridays since each active job's last client update), helper `bt_fridays_since(date)`.
- **Never count `bill_ready` events as a backlog.** `bill_ready` and `bill_paid` are separate notifications with no shared id, so counting ready emails counts history — 180 bills marked ready, 117 of them already paid. They match on job + the vendor's invoice number: `bill_ready.fields.bill_no` appears inside `bill_paid.fields.bill_title` (`<JOB>-<bill_no> - <description>`). Match by containment, not a strict prefix — a few bill numbers aren't numeric (`Sttlmnt Stmnt`).
- Bill notifications only start **2026-09-14**. Anything marked ready before that is absent from the lifecycle view rather than wrongly shown as owed.
- Client update cadence is measured in **Fridays, not days** (`BT_STALE_FRIDAYS = 2` on the page, `bt_fridays_since()` in SQL — keep the two in step). The update is a Friday job, so "14 days" and "two Fridays" are different questions.
- **Date-only vs timestamp.** A bare `YYYY-MM-DD` from a Postgres `date` column is parsed by JS as UTC midnight and lands on the previous day in Central time. `fridaysSince()` and `fmtBtDate()` both split date-only strings from timestamps; any new date helper must do the same or it will be off by one.

### Notification types (parser v4, migration 019)

Schedule and scope: `client_update` (weekly PM update - **body is a ~170-char teaser ending in `..."`, full text is behind the login link**), `client_update_ready` (Buildertrend saying the weekly updates have **not** gone out yet), `change_order_added`, `change_order_approved` (credits arrive parenthesised, e.g. `($102,500.00)`, and are stored negative), `change_order_file`, `document_comment`, `todo_overdue`.

Money out: `invoice_created` / `invoice_updated` (job, amount, `fields.invoice_id`, `status`, `balance_due`, `deadline`), `bill_approval_needed` (job, bill #, vendor, amount — Buildertrend re-sends the same reminder daily, so dedupe on `fields.bill_number`).

Accounts payable (~90% of folder volume): `bill_paid`, `bill_ready`, `lien_waiver_signed`, `bills_overdue` and `bills_upcoming` (digests; individual bills in `fields.bills[]`), `invoice_overdue`, `insurance_expiring` (vendor-level, no job number; `fields.vendors[]`). Also `vendor_activated`, `timesheet_long`.

**Senders matter.** The whole v2/v3 branch chain is gated on `vanbuskirkhomes@buildertrend.com`. Bill approvals and sub/vendor activations come from `info@buildertrend.com` and so were invisible to the parser until v4 — check the sender before concluding a template "isn't arriving". Everything else `@buildertrend.com` is sales, marketing or account mail and is classified `bt_marketing`, which keeps `unclassified` meaning "a template we don't understand yet".

Still unseen: schedule changes, selections, daily logs, client messages. Add a parser only once a real sample is in the mailbox; until then they land as `unclassified`.

**Daily logs and schedule shifts can't be tracked from notification email — confirmed 2026-10-05 against Buildertrend's help centre, not assumed.** A Daily Log emails only the people hand-picked in that log's **Notify Users** field, and a schedule shift is a *prompted manual send* to assignees. Neither is a subscription you can switch on, there is no Daily Log reminder or digest, and Client Updates do not auto-pull daily logs. So a missing email means "nobody ticked the box", not "no log was written" — an alert built on that absence would be false most of the time. Don't build one on the email bridge; it needs a different source.

38 emails stay unclassified on purpose: human correspondence that lives in the same Outlook folder.

### Ingest path

**Live since 2026-09-24.** A Supabase Edge Function (`bt-ingest`) polls the Outlook folder `**Buildertrend` (note the two asterisks; it sits under Inbox / *VB Homes / #8 OFFICE) through Microsoft Graph, driven by `pg_cron` every 15 minutes (migration 002, `bt_trigger_ingest`). Credentials live in `%USERPROFILE%\.vbh\bt-graph.env` and are pushed with `tools/sb-fn-secrets.ps1`; `tools/bt-test-graph.ps1` preflights token, consent, mailbox policy and folder. Deploy with `tools/sb-fn-deploy.ps1 -Name bt-ingest`. Modes: `poll` (default, 6h overlap), `backfill&days=N`, `rerender`.

The client secret expires 2028-09-21 - rotate with `tools/sb-fn-secrets.ps1 -Only GRAPH_CLIENT_SECRET`.

### Constraints

- Job number `R#####`/`M#####` is the key everywhere and matches `projects.job_number`.
- Tolerant parsing: unknown template → `unclassified` with raw body. Never fail a batch on one email.
- Log parsed vs skipped per run (`bt_ingest_runs`).
- Idempotent on Message-ID.
- Schema → parser → ingest → digest. Don't build the digest before parsing is solid on live mail.

## Roadmap (in order)

1. ~~Bridge live~~ - done 2026-09-24: Graph app registered, Edge Function deployed, `pg_cron` polling every 15 min, 343 emails backfilled to Jun 2025, CSV import retired, parser v2 tuned on live mail (unclassified 307 -> 67).
2. ~~meeting.html integration~~ — done in `meeting-v6`: auto roll-forward to the coming meeting day on open; every solds/escrow/model tracker project gets a card (`ensureActiveProjectCards`); read-only Buildertrend strip per card from `v_bt_events`; unmatched-jobs banner from `v_bt_unmatched_jobs`. Buildertrend data is read live, never stored in the meeting JSON.
3. `digest.html` — page shipped (`digest-v1`): activity by job for a 7/14/30-day window, stale and unmatched lists, unclassified emails, bridge health; Copy + "Email team" (Outlook draft to `VBH.MEETING.team`). Still open: the *scheduled* Friday/Monday send, which needs a mail sender once live ingest exists.
4. Real login: Supabase Auth (magic link) + `profiles.role` with roles Owner, Ops Admin, Manager, Field, Labor; RLS on every table; retire the shared password. The shell gate is the single swap point.
5. ~~Hub cleanup~~ — done in `cleanup-v1` / `shell-v1` (shared logo, migration pages archived, one config, shared chrome, build stamps).
