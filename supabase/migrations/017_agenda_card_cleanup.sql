-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 017 · repair the job cards on the agenda
--
--  Migration 011 gave projects.status one meaning and added a check constraint.
--  It only fixed the `projects` table. Each job card on the meeting agenda
--  keeps its OWN copy of phase, status and % inside meetings.state, and those
--  copies still hold the pre-cleanup values: Customer, Punch, Confirm,
--  Foundation.
--
--  That is not cosmetic. Saving the meeting calls pushCardsToTracker(), which
--  writes each card's status back to projects. Those five cards would now be
--  rejected by the constraint, so a save would report "9 updated, 5 failed"
--  with no clue why. My change, my omission.
--
--  This repairs the cards in place:
--    · status values that are not schedule health are cleared. Where the value
--      was really a phase and the card's phase field is empty, it moves there
--      rather than being dropped.
--    · phase casing is aligned to the list meeting.html offers, so the dropdown
--      shows the current value as selected instead of appearing unset.
--
--  What it deliberately does NOT do: guess a phase for a card whose phase is
--  free text describing intent rather than a stage ("Finish this project
--  ASAP"). Those are listed at the end for a human to set.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

-- Every agenda, not just the newest: archived meetings are re-opened and rolled
-- forward, so a stale value in an old one would come back.
with card as (
  select m.meeting_date,
         j.ord,
         j.value as card
  from meetings m
  cross join lateral jsonb_array_elements(m.state->'jobs') with ordinality j(value, ord)
),
fixed as (
  select meeting_date, ord,
         card
         -- status: keep only real schedule health, normalising case
         || jsonb_build_object('status',
              case lower(btrim(coalesce(card->>'status','')))
                when 'on track' then 'On Track'
                when 'ahead'    then 'Ahead'
                when 'at risk'  then 'At Risk'
                when 'behind'   then 'Behind'
                when 'on hold'  then 'On Hold'
                when 'blocked'  then 'Blocked'
                when 'complete' then 'Complete'
                when 'done'     then 'Complete'
                else ''
              end)
         -- phase: align case to the list the dropdown offers; if the old status
         -- was really a phase and phase is empty, promote it
         || jsonb_build_object('phase',
              coalesce(
                nullif(case lower(btrim(coalesce(card->>'phase','')))
                  when 'punch list'    then 'Punch List'
                  when 'punch'         then 'Punch List'
                  when 'pre-construction' then 'Pre-Construction'
                  when 'framing'       then 'Framing'
                  when 'backfill'      then 'Backfill'
                  when 'foundation'    then 'Foundation'
                  when 'flatwork'      then 'Flatwork'
                  when 'roofing'       then 'Roofing'
                  when 'insulation'    then 'Insulation'
                  when 'drywall'       then 'Drywall'
                  when 'paint'         then 'Paint'
                  else btrim(coalesce(card->>'phase',''))
                end, ''),
                case lower(btrim(coalesce(card->>'status','')))
                  when 'punch'      then 'Punch List'
                  when 'foundation' then 'Foundation'
                  when 'framing'    then 'Framing'
                  else null
                end,
                '')) as card
  from card
),
regrouped as (
  select meeting_date, jsonb_agg(card order by ord) as jobs
  from fixed group by meeting_date
)
update meetings m
   set state = jsonb_set(m.state, '{jobs}', r.jobs),
       updated_at = now(),
       updated_by = 'Card cleanup (migration 017)'
from regrouped r
where m.meeting_date = r.meeting_date
  and m.state->'jobs' is distinct from r.jobs;

commit;

-- ── what the current agenda looks like now ─────────────────────────────────
select j->>'name' as card,
       coalesce(nullif(j->>'status',''), '(none)') as status,
       coalesce(nullif(j->>'phase',''),  '(none)') as phase,
       case when coalesce(nullif(j->>'phase',''),'') <> ''
             and j->>'phase' not in (
               'Pre-Construction','Permitting','Staking / Excavation','Foundation','Backfill',
               'Framing','Roofing','Windows & Doors','Exterior / Siding','Rough-Ins (Mech/Elec/Plumb)',
               'Insulation','Drywall','Trim & Millwork','Paint','Cabinets & Tops','Flooring',
               'Finish Mech/Elec/Plumb','Flatwork','Grading & Landscape','Punch List','CO & Closing','Warranty')
            then 'needs a real phase' else '' end as flag
from meetings m cross join lateral jsonb_array_elements(m.state->'jobs') j
where m.meeting_date = (select max(meeting_date) from meetings)
order by 1;
