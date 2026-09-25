-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 015 · rebuild action_items from the meetings
--
--  Migration 014 collapsed duplicates with bool_or(done), which says "done if
--  ever ticked". That is the wrong question. "Cameras: charge batteries" was
--  ticked in one July meeting, reopened, and is sitting on the current agenda
--  unticked — 014 reported it closed.
--
--  It also kept the OLDEST row id of each duplicate group. The live agenda
--  carries a different id for the same item (legacy states re-mint ids on
--  migration), so the next save would not have matched and would have inserted
--  a fresh duplicate.
--
--  Both faults share a cause: treating the mirror as the thing to repair. The
--  meetings are the source of truth, so this rebuilds from them, and states the
--  two rules plainly:
--
--    · an item's state is whatever the MOST RECENT meeting containing it says
--    · its id is the one that most recent meeting uses, so future saves match
--
--  Identity is normalised text plus owner, which is what survives the id churn.
--  Re-runnable: it rebuilds the table each time.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

create temporary table _items on commit drop as
with expanded as (
  select m.meeting_date,
         x->>'id'                                             as item_id,
         btrim(x->>'text')                                    as text,
         nullif(btrim(coalesce(x->>'owner','')), '')          as owner,
         nullif(btrim(coalesce(x->>'job','')), '')            as job_number,
         case when coalesce(x->>'due','') ~ '^\d{4}-\d{2}-\d{2}$' then (x->>'due')::date end as due,
         coalesce((x->>'done')::boolean, false)               as done,
         lower(regexp_replace(btrim(x->>'text'), '[^a-z0-9]+', ' ', 'gi')) as key_text,
         lower(coalesce(btrim(x->>'owner'), ''))              as key_owner
  from meetings m
  cross join lateral jsonb_array_elements(m.state->'action') x
  where coalesce(btrim(x->>'text'), '') <> ''
    and coalesce(x->>'id', '') <> ''
),
latest as (
  select distinct on (key_text, key_owner)
         key_text, key_owner, item_id, text, owner, job_number, due, done, meeting_date
  from expanded
  order by key_text, key_owner, meeting_date desc, item_id
),
span as (
  select key_text, key_owner, min(meeting_date) as first_seen, max(meeting_date) as last_seen
  from expanded group by key_text, key_owner
)
select l.item_id as id, l.text, l.owner, l.job_number, l.due,
       l.done, s.first_seen, s.last_seen
from latest l join span s using (key_text, key_owner);

delete from action_items;

insert into action_items (id, text, owner, job_number, due, done, first_seen, last_seen, done_at, closed_reason)
select i.id, i.text, i.owner, i.job_number, i.due,
       -- Done if the latest meeting ticked it, or if it has left the agenda.
       i.done or i.last_seen < (select max(meeting_date) from meetings),
       i.first_seen,
       i.last_seen,
       case when i.done then i.last_seen
            when i.last_seen < (select max(meeting_date) from meetings) then i.last_seen end,
       case
         when i.done then 'Ticked off on the ' || to_char(i.last_seen, 'Mon DD, YYYY') || ' agenda.'
         when i.last_seen < (select max(meeting_date) from meetings)
           then 'Last seen on the ' || to_char(i.last_seen, 'Mon DD, YYYY')
                || ' agenda and not carried forward — completed or retired at rollover, exact date not recorded.'
       end
from _items i;

commit;

-- ── what the rebuild produced ──────────────────────────────────────────────
select (select count(*) from action_items)                                     as items,
       (select count(*) from v_open_action_items)                              as open_on_agenda,
       (select count(*) from action_items where done and closed_reason like 'Ticked%')    as ticked_off,
       (select count(*) from action_items where done and closed_reason like 'Last seen%') as dropped_at_rollover,
       (select jsonb_array_length(state->'action') from meetings
         where meeting_date = (select max(meeting_date) from meetings))         as rows_on_live_agenda;
