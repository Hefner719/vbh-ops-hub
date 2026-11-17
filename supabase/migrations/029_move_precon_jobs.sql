-- ═══════════════════════════════════════════════════════════════════════════
--  VBH Ops Hub · migration 029 · move not-yet-started jobs to Pre-Construction
--
--  RUN TOGETHER WITH THE projects-v4 / meeting-v13 DEPLOY, not before: the
--  older Projects page does not know stage 'precon' and would hide these rows.
--  Requires migration 028.
--
--  Pre-Construction holds every job that has not broken ground (decided
--  2026-11-16). precon_type keeps what each will become:
--
--    R26004   100 N. Harmon Drive (Bradley)        sold    starts 3/1/2027
--    ER26027  6008 N. Mapleton Ave (Van Buskirk)    sold
--    R26025   213 Ivy Lane, Crooks                  spec    plan being revised
--    R26001   Hitchcock Park Townhome #1            -       2027 start; sold/spec to confirm
--    ER26031  6004 N. Mapleton Ave (Houwman)        design  new; spring 2027 start
--
--  6004 N. Mapleton is lot 21, Mapleton Highlands. Chris Houwman is not under
--  contract - Van Buskirk is helping him through design - so it is tagged
--  'design', not 'sold'. ER26031 is a placeholder estimate number until
--  Buildertrend assigns a job number. There is no lead record for him.
--
--  Each statement checks the current state, so re-running is a no-op.
-- ═══════════════════════════════════════════════════════════════════════════

begin;

update projects set stage = 'precon', precon_type = 'sold', updated_at = now(),
                    updated_by = 'Pre-Construction stage (migration 029)'
 where job_number in ('R26004', 'ER26027') and stage = 'solds';

update projects set stage = 'precon', precon_type = 'spec', updated_at = now(),
                    updated_by = 'Pre-Construction stage (migration 029)'
 where job_number = 'R26025' and stage = 'model';

update projects set stage = 'precon', updated_at = now(),
                    updated_by = 'Pre-Construction stage (migration 029)'
 where job_number = 'R26001' and stage = 'solds';

insert into projects (job_number, stage, precon_type, address, buyer_realtor, phase_note,
                      pct_complete, status, style, notes, updated_by)
select 'ER26031', 'precon', 'design', '6004 N. Mapleton Ave', 'Houwman, Chris',
       'Design', 0, 'On Track', 'Custom Home',
       'Mapleton Highlands, Lot 21. Spring 2027 start. Not under contract - helping through the design process. ER26031 is a placeholder; replace with the Buildertrend job number when assigned.',
       'Pre-Construction stage (migration 029)'
 where not exists (select 1 from projects where job_number = 'ER26031');

commit;

select job_number, stage, precon_type, address, buyer_realtor, phase_note
  from projects where stage = 'precon' order by job_number;
