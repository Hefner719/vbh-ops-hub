-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 026 · close nine finished or retired projects,
--                                rename the Hitchcock Place model
--
--  Tracker cleanup, 2026-11-16, at the Director of Operations' direction. These
--  were still sitting in `solds`, which every "active job" read treats as live
--  work: the meeting's tracker picker, the new-starts banner, the Buildertrend
--  client-update and daily-log cadence views, and job counts.
--
--    R25026  170 Village Circle Mydland   completed (closed 2026-09-21)
--    R25027  171 Village Circle Mydland   completed (closed 2026-07-31)
--    R25029  164 Village Circle           completed
--    R26008  1517 Lakeview Remodel #1     completed
--    R25002  Mapleton Cottages            development-level job, off the tracker
--    R25004  1529 Lakeview Lane Units 1-4 off the tracker
--    R25030  Hitchcock Place OVERALL JOB  development-level job, off the tracker
--    R26015  33 Riverview Heights         off the tracker
--    R26020  2800 Brandywine Circle       completed (phase set to DONE)
--
--  And R26002, the Hitchcock Place model in Mitchell, takes its street address:
--  "Hitchcock Place Model Home #1" -> "1200 E. Hanson", written the same way as
--  its neighbour R26030 "1204 E. Hanson". Agenda cards relabel themselves from
--  the tracker on load (syncCardsFromTracker), so the meeting follows.
--
--  MOVED, not deleted - same rule as migration 023. Only `stage` changes; the
--  last phase_note, status and pct_complete stay as the record of where each
--  job stopped, and closing_date is not invented for the ones without one.
--
--  Production meeting: R26008 and R26020 were the only ones of the nine still
--  carded on the agenda (linked by projectId). meeting.html's removeClosedProjectJobs() drops
--  any card linked to a closed project on every load, including right after the
--  Monday roll-forward, so no agenda edit is needed here. Past meetings keep
--  their cards - those are the archive of what was discussed.
--
--  Left open on purpose: action item rxw4hj3bngc, "Reschedule service call for
--  170 Village Circle (RO system)" (Justin, due 2026-10-06). Closing the job is
--  not closing the service call.
--
--  Before-state (all nine were stage = 'solds'):
--    R25002 46622a85-ea0b-4c86-9217-76a60a8e1874  status -       pct -     phase -
--    R25004 07d4a1b8-8bfb-4604-88ce-05dfbb0eaef6  status -       pct -     phase -
--    R25026 c1c8aa7c-054e-476d-8c8e-342f3ed9dbdb  status -       pct 0.990 phase Punch List
--    R25027 82918829-a16c-4c3f-928c-30fab95b221d  status -       pct 1.000 phase Punch List
--    R25029 edeb090e-a678-4d8c-b77f-4a112e8101a1  status -       pct -     phase Confirm status
--    R25030 366bb5ca-41f6-4e25-9393-d841b38deced  status -       pct -     phase -
--    R26008 0f8c1b9c-8c21-4574-8280-0c586c29134d  status Behind  pct 1.000 phase Exterior / Siding
--    R26015 4e67b3d2-49cb-4506-914b-9a7c4eafe320  status -       pct -     phase -
--    R26020 1f345a5d-e34c-4ae1-9ed9-226ddfaffc8d  status -       pct 0.820 phase DONE
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- Fail loudly if any of the nine moved somewhere other than solds or closed
-- since this was written. Re-running is a no-op: closed rows are skipped.
do $$
declare n int;
begin
  select count(*) into n from projects
   where job_number in ('R25026','R25027','R25029','R26008','R25002','R25004','R25030','R26015','R26020')
     and lower(coalesce(stage,'')) not in ('solds','closed');
  if n <> 0 then
    raise exception '% of these projects are in an unexpected stage - check before closing', n;
  end if;
end $$;

update projects
   set stage = 'closed',
       updated_at = now(),
       updated_by = 'Tracker cleanup 2026-11-16 (migration 026)'
 where job_number in ('R25026','R25027','R25029','R26008','R25002','R25004','R25030','R26015','R26020')
   and lower(coalesce(stage,'')) = 'solds';

update projects
   set address = '1200 E. Hanson',
       updated_at = now(),
       updated_by = 'Tracker cleanup 2026-11-16 (migration 026)'
 where job_number = 'R26002'
   and address = 'Hitchcock Place Model Home #1';

commit;

-- ── what the agenda set holds now ──────────────────────────────────────────
select lower(coalesce(stage,'(null)')) as stage, count(*) as projects
from projects group by 1 order by 2 desc;
