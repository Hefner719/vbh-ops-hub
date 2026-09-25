-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend bridge · migration 010 · health signal
--  build: bt-bridge-v3
--
--  The bridge has run without error since go-live, but it fails QUIETLY: if the
--  Graph client secret expires (2028-09-21), IT revokes consent, or the mailbox
--  folder is renamed, polling simply stops. Nobody would notice until a Tuesday
--  agenda turned up stale.
--
--  This turns "is the bridge alive" into something a page can ask. No mail
--  sender is needed — the answer is rendered where people already look. Once
--  SMTP exists, the same view can drive an alert.
--
--  Thresholds: polling is every 15 minutes, so an hour of silence is several
--  missed cycles, not a blip. Two hours means it is properly down.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace view v_bt_health with (security_invoker = true) as
with last_run as (
  select * from bt_ingest_runs order by id desc limit 1
),
recent as (
  select count(*)                                  as runs_24h,
         coalesce(sum(inserted), 0)                as new_mail_24h,
         coalesce(sum(errors), 0)                  as errors_24h,
         count(*) filter (where error is not null) as failed_runs_24h
  from bt_ingest_runs
  where started_at > now() - interval '24 hours'
),
mail as (
  select max(received_at) as newest_mail,
         count(*) filter (where ingested_at > now() - interval '24 hours') as ingested_24h
  from bt_emails
)
select
  l.id                                             as last_run_id,
  l.started_at                                     as last_run_at,
  round(extract(epoch from (now() - l.started_at)) / 60)::int as minutes_since_run,
  l.error                                          as last_error,
  r.runs_24h, r.new_mail_24h, r.errors_24h, r.failed_runs_24h,
  m.newest_mail, m.ingested_24h,
  case
    when l.id is null                                            then 'never_run'
    when now() - l.started_at > interval '2 hours'               then 'down'
    when now() - l.started_at > interval '1 hour'                then 'stale'
    when l.error is not null                                     then 'erroring'
    when r.failed_runs_24h > 3                                   then 'flaky'
    else 'ok'
  end                                              as status,
  case
    when l.id is null                              then 'The ingest job has never run.'
    when now() - l.started_at > interval '2 hours' then
      'No Buildertrend ingest for ' || round(extract(epoch from (now() - l.started_at)) / 3600)::int ||
      ' hours. Check the Graph credentials and the pg_cron job.'
    when now() - l.started_at > interval '1 hour'  then
      'Last ingest ' || round(extract(epoch from (now() - l.started_at)) / 60)::int ||
      ' minutes ago; polling should run every 15.'
    when l.error is not null                       then 'Last run reported: ' || l.error
    when r.failed_runs_24h > 3                     then
      r.failed_runs_24h || ' failed runs in the last 24 hours.'
    else 'Polling every 15 minutes. ' || r.runs_24h || ' runs and ' ||
         r.new_mail_24h || ' new messages in the last 24 hours.'
  end                                              as message
from recent r cross join mail m left join last_run l on true;

grant select on v_bt_health to anon, authenticated;

comment on view v_bt_health is
  'One row: whether Buildertrend ingest is healthy, and a sentence saying why. Read by the hub banner and the digest.';
