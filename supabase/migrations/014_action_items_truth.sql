-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 014 · make "open" mean open
--
--  The 012 backfill reported 66 open action items. It was wrong twice.
--
--  1. DUPLICATES. Meetings saved before meeting-v6 are stored in the older
--     state format, and migrateState() mints a fresh uid() for every row each
--     time it migrates one. Backfilling five legacy meetings therefore created
--     five separate rows for the same item. 66 rows, 22 distinct texts.
--
--  2. FALSE OPENS. An item was counted open whenever `done` was false in the
--     meeting it appeared in. But the agenda drops completed items at rollover
--     without ever writing done=true — they simply stop appearing. So an item
--     last seen on 23 July, absent from every agenda since, was being reported
--     as open for 102 days when it had in fact been dealt with in July.
--
--  The honest rule: an item is open if it is on the current agenda. Anything
--  whose last sighting predates the newest meeting left the agenda, and the
--  only truthful thing to say is that it is closed and we cannot say exactly
--  when. That is recorded as `closed_reason` rather than dressed up as a date.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

alter table action_items add column if not exists closed_reason text;

-- ── 1 · collapse the duplicates ────────────────────────────────────────────
-- Same normalised text and owner is the same item. Keep the earliest row, and
-- give it the full span so age survives.
-- Same normalised text and same owner is the same item. Keep the earliest row,
-- widen it to the full span so age survives, and drop the copies.
with norm as (
  select id, owner, first_seen, last_seen, done,
         lower(regexp_replace(text, '[^a-z0-9]+', ' ', 'gi')) as key_text,
         lower(coalesce(owner, ''))                           as key_owner
  from action_items
),
ranked as (
  select id,
         row_number() over (partition by key_text, key_owner order by first_seen, id) as rn,
         min(first_seen) over (partition by key_text, key_owner) as span_start,
         max(last_seen)  over (partition by key_text, key_owner) as span_end,
         bool_or(done)   over (partition by key_text, key_owner) as any_done
  from norm
),
widened as (
  update action_items a
     set first_seen = r.span_start,
         last_seen  = r.span_end,
         done       = r.any_done,
         updated_at = now()
  from ranked r
  where a.id = r.id and r.rn = 1
  returning a.id
)
delete from action_items d
using ranked r
where d.id = r.id and r.rn > 1;

-- ── 2 · close what left the agenda ─────────────────────────────────────────
update action_items a
   set done          = true,
       closed_reason = 'Dropped from the agenda after ' || to_char(a.last_seen, 'Mon DD, YYYY')
                       || ' — completed or retired at rollover; the exact date was never recorded.',
       done_at       = a.last_seen,
       updated_at    = now()
where not a.done
  and a.last_seen < (select max(meeting_date) from meetings);

commit;

-- ── 3 · open now means on the current agenda ───────────────────────────────
drop view if exists v_action_load;
drop view if exists v_action_by_person;
drop view if exists v_open_action_items;

create or replace view v_open_action_items with (security_invoker = true) as
select a.id,
       a.text,
       coalesce(nullif(a.owner, ''), 'Unassigned') as owner,
       a.job_number,
       a.due,
       a.first_seen,
       a.last_seen,
       (current_date - a.first_seen) as age_days,
       case when a.due is not null and a.due < current_date
            then current_date - a.due end as days_overdue,
       case
         when a.due is not null and a.due < current_date     then 'overdue'
         when a.due is not null and a.due <= current_date + 2 then 'due_soon'
         when (current_date - a.first_seen) >= 28             then 'stale'
         else 'open'
       end as state
from action_items a
where not a.done
  -- On the newest agenda. An item that stopped appearing is closed, not open.
  and a.last_seen >= (select max(meeting_date) from meetings);

create or replace view v_action_by_person with (security_invoker = true) as
select r.person,
       a.id, a.text, a.job_number, a.due, a.first_seen, a.last_seen,
       a.age_days, a.days_overdue, a.state, a.owner as owner_raw
from v_open_action_items a
cross join lateral vbh_resolve_owners(a.owner) r;

create or replace view v_action_load with (security_invoker = true) as
select person as owner,
       count(*) as open_items,
       count(*) filter (where state = 'overdue')    as overdue,
       count(*) filter (where state = 'stale')      as stale_28d,
       count(*) filter (where owner_raw ~ '[/,&+]') as shared_items,
       min(due) filter (where due is not null)      as next_due,
       max(age_days)                                as oldest_days
from v_action_by_person
group by person;

grant select on v_open_action_items, v_action_by_person, v_action_load to anon, authenticated;

select (select count(*) from action_items)                     as rows_total,
       (select count(*) from action_items where not done)      as not_done,
       (select count(*) from v_open_action_items)              as open_on_agenda,
       (select count(*) from action_items where closed_reason is not null) as closed_by_cleanup;
