-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend email bridge · migration 001 (schema + parser)
--  build: bt-bridge-v1
--
--  Run in the Supabase SQL editor (project bppirsahciuxrqzitfxa). Idempotent:
--  safe to run again after edits — every object is CREATE OR REPLACE / IF NOT
--  EXISTS, and bt_reparse_all() re-runs the parser over stored raw emails.
--
--  Three tables, one job:
--    bt_emails        every notification, raw, exactly as received. Never dropped.
--    bt_events        one parsed record per email, keyed by Buildertrend job #.
--    bt_ingest_runs   audit log — what each run fetched, inserted, skipped.
--  Plus bt_settings for the ingest secret (no anon access).
--
--  Parsing lives in Postgres so the raw source can be re-parsed any time the
--  templates change: fix the regex, run bt_reparse_all(), done.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─── 1 · RAW EMAILS ─────────────────────────────────────────────────────────
create table if not exists bt_emails (
  id            bigint generated always as identity primary key,
  message_id    text        not null unique,   -- Internet Message-ID → idempotent ingest
  received_at   timestamptz,                   -- null for CSV imports (Outlook export has no date)
  from_address  text,
  from_name     text,
  to_address    text,
  subject       text        not null,
  body_text     text,                          -- plain-text rendering (what the parser reads)
  body_html     text,                          -- kept when the source provides it
  source        text        not null default 'graph',  -- graph | power_automate | csv_import
  ingested_at   timestamptz not null default now(),
  parsed_at     timestamptz,
  parse_status  text,                          -- ok | unclassified | error
  parse_error   text
);
create index if not exists bt_emails_received_idx on bt_emails (received_at desc);
create index if not exists bt_emails_status_idx   on bt_emails (parse_status);

-- ─── 2 · PARSED EVENTS ──────────────────────────────────────────────────────
create table if not exists bt_events (
  id             bigint generated always as identity primary key,
  email_id       bigint not null unique references bt_emails(id) on delete cascade,
  event_type     text   not null,     -- client_update | change_order_added | change_order_approved
                                      -- | change_order_file | document_comment | unclassified
  job_number     text,                -- 'R26009' — joins projects.job_number. Null when not found.
  job_name       text,                -- 'R26009 - 3412 Bronze Lane - Kanzenbach Residence'
  occurred_at    timestamptz,         -- received_at, or the period end for CSV-imported client updates
  actor          text,                -- who did it in Buildertrend ('Sydney VanWell')
  title          text,                -- CO title · document title · client-update period text
  amount         numeric(12,2),       -- CO price; negative for credits shown as ($102,500.00)
  period_start   date,                -- client_update only
  period_end     date,
  summary        text,                -- client-update teaser · comment text
  link           text,                -- the 'View …' deep link
  fields         jsonb  not null default '{}'::jsonb,  -- everything else parsed, by type
  parser_version int    not null,
  created_at     timestamptz not null default now()
);
create index if not exists bt_events_job_idx  on bt_events (job_number, occurred_at desc);
create index if not exists bt_events_type_idx on bt_events (event_type, occurred_at desc);

-- ─── 3 · INGEST AUDIT LOG ───────────────────────────────────────────────────
create table if not exists bt_ingest_runs (
  id            bigint generated always as identity primary key,
  source        text        not null,
  started_at    timestamptz not null default now(),
  finished_at   timestamptz,
  fetched       int         not null default 0,
  inserted      int         not null default 0,
  duplicates    int         not null default 0,
  parsed_ok     int         not null default 0,
  unclassified  int         not null default 0,
  errors        int         not null default 0,
  notes         jsonb       not null default '[]'::jsonb,   -- [{message_id, subject, outcome}] per skipped/errored message
  error         text
);

-- ─── 4 · SETTINGS (secret store — no anon policy, so invisible to the hub) ───
create table if not exists bt_settings (
  key   text primary key,
  value text not null
);

-- ─── 5 · ROW-LEVEL SECURITY ─────────────────────────────────────────────────
-- Hub pages read with the anon key. Nothing writes with it: ingest goes through
-- bt_ingest_email() (security definer + shared secret) or the service role.
alter table bt_emails      enable row level security;
alter table bt_events      enable row level security;
alter table bt_ingest_runs enable row level security;
alter table bt_settings    enable row level security;

