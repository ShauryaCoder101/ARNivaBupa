-- =====================================================================
-- NIVA Field Execution — 0006_profile_height.sql
--
-- Adds ONE nullable column: profiles.height_cm — the user's own stature, as
-- they state it, in whole centimetres.
--
-- WHY IT EXISTS
-- -------------
-- The floor-line distance method solves d = h / tan θ, where h is how high off
-- the floor the phone is held. Until now h came from one of two places:
--
--   * a per-device tape calibration (localStorage `niva.floorcal.v1`): accurate
--     (~2.3 % 1σ) but it costs a tape measure, a wall and five minutes, and it
--     was being skipped;
--   * a stated default of 1.45 m at ±8.5 %, which on its own blows the 5 %
--     field budget and is why the capture screen was permanently badged ROUGH.
--
-- A stature the user types once sits between the two, at roughly ±4 % — inside
-- budget, at the cost of one question. The device calibration still wins where
-- it exists.
--
-- HOW h IS DERIVED FROM IT — A RATIO, NOT A SUBTRACTION
-- ----------------------------------------------------
--     h = height_cm/100 × HOLD_RATIO          (HOLD_RATIO = 0.82 in the client)
--
-- NOT h = stature − 0.37 m. Human body proportions are stable as FRACTIONS of
-- stature, not as fixed distances: a 1.90 m adult's shoulder is not the same
-- number of centimetres below the top of their head as a 1.50 m adult's. A
-- constant offset therefore under-reads tall people and over-reads short ones,
-- systematically, and a wider error bar does not fix a bias. Across the 150 cm
-- – 190 cm span the two models disagree by about 7 cm of h, which is 5 % of the
-- distance.
--
-- 0.82 is neck / shoulder (acromial) height as a fraction of stature, and it is
-- valid ONLY because the capture screen instructs the merchandiser to hold the
-- phone there — the ratio describes a posture, and the instruction is what makes
-- the posture real. The client comments both that constant and the eye-level
-- alternative (0.936) next to each other; switching posture is one line.
--
-- The uncertainty is derived, never quoted:
--
--     σ_h = √( (HOLD_RATIO·σ_stature)² + (stature·σ_ratio)² + σ_compliance² )
--
-- and σ_h/h is what the existing error propagation consumes, so a capture made
-- from a stature-derived height carries a visibly larger error bar than one made
-- from a tape calibration. The database stores none of this: it stores the one
-- number a human said, and the client derives the rest.
--
-- The number is on `profiles` and not in localStorage because it is a fact
-- about the PERSON, not about the handset: it must follow them to a
-- replacement phone, and a shared device must not hand one merchandiser
-- another's height.
--
-- WHAT THIS MIGRATION DELIBERATELY DOES NOT DO
-- --------------------------------------------
--   * It does not touch `is_verified`, `tier_rank` or `is_same_frame` on
--     `placements`, or any generated column anywhere. Floor-line capture is
--     tier `Be`, which is unverified in the schema as shipped (0001) AND in
--     the pending re-tier (0005). A better h makes the error bar smaller; it
--     does not promote anything.
--   * It has no dependency on 0005 and does not require it to have been
--     applied. This file is additive to 0001–0004 alone.
--   * It adds NO new policy. See the RLS note below.
--
-- Idempotent and safe to re-run.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The column
-- ---------------------------------------------------------------------
-- `integer`, not numeric: nobody knows their own height to a millimetre, and
-- storing false precision invites it to be read as measured. Nullable, because
-- "not stated" is a real and common answer that the client has to handle
-- honestly (it falls back to the 1.45 m default and says so out loud).
alter table public.profiles
  add column if not exists height_cm integer;

-- Range check as a separate, named, idempotent step so re-running the file
-- does not raise on an already-present constraint. 120–220 cm spans every
-- adult who could plausibly be doing field work, and rejects the two mistakes
-- a numeric input actually produces: a value typed in inches (68) and one
-- typed in millimetres (1720). The client mirrors these exact bounds in
-- STATURE_MIN_CM / STATURE_MAX_CM and refuses out-of-band values before they
-- ever reach the outbox, so this constraint is the backstop and not the UI.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'profiles_height_cm_range'
       and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_height_cm_range
      check (height_cm is null or height_cm between 120 and 220);
  end if;
end $$;

