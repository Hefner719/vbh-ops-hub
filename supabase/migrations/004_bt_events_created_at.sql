-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend email bridge · migration 004
--  build: bt-bridge-v1
--
--  v_bt_events gains event_created_at (when the row was parsed). Emails
--  imported from an Outlook CSV have no received_at, so the digest uses
--  event_created_at to decide whether an undated item falls in its window.
--  CREATE OR REPLACE VIEW may only append columns, so it goes last.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace view v_bt_events with (security_invoker = true) as
select ev.id, ev.event_type, ev.job_number, ev.job_name, ev.occurred_at, ev.actor, ev.title,
       ev.amount, ev.period_start, ev.period_end, ev.summary, ev.link, ev.fields, ev.parser_version,
       e.id as email_id, e.subject, e.received_at, e.from_address, e.source, e.parse_status,
       p.id as project_id, p.address, p.buyer_realtor, p.stage as project_stage, p.status as project_status,
       ev.created_at as event_created_at
from bt_events ev
join bt_emails e on e.id = ev.email_id
left join projects p on upper(p.job_number) = ev.job_number;

grant select on v_bt_events to anon, authenticated;