drop policy if exists "hub read" on bt_emails;
drop policy if exists "hub read" on bt_events;
drop policy if exists "hub read" on bt_ingest_runs;
create policy "hub read" on bt_emails      for select to anon, authenticated using (true);
create policy "hub read" on bt_events      for select to anon, authenticated using (true);
create policy "hub read" on bt_ingest_runs for select to anon, authenticated using (true);
-- bt_settings: RLS on, no policies → only service role / security-definer functions can read it.

-- ═══════════════════════════════════════════════════════════════════════════
--  PARSER · version 1
--  Built against samples/Samples.CSV (28 real notifications, 2026-09-14).
--  Types with no sample are deliberately NOT guessed at; they land as
--  'unclassified' with the raw body intact and get added when samples exist.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function bt_parser_version() returns int
language sql immutable as $$ select 1 $$;

-- '$2,860.00' → 2860.00 · '($102,500.00)' → -102500.00 · garbage → null
create or replace function bt_parse_money(p text) returns numeric
language plpgsql immutable as $$
declare
  s text := coalesce(p, '');
  neg boolean := false;
  n text;
begin
  if s ~ '^\s*\(.*\)\s*$' then neg := true; end if;
  if s ~ '-' then neg := true; end if;
  n := regexp_replace(s, '[^0-9.]', '', 'g');
  if n = '' or n = '.' then return null; end if;
  return case when neg then -1 else 1 end * n::numeric;
exception when others then
  return null;
end $$;

-- 'Nov 15 - 21, 2025' → (2025-11-15, 2025-11-21)
-- 'Aug 29 - Sep 4, 2026' → (2026-08-29, 2026-09-04)
-- 'Dec 27 - Jan 2, 2026' → (2025-12-27, 2026-01-02)   (year rolls back for the start)
create or replace function bt_parse_period(p text, out period_start date, out period_end date)
language plpgsql immutable as $$
declare
  s text := regexp_replace(replace(replace(coalesce(p,''), chr(8211), '-'), chr(8212), '-'), '\s+', ' ', 'g');
  m text[];
begin
  m := regexp_match(bt_trim(s), '^([A-Za-z]{3})[a-z]* (\d{1,2}) - (?:([A-Za-z]{3})[a-z]* )?(\d{1,2}), (\d{4})$');
  if m is null then return; end if;
  period_end   := to_date(coalesce(m[3], m[1]) || ' ' || m[4] || ' ' || m[5], 'Mon DD YYYY');
  period_start := to_date(m[1] || ' ' || m[2] || ' ' || m[5], 'Mon DD YYYY');
  if period_start > period_end then
    period_start := (period_start - interval '1 year')::date;
  end if;
exception when others then
  period_start := null; period_end := null;
end $$;

-- First Buildertrend job number in a string: 'R26009' / 'M25011'. Null if none.
create or replace function bt_extract_job_number(p text) returns text
language sql immutable as $$
  select upper((regexp_match(coalesce(p,''), '\m([RM]\d{5})\M', 'i'))[1])
$$;

-- Trim spaces AND tabs. Outlook's plain-text rendering ends most lines with a
-- tab, and bt_trim() only strips spaces.
create or replace function bt_trim(p text) returns text
language sql immutable as $$
  select nullif(regexp_replace(coalesce(p,''), '^\s+|\s+$', '', 'g'), '')
$$;

-- Escape a literal so it can be embedded in a regex.
create or replace function bt_rx_escape(p text) returns text
language sql immutable as $$
  select regexp_replace(coalesce(p,''), '([.*+?^${}()|\[\]\\])', '\\\1', 'g')
$$;

-- Parse ONE stored email into bt_events. Replaces any previous event for it.
-- Returns the event_type written. Never raises: failures are recorded on the
-- email row as parse_status='error' so one bad message can't stop a batch.
create or replace function bt_parse_email(p_email_id bigint) returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  e            bt_emails%rowtype;
  subj         text;
  body         text;
  m            text[];
  emdash       text := chr(8212);   -- —
  lquote       text := chr(8220);   -- “
  v_type       text := 'unclassified';
  v_job_name   text;
  v_job_number text;
  v_actor      text;
  v_title      text;
  v_summary    text;
  v_link       text;
  v_amount     numeric;
  v_pstart     date;
  v_pend       date;
  v_fields     jsonb := '{}'::jsonb;
  v_occurred   timestamptz;
  after_quote  text;
  is_notification boolean;
