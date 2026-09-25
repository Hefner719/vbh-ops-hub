-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 016 · measuring the one standard we can measure
--
--  The Standards page commits to ten things. Nine of them cannot be measured
--  from anything the hub holds today, and inventing numbers for them would be
--  worse than leaving them blank:
--
--    Site Logs (3x/week), Site Photos, 2-Week Look-Ahead   Buildertrend daily
--        log notifications are not arriving (roadmap issue 6). Once they do,
--        cadence per job per super becomes a straight count.
--    Weekly Site Visit                                     no data source at all.
--    Bids returned in 10 days, coded in 3                  nothing records when
--        a plan went out or when bids came back.
--    Claim acknowledgement in 3 days, inspection in 10     partly visible
--        through past-due to-dos, but the acknowledgement clock is not captured.
--
--  The tenth — Bi-Weekly Project Update, owned by the PM on each job — is
--  fully measurable: every published client update arrives as mail carrying the
--  job, the PM who published it, and the period it covers.
--
--  The standard says each project is updated on a two-week cycle, so a job is
--  compliant when its newest update is 14 days old or less. Fourteen is the
--  commitment, not a guess; a job at 15 days has missed its cycle by a day, and
--  is reported as such rather than being rounded into "about right".
-- ═══════════════════════════════════════════════════════════════════════════

-- Which jobs the standard applies to: the ones actually being built.
-- Development-maintenance work has no client to update, and closed homes are
-- out of the cycle.
create or replace view v_standard_update_compliance with (security_invoker = true) as
with active as (
  select id, upper(job_number) as job_number, address, buyer_realtor, stage, start_date
  from projects
  where stage in ('solds', 'escrow', 'model')
),
latest as (
  select distinct on (job_number)
         job_number, occurred_at, period_start, period_end, actor, summary, link
  from bt_events
  where event_type = 'client_update' and job_number is not null
  order by job_number, coalesce(occurred_at, period_end::timestamptz) desc
)
select a.job_number,
       a.address,
       a.buyer_realtor                                        as client,
       a.stage,
       l.actor                                                as pm,
       coalesce(l.occurred_at::date, l.period_end)            as last_update,
       l.period_start, l.period_end,
       case when l.job_number is null then null
            else current_date - coalesce(l.occurred_at::date, l.period_end) end as days_since,
       case
         when l.job_number is null then 'never'
         when current_date - coalesce(l.occurred_at::date, l.period_end) <= 14 then 'met'
         when current_date - coalesce(l.occurred_at::date, l.period_end) <= 21 then 'late'
         else 'missed'
       end                                                    as compliance,
       l.link
from active a
left join latest l on l.job_number = a.job_number;

comment on view v_standard_update_compliance is
  'Bi-Weekly Project Update standard, per active job. met = updated within the 14-day cycle; late = 15-21 days; missed = over 21; never = no update on record.';

-- Per PM. Jobs with no update on record have no PM to attribute, so they are
-- counted separately rather than being blamed on whoever published last.
create or replace view v_pm_update_scorecard with (security_invoker = true) as
select coalesce(pm, 'Unattributed')                       as pm,
       count(*)                                           as jobs,
       count(*) filter (where compliance = 'met')         as met,
       count(*) filter (where compliance = 'late')        as late,
       count(*) filter (where compliance = 'missed')      as missed,
       count(*) filter (where compliance = 'never')       as never_updated,
       round(100.0 * count(*) filter (where compliance = 'met')
             / nullif(count(*) filter (where compliance <> 'never'), 0), 0) as pct_on_cycle,
       max(days_since)                                    as worst_days
from v_standard_update_compliance
group by coalesce(pm, 'Unattributed');

-- One row, for a headline figure.
create or replace view v_standards_summary with (security_invoker = true) as
select count(*)                                      as active_jobs,
       count(*) filter (where compliance = 'met')    as on_cycle,
       count(*) filter (where compliance in ('late','missed')) as off_cycle,
       count(*) filter (where compliance = 'never')  as never_updated,
       round(100.0 * count(*) filter (where compliance = 'met')
             / nullif(count(*), 0), 0)               as pct_on_cycle,
       max(days_since)                               as worst_days
from v_standard_update_compliance;

grant select on v_standard_update_compliance, v_pm_update_scorecard, v_standards_summary
  to anon, authenticated;
