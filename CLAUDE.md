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
- Hosted on Netlify at vbchomes.net. PWA manifests per page. Pretty URLs are on (`/hub` serves `hub.html`).
- Backend is Supabase, project ref `bppirsahciuxrqzitfxa`. The anon key is public by design and lives in `public/vbh-config.js` (`VBH.SUPABASE_KEY`) and `public/config.js` (`SUPABASE_ANON_KEY`). **Never** put a service-role key, a Graph client secret, or any other secret in this repo. Secrets go in Supabase Edge Function secrets or Netlify env vars.
- Supabase tables in use: `projects` (+ view `v_active_projects`), `project_updates`, `leads`, `meetings`, `work_orders`, `assets`, and the `bt_*` bridge tables below.

## Auth (current state — interim)

One shared password, `VBH.PASSWORD` in `public/vbh-config.js`, checked client-side and remembered in `sessionStorage` (`vbh_auth_ok`). It is also hardcoded as a fallback literal in `hub.html`, `meeting.html`, `projects.html`. There is **no** Netlify Identity, no role matrix, no `vbh-auth.js`, no `_headers`. Real login is on the roadmap (see below). `index.html` (work-order request form) and `intake.html` (client intake) are public on purpose.

## Pages (all in `public/`)

- `hub.html` — landing page / navigation
- `meeting.html` — weekly production meeting agenda (build `meeting-v4`), Supabase-backed (`meetings` JSON snapshots, `project_updates` history). State object `S` is the only source of truth; the DOM is a projection. Read its architecture comment before touching it.
- `projects.html` — Kanban project tracker (`projects`)
- `leads.html` — pipeline with probability pills and archive (`leads`)
- `weeklyupdate.html` — exec briefing for ownership (no hyphen in the filename)
- `gantt.html`, `equipment.html` (`assets`), `raci.html`, `standards.html`
- `index.html` + `dashboard.html` — development-maintenance work-order request form and dispatch board (`work_orders`)
- `intake.html` — client intake form (writes to `leads`)
- `migrate.html`, `migrate-projects.html` — one-time data migration tools. Slated for removal.

Don't restructure existing pages unless the task says so.

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
2. `meeting.html` job cards show a read-only "since last meeting" strip from `v_bt_job_activity`; auto-rollover on first open of a new meeting week; auto-add cards for active projects with Buildertrend activity.
3. `digest.html` in the hub + Friday/Monday email.
4. Real login: Supabase Auth (magic link) + `profiles.role` with roles Owner, Ops Admin, Manager, Field, Labor; RLS on every table; retire the shared password.
5. Hub cleanup: one shared logo file instead of base64 in four pages, remove migration pages, single config file, build stamps everywhere.
