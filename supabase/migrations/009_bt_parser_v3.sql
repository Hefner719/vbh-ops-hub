-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend bridge · migration 009 · parser version 3
--  build: bt-bridge-v3
--
--  Two templates appeared in live mail that the CSV samples never contained:
--
--    todo_overdue    "The to-do "…" is past due since Aug 05, 2025."
--                    Carries job, deadline, who set it, the client and their
--                    phone number, and the description of the work. This is
--                    warranty and service work — the meeting has a section for
--                    exactly this, and it was being kept by hand.
--
--    timesheet_long  "Time sheet - Clocked in Over 12 Hours"
--                    Someone left the clock running. Low value for the
--                    meeting, but parsed so it stops counting as unclassified.
--
--  Only the v2 branches are restated here; everything else is unchanged.
--  Re-runnable. After applying:  select * from bt_reparse_all();
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function bt_parser_version() returns int
language sql immutable as $$ select 3 $$;

-- 'Tue, Aug 05' (no year) resolved against the year the mail arrived, which is
-- the only sound guess; a deadline is never far from its notification.
create or replace function bt_parse_dayless_date(p text, ref timestamptz)
returns date language plpgsql immutable as $$
declare s text := bt_trim(p); d date; y int;
begin
  if s is null or ref is null then return null; end if;
  s := bt_trim(regexp_replace(s, '^[A-Za-z]{3,9},\s*', ''));   -- drop 'Tue, '
  if s !~ '^[A-Za-z]{3,9}\s+\d{1,2}$' then return null; end if;
  y := extract(year from ref)::int;
  d := to_date(s || ' ' || y, 'Mon DD YYYY');
  -- A deadline more than six months ahead of the mail almost certainly belongs
  -- to the previous year (a December deadline mailed in January).
  if d > (ref::date + 180) then d := to_date(s || ' ' || (y - 1), 'Mon DD YYYY'); end if;
  return d;
exception when others then return null;
end $$;

