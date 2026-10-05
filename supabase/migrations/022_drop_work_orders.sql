-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 022 · retire the work_orders table
--
--  The development-maintenance side of the business has wound down. The
--  request form, the dispatch board and their config were removed from the
--  site in the preceding commit and that deploy is live, so nothing reads this
--  table any more.
--
--  THIS IS IRREVERSIBLE. Before running it:
--    · all 34 rows were exported to
--        archive/work-orders-retired-2026-10-05/work_orders.{json,csv}
--      and verified - 34 rows, 22 columns, readable from both files
--    · the 2026-10-05 nightly backup also contains the table in full
--    · six were never closed out (five Approved, one Pending Approval, newest
--      2026-08-29). They are in the export, not lost - but they were never
--      finished, and that is worth knowing rather than discovering later.
--
--  A side benefit worth recording: this table carried "Public insert",
--  "Public read" and "Public update" policies so the unauthenticated request
--  form could work. That is three fewer anon-writable surfaces on the project,
--  and one less thing for the Phase B lockdown to reason about.
--
--  No views or foreign keys depend on it; the row-level policies and the
--  updated_at trigger are dropped with the table. The shared trigger FUNCTION
--  is left alone - other tables still use it.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- Refuse to run if the table is not the one we exported. Better to fail loudly
-- than to drop something that grew rows after the export was taken.
do $$
declare n int;
begin
  select count(*) into n from work_orders;
  if n <> 34 then
    raise exception 'work_orders has % rows, expected the 34 that were exported - re-export before dropping', n;
  end if;
end $$;

drop table if exists work_orders;

commit;

-- ── confirm it is gone, and that nothing else broke ────────────────────────
select to_regclass('public.work_orders') is null as work_orders_dropped;

select count(*) as remaining_public_write_policies
from pg_policies
where schemaname = 'public'
  and cmd in ('INSERT','UPDATE','DELETE')
  and qual is not distinct from null
  and policyname ilike 'public%';
