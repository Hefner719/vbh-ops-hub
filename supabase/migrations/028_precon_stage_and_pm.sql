-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 028 · Pre-Construction stage, PM column
--
--  Schema only. Safe to run ahead of the page deploy: the live projects page
--  ignores columns it does not know, and it cannot write 'precon' (its stage
--  dropdown has no such option, so a save of a precon row fails the check
--  below rather than writing something wrong). Moving jobs INTO precon is
--  migration 029, run together with the page deploy.
--
--  1. stage 'precon' - every job that has not broken ground: sold, spec, or
--     still in design. A job moves to solds / model when it starts.
--     The Buildertrend cadence views (client updates, daily logs) and
--     v_standard_update_compliance read only solds / escrow / model, so a job
--     in pre-construction is never flagged for a missing client update or
--     daily log. That is deliberate.
--
--  2. precon_type - what a pre-construction job will become: 'sold' (under
--     contract), 'spec' (building to sell) or 'design' (no contract yet, being
--     helped through design). Only meaningful while stage = 'precon'; kept on
--     the row after it starts as a record.
--
--  3. project_manager - the PM running the job. Free text holding a name from
--     VBH.PROJECT_MANAGERS (vbh-config.js), the roster that drives the
--     dropdowns. Not constrained to that list here: a PM who leaves comes off
--     the dropdown, but the jobs they ran keep their name until reassigned.
--
--  4. v_active_projects is rebuilt with the two new columns on the end.
--     Postgres fixes a view's column list when it is created, so without this
--     the Projects page (which reads the view) would never see them.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

alter table projects drop constraint if exists projects_stage_check;
alter table projects add constraint projects_stage_check
  check (stage = any (array['precon','solds','escrow','model','dev_maint','closed']));

alter table projects add column if not exists precon_type     text;
alter table projects add column if not exists project_manager text;

alter table projects drop constraint if exists projects_precon_type_check;
alter table projects add constraint projects_precon_type_check
  check (precon_type is null or precon_type in ('sold','spec','design'));

comment on column projects.precon_type is
  'While stage = precon: sold | spec | design (no contract yet). Migration 028.';
comment on column projects.project_manager is
  'PM running the job; a name from VBH.PROJECT_MANAGERS in vbh-config.js. Migration 028.';

-- CREATE OR REPLACE can only append columns, which is exactly what this does.
create or replace view v_active_projects as
 select p.id,
    p.job_number,
    p.stage,
    p.address,
    p.buyer_realtor,
    p.phase_note,
    p.pct_complete,
    p.status,
    p.style,
    p.sqft,
    p.price,
    p.ll_fin,
    p.start_date,
    p.complete_date,
    p.closing_date,
    p.permit_num,
    p.power_meter,
    p.insurance,
    p.appraisal,
    p.bt_flag,
    p.win_flag,
    p.truss_flag,
    p.crew,
    p.notes,
    p.updated_by,
    p.created_at,
    p.updated_at,
    p.from_lead,
    p.converted_at,
    p.schedule_days,
    p.schedule_updated_at,
    p.schedule_updated_by,
    u.meeting_date as last_meeting_date,
    u.note         as last_note,
    u.blocker      as last_blocker,
    u.next_step    as last_next_step,
    p.precon_type,
    p.project_manager
   from projects p
     left join lateral ( select pu.meeting_date,
            pu.note,
            pu.blocker,
            pu.next_step
           from project_updates pu
          where pu.project_id = p.id
          order by pu.meeting_date desc
         limit 1) u on true;

commit;