begin
  select * into e from bt_emails where id = p_email_id;
  if not found then return null; end if;

  -- Normalise: NBSP → space, collapse whitespace in the subject, strip CRs.
  subj := bt_trim(regexp_replace(replace(coalesce(e.subject,''), chr(160), ' '), '\s+', ' ', 'g'));
  body := replace(replace(coalesce(e.body_text,''), chr(160), ' '), chr(13), '');

  -- Only the account's own notification sender produces templated mail.
  -- Sales/marketing mail from *@buildertrend.com stays unclassified on purpose.
  is_notification := lower(coalesce(e.from_address,'')) = 'vanbuskirkhomes@buildertrend.com';

  if is_notification then

    -- ── client_update ──────────────────────────────────────────────────────
    -- Subject: Van Buskirk Homes LLC published an update for Nov 15 - 21, 2025 — R25018 - 1000-1006 River Stone St. BLDG #1
    m := regexp_match(subj, '^Van Buskirk Homes LLC published an update for (.+) ' || emdash || ' (.+)$');
    if m is not null then
      v_type     := 'client_update';
      v_title    := bt_trim(m[1]);
      v_job_name := bt_trim(m[2]);
      select ps.period_start, ps.period_end into v_pstart, v_pend from bt_parse_period(v_title) ps;
      v_actor := bt_trim((regexp_match(body, '([^\n]+?) has published the Client Update'))[1]);
      v_link  := (regexp_match(body, 'View update <(https?://[^>\s]+)>'))[1];
      -- Teaser sits between the opening “ and the closing " — Buildertrend
      -- truncates it to ~170 chars ending in ..." ; the full text is behind the link.
      if position(lquote in body) > 0 then
        after_quote := substring(body from position(lquote in body) + 1);
        v_summary   := bt_trim(split_part(after_quote, '"', 1));
        v_fields    := v_fields || jsonb_build_object('truncated', v_summary like '%...');
        v_summary   := bt_trim(regexp_replace(v_summary, '\.\.\.$', ''));
      end if;
    end if;

    -- ── change_order_added ─────────────────────────────────────────────────
    -- Subject: New Change Order 'Ditra Heat in the Bathrooms' added on job 'R26009 - 3412 Bronze Lane - LOT'
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^New Change Order ''(.*)'' added on job ''(.*)''$');
      if m is not null then
        v_type     := 'change_order_added';
        v_title    := bt_trim(m[1]);
        v_job_name := bt_trim(m[2]);
        v_amount   := bt_parse_money((regexp_match(body, 'Price:\s*([^\n]+)'))[1]);
        v_actor    := bt_trim((regexp_match(body, 'Added By:\s*([^\n]+)'))[1]);
        v_link     := (regexp_match(body, '<(https://buildertrend\.net/app/link/[^>\s]+)>'))[1];
      end if;
    end if;

    -- ── change_order_approved ──────────────────────────────────────────────
    -- Subject: Change Order 'Selections Change Order' Approved on job 'R25026 - 170 Village Circle - Goodwin'
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^Change Order ''(.*)'' Approved on job ''(.*)''$');
      if m is not null then
        v_type     := 'change_order_approved';
        v_title    := bt_trim(m[1]);
        v_job_name := bt_trim(m[2]);
        v_amount   := bt_parse_money((regexp_match(body, 'Price:\s*([^\n]+)'))[1]);
        v_actor    := bt_trim((regexp_match(body, '\nFrom\s+([^\n]+)'))[1]);
        v_link     := (regexp_match(body, '<(https://buildertrend\.net/app/link/[^>\s]+)>'))[1];
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'co_number', (regexp_match(body, 'Change Order #([A-Z]\d{5}-\d{4})'))[1],
          'status',    bt_trim((regexp_match(body, 'Status:[^\n]*?\s(Approved[^\n]*|Declined[^\n]*|Pending[^\n]*)'))[1]),
          'reason',    nullif(bt_trim((regexp_match(body, 'Reason for Action:\s*([^\n]*)'))[1]), '')
        ));
      end if;
    end if;

    -- ── change_order_file ──────────────────────────────────────────────────
    -- Subject: New File was added to 'Change Orders for Closing' by Sydney VanWell
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^New File was added to ''(.*)'' by (.+)$');
      if m is not null then
        v_type     := 'change_order_file';
        v_title    := bt_trim(m[1]);
        v_actor    := bt_trim(m[2]);
        v_job_name := bt_trim((regexp_match(body, '\nJob:\s*([^\n]+)'))[1]);
        v_amount   := bt_parse_money((regexp_match(body, 'Price:\s*([^\n]+)'))[1]);
        v_link     := (regexp_match(body, '<(https://buildertrend\.net/app/link/[^>\s]+)>'))[1];
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'lot_info',    bt_trim((regexp_match(body, 'Lot Info:\s*([^\n]+)'))[1]),
          'status',      bt_trim((regexp_match(body, 'Status:\s*([^\n]+)'))[1]),
          'attachments', (regexp_match(body, '(\d+) Attachments'))[1]::int
        ));
      end if;
    end if;

    -- ── document_comment ───────────────────────────────────────────────────
    -- Subject: Justin Vostad commented on the document "26.7.22-221 Ivy Lane Brandon Plumbing&Heating.pdf." — R26025 - 213 Ivy Lane, Crooks - Model Home
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^(.+) commented on the document "(.+)" ' || emdash || ' (.+)$');
      if m is not null then
        v_type     := 'document_comment';
        v_actor    := bt_trim(m[1]);
        v_title    := bt_trim(regexp_replace(m[2], '\.$', ''));   -- template appends a period after the filename
        v_job_name := bt_trim(m[3]);
        v_link     := (regexp_match(body, 'View Document <(https?://[^>\s]+)>'))[1];
        -- Comment text is the line between the commenter's name line and the first "View Document".
        v_summary  := bt_trim((regexp_match(body, '\n[ \t]*' || bt_rx_escape(v_actor) || '[ \t]*\n[ \t]*([^\n]+?)[ \t]*\n[ \t]*View Document'))[1]);
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'job_address', bt_trim((regexp_match(body, 'Job Address[ \t]+([^\n]+)'))[1])
        ));
      end if;
    end if;

  end if;

  -- Job number: from the job name first, then anywhere in the subject/body.
  v_job_number := coalesce(bt_extract_job_number(v_job_name), bt_extract_job_number(subj),
                           bt_extract_job_number((regexp_match(body, '\nJob(?: Name)?[:\t ]+([^\n]+)'))[1]));
  if v_job_name is null and v_job_number is not null then
    v_job_name := bt_trim((regexp_match(body, '\nJob(?: Name)?[:\t ]+([^\n]+)'))[1]);
  end if;

  -- When did it happen? The received timestamp. CSV imports have none, so a
  -- client update falls back to the end of the week it describes.
  v_occurred := coalesce(e.received_at, v_pend::timestamptz);

  delete from bt_events where email_id = e.id;
  insert into bt_events (email_id, event_type, job_number, job_name, occurred_at, actor, title, amount,
                         period_start, period_end, summary, link, fields, parser_version)
  values (e.id, v_type, v_job_number, v_job_name, v_occurred, v_actor, v_title, v_amount,
          v_pstart, v_pend, v_summary, v_link, v_fields, bt_parser_version());

  update bt_emails
     set parsed_at = now(),
         parse_status = case when v_type = 'unclassified' then 'unclassified' else 'ok' end,
         parse_error = null
   where id = e.id;

  return v_type;

