-- =====================================================================
-- NIVA Field Execution — 0001_schema.sql
-- Core relational schema. Idempotent and safe to re-run.
--
-- Design notes
-- ------------
-- The prototype (niva-merch-app.html) keeps one denormalised `tasks` array in
-- localStorage. Each task inlines the store, the campaign's poster brief, the
-- check-in fix, the after-images, the AR placement record and the audit trail.
-- That is fine for a single-user demo and wrong for a multi-tenant database,
-- because RLS can only be written against rows, not against array elements
-- inside a JSON blob. So the blob is decomposed into eight tables, each of
-- which gets its own policy surface:
--
--   profiles       identity + role, 1:1 with auth.users
--   stores         the store master (a merchandiser must NOT see all of it)
--   campaigns      brand cycle + the poster/standoff brief a task inherits
--   tasks          one store x one campaign execution, carries the status FSM
--   task_images    before / after / poster artwork pointers into Storage
--   placements     the AR verification measurement record (immutable evidence)
--   audit_events   append-only evidentiary log
--   notifications  per-user / per-role inbox
--
-- Vocabulary is deliberately identical to the prototype's ("Rework Required",
-- "In Progress", tier "Asd", capture mode "single-frame", ...) so the client
-- migration is a rename of property paths, not a redesign.
-- =====================================================================

set local check_function_bodies = off;

create schema if not exists extensions;

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------
-- Real enums, not text+check, for the four vocabularies the app branches on.
-- The enum labels are byte-identical to the JS constants so a PostgREST row
-- can be handed to the existing render code unchanged.

