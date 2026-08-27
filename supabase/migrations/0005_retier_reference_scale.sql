-- =====================================================================
-- 0005_retier_reference_scale.sql
--
-- WHY THIS EXISTS
-- ---------------------------------------------------------------------
-- 0001_schema.sql encoded "placement verified" as "passed AND an AR tier":
--
--     is_verified boolean generated always as (
--       passed and tier in ('Asd', 'As', 'Ad', 'A')
--     ) stored
--
-- That definition was correct while reference scaling meant a merchandiser
-- eyeballing two drag handles onto a sheet of paper. It is no longer correct.
-- The client now finds the reference rectangle automatically, refines its four
-- corners to sub-pixel accuracy against the image gradient, and — crucially —
-- only accepts the reading when the device has a REAL focal length from a
-- one-time calibration rather than an assumed field of view. Measured against
-- synthetic scenes at known poses, that path recovers distance to well under
-- 1 %, which is inside the same tolerance the AR path is trusted at.
--
-- So a CALIBRATED reference-scale capture that passes every gate is now
-- verified evidence, equal in standing to AR for the placement KPI:
--
--     tier 'Bq'  reference-scaled, 4-corner quad (auto-detected or outlined)
--     tier 'B'   reference-scaled, 2-handle width only
--
-- and these deliberately remain UNVERIFIED, because neither is a measurement:
--
--     tier 'Be'  the focal length is an assumed 66° HFOV, worth roughly ±12 %
--     tier 'C'   distance and angles were typed in by hand
--
-- WHAT DOES *NOT* CHANGE
-- ---------------------------------------------------------------------
--   * is_same_frame stays AR-only. Same-frame provenance means the photograph
--     was read back out of the very XR frame that produced the measurement.
--     No camera-tier path can do that, and widening it would quietly turn a
--     provenance claim into a lie. (The client had exactly this bug for one
--     commit — placementSingleFrame() was derived from placementVerified() and
--     silently inherited the reference tiers the moment they became verified.
--     A self-test assertion now pins it.)
--   * tier_rank stays as it is. AR remains the STRONGEST tier and still wins
--     bestPlacement(); "verified" and "strongest" are separate axes.
--   * is_unverified stays 'C'-only.
--
-- The client mirrors this in TIER_META[*].verified / placementVerified().
--
-- SAFETY
-- ---------------------------------------------------------------------
-- A stored generated column's expression cannot be altered in place, so the
-- column is dropped and re-added. That is a full table rewrite of `placements`
-- and it takes an ACCESS EXCLUSIVE lock for the duration — run it in a
-- maintenance window on a large table.
--
-- Nothing depends on is_verified structurally: no index, no policy, no
-- constraint. The three rollup functions in 0004_functions.sql reference it by
-- NAME only (through niva_visible_tasks()), so they pick the new definition up
-- with no change and no redeploy. The placements table is insert-only and the
-- niva_block_mutation trigger guards UPDATE/DELETE, not DDL.
--
-- HISTORICAL ROWS ARE RE-CLASSIFIED BY DESIGN. Existing passing Bq/B captures
-- become verified when this runs. That is the intent — the tier was always
-- recorded, only its interpretation changes — but it does mean the
-- placement-verified KPI steps up the moment this is applied. Announce it.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Part 1 — the re-tiering. REQUIRED for the client and the database to
--          agree on what "verified" means.
-- ---------------------------------------------------------------------
alter table public.placements drop column if exists is_verified;

alter table public.placements
  add column is_verified boolean generated always as (
    passed and tier in ('Asd', 'As', 'Ad', 'A', 'Bq', 'B')
  ) stored;

comment on column public.placements.is_verified is
  'Passed every gate AND the distance came from a real measurement: an AR tier, or a CALIBRATED reference scale (Bq/B). Tier Be (assumed focal length) and tier C (typed by hand) are never verified. Mirrors placementVerified() and TIER_META[*].verified in the client.';