exception when others then
  -- Record it and move on. The raw email is untouched; bt_reparse_all() will retry.
  update bt_emails set parsed_at = now(), parse_status = 'error', parse_error = SQLERRM where id = p_email_id;
  return 'error';
end $$;

-- Parse on arrival.
create or replace function bt_on_email_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform bt_parse_email(new.id);
  return new;
end $$;

drop trigger if exists bt_emails_parse on bt_emails;
create trigger bt_emails_parse
  after insert on bt_emails
  for each row execute function bt_on_email_insert();

-- Re-run the current parser over every stored email. Returns a count per type.
create or replace function bt_reparse_all()
returns table (event_type text, n bigint)
language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in select id from bt_emails order by id loop
    perform bt_parse_email(r.id);
  end loop;
  return query
    select ev.event_type, count(*) from bt_events ev group by ev.event_type order by 2 desc;
end $$;

-- ═══════════════════════════════════════════════════════════════════════════
--  INGEST ENTRY POINT
--  One call per message. Idempotent on message_id. Returns 'inserted' or
--  'duplicate'. Callable with the anon key ONLY with the shared secret stored
--  in bt_settings ('ingest_secret'); the service role bypasses that check.
--
--    insert into bt_settings values ('ingest_secret', '<long random string>');
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function bt_ingest_email(
  p_secret       text,
  p_message_id   text,
  p_subject      text,
  p_body_text    text,
  p_received_at  timestamptz default null,
  p_from_address text default null,
  p_from_name    text default null,
  p_to_address   text default null,
  p_body_html    text default null,
  p_source       text default 'power_automate'
) returns text
language plpgsql security definer set search_path = public as $$
declare
  want text;
  new_id bigint;
