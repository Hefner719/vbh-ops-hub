-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 006 · real accounts and roles   (auth-phase-a)
--
--  WHY THIS EXISTS
--  The hub authenticates in the browser against a shared password. That hides
--  the interface, not the data: the Supabase anon key ships in vbh-config.js,
--  and today's policies let that key read, write and DELETE projects, leads,
--  meetings, project_updates and assets. Anyone who views source can empty a
--  table. This builds the identity layer that replaces it.
--
--  PHASE A (this file) — purely additive. Existing anon policies are left in
--  place, so nothing breaks while people sign in for the first time.
--  PHASE B (007_auth_lockdown.sql) — drops the anon policies, once everyone
--  has signed in at least once.
--
--  Roles, coarse to fine:
--    owner, ops_admin   read, write, delete
--    manager, field     read, write
--    labor              read only
-- ═══════════════════════════════════════════════════════════════════════════

-- ── 1 · the intended roster, keyed by email ────────────────────────────────
-- Separate from `profiles` so a person can be given a role before they have
-- ever signed in. Data, not logic — edit freely.
create table if not exists vbh_role_seed (
  email     text primary key,
  full_name text,
  role      text not null default 'field'
            check (role in ('owner','ops_admin','manager','field','labor'))
);

insert into vbh_role_seed (email, full_name, role) values
  ('jordan.hefner@vanbuskirkco.com',     'Jordan Hefner',     'owner'),
  ('steve@vbclink.com',                  'Steve Van Buskirk', 'owner'),
  ('kelly.boyd@vanbuskirkco.com',        'Kelly Boyd',        'owner'),
  ('kara.lilly@vanbuskirkco.com',        'Kara Lilly',        'ops_admin'),
  ('sydney.vanwell@vanbuskirkco.com',    'Sydney Van Well',   'manager'),
  ('justin.vostad@vanbuskirkco.com',     'Justin Vostad',     'manager'),
  ('brandt.williams@vanbuskirkco.com',   'Brandt Williams',   'manager'),
  ('dallas.westover@vanbuskirkco.com',   'Dallas Westover',   'field'),
  ('quentin.robertson@vanbuskirkco.com', 'Quentin Robertson', 'field'),
  ('josh.isaacson@vanbuskirkco.com',     'Josh Isaacson',     'field'),
  ('bill.hoffman@vanbuskirkco.com',      'Bill Hoffman',      'field'),
  ('jackson.breuer@vanbuskirkco.com',    'Jackson Breuer',    'field'),
  ('jacob.bender@vanbuskirkco.com',      'Jacob Bender',      'field'),
  ('logan.callahan@vanbuskirkco.com',    'Logan Callahan',    'field'),
  ('gabbie.hibbert@vanbuskirkco.com',    'Gabbie Hibbert',    'field'),
  ('clay.nelson@vanbuskirkco.com',       'Clay Nelson',       'field')
on conflict (email) do update
  set full_name = excluded.full_name, role = excluded.role;

-- ── 2 · profiles: one row per person with an account ───────────────────────
create table if not exists profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text not null unique,
  full_name  text,
  role       text not null default 'field'
             check (role in ('owner','ops_admin','manager','field','labor')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table profiles is
  'One row per signed-in person. A user with no active row here has no access.';

-- ── 3 · helpers ────────────────────────────────────────────────────────────
-- security definer so they can read `profiles` without recursing through its
-- own RLS; stable so the planner evaluates them once per statement.
create or replace function vbh_role() returns text
language sql stable security definer set search_path = public as $$
  select p.role from profiles p where p.id = auth.uid() and p.active
$$;

create or replace function vbh_is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles p where p.id = auth.uid() and p.active)
$$;

create or replace function vbh_can_write() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(vbh_role() in ('owner','ops_admin','manager','field'), false)
$$;

create or replace function vbh_can_delete() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(vbh_role() in ('owner','ops_admin'), false)
$$;

