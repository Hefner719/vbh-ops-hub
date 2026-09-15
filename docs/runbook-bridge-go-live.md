# Runbook: Buildertrend bridge go-live

State as of 2026-09-15: everything is deployed and waiting on the three Graph values from IT.
Working through this list takes about ten minutes.

## Already done
- Migrations 001, 003, 004 applied. Parser verified on 64 real emails.
- Edge Function `bt-ingest` deployed (`tools/sb-fn-deploy.ps1 -Name bt-ingest`), `verify_jwt` on.
- Function secrets set: `GRAPH_MAILBOX`, `GRAPH_FOLDER`, `BT_CRON_SECRET`.
- `bt_settings` holds `cron_secret` (matches `BT_CRON_SECRET`) and `anon_key`.
- Wiring test: call without `x-cron-secret` → 403; with it → clean error naming the missing Graph secret.

## When IT sends the values
1. Jordan opens `%USERPROFILE%\.vbh\bt-graph.env` (Notepad) and fills in, removing the leading `#`:
   ```
   GRAPH_TENANT_ID=<tenant id>
   GRAPH_CLIENT_ID=<application (client) id>
   GRAPH_CLIENT_SECRET=<secret value>
   ```
   Put the secret's expiry date on the calendar (IT was asked for 24 months). This file is outside the repo and is never pasted into chat.
2. Push them: `tools\sb-fn-secrets.ps1`
3. Backfill 90 days and read the result:
   ```
   curl -X POST "https://bppirsahciuxrqzitfxa.supabase.co/functions/v1/bt-ingest?mode=backfill&days=90" ^
     -H "Authorization: Bearer <anon key>" -H "x-cron-secret: <BT_CRON_SECRET>" -d "{}"
   ```
   Expect `ok:true` with `fetched`, `inserted`, `parsed_ok`, `unclassified`. If it says the folder was not found, check `GRAPH_FOLDER` matches the Outlook folder's display name exactly. A 403 from Graph with `ErrorAccessDenied` means the application access policy hasn't propagated yet (up to 30 min) or admin consent wasn't granted.
4. Check parsing on live mail:
   ```
   tools\sb-sql.ps1 -Query "select event_type, count(*) from bt_events e join bt_emails m on m.id=e.email_id where m.source='graph' group by 1 order by 2 desc"
   tools\sb-sql.ps1 -Query "select subject from v_bt_unclassified where source='graph' limit 30"
   ```
   New notification types (schedule, selections, daily logs) will show in the second query. Save a few as samples and add parser templates; `bt_reparse_all()` re-runs the parser over stored mail.
5. Retire the CSV rows once the backfill covers the same period — the Graph copies have real timestamps and Message-IDs:
   ```
   tools\sb-sql.ps1 -Query "delete from bt_emails where source='csv_import'"
   ```
   (`bt_events` rows cascade.) Do this only after step 4 shows the same client updates present with `source='graph'`.
6. Schedule polling: `tools\sb-sql.ps1 -File supabase\migrations\002_bt_cron.sql` (every 15 minutes). Then:
   ```
   tools\sb-sql.ps1 -Query "select jobid, jobname, schedule, active from cron.job"
   tools\sb-sql.ps1 -Query "select * from bt_ingest_runs order by id desc limit 5"
   ```
7. Open `/digest` — the "Bridge health" section should show the last run with counts instead of "Live ingest not running yet".

## If IT offers a shared mailbox instead
Set `GRAPH_MAILBOX` to that address in the env file, push secrets, and re-point Buildertrend's notification recipient. Nothing else changes.

## Rotating the client secret
IT issues a new secret → update `GRAPH_CLIENT_SECRET` in the env file → `tools\sb-fn-secrets.ps1 -Only GRAPH_CLIENT_SECRET`. No redeploy needed.
