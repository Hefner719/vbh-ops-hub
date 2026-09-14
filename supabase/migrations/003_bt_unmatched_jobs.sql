-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend email bridge · migration 003
--  build: bt-bridge-v1
--
--  Buildertrend jobs that have notification activity but no row in the
--  Projects tracker. First run against real samples found three (R25029,
--  R26013, R26025). The meeting page and digest read this so a missing
--  tracker row is a visible to-do instead of silently dropped activity.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace view v_bt_unmatched_jobs with (security_invoker = true) as
select ev.job_number,
       max(ev.job_name)                          as job_name,
       count(*)                                  as events,
       min(ev.occurred_at)                       as first_seen,
       max(ev.occurred_at)                       as last_seen,
       array_agg(distinct ev.event_type order by ev.event_type) as event_types
from bt_events ev
left join projects p on upper(p.job_number) = ev.job_number
where ev.job_number is not null
  and p.id is null
group by ev.job_number
order by max(ev.occurred_at) desc nulls last;

grant select on v_bt_unmatched_jobs to anon, authenticated;
