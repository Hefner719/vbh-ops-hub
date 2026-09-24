-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 007 · close anonymous access   (auth-phase-b)
--
--  ⚠ DO NOT RUN until every person in `vbh_role_seed` has signed in at least
--    once. Check first:
--
--      select s.email, (p.id is not null) as has_signed_in, p.role, p.active
--      from vbh_role_seed s left join profiles p on lower(p.email) = lower(s.email)
--      order by has_signed_in, s.email;
--
--    Anyone still showing has_signed_in = false loses access the moment this
--    runs. They get it back by signing in — nothing is destroyed — but it will
--    look like an outage to them, so do this deliberately, not mid-meeting.
--
--  What it changes: the anon key (published in vbh-config.js, readable by
--  anyone who views source) stops being able to read or write operational
--  data. The authenticated policies from migration 006 take over.
--
--  What stays open, deliberately: the two public forms must work for people
--  who are not signed in, so anon keeps INSERT — and only INSERT — on
--  work_orders and leads. It cannot read back what it wrote.
--
--  Rollback, if something is wrong:  \i 008_auth_rollback.sql   (see below)
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- ── 1 · drop the blanket anon policies ─────────────────────────────────────
drop policy if exists "public_all"           on leads;
drop policy if exists "meetings_rw"          on meetings;
drop policy if exists "project_updates_all"  on project_updates;
drop policy if exists "projects anon all"    on projects;
drop policy if exists "assets anon all"      on assets;
drop policy if exists "Public insert"        on work_orders;
drop policy if exists "Public read"          on work_orders;
drop policy if exists "Public update"        on work_orders;

-- Bridge tables: remove the anon read left over from migration 001.
drop policy if exists "hub read" on bt_emails;
drop policy if exists "hub read" on bt_events;
drop policy if exists "hub read" on bt_ingest_runs;

-- ── 2 · narrow paths for the two public forms ──────────────────────────────
-- index.html (work order request) and intake.html (client intake) are used by
-- people with no account. INSERT only: a passer-by can file a request but
-- cannot list, alter or delete anything, including their own submission.
drop policy if exists "public form insert" on work_orders;
create policy "public form insert" on work_orders
  for insert to anon with check (true);

drop policy if exists "public form insert" on leads;
create policy "public form insert" on leads
  for insert to anon with check (true);

-- index.html uploads photos to storage; that is governed by storage policies,
-- not these tables, and is unaffected.

commit;

-- ── 3 · verify ─────────────────────────────────────────────────────────────
-- Expect: anon INSERT only on leads and work_orders; everything else
-- authenticated. Run this and read it before telling anyone it is done.
select tablename,
       string_agg(cmd || ':' || array_to_string(roles, '/'), ', ' order by cmd) as policies
from pg_policies
where schemaname = 'public'
  and tablename in ('projects','leads','meetings','project_updates','work_orders',
                    'assets','bt_emails','bt_events','bt_ingest_runs','profiles')
group by tablename
order by tablename;