do $$ begin
  create type public.niva_role as enum ('Merchandiser', 'Manager', 'Admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.task_status as enum (
    'Draft', 'Assigned', 'In Progress', 'Submitted',
    'Rework Required', 'Approved', 'Closed'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.image_kind as enum ('before', 'after', 'poster');
exception when duplicate_object then null; end $$;

-- Verification tiers, strongest first. Mirrors TIER_META in the prototype.
--   Asd/As = AR single-frame (photo read back out of the measured XR frame)
--   Ad/A   = AR measured, photo taken after session handover
--   Bq/B   = reference-scaled from a known-width object
--   Be     = reference-scaled with an *estimated* focal length
--   C      = unverified (typed in by hand, no camera / no sensors)
do $$ begin
  create type public.verification_tier as enum ('Asd', 'As', 'Ad', 'A', 'Bq', 'B', 'Be', 'C');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.capture_mode as enum ('single-frame', 'handover', 'camera', 'manual');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.notification_kind as enum (
    'Task Assigned', 'Task Submitted', 'Approval Required', 'Task Approved',
    'Rework Required', 'Task Closed', 'Placement Verified', 'Unverified Capture'
  );
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------
-- 1:1 with auth.users. `role` is the authorization principal for every policy
-- in 0002_rls.sql, which is why 0004_functions.sql installs a trigger that
-- refuses to let a non-admin change it (see niva_profiles_guard).
--
-- ON DELETE CASCADE from auth.users: deleting the login deletes the profile.
-- Field history does not cascade — tasks reference profiles with RESTRICT, so
-- a user who has touched a task cannot be deleted until that task is
-- reassigned. That is intentional: the audit trail must keep naming a real row.
create table if not exists public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  full_name   text        not null,
  role        public.niva_role not null default 'Merchandiser',
  title       text,
  region      text        check (region is null or region in ('North', 'South', 'East', 'West')),
  is_active   boolean     not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on table  public.profiles is 'Application identity + role, 1:1 with auth.users.';
comment on column public.profiles.role is
  'Authorization principal. Only an Admin may change this (enforced by trigger niva_profiles_guard).';

-- ---------------------------------------------------------------------
-- stores
-- ---------------------------------------------------------------------
-- The prototype inlines store fields on each task; a real store master is a
-- separate asset that merchandisers must not be able to enumerate.
--
-- store_code: `citext` is avoided so nothing depends on an extension living in
-- a particular schema (which matters because every SECURITY DEFINER function
-- here pins `search_path = ''`). A case-insensitive UNIQUE INDEX gives the
-- same guarantee with no extension dependency, and a CHECK keeps the stored
-- form canonical (upper case), matching the prototype's "MH-MUM-0140".
create table if not exists public.stores (
  id           uuid primary key default gen_random_uuid(),
  store_code   text not null,
  name         text not null,
  city         text not null,
  state        text not null,
  state_code   text not null,
  region       text not null check (region in ('North', 'South', 'East', 'West')),
  lat          double precision not null check (lat between -90 and 90),
  lng          double precision not null check (lng between -180 and 180),
  geofence_m   integer not null default 150 check (geofence_m between 10 and 5000),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint stores_code_canonical check (store_code = upper(store_code))
);

create unique index if not exists stores_store_code_lower_key
  on public.stores (lower(store_code));

comment on column public.stores.geofence_m is
  'Check-in radius in metres. The prototype hard-codes GEOFENCE_M = 150; here it is per-store so a mall anchor store can be widened without a code change.';

-- ---------------------------------------------------------------------
-- campaigns
-- ---------------------------------------------------------------------
-- owner_id is the *authorization* anchor for managers: "a manager reads and
-- manages tasks within campaigns they own". Tasks additionally carry their own
-- manager_id (the prototype assigns managers per task), so a manager sees the
-- union of {campaigns I own} and {tasks I am named on}.
create table if not exists public.campaigns (
  id              uuid primary key default gen_random_uuid(),
  code            text not null,
  name            text not null,
  brand           text not null,
  starts_on       date not null,
  ends_on         date not null,
  note            text,
  owner_id        uuid references public.profiles (id) on delete restrict,
  -- poster brief a new task inherits (CAMPAIGNS[].poster in the prototype)
  poster_w_ft     numeric(6,2) not null default 4.0  check (poster_w_ft  > 0),
  poster_h_ft     numeric(6,2) not null default 3.0  check (poster_h_ft  > 0),
  standoff_ft     numeric(6,2) not null default 6.0  check (standoff_ft  > 0),
  standoff_tol_ft numeric(6,2) not null default 0.5  check (standoff_tol_ft > 0),
  angle_tol_deg   numeric(5,2) not null default 5.0  check (angle_tol_deg  > 0),
  is_active       boolean not null default true,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint campaigns_dates_ordered check (ends_on >= starts_on)
);

create unique index if not exists campaigns_code_lower_key
  on public.campaigns (lower(code));

-- ---------------------------------------------------------------------
-- tasks
-- ---------------------------------------------------------------------
-- One execution of one campaign at one store. Carries the status FSM enforced
-- by niva_tasks_transition_guard in 0004_functions.sql.
--
-- ON DELETE choices, deliberately:
--   campaign_id  RESTRICT — deleting a campaign must not silently delete field
--                history. Deactivate it (is_active) instead.
--   store_id     RESTRICT — same reasoning.
--   assignee_id  RESTRICT — the audit trail names this person.
--   manager_id   RESTRICT — ditto.
--   created_by   SET NULL — provenance is nice to have, not evidentiary; the
--                audit_events row is the evidentiary copy.
create table if not exists public.tasks (
  id                uuid primary key default gen_random_uuid(),
  task_code         text not null,
  campaign_id       uuid not null references public.campaigns (id) on delete restrict,
  store_id          uuid not null references public.stores (id)    on delete restrict,
  assignee_id       uuid          references public.profiles (id)  on delete restrict,
  manager_id        uuid not null references public.profiles (id)  on delete restrict,
  created_by        uuid          references public.profiles (id)  on delete set null,

  exec_date         date,
  display_type      text not null check (display_type in (
                      'In-shop Branding', 'Gondola End Cap', 'Window Display',
                      'Floor Stack', 'Shelf Strip', 'Standee')),

  -- The POSTER's true size in feet, and the capture brief the guided-capture
  -- flow gates against. Copied from the campaign at creation time so that
  -- editing a campaign later cannot retroactively invalidate past evidence.
  width_ft          numeric(6,2) not null check (width_ft  > 0),
  height_ft         numeric(6,2) not null check (height_ft > 0),
  standoff_ft       numeric(6,2) not null default 6.0  check (standoff_ft > 0),
  standoff_tol_ft   numeric(6,2) not null default 0.5  check (standoff_tol_ft > 0),
  angle_tol_deg     numeric(5,2) not null default 5.0  check (angle_tol_deg > 0),

  instructions      text,
  status            public.task_status not null default 'Draft',
  merch_remarks     text not null default '',
  review_remarks    text not null default '',

  -- geofenced check-in (prototype: task.checkIn)
  checkin_at         timestamptz,
  checkin_lat        double precision,
  checkin_lng        double precision,
  checkin_distance_m integer,
  checkin_accuracy_m integer,
  checkin_pass       boolean,
  checkin_device     text,
  checkin_source     text check (checkin_source is null or checkin_source in ('device', 'simulated')),

  submitted_at      timestamptz,
  approved_at       timestamptz,
  closed_at         timestamptz,
  completion_ref    text,

  -- Best (highest-tier, passing-beats-failing) placement across this task's
  -- after-images. Denormalised so the dashboard rollup never has to rank
  -- placements at query time. Maintained by trigger, not by the client.
  best_placement_id uuid,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint tasks_store_campaign_unique unique (campaign_id, store_id)
);

create unique index if not exists tasks_task_code_lower_key
  on public.tasks (lower(task_code));

create index if not exists tasks_assignee_idx   on public.tasks (assignee_id);
create index if not exists tasks_manager_idx    on public.tasks (manager_id);
create index if not exists tasks_campaign_idx   on public.tasks (campaign_id);
create index if not exists tasks_store_idx      on public.tasks (store_id);
create index if not exists tasks_status_idx     on public.tasks (status);

comment on column public.tasks.best_placement_id is
  'Denormalised pointer to the strongest placement for this task. Written only by trigger niva_placements_after_insert; the client cannot set it (blocked by niva_tasks_column_guard for merchandisers and never exposed as a writable field in the app).';

-- ---------------------------------------------------------------------
-- placements  (IMMUTABLE EVIDENCE)
-- ---------------------------------------------------------------------
-- The AR verification record produced by the guided-capture flow. This is a
-- measurement, not an opinion: once written it must never change, because the
-- whole point of the tier system is that a reviewer can trust the number.
-- 0002_rls.sql grants INSERT only, and 0004_functions.sql installs a trigger
-- that raises on UPDATE or DELETE even for the table owner.
--
-- Every field maps 1:1 onto the prototype's placement record.
create table if not exists public.placements (
  id                uuid primary key default gen_random_uuid(),
  task_id           uuid not null references public.tasks (id) on delete restrict,

  tier              public.verification_tier not null,
  tier_label        text not null,
  capture_mode      public.capture_mode not null,

  -- distance gate
  distance_ft       numeric(8,3),
  target_ft         numeric(8,3) not null,
  tol_ft            numeric(8,3) not null,
  distance_ok       boolean not null default false,
  distance_source   text,

  -- angle gates (degrees, GL frame; wall normal points toward the camera)
  pitch_deg         numeric(7,2),
  roll_deg          numeric(7,2),
  yaw_deg           numeric(7,2),
  angle_tol_deg     numeric(5,2) not null,
  pitch_ok          boolean not null default false,
  roll_ok           boolean not null default false,
  yaw_ok            boolean not null default false,
  yaw_verified      boolean not null default false,
  angle_source      text,
  attitude_assumed  boolean not null default false,

  -- intrinsics
  focal_px          integer,
  focal_source      text,

  -- subject
  poster_w_ft       numeric(6,2),
  poster_h_ft       numeric(6,2),

  -- overall gate + geofence at shutter time
  passed            boolean not null default false,
  geofence_pass     boolean,
  geofence_m        integer,
  arm_ms            integer,

  -- raw-camera readback diagnostics (single-frame tier only)
  camera_w              integer,
  camera_h              integer,
  camera_readback_ms    numeric(9,2),
  camera_path           text,
  camera_aspect_agrees  boolean,
  camera_diagnostics    jsonb not null default '{}'::jsonb,

  note              text not null default '',

  -- captured_at is DEVICE time (forgeable, useful); recorded_at is SERVER time
  -- stamped by trigger (not forgeable). Keeping both is what lets a reviewer
  -- notice a device clock that disagrees with reality.
  captured_at       timestamptz,
  recorded_at       timestamptz not null default now(),
  created_by        uuid references public.profiles (id) on delete restrict,

  -- Derived verification outcomes, computed once and stored, so the dashboard
  -- rollup is a plain aggregate and the definition cannot drift between the
  -- client, the rollup and any report. Mirrors placementVerified() /
  -- placementSingleFrame() / placementUnverified() in the prototype.
  is_verified   boolean generated always as (
                  passed and tier in ('Asd', 'As', 'Ad', 'A')
                ) stored,
  is_same_frame boolean generated always as (
                  passed and tier in ('Asd', 'As', 'Ad', 'A')
                  and capture_mode = 'single-frame'
                ) stored,
  is_unverified boolean generated always as (tier = 'C') stored,

  -- Cheap ranking key used to pick a task's "best" placement, matching
  -- bestPlacement(): tier rank * 2 + (passed ? 1 : 0).
  tier_rank     smallint generated always as (
                  (case tier
                     when 'Asd' then 4 when 'As' then 4
                     when 'Ad'  then 3 when 'A'  then 3
                     when 'Bq'  then 2 when 'B'  then 2
                     when 'Be'  then 1 else 0 end) * 2
                  + (case when passed then 1 else 0 end)
                ) stored
);

create index if not exists placements_task_idx on public.placements (task_id);
create index if not exists placements_rank_idx on public.placements (task_id, tier_rank desc);

comment on table public.placements is
  'IMMUTABLE. AR/reference measurement evidence. Insert-only: UPDATE and DELETE are revoked and additionally blocked by trigger niva_block_mutation.';

-- Late FK: tasks.best_placement_id -> placements.id (circular with
-- placements.task_id, so it is added after both tables exist).
do $$ begin
  alter table public.tasks
    add constraint tasks_best_placement_fk
    foreign key (best_placement_id) references public.placements (id) on delete restrict;
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------
-- task_images
-- ---------------------------------------------------------------------
-- Metadata + pointer into Supabase Storage. The bytes never live in Postgres.
-- storage_path follows the convention documented in 0003_storage.sql:
--   evidence/tasks/<task_id>/<kind>/<uuid>.jpg
-- clean_storage_path holds the un-stamped original for a guided capture
-- (prototype: afterImages[].cleanSrc), so a reviewer can compare the overlay
-- against the raw frame.
create table if not exists public.task_images (
  id                 uuid primary key default gen_random_uuid(),
  task_id            uuid not null references public.tasks (id) on delete cascade,
  kind               public.image_kind not null,
  bucket_id          text not null,
  storage_path       text not null,
  clean_storage_path text,
  placement_id       uuid references public.placements (id) on delete restrict,

  lat                double precision,
  lng                double precision,
  device             text,
  is_guided          boolean not null default false,

  captured_at        timestamptz,
  uploaded_by        uuid references public.profiles (id) on delete restrict,
  recorded_at        timestamptz not null default now(),

  -- Scoped to the task, NOT globally unique on the path: several tasks in the
  -- same campaign legitimately point at the SAME poster-artwork object. What
  -- must not happen is one task referencing the same object twice.
  constraint task_images_task_path_unique unique (task_id, bucket_id, storage_path)
);

-- Older builds of this file used a globally-unique (bucket_id, storage_path)
-- constraint, which made a shared campaign key visual unrepresentable.
do $$ begin
  alter table public.task_images drop constraint if exists task_images_path_unique;
exception when undefined_table then null; end $$;

create index if not exists task_images_task_idx on public.task_images (task_id, kind);

-- ---------------------------------------------------------------------
-- audit_events  (APPEND-ONLY EVIDENTIARY LOG)
-- ---------------------------------------------------------------------
-- actor_name / actor_role are denormalised copies, not joins. That is on
-- purpose: the log must record who the actor WAS at the time, so that renaming
-- a user or demoting them later cannot rewrite history. actor_id keeps the
-- referential link for the cases where you do want the live row.
--
-- occurred_at is client/device time; recorded_at is server time stamped by
-- trigger. See 0004_functions.sql for the append-only enforcement.
create table if not exists public.audit_events (
  id           bigint generated always as identity primary key,
  task_id      uuid references public.tasks (id) on delete restrict,
  actor_id     uuid references public.profiles (id) on delete restrict,
  actor_name   text not null,
  actor_role   public.niva_role,
  action       text not null,
  detail       text not null default '',
  gps_lat      double precision,
  gps_lng      double precision,
  occurred_at  timestamptz not null default now(),
  recorded_at  timestamptz not null default now()
);

create index if not exists audit_events_task_idx on public.audit_events (task_id, occurred_at desc);
create index if not exists audit_events_actor_idx on public.audit_events (actor_id, occurred_at desc);

comment on table public.audit_events is
  'APPEND-ONLY. UPDATE/DELETE/TRUNCATE are revoked from every role including service_role, no UPDATE or DELETE policy exists, and trigger niva_block_mutation raises even for the table owner.';

-- ---------------------------------------------------------------------
-- notifications
-- ---------------------------------------------------------------------
-- Either targeted at one user (target_user_id) or broadcast to a role
-- (target_role), exactly like mkNotif() in the prototype.
create table if not exists public.notifications (
  id             uuid primary key default gen_random_uuid(),
  kind           public.notification_kind not null,
  target_role    public.niva_role,
  target_user_id uuid references public.profiles (id) on delete cascade,
  task_id        uuid references public.tasks (id) on delete cascade,
  body           text not null,
  created_by     uuid references public.profiles (id) on delete set null,
  occurred_at    timestamptz not null default now(),
  read_at        timestamptz,
  recorded_at    timestamptz not null default now(),
  constraint notifications_has_target check (target_user_id is not null or target_role is not null)
);

create index if not exists notifications_user_idx on public.notifications (target_user_id, occurred_at desc);
create index if not exists notifications_role_idx on public.notifications (target_role, occurred_at desc);

-- ---------------------------------------------------------------------
-- Row Level Security: switch it on here so that a partially-applied migration
-- set can never leave a table readable by everyone. Policies arrive in 0002.
-- Until 0002 runs, RLS with no policies means "deny everything", which is the
-- correct failure mode.
--
-- FORCE is applied as well as ENABLE: ENABLE alone exempts the table OWNER,
-- and in Supabase the owner is `postgres`, which is the role the SQL Editor
-- and migrations run as. FORCE means a mistake in a dashboard query cannot
-- quietly read across tenants either.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'stores', 'campaigns', 'tasks',
    'placements', 'task_images', 'audit_events', 'notifications'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force  row level security', t);
  end loop;
end $$;