begin
  if current_setting('request.jwt.claims', true)::jsonb ->> 'role' is distinct from 'service_role' then
    select value into want from bt_settings where key = 'ingest_secret';
    if want is null or p_secret is distinct from want then
      raise exception 'bt_ingest_email: bad secret' using errcode = '28000';
    end if;
  end if;

  if coalesce(bt_trim(p_message_id), '') = '' then
    raise exception 'bt_ingest_email: message_id required';
  end if;

  insert into bt_emails (message_id, received_at, from_address, from_name, to_address, subject, body_text, body_html, source)
  values (bt_trim(p_message_id), p_received_at, lower(nullif(bt_trim(p_from_address),'')), nullif(bt_trim(p_from_name),''),
          nullif(bt_trim(p_to_address),''), coalesce(p_subject,''), p_body_text, p_body_html, coalesce(p_source,'power_automate'))
  on conflict (message_id) do nothing
  returning id into new_id;

  return case when new_id is null then 'duplicate' else 'inserted' end;
end $$;

revoke all on function bt_ingest_email(text,text,text,text,timestamptz,text,text,text,text,text) from public;
grant execute on function bt_ingest_email(text,text,text,text,timestamptz,text,text,text,text,text) to anon, authenticated, service_role;

-- Reparse is admin-only (SQL editor / service role).
revoke all on function bt_reparse_all() from public, anon, authenticated;
revoke all on function bt_parse_email(bigint) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  READ MODELS for the hub
-- ═══════════════════════════════════════════════════════════════════════════

-- Every parsed event with its raw subject and the matching tracker project.
create or replace view v_bt_events with (security_invoker = true) as
select ev.id, ev.event_type, ev.job_number, ev.job_name, ev.occurred_at, ev.actor, ev.title,
       ev.amount, ev.period_start, ev.period_end, ev.summary, ev.link, ev.fields, ev.parser_version,
       e.id as email_id, e.subject, e.received_at, e.from_address, e.source, e.parse_status,
       p.id as project_id, p.address, p.buyer_realtor, p.stage as project_stage, p.status as project_status
from bt_events ev
join bt_emails e on e.id = ev.email_id
left join projects p on upper(p.job_number) = ev.job_number;

-- Per-job roll-up for the meeting page's job cards: what happened since the
-- last meeting. 14-day window so a skipped week still shows.
create or replace view v_bt_job_activity with (security_invoker = true) as
with recent as (
  select * from bt_events
  where job_number is not null
    and occurred_at >= now() - interval '14 days'
)
select job_number,
       max(job_name)                                                        as job_name,
       max(occurred_at)                                                     as last_activity,
       count(*) filter (where event_type = 'client_update')                 as client_updates,
       count(*) filter (where event_type = 'change_order_added')            as cos_added,
       count(*) filter (where event_type = 'change_order_approved')         as cos_approved,
       coalesce(sum(amount) filter (where event_type = 'change_order_approved'), 0) as co_approved_total,
       count(*) filter (where event_type = 'document_comment')              as comments,
       (array_agg(summary order by occurred_at desc)
          filter (where event_type = 'client_update' and summary is not null))[1] as latest_update,
       (array_agg(period_end order by occurred_at desc)
          filter (where event_type = 'client_update'))[1]                   as latest_update_week
from recent
group by job_number;

-- Emails the parser couldn't place — review this list when adding templates.
create or replace view v_bt_unclassified with (security_invoker = true) as
select e.id, e.received_at, e.from_address, e.subject, e.parse_status, e.parse_error, e.source
from bt_emails e
where e.parse_status in ('unclassified', 'error')
order by e.received_at desc nulls last, e.id desc;

grant select on v_bt_events, v_bt_job_activity, v_bt_unclassified to anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
--  Build stamp — read it back to confirm which version is installed:
--    select bt_parser_version();
-- ═══════════════════════════════════════════════════════════════════════════
