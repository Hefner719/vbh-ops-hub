-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend bridge · migration 025 · parser version 5
--  build: bt-bridge-v7
--
--  BUILDERTREND CHANGED THEIR SENDING ADDRESS AND THE BRIDGE WENT QUIET.
--
--  Every notification used to come from vanbuskirkhomes@buildertrend.com.
--  That address sent its last message on 2026-10-23; since then everything has
--  arrived from notifications@buildertrend.net. The whole v2-v4 branch chain
--  sits behind `is_notification`, which tested for the old address alone, so
--  all 399 messages received in the seventeen days since fell straight through
--  to `unclassified` - bills, lien waivers, overdue digests, client updates,
--  change orders, the lot. Ingest never broke and no run ever errored, which
--  is exactly why it went unnoticed: the job cards simply filled up with rows
--  tagged UNCLASSIFIED and nothing else.
--
--  The bodies are unchanged - same "Title: / Bill #: / Job:" shape - so
--  widening the sender test is all that is needed to recover every one.
--
--  DAILY LOGS ARE NOW ARRIVING. Switching on the Daily Log notification
--  worked, and these have been landing unparsed alongside everything else:
--
--    New Daily Log
--    Author: Quentin Robertson
--    Job: R26017 - 1501 Karna Circle - Monday, Justin & Tess
--    Date: 11-6-2026
--    Progress: siding continues
--
--  Parsed here as `daily_log`, which is the event type
--  v_bt_daily_log_cadence (migration 021) has been waiting for. That view
--  guards itself until the type exists, so the three-work-day tracking starts
--  working on its own the moment this runs.
--
--  Dated by `Date:` - the day the work happened - not by when the mail
--  arrived, so a log written up the next morning does not read as a day with
--  no log on site.
--
--  Everything in v4 is carried over unchanged. Re-runnable.
--  After applying:  select * from bt_reparse_all();
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function bt_parser_version() returns int
language sql immutable as $$ select 5 $$;

