-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 027 · tracker additions and corrections, 2026-11-16
--
--  Directed by the Director of Operations while cleaning up the active list
--  (migration 026 did the closures). Applied live 2026-11-16; this file is the
--  record and is safe to re-run - every statement checks the state first.
--
--  1. 100 N. Harmon Drive, Lake Mitchell - R26004 reopened.
--     Migration 024 brought R26004 in from Buildertrend as 'closed' because it
--     had no mail in the last 30 days. It is the Bradley job (lead ER26004):
--     sold, in pre-construction and selections, starting 2027-03-01. The lead's
--     details are carried over the same way leads.html convertLead() does it,
--     and the lead is marked Closed - Won and archived.
--
--  2. 6008 N. Mapleton Ave - new, sold. Mapleton Highlands lot 20, block 2.
--     The lead had lot 21; lot 20 is correct (6004 is lot 21). No Buildertrend
--     job number yet, so the row carries the estimate number ER26027 until one
--     is assigned. Note ER26027 is NOT R26027 (3404 Bronze Lane) - estimate
--     numbers do not map onto job numbers, so replace it rather than strip
--     the E. Lead marked Closed - Won and archived.
--
--  3. 1204 E. Hanson (R26030) is a model home: stage solds -> model.
--
--  4. 908 Bluffside Drive: job number ER26022 -> R26022. The tracker held the
--     lead's estimate number, while Buildertrend files the job as R26022
--     (City of Brandon permit, footings and walls poured 2026-11-13). Every one
--     of its notifications was landing in v_bt_unmatched_jobs and none reached
--     its meeting card. Meeting cards link by project id, so the card keeps its
--     link and relabels itself on load. The Martin lead was already Closed - Won.
--
--  Lead status is written 'Closed - Won', the spelling in VBH.LEADS.STATUSES
--  and on every existing won lead.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- 1 ── 100 N. Harmon Drive ──────────────────────────────────────────────────
update projects set
  stage         = 'solds',
  buyer_realtor = 'Bradley, Jen & Jason',
  phase_note    = 'Pre-Construction / Selections',
  pct_complete  = 0,
  status        = 'On Track',
  style         = 'Custom Home',
  sqft          = 4788,
  start_date    = '2027-03-01',
  complete_date = '2028-02-01',
  notes         = 'Start 3/1/2027. Converted from lead 11/16/2026 (estimate ER26004). Location: Lake Mitchell SD. Budget: 1,500,000. Rep: Jordan Hefner.',
  from_lead     = true,
  converted_at  = now(),
  updated_at    = now(),
  updated_by    = 'Tracker cleanup 2026-11-16 (migration 027)'
where job_number = 'R26004' and stage = 'closed';

update leads set status = 'Closed - Won', archived = true, updated_at = now()
where id = 'caac9dda-8ea6-467c-b706-5d89d59d3344' and status = 'Active Lead';

-- 2 ── 6008 N. Mapleton Ave ─────────────────────────────────────────────────
insert into projects (job_number, stage, address, buyer_realtor, phase_note, pct_complete,
                      status, style, notes, from_lead, converted_at, updated_by)
select 'ER26027', 'solds', '6008 N. Mapleton Ave', 'Van Buskirk, Steve & Shannon',
       'Pre-Construction', 0, 'On Track', 'Custom Home',
       'Mapleton Highlands, Lot 20, Block 2. ER26027 is the estimate number - replace with the Buildertrend job number when assigned. Converted from lead 11/16/2026. Rep: Jordan Hefner.',
       true, now(), 'Tracker cleanup 2026-11-16 (migration 027)'
where not exists (select 1 from projects where job_number = 'ER26027');

update leads set lot = '20', job_number = 'ER26027', tentative_address = '6008 N. Mapleton Ave',
                 status = 'Closed - Won', archived = true, updated_at = now()
where id = '9bd96e4b-b0d3-4a2d-b7c0-663836d6836a' and status = 'Active Lead';

-- 3 ── 1204 E. Hanson is a model ────────────────────────────────────────────
update projects set stage = 'model', updated_at = now(),
                    updated_by = 'Tracker cleanup 2026-11-16 (migration 027)'
where job_number = 'R26030' and stage = 'solds';

-- 4 ── 908 Bluffside takes its Buildertrend job number ──────────────────────
update projects set job_number = 'R26022', updated_at = now(),
                    updated_by = 'Tracker cleanup 2026-11-16 (migration 027)'
where job_number = 'ER26022'
  and not exists (select 1 from projects where job_number = 'R26022');

commit;

-- R26022 should no longer appear here.
select * from v_bt_unmatched_jobs;
