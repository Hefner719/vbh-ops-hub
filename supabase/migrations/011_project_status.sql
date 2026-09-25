-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 011 · one meaning for projects.status
--
--  THE PROBLEM
--  `projects.status` was written by two pages with different vocabularies:
--  projects.html offered a free-text box hinting "Rental / Customer / For Sale
--  / SOLD", while meeting.html offered a dropdown of On Track / At Risk /
--  Behind. The column ended up holding four different concepts —
--
--    schedule health   On Track, On track, DONE
--    sale/occupancy    Rental, Customer, SOLD
--    construction phase Foundation, Punch, punch list, Road
--    a workflow flag   Confirm
--
--  — which is why nothing could filter or report on it reliably.
--
--  THE DECISION
--  `status` becomes schedule health only, using the list meeting.html already
--  uses. That is what the meeting, the digest and the exec update all ask of
--  it. Construction phase already has a column of its own (`phase_note`), and
--  sale/occupancy belongs to the development-maintenance side, which is being
--  retired at the end of 2026.
--
--  NOTHING IS DISCARDED. Values that are not schedule health are copied into
--  `phase_note` (when empty) or appended to `notes`, with a marker, before the
--  status is cleared. Read `status_cleanup_log` afterwards to see every change.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- A record of what this migration touched, so the change is reviewable and
-- reversible by hand if a judgement here was wrong.
create table if not exists status_cleanup_log (
  id          bigint generated always as identity primary key,
  job_number  text,
  old_status  text,
  new_status  text,
  moved_to    text,
  moved_value text,
  changed_at  timestamptz not null default now()
);

-- ── 1 · casing and synonyms → the controlled list ──────────────────────────
with fixed as (
  select id, job_number, status,
         case lower(btrim(status))
           when 'on track'  then 'On Track'
           when 'ahead'     then 'Ahead'
           when 'at risk'   then 'At Risk'
           when 'behind'    then 'Behind'
           when 'on hold'   then 'On Hold'
           when 'blocked'   then 'Blocked'
           when 'done'      then 'Complete'
           when 'complete'  then 'Complete'
           when 'completed' then 'Complete'
         end as norm
  from projects
  where status is not null and btrim(status) <> ''
)
, upd as (
  update projects p set status = f.norm
  from fixed f
  where p.id = f.id and f.norm is not null and p.status is distinct from f.norm
  returning p.job_number, f.status as old_status, f.norm as new_status
)
insert into status_cleanup_log (job_number, old_status, new_status)
select job_number, old_status, new_status from upd;

-- ── 2 · phase-like values → phase_note ─────────────────────────────────────
-- Only when phase_note is empty; a real phase already recorded there wins.
with phaseish as (
  select id, job_number, status, phase_note
  from projects
  where status is not null and btrim(status) <> ''
    and lower(btrim(status)) in ('foundation','punch','punch list','road','framing',
                                 'flatwork','drywall','trim','paint','siding','permit')
)
, upd as (
  update projects p
     set phase_note = case when coalesce(btrim(p.phase_note), '') = '' then x.status else p.phase_note end,
         status     = null
  from phaseish x
  where p.id = x.id
  returning p.job_number, x.status as old_status,
            case when coalesce(btrim(x.phase_note), '') = '' then 'phase_note' else '(phase_note already set)' end as moved_to,
            x.status as moved_value
)
insert into status_cleanup_log (job_number, old_status, new_status, moved_to, moved_value)
select job_number, old_status, null, moved_to, moved_value from upd;

-- ── 3 · sale/occupancy values → notes, then cleared ────────────────────────
-- Retired with the development-maintenance side at the end of 2026; kept as a
-- note so the information is not lost in the meantime.
with saleish as (
  select id, job_number, status, notes
  from projects
  where status is not null and btrim(status) <> ''
    and lower(btrim(status)) in ('rental','customer','sold','for sale','spec')
)
, upd as (
  update projects p
     set notes  = btrim(coalesce(p.notes, '') || case when coalesce(btrim(p.notes),'') = '' then '' else E'\n' end
                        || 'Sale/occupancy (was in Status): ' || x.status),
         status = null
  from saleish x
  where p.id = x.id
  returning p.job_number, x.status as old_status
)
insert into status_cleanup_log (job_number, old_status, new_status, moved_to, moved_value)
select job_number, old_status, null, 'notes', old_status from upd;

-- ── 4 · anything still off-list → notes, then cleared ──────────────────────
-- Catches one-offs such as 'Confirm'. Deliberately generous: a value nobody
-- recognises is worth keeping as a note rather than guessing at its meaning.
with leftover as (
  select id, job_number, status, notes from projects
  where status is not null and btrim(status) <> ''
    and status not in ('On Track','Ahead','At Risk','Behind','On Hold','Blocked','Complete')
)
, upd as (
  update projects p
     set notes  = btrim(coalesce(p.notes, '') || case when coalesce(btrim(p.notes),'') = '' then '' else E'\n' end
                        || 'Was in Status: ' || x.status),
         status = null
  from leftover x
  where p.id = x.id
  returning p.job_number, x.status as old_status
)
insert into status_cleanup_log (job_number, old_status, new_status, moved_to, moved_value)
select job_number, old_status, null, 'notes', old_status from upd;

-- ── 5 · stop it drifting again ─────────────────────────────────────────────
-- Null and empty stay legal: not every project has a health call yet.
alter table projects drop constraint if exists projects_status_check;
alter table projects add constraint projects_status_check
  check (status is null or status = '' or
         status in ('On Track','Ahead','At Risk','Behind','On Hold','Blocked','Complete'));

commit;

-- ── review ─────────────────────────────────────────────────────────────────
select job_number, old_status, coalesce(new_status,'(cleared)') as new_status,
       coalesce(moved_to,'-') as preserved_in
from status_cleanup_log order by id;