-- "11-6-2026" / "11-06-2026" -> date. Returns null rather than raising.
create or replace function bt_parse_loose_date(p text)
returns date language plpgsql immutable as $$
declare m text[];
begin
  if p is null or btrim(p) = '' then return null; end if;
  m := regexp_match(btrim(p), '^(\d{1,2})-(\d{1,2})-(\d{4})$');
  if m is null then return null; end if;
  return make_date(m[3]::int, m[1]::int, m[2]::int);
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
  /* v5: Buildertrend moved from vanbuskirkhomes@buildertrend.com to
     notifications@buildertrend.net on 2026-10-23. Both are accepted — the old
     address still has 992 messages of history behind it that must keep
     parsing. Any further address they move to belongs in this list. */
  is_notification := lower(coalesce(e.from_address,'')) in
                     ('vanbuskirkhomes@buildertrend.com', 'notifications@buildertrend.net');

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

    -- ── owner invoices (v4) ────────────────────────────────────────────────
    -- "Kara Lilly created a new $14,671.31 invoice for R26020 - 2800 …"
    -- Nine of these landed on a single day and every one was discarded as
    -- unclassified. This is the money going out the door per job: amount,
    -- balance, draft-or-sent, and the deadline it has to be out by.
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^(.+?) (created a new|updated a|has updated a) \$([0-9,.]+) invoice for (.+?)\.?$');
      if m is not null then
        v_type     := case when m[2] = 'created a new' then 'invoice_created' else 'invoice_updated' end;
        v_actor    := bt_trim(m[1]);
        v_amount   := bt_parse_money(m[3]);
        v_job_name := bt_trim(m[4]);
        v_title    := bt_trim((regexp_match(body, 'ID #\s*([A-Z]\d{5}-\d{4})'))[1]);
        v_link     := (regexp_match(body, '<(https://buildertrend\.net/app/link/[^>\s]+)>'))[1];
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'invoice_id',  bt_trim((regexp_match(body, 'ID #\s*([A-Z]\d{5}-\d{4})'))[1]),
          'status',      bt_trim((regexp_match(body, 'Status\s+(Draft|Sent|Paid|Overdue|Partially Paid)'))[1]),
          'balance_due', bt_parse_money((regexp_match(body, 'Balance due\s*\$?([0-9,.]+)'))[1]),
          'deadline',    bt_trim((regexp_match(body, 'Deadline\s+([A-Z][a-z]{2} \d{1,2}, \d{4})'))[1])));
        v_summary := case when m[2] = 'created a new' then 'Invoice raised' else 'Invoice updated' end
                     || coalesce(' ' || v_title, '')
                     || coalesce(' - ' || (v_fields->>'status'), '');
      end if;
    end if;

    -- ── client_update_ready (v4) ───────────────────────────────────────────
    -- Buildertrend nagging that the weekly client updates have NOT gone out.
    -- The meeting asks this out loud every Tuesday; now it can answer itself.
    if v_type = 'unclassified' then
      if subj ~ 'Client Updates are ready to (publish|send)' then
        v_type  := 'client_update_ready';
        v_title := subj;
        select ps.period_start, ps.period_end into v_pstart, v_pend
          from bt_parse_period((regexp_match(body, 'updates will cover ([^.]+?)\.'))[1]) ps;
        v_summary := 'Client Updates not yet published'
                     || coalesce(' for ' || bt_trim((regexp_match(body, 'updates will cover ([^.]+?)\.'))[1]), '');
      end if;
    end if;

    -- ── daily_log (v5) ─────────────────────────────────────────────────────
    -- "R26017 - 1501 Karna Circle - … - Daily Log information has been added"
    -- These started arriving once the Daily Log notification was switched on.
    -- Author, job, the date the work happened, and the progress note - which
    -- is the field the three-work-day rule counts from.
    if v_type = 'unclassified' then
      if subj ~ 'Daily Log information has been added' then
        v_type     := 'daily_log';
        v_actor    := bt_trim((regexp_match(body, 'Author:\s*([^\n]+?)\s*(?:Job:|$)'))[1]);
        v_job_name := bt_trim((regexp_match(body, 'Job:\s*([^\n]+?)\s*(?:Address:|$)'))[1]);
        v_link     := (regexp_match(body, '<(https?://[^>\s]+)>'))[1];
        v_summary  := bt_trim((regexp_match(body, 'Progress:\s*(.*?)\s*(?:Issues:|Materials Delivered:|View Details|$)'))[1]);
        v_title    := coalesce(nullif(v_summary,''), 'Daily log');
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'log_date',  bt_parse_loose_date(bt_trim((regexp_match(body, 'Date:\s*(\d{1,2}-\d{1,2}-\d{4})'))[1])),
          'issues',    nullif(bt_trim((regexp_match(body, 'Issues:\s*(.*?)\s*(?:Materials Delivered:|View Details|$)'))[1]), ''),
          'materials', nullif(bt_trim((regexp_match(body, 'Materials Delivered:\s*(.*?)\s*(?:View Details|$)'))[1]), ''),
          'address',   nullif(bt_trim((regexp_match(body, 'Address:\s*([^\n]+?)\s*(?:Date:|$)'))[1]), '')));
        -- The log is dated by the day the work happened, not the day the mail
        -- arrived: a log written up the next morning must not count as a day
        -- with no log on site.
        v_pstart := (v_fields->>'log_date')::date;
      end if;
    end if;

  end if;   -- is_notification

  -- ── mail from info@buildertrend.com (v4) ─────────────────────────────────
  -- Bill approvals and sub/vendor activations arrive from a DIFFERENT sender
  -- than the job notifications, which is the only reason they were never
  -- parsed: the whole block above is gated on the notification address.
  if v_type = 'unclassified' and lower(coalesce(e.from_address,'')) = 'info@buildertrend.com' then

    if subj ~ '^(You have a bill to approve|Bill assigned to you for approval)' then
      v_type     := 'bill_approval_needed';
      v_job_name := bt_trim((regexp_match(body, '(?:View details|below)\s+([A-Z]\d{5}[^\n]*?)\s+Bill #'))[1]);
      v_title    := bt_trim((regexp_match(body, 'Title\s+(.+?)\s+Sub/vendor'))[1]);
      v_amount   := bt_parse_money((regexp_match(body, 'Bill amount\s*\$?([0-9,.]+)'))[1]);
      v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
        'bill_number', bt_trim((regexp_match(body, 'Bill #\s*(\d+)'))[1]),
        'vendor',      bt_trim((regexp_match(body, 'Sub/vendor\s+(.+?)\s+Bill amount'))[1]),
        'awaiting',    true));
      -- "Bill assigned to you" carries no detail at all; say so rather than
      -- inventing a title for it.
      v_summary := coalesce('Awaiting approval: ' || v_title, 'A bill is awaiting approval (no detail in the email)');
    end if;

    if v_type = 'unclassified' then
      m := regexp_match(subj, '^Sub/Vendor Now Activated:\s*(.+)$');
      if m is not null then
        v_type    := 'vendor_activated';
        v_title   := bt_trim(m[1]);
        v_summary := bt_trim(m[1]) || ' is now active in Buildertrend';
        v_fields  := v_fields || jsonb_build_object('vendor', bt_trim(m[1]));
      end if;
    end if;
  end if;

  -- ── Buildertrend's own marketing and system mail (v4) ────────────────────
  -- Not a parse failure and not worth anyone's attention. Separating it means
  -- `unclassified` finally means "a template we don't understand yet", which
  -- is the only thing that list is useful for.
  if v_type = 'unclassified'
     and lower(coalesce(e.from_address,'')) ~ '@(email\.)?buildertrend\.com$'
     and lower(coalesce(e.from_address,'')) <> 'vanbuskirkhomes@buildertrend.com' then
    v_type    := 'bt_marketing';
    v_title   := subj;
    v_summary := 'Buildertrend marketing or account mail';
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
