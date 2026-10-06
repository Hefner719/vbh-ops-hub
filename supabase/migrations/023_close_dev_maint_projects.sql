-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 023 · close the development-maintenance projects
--
--  The development-maintenance side wound down (its work-order form, dispatch
--  board and table went in migrations 022 and the preceding commits). Twenty-
--  four projects were still sitting in the tracker as `dev_maint`, which every
--  "active project" read treats as live work: project counts, the unmatched-job
--  banner, anything filtering on not-closed.
--
--  These are MOVED, not deleted. Unlike the retired app pages, this is real
--  history - what was built where, and when. Stage becomes 'closed' and
--  nothing else is touched: the existing closed projects keep their last
--  phase_note, status and pct_complete as a record of where they stopped, and
--  these should read the same way.
--
--  closing_date is deliberately left alone. It means the day a home closed;
--  inventing one for a maintenance job would put a fiction into a column other
--  things read.
--
--  BEFORE RUNNING: all 24 rows exported to
--    archive/dev-maint-closed-2026-10-06/projects_dev_maint_before_close.{json,csv}
--
--  Checked first, and worth keeping in the record: 22 of the 24 have had no
--  Buildertrend activity at all in 90 days, and NONE has an outstanding bill.
--  Two have an unpaid invoice owed TO Van Buskirk, last reported 2026-09-16:
--    M26106 Mapleton Highlands  $6,597.68  (invoice M26106-0004)
--    M26111 Akerson Commercial  $2,185.96  (invoice M26111-0004)
--  Closing the tracker stage is an operational classification and changes
--  nothing about those receivables - they live in Buildertrend and QuickBooks.
--  Noted here so closing the job is not mistaken for closing the money.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- Fail loudly rather than close something that changed since the export.
do $$
declare n int;
begin
  select count(*) into n from projects where lower(coalesce(stage,'')) = 'dev_maint';
  if n <> 24 then
    raise exception 'expected the 24 dev_maint projects that were exported, found % - re-export first', n;
  end if;
end $$;

update projects
   set stage = 'closed',
       updated_at = now(),
       updated_by = 'Dev-maintenance wind-down (migration 023)'
 where lower(coalesce(stage,'')) = 'dev_maint';

commit;

-- ── what the tracker holds now ─────────────────────────────────────────────
select lower(coalesce(stage,'(null)')) as stage, count(*) as projects
from projects group by 1 order by 2 desc;

-- The agenda set is untouched: still the same active builds.
select count(*) as still_active
from projects
where lower(coalesce(stage,'')) in ('solds','escrow','model');
