-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend email bridge · migration 005 · parser version 2
--  build: bt-bridge-v2
--
--  Live ingest (2026-09-24) showed the Buildertrend folder is ~90% accounts-
--  payable traffic that parser v1 never saw in the CSV samples: 191 bill
--  notifications, 22 lien waivers, plus overdue-bill digests, insurance
--  expiry reminders and overdue invoices. All landed as 'unclassified'.
--
--  This adds six event types. Written against real bodies captured 2026-09-24;
--  every template below is quoted in the branch that parses it.
--
--  New types
--    bill_paid           Bill 'X' payment made on job 'Y'        (job, vendor, amount)
--    bill_ready          Bill Marked Ready for Payment           (job, vendor, bill #)
--    lien_waiver_signed  Lien Waiver Signed                      (job, vendor, bill title)
--    bills_overdue       You have N overdue bill(s)              (digest; fields.bills[])
--    invoice_overdue     A $X invoice for JOB is N days overdue  (invoice id, balance)
--    insurance_expiring  Insurance Expiration Notice for ...     (no job; fields.vendors[])
--
--  Re-runnable. After applying:  select * from bt_reparse_all();
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function bt_parser_version() returns int
language sql immutable as $$ select 2 $$;

-- 'Sep 10, 2026' / '9-14-2026' / '10-22-2026' → date, else null.
create or replace function bt_parse_loose_date(p text) returns date
language plpgsql immutable as $$
declare s text := bt_trim(p);
begin
  if s is null then return null; end if;
  s := regexp_replace(s, '\s+at\s+.*$', '');            -- 'Sep 15, 2026 at 11:59 PM'
  s := regexp_replace(s, '\s*\(.*\)$', '');             -- 'Sep 10, 2026 (12 days overdue)'
  s := bt_trim(s);
  if s ~ '^[A-Za-z]{3,9}\s+\d{1,2},\s*\d{4}$' then return to_date(s, 'Mon DD, YYYY'); end if;
  if s ~ '^\d{1,2}-\d{1,2}-\d{4}$'            then return to_date(s, 'MM-DD-YYYY');   end if;
  if s ~ '^\d{1,2}/\d{1,2}/\d{4}$'            then return to_date(s, 'MM/DD/YYYY');   end if;
  return null;
exception when others then return null;
end $$;

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
  blk          text[];
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
  arr          jsonb := '[]'::jsonb;
  jobs_seen    text[];
begin
  select * into e from bt_emails where id = p_email_id;
  if not found then return null; end if;

  subj := bt_trim(regexp_replace(replace(coalesce(e.subject,''), chr(160), ' '), '\s+', ' ', 'g'));
  body := replace(replace(coalesce(e.body_text,''), chr(160), ' '), chr(13), '');

  -- Only the account's own notification sender produces templated mail.
  is_notification := lower(coalesce(e.from_address,'')) = 'vanbuskirkhomes@buildertrend.com';

  if is_notification then

    -- ── client_update ──────────────────────────────────────────────────────
    -- Van Buskirk Homes LLC published an update for Nov 15 - 21, 2025 — R25018 - …
    m := regexp_match(subj, '^Van Buskirk Homes LLC published an update for (.+) ' || emdash || ' (.+)$');
    if m is not null then
      v_type     := 'client_update';
      v_title    := bt_trim(m[1]);
      v_job_name := bt_trim(m[2]);
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

    -- ── change_order_added ─────────────────────────────────────────────────
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
          'reason',    bt_trim((regexp_match(body, 'Reason for Action:\s*([^\n]*)'))[1])
        ));
      end if;
    end if;

    -- ── change_order_file ──────────────────────────────────────────────────
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
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^(.+) commented on the document "(.+)" ' || emdash || ' (.+)$');
      if m is not null then
        v_type     := 'document_comment';
        v_actor    := bt_trim(m[1]);
        v_title    := bt_trim(regexp_replace(m[2], '\.$', ''));
        v_job_name := bt_trim(m[3]);
        v_link     := (regexp_match(body, 'View Document <(https?://[^>\s]+)>'))[1];
        v_summary  := bt_trim((regexp_match(body, '\n[ \t]*' || bt_rx_escape(v_actor) || '[ \t]*\n[ \t]*([^\n]+?)[ \t]*\n[ \t]*View Document'))[1]);
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'job_address', bt_trim((regexp_match(body, 'Job Address[ \t]+([^\n]+)'))[1])
        ));
      end if;
    end if;

    -- ═══ v2 · ACCOUNTS PAYABLE ═══════════════════════════════════════════════

    -- ── bill_paid ──────────────────────────────────────────────────────────
    --   Subject: Bill 'R25018-16160 - Raise front walks' payment made on job 'R25018 - …'
    --   Body:    Bill payment made. / From QuickBooks / Job: … / Address: … /
    --            Bill # - Title: … / Scheduled Completion Date: 9-14-2026 /
    --            Amount Paid: $1,479.00 / Paid To: RAISE RITE INC
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^Bill ''(.*)'' payment made on job ''(.*)''$');
      if m is not null then
        v_type     := 'bill_paid';
        v_title    := bt_trim(m[1]);
        v_job_name := bt_trim(m[2]);
        v_amount   := bt_parse_money((regexp_match(body, 'Amount Paid:\s*([^\n]+)'))[1]);
        v_actor    := bt_trim((regexp_match(body, 'Paid To:\s*([^\n]+)'))[1]);   -- the vendor
        v_summary  := v_actor;
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'vendor',          v_actor,
          'source_system',   bt_trim((regexp_match(body, '\nFrom\s+([^\n]+)'))[1]),
          'bill_title',      bt_trim((regexp_match(body, 'Bill # - Title:\s*([^\n]+)'))[1]),
          'scheduled_completion', bt_parse_loose_date((regexp_match(body, 'Scheduled Completion Date:\s*([^\n]+)'))[1])
        ));
      end if;
    end if;

    -- ── bill_ready ─────────────────────────────────────────────────────────
    --   Body: Bill Marked Ready for Payment / Title: … / Bill #: … / Job: … /
    --         Address: … / Performing User: <vendor> / Comments:…
    if v_type = 'unclassified' and subj = 'Bill Marked Ready for Payment' then
      v_type     := 'bill_ready';
      v_title    := bt_trim((regexp_match(body, '\nTitle:\s*([^\n]+)'))[1]);
      v_job_name := bt_trim((regexp_match(body, '\nJob:\s*([^\n]+)'))[1]);
      v_actor    := bt_trim((regexp_match(body, 'Performing User:\s*([^\n]+)'))[1]);
      v_summary  := v_actor;
      v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
        'vendor',   v_actor,
        'bill_no',  bt_trim((regexp_match(body, 'Bill #:\s*([^\n]+)'))[1]),
        'address',  bt_trim((regexp_match(body, '\nAddress:\s*([^\n]+)'))[1]),
        'comments', bt_trim((regexp_match(body, 'Comments:\s*([^\n]+)'))[1])
      ));
    end if;

    -- ── lien_waiver_signed ─────────────────────────────────────────────────
    --   Body: Lien Waiver Signed / From ABSOLUTE BUSINESSES LLC /
    --         Bill # - Title: R26021-0346 - Framing and Siding Labor / Job: …
    if v_type = 'unclassified' and subj = 'Lien Waiver Signed' then
      v_type     := 'lien_waiver_signed';
      v_actor    := bt_trim((regexp_match(body, '\nFrom\s+([^\n]+)'))[1]);
      v_title    := bt_trim((regexp_match(body, 'Bill # - Title:\s*([^\n]+)'))[1]);
      v_job_name := bt_trim((regexp_match(body, '\nJob:\s*([^\n]+)'))[1]);
      v_summary  := v_actor;
      v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object('vendor', v_actor));
    end if;

    -- ── bills_overdue (digest, one or more bills) ──────────────────────────
    --   Subject: You have 4 overdue bills
    --   Each block: Job <job> / Bill # <n> / Title <t> / Bill amount $x /
    --               Due date Sep 10, 2026 (12 days overdue)
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^You have (\d+) (overdue|upcoming) bills?$');
      if m is not null then
        v_type   := case when m[2] = 'overdue' then 'bills_overdue' else 'bills_upcoming' end;
        v_title  := subj;
        arr := '[]'::jsonb; jobs_seen := '{}';
        for blk in
          select regexp_matches(
            body,
            'Job\s+([^\n]+)\n+Bill #\s*([^\n]+)\n+Title\s+([^\n]+)\n+Bill amount\s*([^\n]+)\n+Due date\s+([^\n]+)',
            'g')
        loop
          arr := arr || jsonb_strip_nulls(jsonb_build_object(
            'job_name',    bt_trim(blk[1]),
            'job_number',  bt_extract_job_number(blk[1]),
            'bill_no',     bt_trim(blk[2]),
            'title',       bt_trim(blk[3]),
            'amount',      bt_parse_money(blk[4]),
            'due_date',    bt_parse_loose_date(blk[5]),
            'days_overdue',(regexp_match(blk[5], '\((\d+) days? overdue\)'))[1]::int
          ));
          if bt_extract_job_number(blk[1]) is not null then
            jobs_seen := array_append(jobs_seen, bt_extract_job_number(blk[1]));
          end if;
        end loop;
        v_fields := v_fields || jsonb_build_object('bills', arr, 'count', coalesce(m[1]::int, jsonb_array_length(arr)));
        select sum((x->>'amount')::numeric) into v_amount from jsonb_array_elements(arr) x where x ? 'amount';
        -- Only key the event to a job when every bill in the digest is that job.
        select distinct j into v_job_number from unnest(jobs_seen) j;
        if (select count(distinct j) from unnest(jobs_seen) j) <> 1 then v_job_number := null; end if;
        v_summary := jsonb_array_length(arr) || ' bill(s)' ||
                     case when v_amount is not null then ' totaling $' || to_char(v_amount, 'FM999,999,990.00') else '' end;
      end if;
    end if;

    -- ── invoice_overdue ────────────────────────────────────────────────────
    --   Subject: A $149,490.13 invoice for R26009 - … is 1 day overdue
    --   Body: ID # R26009-0001 / Status Pending/Sent / Deadline Sep 15, 2026 at … /
    --         Invoice amount $… / Balance due $…
    if v_type = 'unclassified' then
      m := regexp_match(subj, '^An? \$([0-9,]+\.?[0-9]*) invoice for (.+) is (\d+) days? overdue$');
      if m is not null then
        v_type     := 'invoice_overdue';
        v_amount   := bt_parse_money(m[1]);
        v_job_name := bt_trim(m[2]);
        v_title    := 'Invoice overdue';
        v_fields   := v_fields || jsonb_strip_nulls(jsonb_build_object(
          'days_overdue', m[3]::int,
          'invoice_id',   bt_trim((regexp_match(body, 'ID #\s*([^\n]+)'))[1]),
          'status',       bt_trim((regexp_match(body, '\nStatus\s+([^\n]+)'))[1]),
          'deadline',     bt_parse_loose_date((regexp_match(body, '\nDeadline\s+([^\n]+)'))[1]),
          'balance_due',  bt_parse_money((regexp_match(body, 'Balance due\s*([^\n]+)'))[1])
        ));
        v_summary := '$' || to_char(v_amount, 'FM999,999,990.00') || ' overdue ' || m[3] || ' day(s)';
      end if;
    end if;

    -- ── insurance_expiring (vendor-level, no job) ──────────────────────────
    --   Subject: Insurance Expiration Notice for 2 subcontractors
    --   Body lines: RENKEN PAINTING* - Exp: 10-22-2026
    if v_type = 'unclassified' and subj like 'Insurance Expiration Notice%' then
      v_type  := 'insurance_expiring';
      v_title := subj;
      arr := '[]'::jsonb;
      for blk in
        select regexp_matches(body, '([^\n]+?)\s+-\s+Exp:\s*(\d{1,2}-\d{1,2}-\d{4})', 'g')
      loop
        arr := arr || jsonb_build_object(
          'vendor',  bt_trim(blk[1]),
          'expires', bt_parse_loose_date(blk[2]));
      end loop;
      v_fields  := v_fields || jsonb_build_object('vendors', arr, 'count', jsonb_array_length(arr));
      v_summary := (select string_agg(x->>'vendor', ', ' order by x->>'expires') from jsonb_array_elements(arr) x);
    end if;

  end if;

  -- Job number: from the job name first, then the subject, then a Job: line.
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

-- ── Finance roll-up per job, for the digest ────────────────────────────────
create or replace view v_bt_job_finance with (security_invoker = true) as
select job_number,
       count(*) filter (where event_type = 'bill_paid')          as bills_paid,
       coalesce(sum(amount) filter (where event_type = 'bill_paid'), 0)      as bills_paid_total,
       count(*) filter (where event_type = 'bill_ready')         as bills_ready,
       count(*) filter (where event_type = 'lien_waiver_signed') as lien_waivers,
       max(occurred_at) filter (where event_type = 'lien_waiver_signed')     as last_lien_waiver,
       count(*) filter (where event_type = 'invoice_overdue')    as invoices_overdue,
       coalesce(max(amount) filter (where event_type = 'invoice_overdue'), 0) as largest_overdue_invoice
from bt_events
where job_number is not null
group by job_number;

grant select on v_bt_job_finance to anon, authenticated;