-- Restated verbatim so the invariant is visible in this file rather than only
-- in 0001. Neither expression changes; re-asserting them is documentation.
comment on column public.placements.is_same_frame is
  'AR ONLY, deliberately. The photograph was read back from the same XR frame that produced the measurement (raw camera access). Reference-scale captures can be verified but can never be same-frame.';
comment on column public.placements.tier_rank is
  'Ordering key for bestPlacement(): tier rank * 2 + (passed ? 1 : 0). AR still outranks reference scale. Separate axis from is_verified.';

-- ---------------------------------------------------------------------
-- Part 2 — reference-scale provenance columns.
--          OPTIONAL and NOT YET WRITTEN BY THE CLIENT.
--
-- The client records all of this today, but folds it into placements.note as
-- readable text rather than sending columns that might not exist: a PostgREST
-- insert naming an unknown column fails with 400 PGRST204, and the outbox
-- treats that as permanent, so a client that got ahead of its database would
-- lose captures instead of degrading. Applying part 2 is therefore safe and
-- forward-compatible in either order; the client starts populating these only
-- once placementRow()/mapPlacement() are extended to name them.
--
-- Table-level GRANTs cover columns added later, so 0002_rls.sql needs no
-- change: `grant select, insert on public.placements to authenticated` already
-- applies. The columns are nullable with no defaults beyond error_terms, so
-- existing rows and existing inserts are unaffected.
-- ---------------------------------------------------------------------
alter table public.placements
  add column if not exists ref_source        text,
  add column if not exists ref_label         text,
  add column if not exists ref_w_mm          numeric(9,2),
  add column if not exists ref_h_mm          numeric(9,2),
  add column if not exists ref_auto_detected boolean,
  add column if not exists ref_confidence    numeric(5,3),
  add column if not exists ref_corner_rms_px numeric(7,3),
  add column if not exists ref_edge_support  numeric(5,3),
  add column if not exists radial_offset     numeric(5,3),
  add column if not exists error_pct         numeric(6,3),
  add column if not exists error_terms       jsonb not null default '{}'::jsonb,
  add column if not exists detect_ms         integer,
  add column if not exists detect_work       text,
  add column if not exists detect_degraded   boolean;

comment on column public.placements.ref_source is
  'Which known-size reference the distance was scaled from: ''poster'' (the installed poster, size from the task brief), ''a4q'' (a printed A4 sheet), a fixture preset, or ''custom''.';
comment on column public.placements.ref_auto_detected is
  'true when the four corners came from the automatic detector rather than dragged handles. Either way a human confirmed the outline before it counted.';
comment on column public.placements.ref_confidence is
  'Detector confidence 0..1 at the moment of capture: how well the outline fits a rectangle of the declared aspect ratio under the known intrinsics, weighted with area and edge support.';
comment on column public.placements.error_pct is
  'Estimated 1-sigma relative error on distance_ft, DERIVED per capture from the quadrature sum in error_terms — not a constant. This is the number to judge a reading by; the field tolerance is 5 %.';
comment on column public.placements.error_terms is
  'The error budget behind error_pct, each a percentage: {focal, refDim, corner, barrel}. focal = focal-length uncertainty (a device calibration knows its own tape-measure and handle error; an assumed FOV does not). refDim = the reference''s own dimensional tolerance. corner = corner localisation from the line-fit residual. barrel = uncorrected radial lens distortion, growing as r-squared from the optical centre.';
comment on column public.placements.radial_offset is
  'How far the reference sat from the optical centre, as a fraction of the half-diagonal. Above ~0.55 the barrel term starts to dominate and the capture UI nudges the user to re-centre.';

commit;

-- =====================================================================
-- Verification (run after applying):
--
--   select tier, passed, is_verified, is_same_frame, tier_rank, count(*)
--     from public.placements group by 1,2,3,4,5 order by tier_rank desc;
--
-- Expected: Bq/B rows with passed = true now show is_verified = true and
-- is_same_frame = false; Be and C rows show is_verified = false; every
-- tier_rank is unchanged from before the migration.
--
--   select * from public.niva_kpis(null);
--
-- Expected: placement_verified rises by the number of passing Bq/B
-- submissions; same_frame and unverified are unchanged.
-- =====================================================================