grant execute on function vbh_role(), vbh_is_staff(), vbh_can_write(), vbh_can_delete()
  to anon, authenticated;

-- ── 4 · who may hold an account ────────────────────────────────────────────
-- Company domains only. Anyone else who signs up lands inactive and sees
-- nothing, so an open signup form is not by itself a way in.
create or replace function vbh_is_company_email(p text) returns boolean
language sql immutable as $$
  select lower(coalesce(p,'')) ~ '@(vanbuskirkco\.com|vbclink\.com)$'
$$;

create or replace function vbh_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare s vbh_role_seed%rowtype;
begin
  select * into s from vbh_role_seed where lower(email) = lower(new.email);
  insert into profiles (id, email, full_name, role, active)
  values (new.id,
          lower(new.email),
          coalesce(s.full_name, new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
          coalesce(s.role, 'field'),
          vbh_is_company_email(new.email))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists vbh_on_auth_user_created on auth.users;
create trigger vbh_on_auth_user_created
  after insert on auth.users
  for each row execute function vbh_handle_new_user();

-- ── 5 · profiles RLS ───────────────────────────────────────────────────────
alter table profiles      enable row level security;
alter table vbh_role_seed enable row level security;

drop policy if exists "read own profile"    on profiles;
drop policy if exists "staff read profiles" on profiles;
drop policy if exists "admins manage"       on profiles;
drop policy if exists "admins manage seed"  on vbh_role_seed;

create policy "read own profile" on profiles
  for select to authenticated using (id = auth.uid());
create policy "staff read profiles" on profiles
  for select to authenticated using (vbh_is_staff());
create policy "admins manage" on profiles
  for all to authenticated using (vbh_can_delete()) with check (vbh_can_delete());
-- The roster is admin-only; nobody else needs to see it.
create policy "admins manage seed" on vbh_role_seed
  for all to authenticated using (vbh_can_delete()) with check (vbh_can_delete());

-- ── 6 · authenticated policies, alongside the existing anon ones ───────────
-- Phase A: both sets live, so signing in changes nothing yet. Phase B removes
-- the anon set and these take over.
do $$
declare t text;
begin
  foreach t in array array['projects','leads','meetings','project_updates','work_orders','assets'] loop
    execute format('drop policy if exists "staff read %1$s"   on %1$I', t);
    execute format('drop policy if exists "staff write %1$s"  on %1$I', t);
    execute format('drop policy if exists "staff update %1$s" on %1$I', t);
    execute format('drop policy if exists "admin delete %1$s" on %1$I', t);
    execute format('create policy "staff read %1$s"   on %1$I for select to authenticated using (vbh_is_staff())', t);
    execute format('create policy "staff write %1$s"  on %1$I for insert to authenticated with check (vbh_can_write())', t);
    execute format('create policy "staff update %1$s" on %1$I for update to authenticated using (vbh_can_write()) with check (vbh_can_write())', t);
    execute format('create policy "admin delete %1$s" on %1$I for delete to authenticated using (vbh_can_delete())', t);
  end loop;
end $$;

-- `assets` never had row security switched on at all. Turning it on without a
-- matching anon policy would break the Asset Tracker today, so it gets one
-- until Phase B.
alter table assets enable row level security;
drop policy if exists "assets anon all" on assets;
create policy "assets anon all" on assets for all to anon using (true) with check (true);

-- Bridge tables: staff read. Ingest writes with the service role.
do $$
declare t text;
begin
  foreach t in array array['bt_emails','bt_events','bt_ingest_runs'] loop
    execute format('drop policy if exists "staff read %1$s" on %1$I', t);
    execute format('create policy "staff read %1$s" on %1$I for select to authenticated using (vbh_is_staff())', t);
  end loop;
end $$;

grant select on profiles to authenticated;
grant select, insert, update, delete on vbh_role_seed to authenticated;
