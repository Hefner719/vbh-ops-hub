-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 024 · put the missing Buildertrend builds in the tracker
--
--  The meeting page no longer assembles its own job list (meeting-v12) — jobs
--  are picked from the Projects tracker. That only works if the tracker holds
--  every real job, and it did not: 22 job numbers appeared in Buildertrend mail
--  with no project behind them.
--
--  Thirteen of those are actual homes and go in here. The other nine are not
--  projects and are deliberately left out:
--      R26100  VB Homes Overhead            (86 notifications)
--      R26105  Signs & Marketing Job
--      R26104  Marketing Co-Op Job
--      R25102  Yearly Warranty Job
--      R26102  Yearly Warranty Job
--      R25101  Overhead Buildertrend Training
--      M26100  2026 Development Maintenance Overhead
--      R26014  300 IVY Lane, CANCELED PROJECT
--      R26022  908 Bluffside — see the note below
--  They are cost buckets, not builds. Adding them would put them in the picker
--  and in every active-project count from now on.
--
--  R26022 IS NOT ADDED ON PURPOSE. The tracker already holds this house as
--  ER26022 (908 Bluffside Drive, Martin). Buildertrend calls it R26022, and
--  because bt_extract_job_number() matches on a word boundary before R/M, the
--  leading "E" means that card has never picked up any of its Buildertrend
--  activity. Adding R26022 would create a second record for one house, so this
--  needs a human decision: rename ER26022 → R26022 and the card starts showing
--  its 10 notifications, or keep ER and accept the gap. Left alone for now.
--
--  STAGE is inferred from Buildertrend activity, which is the only evidence
--  available: mail in the last 30 days → 'solds', otherwise 'closed'. Two are
--  near the line and worth a second look — The Woods on Phillips last saw mail
--  31 days ago and is coming in closed, Mapleton Cottages 26 days ago and is
--  coming in active. Correct either in the Projects tab; nothing here is
--  irreversible.
--
--  Address and client are split out of the Buildertrend job name, which is
--  shaped "<JOB> - <address>" or "<JOB> - <address> - <client>".
--  Idempotent: re-running adds nothing.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

with builds(job_number) as (values
  ('R25002'),('R25004'),('R25006'),('R25028'),('R25030'),('R26001'),('R26003'),
  ('R26004'),('R26006'),('R26015'),('R26019'),('R26027'),('R26030')
),
src as (
  select b.job_number,
         max(u.job_name)  as job_name,
         max(u.last_seen) as last_seen
  from builds b
  join v_bt_unmatched_jobs u on u.job_number = b.job_number
  group by 1
),
parsed as (
  select job_number,
         last_seen,
         -- everything after the first " - "
         btrim(substr(job_name, position(' - ' in job_name) + 3)) as rest
  from src
)
insert into projects (job_number, address, buyer_realtor, stage, updated_by, updated_at)
select p.job_number,
       nullif(btrim(split_part(p.rest, ' - ', 1)), '')                            as address,
       nullif(btrim(substr(p.rest, length(split_part(p.rest, ' - ', 1)) + 4)), '') as buyer_realtor,
       case when p.last_seen > now() - interval '30 days' then 'solds' else 'closed' end,
       'Added from Buildertrend (migration 024)',
       now()
from parsed p
where not exists (select 1 from projects x where x.job_number = p.job_number);

commit;

-- ── what went in ───────────────────────────────────────────────────────────
select job_number, address, buyer_realtor, stage
from projects
where updated_by = 'Added from Buildertrend (migration 024)'
order by stage, job_number;

-- ── and what is left unmatched, which should now be the nine non-builds ────
select job_number, left(job_name, 46) as job_name, events
from v_bt_unmatched_jobs order by events desc;