create or replace function bt_parse_email(p_email_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare
  e            bt_emails%rowtype;
  subj         text;
  body         text;
  m            text[];
  blk          text[];
  emdash       text := chr(8212);
  lquote       text := chr(8220);
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
  arr          jsonb := '[]'::jsonb;
  jobs_seen    text[];
  tail         text;
begin
  select * into e from bt_emails where id = p_email_id;
  if not found then return null; end if;

  subj := bt_trim(regexp_replace(replace(coalesce(e.subject,''), chr(160), ' '), '\s+', ' ', 'g'));
  body := replace(replace(coalesce(e.body_text,''), chr(160), ' '), chr(13), '');
  is_notification := lower(coalesce(e.from_address,'')) = 'vanbuskirkhomes@buildertrend.com';

  if is_notification then

    -- ── client_update ──────────────────────────────────────────────────────
    m := regexp_match(subj, '^Van Buskirk Homes LLC published an update for (.+) ' || emdash || ' (.+)$');
    if m is not null then
      v_type := 'client_update'; v_title := bt_trim(m[1]); v_job_name := bt_trim(m[2]);
      select ps.period_start, ps.period_end into v_pstart, v_pend from bt_parse_period(v_title) ps;
      v_actor := bt_trim((regexp_match(body, '([^\n]+?) has published the Client Update'))[1]);
      v_link  := (regexp_match(body, 'View update <(https?://[^>\s]+)>'))[1];
      if position(lquote in body) > 0 then
        after_quote := substring(body from position(lquote in body) + 1);
        v_summary   := bt_trim(split_part(after_quote, '"', 1));
        v_fields    := v_fields || jsonb_build_object('truncated', v_summary like '%...');
        v_summary   := bt_trim(regexp_replace(v_summary, '\.\.\.$', ''));
      end if;
    end if;

    -- ── change orders ──────────────────────────────────────────────────────
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^New Change Order ''(.*)'' added on job ''(.*)''$');
      if m is not null then
        v_type := 'change_order_added'; v_title := bt_trim(m[1]); v_job_name := bt_trim(m[2]);
        v_amount := bt_parse_money((regexp_match(body, 'Price:\s*([^\n]+)'))[1]);
        v_actor  := bt_trim((regexp_match(body, 'Added By:\s*([^\n]+)'))[1]);
        v_link   := (regexp_match(body, '<(https://buildertrend\.net/app/link/[^>\s]+)>'))[1];
      end if;
    end if;
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^Change Order ''(.*)'' Approved on job ''(.*)''$');
      if m is not null then
        v_type := 'change_order_approved'; v_title := bt_trim(m[1]); v_job_name := bt_trim(m[2]);
        v_amount := bt_parse_money((regexp_match(body, 'Price:\s*([^\n]+)'))[1]);
        v_actor  := bt_trim((regexp_match(body, '\nFrom\s+([^\n]+)'))[1]);
        v_link   := (regexp_match(body, '<(https://buildertrend\.net/app/link/[^>\s]+)>'))[1];
        v_fields := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'co_number', (regexp_match(body, 'Change Order #([A-Z]\d{5}-\d{4})'))[1],
          'status',    bt_trim((regexp_match(body, 'Status:[^\n]*?\s(Approved[^\n]*|Declined[^\n]*|Pending[^\n]*)'))[1]),
          'reason',    bt_trim((regexp_match(body, 'Reason for Action:\s*([^\n]*)'))[1])));
      end if;
    end if;
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^New File was added to ''(.*)'' by (.+)$');
      if m is not null then
        v_type := 'change_order_file'; v_title := bt_trim(m[1]); v_actor := bt_trim(m[2]);
        v_job_name := bt_trim((regexp_match(body, '\nJob:\s*([^\n]+)'))[1]);
        v_amount   := bt_parse_money((regexp_match(body, 'Price:\s*([^\n]+)'))[1]);
        v_link     := (regexp_match(body, '<(https://buildertrend\.net/app/link/[^>\s]+)>'))[1];
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'lot_info',    bt_trim((regexp_match(body, 'Lot Info:\s*([^\n]+)'))[1]),
          'status',      bt_trim((regexp_match(body, 'Status:\s*([^\n]+)'))[1]),
          'attachments', (regexp_match(body, '(\d+) Attachments'))[1]::int));
      end if;
    end if;

    -- ── document_comment ───────────────────────────────────────────────────
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^(.+) commented on the document "(.+)" ' || emdash || ' (.+)$');
      if m is not null then
        v_type := 'document_comment'; v_actor := bt_trim(m[1]);
        v_title := bt_trim(regexp_replace(m[2], '\.$', '')); v_job_name := bt_trim(m[3]);
        v_link  := (regexp_match(body, 'View Document <(https?://[^>\s]+)>'))[1];
        v_summary := bt_trim((regexp_match(body, '\n[ \t]*' || bt_rx_escape(v_actor) || '[ \t]*\n[ \t]*([^\n]+?)[ \t]*\n[ \t]*View Document'))[1]);
        v_fields  := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'job_address', bt_trim((regexp_match(body, 'Job Address[ \t]+([^\n]+)'))[1])));
      end if;
    end if;

    -- ── accounts payable (v2) ──────────────────────────────────────────────
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^Bill ''(.*)'' payment made on job ''(.*)''$');
      if m is not null then
        v_type := 'bill_paid'; v_title := bt_trim(m[1]); v_job_name := bt_trim(m[2]);
        v_amount := bt_parse_money((regexp_match(body, 'Amount Paid:\s*([^\n]+)'))[1]);
        v_actor  := bt_trim((regexp_match(body, 'Paid To:\s*([^\n]+)'))[1]);
        v_summary := v_actor;
        v_fields := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'vendor', v_actor,
          'source_system', bt_trim((regexp_match(body, '\nFrom\s+([^\n]+)'))[1]),
          'bill_title', bt_trim((regexp_match(body, 'Bill # - Title:\s*([^\n]+)'))[1]),
          'scheduled_completion', bt_parse_loose_date((regexp_match(body, 'Scheduled Completion Date:\s*([^\n]+)'))[1])));
      end if;
    end if;
    if v_type = 'unclassified' and subj = 'Bill Marked Ready for Payment' then
      v_type := 'bill_ready';
      v_title    := bt_trim((regexp_match(body, '\nTitle:\s*([^\n]+)'))[1]);
      v_job_name := bt_trim((regexp_match(body, '\nJob:\s*([^\n]+)'))[1]);
      v_actor    := bt_trim((regexp_match(body, 'Performing User:\s*([^\n]+)'))[1]);
      v_summary  := v_actor;
      v_fields := v_fields || jsonb_strip_nulls(jsonb_build_object(
        'vendor', v_actor,
        'bill_no', bt_trim((regexp_match(body, 'Bill #:\s*([^\n]+)'))[1]),
        'address', bt_trim((regexp_match(body, '\nAddress:\s*([^\n]+)'))[1]),
        'comments', bt_trim((regexp_match(body, 'Comments:\s*([^\n]+)'))[1])));
    end if;
    if v_type = 'unclassified' and subj = 'Lien Waiver Signed' then
      v_type := 'lien_waiver_signed';
      v_actor    := bt_trim((regexp_match(body, '\nFrom\s+([^\n]+)'))[1]);
      v_title    := bt_trim((regexp_match(body, 'Bill # - Title:\s*([^\n]+)'))[1]);
      v_job_name := bt_trim((regexp_match(body, '\nJob:\s*([^\n]+)'))[1]);
      v_summary  := v_actor;
      v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object('vendor', v_actor));
    end if;
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^You have (\d+) (overdue|upcoming) bills?$');
      if m is not null then
        v_type := case when m[2] = 'overdue' then 'bills_overdue' else 'bills_upcoming' end;
        v_title := subj; arr := '[]'::jsonb; jobs_seen := '{}';
        for blk in
          select regexp_matches(body,
            'Job\s+([^\n]+)\n+Bill #\s*([^\n]+)\n+Title\s+([^\n]+)\n+Bill amount\s*([^\n]+)\n+Due date\s+([^\n]+)', 'g')
        loop
          arr := arr || jsonb_strip_nulls(jsonb_build_object(
            'job_name', bt_trim(blk[1]), 'job_number', bt_extract_job_number(blk[1]),
            'bill_no', bt_trim(blk[2]), 'title', bt_trim(blk[3]),
            'amount', bt_parse_money(blk[4]), 'due_date', bt_parse_loose_date(blk[5]),
            'days_overdue', (regexp_match(blk[5], '\((\d+) days? overdue\)'))[1]::int));
          if bt_extract_job_number(blk[1]) is not null then
            jobs_seen := array_append(jobs_seen, bt_extract_job_number(blk[1]));
          end if;
        end loop;
        v_fields := v_fields || jsonb_build_object('bills', arr, 'count', coalesce(m[1]::int, jsonb_array_length(arr)));
        select sum((x->>'amount')::numeric) into v_amount from jsonb_array_elements(arr) x where x ? 'amount';
        select distinct j into v_job_number from unnest(jobs_seen) j;
        if (select count(distinct j) from unnest(jobs_seen) j) <> 1 then v_job_number := null; end if;
        v_summary := jsonb_array_length(arr) || ' bill(s)' ||
                     case when v_amount is not null then ' totaling $' || to_char(v_amount, 'FM999,999,990.00') else '' end;
      end if;
    end if;
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^An? \$([0-9,]+\.?[0-9]*) invoice for (.+) is (\d+) days? overdue$');
      if m is not null then
        v_type := 'invoice_overdue'; v_amount := bt_parse_money(m[1]);
        v_job_name := bt_trim(m[2]); v_title := 'Invoice overdue';
        v_fields := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'days_overdue', m[3]::int,
          'invoice_id', bt_trim((regexp_match(body, 'ID #\s*([^\n]+)'))[1]),
          'status', bt_trim((regexp_match(body, '\nStatus\s+([^\n]+)'))[1]),
          'deadline', bt_parse_loose_date((regexp_match(body, '\nDeadline\s+([^\n]+)'))[1]),
          'balance_due', bt_parse_money((regexp_match(body, 'Balance due\s*([^\n]+)'))[1])));
        v_summary := '$' || to_char(v_amount, 'FM999,999,990.00') || ' overdue ' || m[3] || ' day(s)';
      end if;
    end if;
    if v_type = 'unclassified' and subj like 'Insurance Expiration Notice%' then
      v_type := 'insurance_expiring'; v_title := subj; arr := '[]'::jsonb;
      for blk in select regexp_matches(body, '([^\n]+?)\s+-\s+Exp:\s*(\d{1,2}-\d{1,2}-\d{4})', 'g') loop
        arr := arr || jsonb_build_object('vendor', bt_trim(blk[1]), 'expires', bt_parse_loose_date(blk[2]));
      end loop;
      v_fields := v_fields || jsonb_build_object('vendors', arr, 'count', jsonb_array_length(arr));
      v_summary := (select string_agg(x->>'vendor', ', ' order by x->>'expires') from jsonb_array_elements(arr) x);
    end if;

    -- ═══ v3 · SCHEDULE AND LABOUR ════════════════════════════════════════════

    -- ── todo_overdue ───────────────────────────────────────────────────────
    --   Subject: The to-do "8013 S Pinewood Ave: Service Work - VBH" is past due since Aug 05, 2025.
    --   Body:    To-Do Deadline Date Has Passed / Job: … / To-Do: … / Address: … /
    --            Added By: Sydney VanWell / Deadline: Tue, Aug 05 /
    --            <client name> / <phone> / <description> / View Details
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^The to-do "(.+)" is past due since (.+?)\.?$');
      if m is not null then
        v_type     := 'todo_overdue';
        v_title    := bt_trim(m[1]);
        v_job_name := bt_trim((regexp_match(body, '\nJob:\s*([^\n]+)'))[1]);
        v_actor    := bt_trim((regexp_match(body, 'Added By:\s*([^\n]+)'))[1]);
        v_link     := (regexp_match(body, 'View Details <(https?://[^>\s]+)>'))[1];
        -- Everything between the Deadline line and "View Details" is the client
        -- block plus the description of the work.
        -- No 'n' flag: in Postgres that would stop . matching newlines, and this
        -- capture deliberately spans the client block and the description.
        tail := (regexp_match(body, 'Deadline:\s*[^\n]*\n(.*?)(?:\n\s*View Details|\*\* This email)'))[1];
        -- Drop the contact line and phone, both captured separately, so the
        -- summary is just the description of the work.
        v_summary := bt_trim(regexp_replace(
                       regexp_replace(
                         regexp_replace(coalesce(tail,''), '^\s*[A-Za-z][^\n]*\n', ''),
                         '\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4}', '', 'g'),
                       '\s+', ' ', 'g'));
        v_fields := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'due_date',     coalesce(bt_parse_loose_date(m[2]),
                                   bt_parse_dayless_date((regexp_match(body, 'Deadline:\s*([^\n]+)'))[1], e.received_at)),
          'deadline_raw', bt_trim((regexp_match(body, 'Deadline:\s*([^\n]+)'))[1]),
          'address',      bt_trim((regexp_match(body, '\nAddress:\s*([^\n]+)'))[1]),
          'contact',      bt_trim((regexp_match(coalesce(tail,''), '^\s*([A-Za-z][^\n]*?)\s*\n'))[1]),
          'phone',        (regexp_match(coalesce(tail,''), '(\(?\d{3}\)?[ .-]?\d{3}[ .-]?\d{4})'))[1]));
        if v_fields->>'due_date' is not null then
          v_fields := v_fields || jsonb_build_object(
            'days_overdue', greatest(0, (current_date - (v_fields->>'due_date')::date)));
        end if;
      end if;
    end if;

    -- ── timesheet_long ─────────────────────────────────────────────────────
    --   Subject: Time sheet - Clocked in Over 12 Hours
    --   Body:    R25101 - Overhead … - Clocked in since: 8-14-2025 8:21 AM
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^Time sheet - Clocked in Over (\d+) Hours?$');
      if m is not null then
        v_type  := 'timesheet_long';
        v_title := subj;
        v_job_name := bt_trim((regexp_match(body, '\n([A-Z]\d{5}[^\n]*?) - Clocked in since:'))[1]);
        v_fields := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'hours',            m[1]::int,
          'clocked_in_since', bt_trim((regexp_match(body, 'Clocked in since:\s*([^\n]+)'))[1])));
        v_summary := 'Clocked in over ' || m[1] || ' hours';
      end if;
    end if;

  end if;

  v_job_number := coalesce(v_job_number,
                           bt_extract_job_number(v_job_name),
                           bt_extract_job_number(subj),
                           bt_extract_job_number((regexp_match(body, '\nJob(?: Name)?[:\t ]+([^\n]+)'))[1]));
  if v_job_name is null and v_job_number is not null then
    v_job_name := bt_trim((regexp_match(body, '\nJob(?: Name)?[:\t ]+([^\n]+)'))[1]);
  end if;

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
  update bt_emails set parsed_at = now(), parse_status = 'error', parse_error = SQLERRM where id = p_email_id;
  return 'error';
end $$;

revoke all on function bt_parse_email(bigint) from public, anon, authenticated;

-- Open service and warranty work, newest first. The meeting's Warranty section
-- was kept by hand; this is the same information, straight from Buildertrend.
create or replace view v_bt_open_todos with (security_invoker = true) as
select ev.job_number,
       ev.job_name,
       ev.title,
       ev.actor                          as added_by,
       (ev.fields->>'due_date')::date    as due_date,
       (ev.fields->>'days_overdue')::int as days_overdue,
       ev.fields->>'contact'             as contact,
       ev.fields->>'phone'               as phone,
       ev.summary                        as detail,
       ev.link,
       ev.occurred_at
from bt_events ev
where ev.event_type = 'todo_overdue'
order by (ev.fields->>'due_date')::date nulls last;

grant select on v_bt_open_todos to anon, authenticated;
