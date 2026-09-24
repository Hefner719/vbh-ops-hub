-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 008 · undo the Phase B lockdown   (auth-rollback)
--
--  Restores the pre-2026-09-24 anon policies exactly. Use only if closing
--  anonymous access breaks something during the rollout and people need to
--  work right now; then fix the cause and run 007 again.
--
--  Being explicit about the cost: while this is in effect, anyone who views
--  source on vbchomes.net can read, change and delete projects, leads,
--  meetings, project_updates and assets. It is a fallback, not a resting
--  state. Do not leave it applied overnight.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

drop policy if exists "public form insert" on work_orders;
drop policy if exists "public form insert" on leads;

create policy "public_all"          on leads           for all to public using (true) with check (true);
create policy "meetings_rw"         on meetings        for all to public using (true) with check (true);
create policy "project_updates_all" on project_updates for all to public using (true) with check (true);
create policy "projects anon all"   on projects        for all to anon   using (true) with check (true);
create policy "assets anon all"     on assets          for all to anon   using (true) with check (true);

create policy "Public insert" on work_orders for insert to public with check (true);
create policy "Public read"   on work_orders for select to public using (true);
create policy "Public update" on work_orders for update to public using (true);

create policy "hub read" on bt_emails      for select to anon, authenticated using (true);
create policy "hub read" on bt_events      for select to anon, authenticated using (true);
create policy "hub read" on bt_ingest_runs for select to anon, authenticated using (true);

commit;

select tablename, string_agg(cmd || ':' || array_to_string(roles,'/'), ', ' order by cmd) as policies
from pg_policies where schemaname='public'
group by tablename order by tablename;
