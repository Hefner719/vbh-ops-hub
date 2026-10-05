-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 018 · remember the job cards taken off on purpose
--
--  Two things happened on 2026-10-05.
--
--  1. During the production meeting Jordan removed four job cards, leaving an
--     11-card agenda, and saved it (rev 138, 11 rows written to
--     project_updates: R25022 R26002 R26008 R26009 R26010 R26013 R26016 R26017
--     R26020 R26021 ER26022).
--
--  2. Opening the page afterwards put all four back. ensureActiveProjectCards()
--     adds a card for every tracker project sitting in an agenda stage
--     (solds / escrow / model), and nothing recorded that those four removals
--     were deliberate — so the agenda arrived at 15 cards again. Mine: the
--     reload was my verification run.
--
--  meeting-v10 fixes the cause: a removal is recorded in state.dropped against
--  the project plus the stage it was in, and the card only returns if that
--  project MOVES stage. This migration applies the same thing to the data:
--  it takes the four cards back off and writes the matching notes, so the
--  agenda is what Jordan left and it stays that way.
--
--  Idempotent — the cards are matched on job number and the notes are keyed on
--  project id, so a second run changes nothing.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

with target as (
  select meeting_date, state, rev
  from meetings
  where meeting_date = (select max(meeting_date) from meetings)
),
-- the four that were re-added, with the stage each is in right now
notes as (
  select jsonb_agg(jsonb_build_object(
           'projectId', p.id::text,
           'jobNumber', p.job_number,
           'stage',     lower(p.stage),
           'at',        '2026-10-05T14:18:27Z',
           'by',        'Jordan Hefner'
         ) order by p.job_number) as arr
  from projects p
  where p.job_number in ('R25026','R25027','R25029','R26025')
),
-- keep only the cards whose name does NOT carry one of those job numbers
kept as (
  select t.meeting_date,
         coalesce(jsonb_agg(j.value order by j.ord)
                  filter (where j.value->>'name' !~ '\m(R25026|R25027|R25029|R26025)\M'),
                  '[]'::jsonb) as jobs
  from target t
  cross join lateral jsonb_array_elements(t.state->'jobs') with ordinality j(value, ord)
  group by t.meeting_date
),
-- notes already present stay as they are; the four are added if missing
merged as (
  select t.meeting_date,
         k.jobs,
         ( select coalesce(jsonb_agg(d), '[]'::jsonb)
           from (
             select d from jsonb_array_elements(coalesce(t.state->'dropped','[]'::jsonb)) d
             union all
             select n from jsonb_array_elements((select arr from notes)) n
             where not exists (
               select 1 from jsonb_array_elements(coalesce(t.state->'dropped','[]'::jsonb)) e
               where e->>'projectId' = n->>'projectId')
           ) s(d)
         ) as dropped,
         t.rev
  from target t join kept k on k.meeting_date = t.meeting_date
)
update meetings m
   set state = jsonb_set(jsonb_set(m.state, '{jobs}', g.jobs), '{dropped}', g.dropped),
       rev = g.rev + 1,                       -- so any page still open re-syncs instead of overwriting
       updated_at = now(),
       updated_by = 'Card dismissals (migration 018)'
from merged g
where m.meeting_date = g.meeting_date;

commit;

-- ── what the agenda holds now ───────────────────────────────────────────────
select jsonb_array_length(state->'jobs')    as job_cards,
       jsonb_array_length(state->'dropped') as removal_notes,
       jsonb_array_length(state->'action')  as action_items,
       rev
from meetings
where meeting_date = (select max(meeting_date) from meetings);

select j->>'name' as card
from meetings m cross join lateral jsonb_array_elements(m.state->'jobs') j
where m.meeting_date = (select max(meeting_date) from meetings)
order by 1;
