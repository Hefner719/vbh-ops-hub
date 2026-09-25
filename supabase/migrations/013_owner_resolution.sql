-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 013 · resolve who an action item belongs to
--
--  Owner strings in the meeting agenda are written the way people speak:
--  "Justin", "JV", "JH/SV/JV", "Josh/Bill", "Kara/Sydney", "All PMs". Counting
--  them literally makes "JH/SV/JV" look like a person with eight open items
--  while Jordan, Sydney and Justin each appear to owe nothing from it.
--
--  meeting.html already resolves these for its Send panel (splitOwners +
--  personByName). This mirrors that logic in SQL so the same question can be
--  asked of the database: what does one person actually owe?
--
--  The roster comes from vbh_role_seed, so adding someone there is enough —
--  no list is repeated here.
-- ═══════════════════════════════════════════════════════════════════════════

-- First names and initials, derived from the roster rather than hard-coded.
create or replace view v_people as
select email,
       full_name,
       role,
       split_part(full_name, ' ', 1)                                   as first_name,
       lower(split_part(full_name, ' ', 1))                            as first_lower,
       lower(left(split_part(full_name, ' ', 1), 1) ||
             left(split_part(full_name, ' ', 2), 1))                   as initials,
       lower(split_part(full_name, ' ', 2))                            as last_lower
from vbh_role_seed
where coalesce(full_name, '') <> '';

grant select on v_people to anon, authenticated;

-- One owner string in, zero or more canonical first names out.
-- "JH/SV/JV" -> Jordan, Sydney, Justin.  "All PMs" -> every manager.
-- Anything unrecognised comes back as itself, so nothing silently vanishes.
create or replace function vbh_resolve_owners(p_owner text)
returns table (person text)
language plpgsql stable security definer set search_path = public as $$
declare
  part  text;
  hit   text;
  found boolean;
begin
  if coalesce(btrim(p_owner), '') = '' then
    person := 'Unassigned'; return next; return;
  end if;

  -- Group shorthands used on the agenda.
  if lower(btrim(p_owner)) in ('all pms', 'pms', 'all pm') then
    for hit in select first_name from v_people where role = 'manager' loop
      person := hit; return next;
    end loop;
    return;
  end if;
  if lower(btrim(p_owner)) in ('all', 'everyone', 'team') then
    for hit in select first_name from v_people where role in ('owner','ops_admin','manager','field') loop
      person := hit; return next;
    end loop;
    return;
  end if;

  -- Split the way people write it: slashes, commas, ampersands, plus, "and".
  for part in
    select btrim(t) from regexp_split_to_table(p_owner, '\s*(/|,|&|\+|\band\b)\s*') t
    where btrim(t) <> ''
  loop
    found := false;
    select p.first_name into hit from v_people p
     where lower(part) = p.first_lower
        or lower(part) = p.initials
        or lower(part) = p.last_lower
        or lower(part) = lower(p.full_name)
     limit 1;
    if hit is not null then
      person := hit; found := true; return next;
    end if;
    if not found then
      person := part; return next;   -- keep it visible rather than dropping it
    end if;
    hit := null;
  end loop;
end $$;

grant execute on function vbh_resolve_owners(text) to anon, authenticated;

-- ── open items, one row per person per item ────────────────────────────────
-- Dropped rather than replaced: migration 012 created v_action_load with a
-- different shape, and CREATE OR REPLACE VIEW cannot rename or reorder columns.
drop view if exists v_action_load;
drop view if exists v_action_by_person;

create or replace view v_action_by_person with (security_invoker = true) as
select r.person,
       a.id, a.text, a.job_number, a.due, a.first_seen, a.last_seen,
       a.age_days, a.days_overdue, a.state,
       a.owner as owner_raw
from v_open_action_items a
cross join lateral vbh_resolve_owners(a.owner) r;

-- ── per-person load, now counting shared items for everyone named ──────────
create or replace view v_action_load with (security_invoker = true) as
select person                                           as owner,
       count(*)                                         as open_items,
       count(*) filter (where state = 'overdue')        as overdue,
       count(*) filter (where state = 'stale')          as stale_28d,
       count(*) filter (where owner_raw ~ '[/,&+]')     as shared_items,
       min(due) filter (where due is not null)          as next_due,
       max(age_days)                                    as oldest_days
from v_action_by_person
group by person;

grant select on v_action_by_person, v_action_load to anon, authenticated;

-- ── explicit aliases, because initials collide ─────────────────────────────
-- Steve Van Buskirk and Sydney Van Well both reduce to "SV". On a production
-- meeting agenda "SV" always means Sydney: Steve is the CEO and does not sit in
-- that meeting. Derived initials cannot know that, so the ambiguous cases are
-- stated here. This mirrors the `aliases` list in vbh-config.js.
create table if not exists vbh_owner_alias (
  alias  text primary key,          -- lower case
  person text not null              -- the first name vbh_resolve_owners returns
);

insert into vbh_owner_alias (alias, person) values
  ('jh','Jordan'), ('sv','Sydney'), ('jv','Justin'), ('dw','Dallas'),
  ('qr','Quentin'), ('kl','Kara'), ('ji','Josh'), ('bh','Bill'),
  ('bw','Brandt'), ('kb','Kelly'), ('svb','Steve')
on conflict (alias) do update set person = excluded.person;

alter table vbh_owner_alias enable row level security;
drop policy if exists "staff read aliases" on vbh_owner_alias;
drop policy if exists "anon read aliases"  on vbh_owner_alias;
create policy "staff read aliases" on vbh_owner_alias for select to authenticated using (true);
create policy "anon read aliases"  on vbh_owner_alias for select to anon using (true);
grant select on vbh_owner_alias to anon, authenticated;

-- Re-create the resolver with the alias table consulted first.
create or replace function vbh_resolve_owners(p_owner text)
returns table (person text)
language plpgsql stable security definer set search_path = public as $$
declare
  part  text;
  hit   text;
begin
  if coalesce(btrim(p_owner), '') = '' then
    person := 'Unassigned'; return next; return;
  end if;

  if lower(btrim(p_owner)) in ('all pms', 'pms', 'all pm') then
    for hit in select first_name from v_people where role = 'manager' loop
      person := hit; return next;
    end loop;
    return;
  end if;
  if lower(btrim(p_owner)) in ('all', 'everyone', 'team') then
    for hit in select first_name from v_people where role in ('owner','ops_admin','manager','field') loop
      person := hit; return next;
    end loop;
    return;
  end if;

  for part in
    select btrim(t) from regexp_split_to_table(p_owner, '\s*(/|,|&|\+|\band\b)\s*') t
    where btrim(t) <> ''
  loop
    hit := null;
    -- 1 · an explicit alias always wins, so colliding initials resolve correctly
    select a.person into hit from vbh_owner_alias a where a.alias = lower(part) limit 1;
    -- 2 · then the roster, by first name, surname or full name
    if hit is null then
      select p.first_name into hit from v_people p
       where lower(part) = p.first_lower
          or lower(part) = p.last_lower
          or lower(part) = lower(p.full_name)
       limit 1;
    end if;
    -- 3 · then derived initials, for anyone without an explicit alias
    if hit is null then
      select p.first_name into hit from v_people p where lower(part) = p.initials limit 1;
    end if;
    person := coalesce(hit, part);   -- unrecognised stays visible
    return next;
  end loop;
end $$;

grant execute on function vbh_resolve_owners(text) to anon, authenticated;
