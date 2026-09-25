-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 012 · action items that outlive one meeting
--
--  THE PROBLEM
--  Action items live inside each week's `meetings.state` JSON. That makes them
--  invisible between meetings: there is no way to ask "what does Justin owe?"
--  without opening an agenda, and an item that is never ticked simply rides the
--  rollover forever without anyone noticing how long it has been there.
--
--  THIS TABLE is a projection, not a second home. The meeting page stays the
--  place items are created and ticked; on save it mirrors them here, keyed by
--  the id the meeting state already assigns each row. Nothing is entered twice,
--  and the agenda remains the source of truth for the current week.
--
--  What that buys: age, per-person load, and items that survive being carried
--  from week to week so "open for 6 weeks" becomes a fact rather than a feeling.
-- ═══════════════════════════════════════════════════════════════════════════

create table if not exists action_items (
  id            text primary key,          -- the id from meetings.state, so re-saving updates
  text          text not null,
  owner         text,
  job_number    text,
  due           date,
  done          boolean not null default false,
  first_seen    date not null,             -- the meeting that raised it
  last_seen     date not null,             -- the most recent meeting still carrying it
  done_at       date,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists action_items_owner_idx on action_items (owner) where not done;
create index if not exists action_items_due_idx   on action_items (due)   where not done;

comment on table action_items is
  'Mirror of the action items in meetings.state, so they can be read across weeks. The meeting page owns them; this is a projection.';

-- ── sync one meeting's items ───────────────────────────────────────────────
-- Called by meeting.html on save. Idempotent: re-saving the same meeting
-- updates in place. `first_seen` is preserved so age survives a rollover.
create or replace function sync_action_items(p_meeting_date date, p_items jsonb)
returns integer
language plpgsql security definer set search_path = public as $$
declare n integer := 0;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' then return 0; end if;

  insert into action_items (id, text, owner, job_number, due, done, first_seen, last_seen, done_at)
  select x->>'id',
         btrim(x->>'text'),
         nullif(btrim(coalesce(x->>'owner','')), ''),
         nullif(btrim(coalesce(x->>'job','')), ''),
         case when coalesce(x->>'due','') ~ '^\d{4}-\d{2}-\d{2}$' then (x->>'due')::date end,
         coalesce((x->>'done')::boolean, false),
         p_meeting_date,
         p_meeting_date,
         case when coalesce((x->>'done')::boolean, false) then p_meeting_date end
  from jsonb_array_elements(p_items) x
  where coalesce(btrim(x->>'text'), '') <> ''
    and coalesce(x->>'id', '') <> ''
  on conflict (id) do update set
    text       = excluded.text,
    owner      = excluded.owner,
    job_number = excluded.job_number,
    due        = excluded.due,
    done       = excluded.done,
    -- earliest wins, so age is measured from when the item was first raised
    first_seen = least(action_items.first_seen, excluded.first_seen),
    last_seen  = greatest(action_items.last_seen, excluded.last_seen),
    done_at    = case when excluded.done and action_items.done_at is null then excluded.last_seen
                      when not excluded.done then null
                      else action_items.done_at end,
    updated_at = now();

  get diagnostics n = row_count;
  return n;
end $$;

grant execute on function sync_action_items(date, jsonb) to anon, authenticated;

-- ── what is open, and how long has it been ─────────────────────────────────
create or replace view v_open_action_items with (security_invoker = true) as
select a.id,
       a.text,
       coalesce(nullif(a.owner, ''), 'Unassigned') as owner,
       a.job_number,
       a.due,
       a.first_seen,
       a.last_seen,
       (current_date - a.first_seen)                        as age_days,
       case when a.due is not null and a.due < current_date
            then current_date - a.due end                   as days_overdue,
       case
         when a.due is not null and a.due < current_date         then 'overdue'
         when a.due is not null and a.due <= current_date + 2     then 'due_soon'
         when (current_date - a.first_seen) >= 28                 then 'stale'
         else 'open'
       end                                                  as state
from action_items a
where not a.done;

-- ── per-person load, for the digest and the meeting wrap-up ────────────────
create or replace view v_action_load with (security_invoker = true) as
select owner,
       count(*)                                        as open_items,
       count(*) filter (where state = 'overdue')       as overdue,
       count(*) filter (where state = 'stale')         as stale_28d,
       min(due) filter (where due is not null)         as next_due,
       max(age_days)                                   as oldest_days
from v_open_action_items
group by owner;

grant select on v_open_action_items, v_action_load to anon, authenticated;

-- ── backfill from the meetings already stored ──────────────────────────────
-- Oldest first, so first_seen lands on the meeting that actually raised each
-- item rather than the most recent one carrying it.
do $$
declare m record; total integer := 0; n integer;
begin
  for m in select meeting_date, state from meetings order by meeting_date asc loop
    n := sync_action_items(m.meeting_date, m.state->'action');
    total := total + coalesce(n, 0);
  end loop;
  raise notice 'Backfilled % action item rows from % meetings', total,
    (select count(*) from meetings);
end $$;

select count(*) filter (where not done) as open_now,
       count(*) filter (where done)     as completed,
       min(first_seen)                  as earliest,
       max(last_seen)                   as latest
from action_items;