comment on column public.profiles.height_cm is
  'Self-stated stature in whole centimetres, or NULL if never stated. Used ONLY '
  'to derive the phone-holding height h = (height_cm/100) * HOLD_RATIO (0.82, the '
  'neck/shoulder fraction of stature the capture screen instructs) for floor-line '
  'distance (d = h / tan theta), and its uncertainty. A ratio, not a subtraction: '
  'body proportions are stable as fractions of stature, so a constant offset would '
  'bias tall and short users in opposite directions. Never used for authorization.';

-- ---------------------------------------------------------------------
-- 2. Authorization — NO NEW POLICY IS NEEDED, and here is the proof
-- ---------------------------------------------------------------------
-- The question is whether a user can write their own height_cm without that
-- also handing them a way to rewrite their own role.
--
--   GRANT      0002_rls.sql §B already does
--                `grant select, insert, update on public.profiles to authenticated;`
--              which is column-unrestricted. A new column inherits it.
--
--   POLICY     0002_rls.sql §C already defines
--
--                create policy profiles_update_self on public.profiles
--                  for update to authenticated
--                  using      (id = (select auth.uid()))
--                  with check (id = (select auth.uid()));
--
--              Row-level security decides which ROWS may be written, not which
--              COLUMNS. So this policy already permits an UPDATE of height_cm
--              on the caller's own row, and permits it on no other row.
--
--   TRIGGER    Column-level authority is where it has always been for this
--              table: trigger `niva_profiles_guard` (0004_functions.sql §4)
--              raises NIVA_ROLE_ESCALATION on
--                `new.role is distinct from old.role and not niva_is_admin()`
--              and NIVA_READONLY_FIELD on any change to `id`. It inspects those
--              two columns and only those two, so adding height_cm neither
--              widens nor narrows what it refuses.
--
-- Net effect, unchanged by this migration: a merchandiser may PATCH their own
-- row; if that PATCH also carries {"role":"Admin"} the whole statement is
-- rejected by the trigger and the height is not written either. Escalation is
-- refused at exactly the same place, in exactly the same way, as before.
--
-- A column-scoped policy was considered and rejected: Postgres RLS has no
-- column granularity, so "a policy that permits exactly this column" would have
-- to be a second guard trigger duplicating the one in 0004 — two places to keep
-- in sync, for no additional guarantee. (Column-level GRANTs exist, but they
-- cannot express "this column on your own row"; the row scope still has to come
-- from the policy that is already there, and narrowing the table GRANT would
-- break every other self-update the app makes.)
--
-- The client never sends `role` on this path either: Outbox op `profile.patch`
-- carries `{height_cm}` and nothing else, and Session.mergeProfile() filters
-- `role` and `id` out of anything it merges back. That is defence in depth, not
-- the control — the trigger is the control.
--
-- The assertion below is a belt-and-braces check that the two objects this
-- reasoning depends on are actually present in the database this file is being
-- applied to. It raises rather than silently leaving the column unwritable.
do $$
begin
  if not exists (
    select 1 from pg_policies
     where schemaname = 'public' and tablename = 'profiles'
       and policyname = 'profiles_update_self'
  ) then
    raise exception
      'NIVA_MIGRATION: policy profiles_update_self is missing — apply 0002_rls.sql first, '
      'or users will not be able to save their own height_cm.';
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.profiles'::regclass
       and tgname  = 'trg_profiles_guard'
       and not tgisinternal
  ) then
    raise exception
      'NIVA_MIGRATION: trigger trg_profiles_guard is missing — apply 0004_functions.sql first. '
      'Without it profiles_update_self would allow a self-service role change.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. No backfill
-- ---------------------------------------------------------------------
-- Every existing row keeps height_cm = NULL, which the client reads as "never
-- stated" and answers with the badged-ROUGH 1.45 m default. Inventing a
-- population average here would put a number in the database that nobody said,
-- and the error bar on every capture derived from it would be a lie.

-- =====================================================================
-- Verification (run after applying):
--
--   select count(*) from information_schema.columns
--    where table_schema='public' and table_name='profiles' and column_name='height_cm';
--   -- expect 1
--
-- As a signed-in merchandiser (anon key + their own JWT):
--
--   patch /rest/v1/profiles?id=eq.<self>   {"height_cm": 173}   -> 200, row updated
--   patch /rest/v1/profiles?id=eq.<other>  {"height_cm": 173}   -> 200, ZERO rows
--   patch /rest/v1/profiles?id=eq.<self>   {"height_cm": 173,
--                                           "role": "Admin"}    -> NIVA_ROLE_ESCALATION,
--                                                                  and no height written
--   patch /rest/v1/profiles?id=eq.<self>   {"height_cm": 68}    -> 23514, check violation
-- =====================================================================
