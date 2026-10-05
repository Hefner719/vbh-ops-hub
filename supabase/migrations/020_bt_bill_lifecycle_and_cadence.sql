-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend bridge · migration 020
--  build: bt-bridge-v5
--
--  Two things the meeting kept getting wrong.
--
--  1 · "N bills ready for payment" was counting history, not work.
--      bill_ready and bill_paid are separate notifications with no shared id,
--      so the card simply counted every "ready" email it had ever seen. Of the
--      180 bills marked ready, 117 had already been paid - two thirds of that
--      number was noise, and a real backlog was indistinguishable from a busy
--      month.
--
--      The two events CAN be matched. bill_ready carries the vendor's invoice
--      number in fields.bill_no; bill_paid carries fields.bill_title shaped
--      '<JOB>-<bill_no> - <description>'. Matching on job + bill number gives
--      a lifecycle per bill, and "outstanding" finally means outstanding.
--
--      Matching is by containment rather than a strict prefix: a few bill
--      numbers are not numeric ('Sttlmnt Stmnt') and a strict pattern dropped
--      three real payments, which would have reported paid bills as owing.
--
--  2 · Client update cadence was tracked in someone's head.
--      Every job on the agenda gets asked about; nothing recorded how long it
--      had actually been. v_bt_client_update_cadence counts the Fridays that
--      have passed since each job's last published update, which is the way
--      the question is actually asked here.
--
--  COVERAGE LIMIT, and it matters: bill_ready / bill_paid notifications only
--  start 2026-09-14. A bill marked ready before that date is not in this data
--  at all, so it is absent rather than wrongly shown as owing. The view
--  reports its own window so nobody reads it as all-time.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── every bill we have seen, and whether it was ever paid ──────────────────
drop view if exists v_bt_bills_outstanding;
drop view if exists v_bt_bill_status;

create view v_bt_bill_status with (security_invoker = true) as
with ready as (
  select distinct on (ev.job_number, ev.fields->>'bill_no')
         ev.job_number,
         ev.fields->>'bill_no' as bill_no,
         ev.fields->>'vendor'  as vendor,
         ev.title,
         ev.fields->>'address' as address,
         ev.occurred_at        as ready_at
  from bt_events ev
  where ev.event_type = 'bill_ready'
    and nullif(btrim(coalesce(ev.fields->>'bill_no','')), '') is not null
  order by ev.job_number, ev.fields->>'bill_no', ev.occurred_at      -- first time it was called ready
),
paid as (
  select ev.job_number,
         ev.fields->>'bill_title' as bill_title,
         ev.amount,
         ev.occurred_at as paid_at
  from bt_events ev
  where ev.event_type = 'bill_paid'
    and nullif(btrim(coalesce(ev.fields->>'bill_title','')), '') is not null
),
matched as (
  select r.*,
         p.paid_at,
         p.amount as amount_paid
  from ready r
  left join lateral (
    select p.paid_at, p.amount
    from paid p
    where p.job_number = r.job_number
      and position(r.bill_no in p.bill_title) > 0
    order by p.paid_at desc
    limit 1
  ) p on true
)
select job_number,
       bill_no,
       vendor,
       title,
       address,
       ready_at,
       paid_at,
       amount_paid,
       case when paid_at is null then 'outstanding' else 'paid' end as status,
       case when paid_at is null
            then (current_date - ready_at::date)
            else null end as days_outstanding
from matched;

grant select on v_bt_bill_status to anon, authenticated;

-- ── only what is actually owed ─────────────────────────────────────────────
create view v_bt_bills_outstanding with (security_invoker = true) as
select job_number, bill_no, vendor, title, address, ready_at, days_outstanding
from v_bt_bill_status
where status = 'outstanding'
order by ready_at;

grant select on v_bt_bills_outstanding to anon, authenticated;

-- ── how many Fridays since each job's last client update ───────────────────
-- Jordan's rule: more than two Fridays without one is a problem. Counting
-- Fridays rather than days is deliberate - client updates are a Friday habit,
-- so "14 days" and "two Fridays" are not the same question.
create or replace function bt_fridays_since(d date)
returns int language sql stable as $$
  select case when d is null then null else
    (select count(*)::int
       from generate_series(d + 1, current_date, interval '1 day') g
      where extract(dow from g) = 5)
  end
$$;

drop view if exists v_bt_client_update_cadence;
create view v_bt_client_update_cadence with (security_invoker = true) as
select p.job_number,
       p.address                           as job_name,
       lower(p.stage)                      as stage,
       u.last_update::date                 as last_client_update,
       bt_fridays_since(u.last_update::date) as fridays_since,
       u.update_count,
       case
         when u.last_update is null                             then 'never'
         when bt_fridays_since(u.last_update::date) > 2         then 'overdue'
         when bt_fridays_since(u.last_update::date) = 2         then 'due'
         else 'ok'
       end as cadence
from projects p
left join lateral (
  select max(ev.occurred_at) as last_update, count(*) as update_count
  from bt_events ev
  where ev.event_type = 'client_update'
    and ev.job_number = p.job_number
) u on true
where lower(coalesce(p.stage,'')) in ('solds','escrow','model')
order by (u.last_update is not null), u.last_update;

grant select on v_bt_client_update_cadence to anon, authenticated;

-- ── sanity ─────────────────────────────────────────────────────────────────
select count(*) filter (where status = 'outstanding') as outstanding,
       count(*) filter (where status = 'paid')        as paid,
       min(ready_at)::date                            as data_starts
from v_bt_bill_status;

select cadence, count(*) from v_bt_client_update_cadence group by 1 order by 1;
