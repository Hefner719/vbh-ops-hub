-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend bridge · migration 021 · daily log cadence
--  build: bt-bridge-v6
--
--  Jordan's rule: no job should go more than three work days without a daily
--  log. This is the measuring half - the counting, the threshold and the view
--  the meeting page reads. The parser branch that turns a daily-log email into
--  a `daily_log` event is deliberately NOT here: no such email has ever
--  arrived (16 months of mail, checked across every sender), so there is no
--  real sample to write it against. House rule, and a sound one - every
--  template in this parser was written from a genuine message.
--
--  WHY THE VIEW GUARDS ITSELF
--  Until daily_log events exist, every job would read "no log ever" and the
--  banner would open with eleven false alarms on day one. The view returns no
--  rows at all while the event type is unseen, so it is silent until there is
--  something true to say, then starts working on its own.
--
--  ASSUMPTIONS, both one-line changes:
--    · Work days are Monday-Friday. Include Saturdays by changing the `between
--      1 and 5` below to `between 1 and 6`.
--    · Scope is every active job (solds / escrow / model). Unlike client
--      updates - where a model has no client to write to - a model under
--      construction should still have daily logs, so nothing is excluded.
-- ═══════════════════════════════════════════════════════════════════════════

-- Work days strictly after `d`, up to and including today.
-- dow: 0 = Sunday, 6 = Saturday.
create or replace function bt_workdays_since(d date)
returns int language sql stable as $$
  select case when d is null then null else
    (select count(*)::int
       from generate_series(d + 1, current_date, interval '1 day') g
      where extract(dow from g) between 1 and 5)
  end
$$;

drop view if exists v_bt_daily_log_cadence;
create view v_bt_daily_log_cadence with (security_invoker = true) as
with seen as (
  -- Silent until daily logs actually start arriving.
  select exists (select 1 from bt_events where event_type = 'daily_log') as any_logs
)
select p.job_number,
       p.address                               as job_name,
       lower(p.stage)                          as stage,
       l.last_log::date                        as last_daily_log,
       bt_workdays_since(l.last_log::date)     as workdays_since,
       l.log_count,
       l.last_author,
       case
         when l.last_log is null                            then 'never'
         when bt_workdays_since(l.last_log::date) > 3       then 'overdue'
         when bt_workdays_since(l.last_log::date) = 3       then 'due'
         else 'ok'
       end as cadence
from projects p
cross join seen s
left join lateral (
  select max(ev.occurred_at) as last_log,
         count(*)            as log_count,
         (array_agg(ev.actor order by ev.occurred_at desc))[1] as last_author
  from bt_events ev
  where ev.event_type = 'daily_log'
    and ev.job_number = p.job_number
) l on true
where s.any_logs
  and lower(coalesce(p.stage,'')) in ('solds','escrow','model')
order by (l.last_log is not null), l.last_log;

grant select on v_bt_daily_log_cadence to anon, authenticated;

-- ── sanity ─────────────────────────────────────────────────────────────────
-- Zero rows until the first daily_log event lands. That is correct, not a fault.
select (select count(*) from bt_events where event_type = 'daily_log') as daily_log_events,
       (select count(*) from v_bt_daily_log_cadence)                   as rows_in_view;

-- Counting check against known dates, so the threshold is not taken on trust.
select bt_workdays_since(current_date)     as today_should_be_0,
       bt_workdays_since(current_date - 1) as yesterday,
       bt_workdays_since(current_date - 7) as a_week_ago_should_be_5;
