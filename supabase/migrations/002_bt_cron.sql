-- ═══════════════════════════════════════════════════════════════════════════
--  VBH · Buildertrend email bridge · migration 002 (scheduled ingest)
--  build: bt-bridge-v1
--
--  Schedules the bt-ingest Edge Function every 15 minutes with pg_cron + pg_net.
--  Contains NO secrets: the function URL is derived, the cron secret is read
--  from bt_settings at call time.
--
--  Before running:
--    1. Deploy supabase/functions/bt-ingest with its secrets set.
--    2. insert into bt_settings values ('cron_secret', '<same value as BT_CRON_SECRET>');
--    3. insert into bt_settings values ('anon_key', '<project anon key>');   -- Edge Functions require a JWT bearer
--  Re-runnable: the cron job is replaced, not duplicated.
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Fire the ingest function once. Returns the pg_net request id.
create or replace function bt_trigger_ingest(p_mode text default 'poll')
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_secret text;
  v_anon   text;
  v_url    text;
  v_ref    text;
  v_req    bigint;
begin
  select value into v_secret from bt_settings where key = 'cron_secret';
  select value into v_anon   from bt_settings where key = 'anon_key';
  if v_secret is null or v_anon is null then
    raise exception 'bt_trigger_ingest: bt_settings needs cron_secret and anon_key';
  end if;

  -- The project ref is public (it's in every hub page); only the keys are not.
  v_ref := 'bppirsahciuxrqzitfxa';
  v_url := 'https://' || v_ref || '.supabase.co/functions/v1/bt-ingest?mode=' || coalesce(p_mode, 'poll');

  select net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_anon,
      'x-cron-secret', v_secret),
    body    := '{}'::jsonb,
    timeout_milliseconds := 120000
  ) into v_req;
  return v_req;
end $$;

revoke all on function bt_trigger_ingest(text) from public, anon, authenticated;

-- Every 15 minutes. cron.schedule with a name upserts, so re-running is safe.
select cron.schedule('bt-ingest-poll', '*/15 * * * *', $$ select bt_trigger_ingest('poll'); $$);

-- Check it:
--   select jobid, jobname, schedule, active from cron.job;
--   select * from cron.job_run_details order by start_time desc limit 10;
--   select * from bt_ingest_runs order by id desc limit 10;
