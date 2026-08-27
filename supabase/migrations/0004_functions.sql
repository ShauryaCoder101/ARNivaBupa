-- =====================================================================
-- NIVA Field Execution — 0004_functions.sql
-- Triggers, state-machine enforcement, dashboard rollups.
-- Idempotent and safe to re-run.
--
-- Everything here exists because RLS alone cannot express it. A policy is a
-- boolean over a single row image; it cannot compare OLD to NEW, so "you may
-- not change your own role", "Submitted may only become Approved or Rework
-- Required" and "an audit row may never be updated" all have to be triggers.
-- Triggers also fire for the table owner and for service_role, which policies
-- do not, so they are the last line that still holds if a service key leaks.
-- =====================================================================

set local check_function_bodies = off;

-- =====================================================================
-- 1. Housekeeping
-- =====================================================================

create or replace function public.niva_touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

do $$
declare t text;
begin
  foreach t in array array['profiles', 'stores', 'campaigns', 'tasks'] loop
    execute format('drop trigger if exists %I on public.%I', 'trg_' || t || '_touch', t);
    execute format(
      'create trigger %I before update on public.%I
         for each row execute function public.niva_touch_updated_at()',
      'trg_' || t || '_touch', t);
  end loop;
end $$;

-- =====================================================================
-- 2. IMMUTABILITY — audit_events and placements
-- =====================================================================
-- 0002 revokes UPDATE/DELETE/TRUNCATE from anon, authenticated and
-- service_role, and defines no UPDATE or DELETE policy. That covers everyone
-- who arrives through PostgREST. It does NOT cover the table owner, which is
-- the role the Supabase SQL Editor runs as — i.e. the person most likely to
-- "just fix one row". This trigger closes that: it fires for every role
-- including the owner, and there is no session setting that turns it off.
--
-- Residual gap, stated plainly: a superuser, or the owner, can still
-- `alter table ... disable trigger` or drop it. Postgres has no
-- owner-proof immutability. What this buys is that tampering must be a
-- deliberate, separately-auditable DDL act, not an accidental UPDATE.

create or replace function public.niva_block_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception
    'NIVA_IMMUTABLE: % rows are write-once. % is not permitted on this table by any role.',
    tg_table_name, tg_op
    using errcode = 'restrict_violation',
          hint = 'Correct the record by appending a new row that supersedes it. History is never rewritten.';
  return null;
end;
$$;

drop trigger if exists trg_audit_events_immutable on public.audit_events;
create trigger trg_audit_events_immutable
  before update or delete on public.audit_events
  for each row execute function public.niva_block_mutation();

drop trigger if exists trg_placements_immutable on public.placements;
create trigger trg_placements_immutable
  before update or delete on public.placements
  for each row execute function public.niva_block_mutation();

-- =====================================================================
-- 3. ACTOR STAMPING — you cannot write history in someone else's name
-- =====================================================================
-- The RLS WITH CHECK clauses already require actor_id = auth.uid(). That is
-- NOT sufficient on its own, and the reason is an ordering subtlety worth
-- spelling out: a BEFORE INSERT trigger runs *before* the RLS WITH CHECK is
-- evaluated, and the check sees the post-trigger row. So a trigger that
-- silently overwrote actor_id would make the WITH CHECK vacuously true, and an
-- attempt to forge an audit entry in someone else's name would be quietly
-- *accepted* (rewritten to the real actor) rather than refused. The row would
-- be correctly attributed, but the forgery attempt would leave no trace.
--
-- (This was caught by test A23, which asserted the insert must be blocked and
-- found it succeeding.)
--
-- So these triggers RAISE on a mismatch rather than silently correcting, and
-- only fill in the identity when the client left it NULL. The denormalised
-- actor_name / actor_role are always read from the caller's own profile and
-- never trusted from the request body.
--
-- `auth.uid() is null` means there is no JWT at all — a migration, seed.sql,
-- or a service_role job. Those callers are trusted by construction and are
-- allowed to supply the actor, which is what lets seed.sql reproduce a
-- historical trail. There is no way to reach this branch through PostgREST as
-- a signed-in user.

create or replace function public.niva_stamp_audit_actor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  new.recorded_at := now();
  if v_uid is null then
    if new.actor_name is null then new.actor_name := 'system'; end if;
    return new;
  end if;

  if new.actor_id is not null and new.actor_id <> v_uid then
    raise exception
      'NIVA_ACTOR_MISMATCH: cannot record an audit event in another user''s name (claimed %, caller %)',
      new.actor_id, v_uid
      using errcode = 'insufficient_privilege',
            hint = 'Omit actor_id; the server fills it in from your session.';
  end if;

  new.actor_id := v_uid;
  select p.full_name, p.role
    into new.actor_name, new.actor_role
    from public.profiles p
   where p.id = v_uid;

  if new.actor_name is null then
    raise exception 'NIVA_NO_PROFILE: authenticated user % has no profile row', v_uid
      using errcode = 'insufficient_privilege';
  end if;

  if new.occurred_at is null then
    new.occurred_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_audit_events_stamp on public.audit_events;
create trigger trg_audit_events_stamp
  before insert on public.audit_events
  for each row execute function public.niva_stamp_audit_actor();

create or replace function public.niva_stamp_placement()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  new.recorded_at := now();
  if v_uid is not null then
    if new.created_by is not null and new.created_by <> v_uid then
      raise exception 'NIVA_ACTOR_MISMATCH: cannot attribute a placement to another user'
        using errcode = 'insufficient_privilege';
    end if;
    new.created_by := v_uid;
  end if;
  if new.captured_at is null then
    new.captured_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_placements_stamp on public.placements;
create trigger trg_placements_stamp
  before insert on public.placements
  for each row execute function public.niva_stamp_placement();

create or replace function public.niva_stamp_task_image()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  new.recorded_at := now();
  if v_uid is not null then
    if new.uploaded_by is not null and new.uploaded_by <> v_uid then
      raise exception 'NIVA_ACTOR_MISMATCH: cannot attribute an upload to another user'
        using errcode = 'insufficient_privilege';
    end if;
    new.uploaded_by := v_uid;
  end if;
  if new.captured_at is null then
    new.captured_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_task_images_stamp on public.task_images;
create trigger trg_task_images_stamp
  before insert on public.task_images
  for each row execute function public.niva_stamp_task_image();

create or replace function public.niva_stamp_notification()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  new.recorded_at := now();
  if v_uid is not null then
    if new.created_by is not null and new.created_by <> v_uid then
      raise exception 'NIVA_ACTOR_MISMATCH: cannot send a notification in another user''s name'
        using errcode = 'insufficient_privilege';
    end if;
    new.created_by := v_uid;
  end if;
  if new.occurred_at is null then
    new.occurred_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notifications_stamp on public.notifications;
create trigger trg_notifications_stamp
  before insert on public.notifications
  for each row execute function public.niva_stamp_notification();

-- A recipient may mark a notification read. Nothing else.
-- ATTACK PREVENTED: rewriting the body of a notification you received
-- ("Approval Required for ..." -> something else) and presenting it as what
-- your manager sent.
create or replace function public.niva_notifications_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    return new;                                  -- trusted server context
  end if;
  if new.id             is distinct from old.id
  or new.kind           is distinct from old.kind
  or new.target_role    is distinct from old.target_role
  or new.target_user_id is distinct from old.target_user_id
  or new.task_id        is distinct from old.task_id
  or new.body           is distinct from old.body
  or new.created_by     is distinct from old.created_by
  or new.occurred_at    is distinct from old.occurred_at
  or new.recorded_at    is distinct from old.recorded_at then
    raise exception 'NIVA_READONLY_FIELD: only read_at may be modified on a notification'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_notifications_guard on public.notifications;
create trigger trg_notifications_guard
  before update on public.notifications
  for each row execute function public.niva_notifications_guard();

-- =====================================================================
-- 4. PRIVILEGE ESCALATION GUARD — profiles.role
-- =====================================================================
-- ATTACK PREVENTED: `PATCH /rest/v1/profiles?id=eq.<me>` with
-- {"role":"Admin"}. The RLS policy cannot stop this, because from the policy's
-- point of view the row still belongs to the caller both before and after.
-- Only a trigger can see that OLD.role <> NEW.role.
--
-- On INSERT, a self-provisioned profile is forced to 'Merchandiser' — a user
-- signing up cannot choose to be an Admin. Roles are granted by an existing
-- Admin, or out-of-band by seed.sql / the Admin API.

create or replace function public.niva_profiles_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    return new;                                  -- trusted server context
  end if;

  if tg_op = 'INSERT' then
    if new.id <> v_uid and not public.niva_is_admin() then
      raise exception 'NIVA_FORBIDDEN: cannot create a profile for another user'
        using errcode = 'insufficient_privilege';
    end if;
    if not public.niva_is_admin() then
      new.role := 'Merchandiser';
    end if;
    return new;
  end if;

  -- UPDATE
  if new.id is distinct from old.id then
    raise exception 'NIVA_READONLY_FIELD: profiles.id is immutable'
      using errcode = 'insufficient_privilege';
  end if;

  if new.role is distinct from old.role and not public.niva_is_admin() then
    raise exception
      'NIVA_ROLE_ESCALATION: only an Admin may change a role (attempted % -> % on %)',
      old.role, new.role, old.id
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_profiles_guard on public.profiles;
create trigger trg_profiles_guard
  before insert or update on public.profiles
  for each row execute function public.niva_profiles_guard();

-- =====================================================================
-- 5. TASK STATE MACHINE
-- =====================================================================
-- The prototype has TRANSITIONS as a JS object and checks it client-side.
-- A buggy build, a stale cached bundle, or anyone with curl and a valid JWT
-- can ignore it. So the same map lives here, and here it is authoritative:
--
--   Draft            -> Assigned            (manager)
--   Assigned         -> In Progress         (assignee — the geofenced check-in)
--   In Progress      -> Submitted           (assignee)
--   Submitted        -> Approved            (manager, and NOT the assignee)
--   Submitted        -> Rework Required     (manager)
--   Rework Required  -> In Progress         (assignee)
--   Approved         -> Closed              (manager)
--
-- Anything else raises. In particular Draft -> Closed, In Progress ->
-- Approved, and Closed -> anything are all impossible regardless of what the
-- client sends. Terminal state is Closed.
--
-- The trigger enforces three separate things, and it is worth being explicit
-- about which is which:
--   (a) the shape of the graph  — is this edge in the map at all;
--   (b) who may traverse it     — role and relationship to the task;
--   (c) the lifecycle stamps    — submitted_at / approved_at / closed_at /
--       completion_ref are written by the server, never accepted from the
--       client, so they cannot be back-dated.

create or replace function public.niva_tasks_transition_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_role  public.niva_role := public.niva_current_role();
  v_is_mgr boolean;
  v_manages boolean;
begin
  if new.status = old.status then
    -- Not a transition. Still refuse to let the client move the lifecycle
    -- stamps around on a same-status edit.
    if v_uid is not null and (
         new.submitted_at   is distinct from old.submitted_at
      or new.approved_at    is distinct from old.approved_at
      or new.closed_at      is distinct from old.closed_at
      or new.completion_ref is distinct from old.completion_ref
    ) then
      raise exception 'NIVA_READONLY_FIELD: lifecycle timestamps are set by the server, not the client'
        using errcode = 'insufficient_privilege';
    end if;
    return new;
  end if;

  -- (a) Is the edge in the graph?
  if not (
       (old.status = 'Draft'           and new.status = 'Assigned')
    or (old.status = 'Assigned'        and new.status = 'In Progress')
    or (old.status = 'In Progress'     and new.status = 'Submitted')
    or (old.status = 'Submitted'       and new.status = 'Approved')
    or (old.status = 'Submitted'       and new.status = 'Rework Required')
    or (old.status = 'Rework Required' and new.status = 'In Progress')
    or (old.status = 'Approved'        and new.status = 'Closed')
  ) then
    raise exception 'NIVA_ILLEGAL_TRANSITION: % -> % is not a legal task transition (task %)',
      old.status, new.status, old.task_code
      using errcode = 'check_violation',
            hint = 'Legal edges: Draft->Assigned, Assigned->In Progress, In Progress->Submitted, Submitted->Approved, Submitted->Rework Required, Rework Required->In Progress, Approved->Closed.';
  end if;

  -- (b) May THIS caller traverse it?
  if v_uid is not null then
    v_is_mgr := v_role in ('Manager', 'Admin');
    v_manages := v_role = 'Admin'
                 or old.manager_id = v_uid
                 or (v_role = 'Manager' and public.niva_owns_campaign(old.campaign_id));

    if new.status in ('Assigned', 'Approved', 'Rework Required', 'Closed') then
      if not (v_is_mgr and v_manages) then
        raise exception 'NIVA_FORBIDDEN: % -> % may only be performed by the task''s manager or an admin',
          old.status, new.status
          using errcode = 'insufficient_privilege';
      end if;
    end if;

    -- SEPARATION OF DUTIES. The single most valuable fraud in a field-
    -- execution system is signing off your own work, so it is refused here
    -- even for an Admin and even for a Manager who happens to be the
    -- assignee. RLS blocks it too (tasks_update_field cannot produce an
    -- 'Approved' post-image); this is the independent second lock.
    if new.status = 'Approved' and old.assignee_id = v_uid then
      raise exception 'NIVA_SELF_APPROVAL: % may not approve a task assigned to themselves', v_uid
        using errcode = 'insufficient_privilege',
              hint = 'Approval must come from a different user than the assignee.';
    end if;

    if new.status = 'Submitted' and old.assignee_id is distinct from v_uid then
      raise exception 'NIVA_FORBIDDEN: only the assigned merchandiser may submit a task'
        using errcode = 'insufficient_privilege';
    end if;

    if new.status = 'In Progress'
       and old.assignee_id is distinct from v_uid
       and not (v_is_mgr and v_manages) then
      raise exception 'NIVA_FORBIDDEN: only the assignee (or the task manager) may start execution'
        using errcode = 'insufficient_privilege';
    end if;
  end if;

  -- Assignment must exist before work can start.
  if new.status <> 'Draft' and new.assignee_id is null then
    raise exception 'NIVA_INVALID: a task cannot leave Draft without an assignee'
      using errcode = 'check_violation';
  end if;

  -- Check-in must have happened, and passed, before execution starts.
  if new.status = 'In Progress' and old.status = 'Assigned'
     and coalesce(new.checkin_pass, false) is not true then
    raise exception 'NIVA_GEOFENCE: a passing geofenced check-in is required before starting execution'
      using errcode = 'check_violation',
            hint = 'Write checkin_at/checkin_lat/checkin_lng/checkin_distance_m/checkin_pass in the same PATCH that moves the task to In Progress.';
  end if;

  -- (c) Server-owned lifecycle stamps.
  if new.status = 'Submitted' then
    new.submitted_at := now();
  elsif new.status = 'Approved' then
    new.approved_at := now();
  elsif new.status = 'Closed' then
    new.closed_at := now();
    if new.completion_ref is null then
      new.completion_ref := 'NIVA-CR-' || new.task_code || '-' ||
        lpad((abs(hashtext(new.id::text)) % 9000 + 1000)::text, 4, '0');
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_tasks_transition on public.tasks;
create trigger trg_tasks_transition
  before update on public.tasks
  for each row execute function public.niva_tasks_transition_guard();

-- ---------------------------------------------------------------------
-- Column guard: what a merchandiser may touch at all
-- ---------------------------------------------------------------------
-- ATTACK PREVENTED: a merchandiser PATCHing their own task to widen the
-- geofence, move the exec date, shrink the poster so the standoff gate passes
-- more easily, or rewrite the review remarks the manager left. The RLS policy
-- can only say "this row is yours"; it cannot say "these six columns are".
--
-- best_placement_id is locked for EVERY client role — it is derived state,
-- maintained by trg_placements_best below, and letting a client set it would
-- let them point a task at some other task's passing measurement.

create or replace function public.niva_tasks_column_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
begin
  if v_uid is null then
    return new;                                  -- trusted server context
  end if;

  if new.best_placement_id is distinct from old.best_placement_id
     and coalesce(current_setting('niva.internal_write', true), '') <> 'on' then
    raise exception 'NIVA_READONLY_FIELD: tasks.best_placement_id is derived and cannot be set by a client'
      using errcode = 'insufficient_privilege';
  end if;

  if public.niva_current_role() <> 'Merchandiser' then
    return new;
  end if;

  if new.id              is distinct from old.id
  or new.task_code       is distinct from old.task_code
  or new.campaign_id     is distinct from old.campaign_id
  or new.store_id        is distinct from old.store_id
  or new.assignee_id     is distinct from old.assignee_id
  or new.manager_id      is distinct from old.manager_id
  or new.created_by      is distinct from old.created_by
  or new.exec_date       is distinct from old.exec_date
  or new.display_type    is distinct from old.display_type
  or new.width_ft        is distinct from old.width_ft
  or new.height_ft       is distinct from old.height_ft
  or new.standoff_ft     is distinct from old.standoff_ft
  or new.standoff_tol_ft is distinct from old.standoff_tol_ft
  or new.angle_tol_deg   is distinct from old.angle_tol_deg
  or new.instructions    is distinct from old.instructions
  or new.review_remarks  is distinct from old.review_remarks
  or new.completion_ref  is distinct from old.completion_ref
  or new.created_at      is distinct from old.created_at then
    raise exception
      'NIVA_READONLY_FIELD: a merchandiser may only update status, merch_remarks and the check-in fields on their own task'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_tasks_column_guard on public.tasks;
create trigger trg_tasks_column_guard
  before update on public.tasks
  for each row execute function public.niva_tasks_column_guard();

-- ---------------------------------------------------------------------
-- Derived: tasks.best_placement_id
-- ---------------------------------------------------------------------
-- Mirrors bestPlacement() in the prototype: highest tier wins, and within a
-- tier a passing capture beats a failing one (that is what placements.tier_rank
-- encodes). Runs as definer with a scoped session flag so it can write a
-- column that no client is allowed to write.

create or replace function public.niva_placements_best()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_best uuid;
begin
  select p.id into v_best
    from public.placements p
   where p.task_id = new.task_id
   order by p.tier_rank desc, p.recorded_at desc
   limit 1;

  perform set_config('niva.internal_write', 'on', true);
  update public.tasks set best_placement_id = v_best where id = new.task_id;
  perform set_config('niva.internal_write', 'off', true);

  return null;
end;
$$;

drop trigger if exists trg_placements_best on public.placements;
create trigger trg_placements_best
  after insert on public.placements
  for each row execute function public.niva_placements_best();

-- =====================================================================
-- 6. AUTH BOOTSTRAP — auth.users -> public.profiles
-- =====================================================================
-- Supabase creates the auth.users row; this mirrors it into profiles so the
-- very first PostgREST request from a new sign-in already has a role to look
-- up. Role and title are read from the user's metadata (set by the Admin API
-- or by seed.sql) and default to Merchandiser — the least-privileged role —
-- if the metadata says nothing or says something that is not a valid role.
--
-- Note the deliberate asymmetry: this trigger CAN set role from metadata,
-- because it runs with no JWT in an auth-service transaction. A signed-in user
-- editing their own raw_user_meta_data later cannot re-trigger it.

create or replace function public.niva_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.niva_role;
begin
  begin
    v_role := (new.raw_user_meta_data ->> 'role')::public.niva_role;
  exception when others then
    v_role := 'Merchandiser';
  end;

  insert into public.profiles (id, full_name, role, title, region)
  values (
    new.id,
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(new.email, '@', 1)),
    coalesce(v_role, 'Merchandiser'),
    nullif(new.raw_user_meta_data ->> 'title', ''),
    nullif(new.raw_user_meta_data ->> 'region', '')
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

do $$
begin
  if to_regclass('auth.users') is not null then
    execute 'drop trigger if exists trg_niva_on_auth_user_created on auth.users';
    execute 'create trigger trg_niva_on_auth_user_created
               after insert on auth.users
               for each row execute function public.niva_handle_new_user()';
  else
    raise notice 'auth.users not present — skipping the profile bootstrap trigger (non-Supabase database)';
  end if;
end $$;

-- =====================================================================
-- 7. DASHBOARD ROLLUPS
-- =====================================================================
-- The national dashboard needs region/state/city aggregates plus nine KPI
-- counts. Pulling every task row to the browser to compute them would (a) be
-- slow, and (b) be pointless for a merchandiser, whose RLS view is a handful
-- of rows anyway. These functions return the aggregate directly.
--
-- WHY SECURITY DEFINER, AND HOW IT IS KEPT HONEST
-- ----------------------------------------------
-- A SECURITY DEFINER aggregate over an RLS-protected table is exactly the
-- shape of bug that leaks a national total to a merchandiser. Three things
-- prevent that here:
--
--   1. niva_visible_tasks() restates the canonical visibility predicate
--      EXPLICITLY in its WHERE clause. It does not rely on RLS at all, so
--      there is no question of "did the policy apply inside the definer".
--   2. auth.uid() and niva_current_role() still resolve the *caller's*
--      identity inside a definer function (they read the request GUC, not the
--      session role), so the predicate is evaluated against the real caller.
--   3. EXECUTE on niva_visible_tasks() is revoked from authenticated. The row
--      source is reachable only through the three aggregate functions below,
--      which never return a task id, a store name, or anything else
--      row-identifying beyond the grouping key.
--
-- The RLS test suite asserts that the count returned here equals the count a
-- plain `select count(*) from tasks` returns under RLS for the same user
-- (test R10). If the policy and this predicate ever drift, that test fails.

create or replace function public.niva_visible_tasks()
returns table (
  task_id      uuid,
  campaign_id  uuid,
  status       public.task_status,
  region       text,
  state        text,
  city         text,
  is_verified   boolean,
  is_same_frame boolean,
  is_unverified boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    t.id,
    t.campaign_id,
    t.status,
    s.region,
    s.state,
    s.city,
    coalesce(p.is_verified, false),
    coalesce(p.is_same_frame, false),
    (p.id is null or coalesce(p.is_unverified, false))
  from public.tasks t
  join public.stores s        on s.id = t.store_id
  left join public.campaigns c on c.id = t.campaign_id
  left join public.placements p on p.id = t.best_placement_id
  -- >>> CANONICAL TASK VISIBILITY RULE — keep in sync with the tasks_select
  --     policy in 0002_rls.sql and with public.niva_task_visible(). <<<
  where public.niva_current_role() = 'Admin'
     or t.assignee_id = (select auth.uid())
     or t.manager_id  = (select auth.uid())
     or (public.niva_current_role() = 'Manager' and c.owner_id = (select auth.uid()));
$$;

revoke all on function public.niva_visible_tasks() from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- The nine KPI tiles the prototype's dashboard renders.
-- ---------------------------------------------------------------------
create or replace function public.niva_dashboard_kpis(p_campaign_id uuid default null)
returns table (
  total_planned      bigint,
  completed          bigint,
  pending            bigint,
  in_progress        bigint,
  rework             bigint,
  pct_complete       integer,
  submissions        bigint,
  placement_verified bigint,
  same_frame         bigint,
  unverified         bigint,
  draft              bigint,
  assigned           bigint,
  executing          bigint,
  submitted          bigint,
  approved           bigint,
  closed             bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  with v as (
    select * from public.niva_visible_tasks()
     where p_campaign_id is null or campaign_id = p_campaign_id
  ), s as (
    select *, status in ('Submitted', 'Rework Required', 'Approved', 'Closed') as is_submission
      from v
  )
  select
    count(*)                                                       as total_planned,
    count(*) filter (where status in ('Approved', 'Closed'))       as completed,
    count(*) filter (where status in ('Draft', 'Assigned'))        as pending,
    count(*) filter (where status in ('In Progress', 'Submitted')) as in_progress,
    count(*) filter (where status = 'Rework Required')             as rework,
    case when count(*) = 0 then 0
         else round(100.0 * count(*) filter (where status in ('Approved', 'Closed')) / count(*))::int
    end                                                            as pct_complete,
    count(*) filter (where is_submission)                          as submissions,
    count(*) filter (where is_submission and is_verified)          as placement_verified,
    count(*) filter (where is_submission and is_same_frame)        as same_frame,
    count(*) filter (where is_submission and is_unverified)        as unverified,
    count(*) filter (where status = 'Draft')                       as draft,
    count(*) filter (where status = 'Assigned')                    as assigned,
    count(*) filter (where status = 'In Progress')                 as executing,
    count(*) filter (where status = 'Submitted')                   as submitted,
    count(*) filter (where status = 'Approved')                    as approved,
    count(*) filter (where status = 'Closed')                      as closed
  from s;
$$;

-- ---------------------------------------------------------------------
-- Region / State / City breakdown — the "Progress by ..." panel.
-- p_granularity is matched against a fixed CASE, never interpolated into SQL.
-- ---------------------------------------------------------------------
create or replace function public.niva_dashboard_rollup(
  p_granularity text default 'Region',
  p_campaign_id uuid default null
)
returns table (
  bucket             text,
  total_planned      bigint,
  completed          bigint,
  pending            bigint,
  in_progress        bigint,
  rework             bigint,
  pct_complete       integer,
  submissions        bigint,
  placement_verified bigint,
  same_frame         bigint,
  unverified         bigint,
  draft              bigint,
  assigned           bigint,
  executing          bigint,
  submitted          bigint,
  approved           bigint,
  closed             bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  with v as (
    select
      case lower(coalesce(p_granularity, 'region'))
        when 'region' then region
        when 'state'  then state
        when 'city'   then city
        else region
      end as bucket,
      status, is_verified, is_same_frame, is_unverified,
      status in ('Submitted', 'Rework Required', 'Approved', 'Closed') as is_submission
    from public.niva_visible_tasks()
    where p_campaign_id is null or campaign_id = p_campaign_id
  )
  select
    bucket,
    count(*),
    count(*) filter (where status in ('Approved', 'Closed')),
    count(*) filter (where status in ('Draft', 'Assigned')),
    count(*) filter (where status in ('In Progress', 'Submitted')),
    count(*) filter (where status = 'Rework Required'),
    case when count(*) = 0 then 0
         else round(100.0 * count(*) filter (where status in ('Approved', 'Closed')) / count(*))::int
    end,
    count(*) filter (where is_submission),
    count(*) filter (where is_submission and is_verified),
    count(*) filter (where is_submission and is_same_frame),
    count(*) filter (where is_submission and is_unverified),
    count(*) filter (where status = 'Draft'),
    count(*) filter (where status = 'Assigned'),
    count(*) filter (where status = 'In Progress'),
    count(*) filter (where status = 'Submitted'),
    count(*) filter (where status = 'Approved'),
    count(*) filter (where status = 'Closed')
  from v
  group by bucket
  order by count(*) desc, bucket;
$$;

-- ---------------------------------------------------------------------
-- Per-campaign rollup — the Campaigns list page.
-- ---------------------------------------------------------------------
create or replace function public.niva_campaign_rollup()
returns table (
  campaign_id        uuid,
  total_planned      bigint,
  completed          bigint,
  pending            bigint,
  in_progress        bigint,
  rework             bigint,
  pct_complete       integer,
  submissions        bigint,
  placement_verified bigint,
  same_frame         bigint,
  unverified         bigint
)
language sql
stable
security definer
set search_path = ''
as $$
  with v as (
    select campaign_id, status, is_verified, is_same_frame, is_unverified,
           status in ('Submitted', 'Rework Required', 'Approved', 'Closed') as is_submission
      from public.niva_visible_tasks()
  )
  select
    campaign_id,
    count(*),
    count(*) filter (where status in ('Approved', 'Closed')),
    count(*) filter (where status in ('Draft', 'Assigned')),
    count(*) filter (where status in ('In Progress', 'Submitted')),
    count(*) filter (where status = 'Rework Required'),
    case when count(*) = 0 then 0
         else round(100.0 * count(*) filter (where status in ('Approved', 'Closed')) / count(*))::int
    end,
    count(*) filter (where is_submission),
    count(*) filter (where is_submission and is_verified),
    count(*) filter (where is_submission and is_same_frame),
    count(*) filter (where is_submission and is_unverified)
  from v
  group by campaign_id;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'niva_dashboard_kpis(uuid)',
    'niva_dashboard_rollup(text,uuid)',
    'niva_campaign_rollup()'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('revoke all on function public.%s from anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Geofence helper, exposed so the client can ask the server whether a fix is
-- inside the store's radius instead of trusting its own haversine. Same
-- formula and same 150 m default as the prototype.
-- ---------------------------------------------------------------------
create or replace function public.niva_geofence_check(
  p_task_id uuid, p_lat double precision, p_lng double precision
)
returns table (distance_m integer, geofence_m integer, pass boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select
    round(d)::int,
    s.geofence_m,
    d <= s.geofence_m
  from public.tasks t
  join public.stores s on s.id = t.store_id
  cross join lateral (
    select 2 * 6371000 * asin(least(1, sqrt(
        power(sin(radians(p_lat - s.lat) / 2), 2)
      + cos(radians(s.lat)) * cos(radians(p_lat))
      * power(sin(radians(p_lng - s.lng) / 2), 2)
    ))) as d
  ) g
  where t.id = p_task_id
    and public.niva_task_visible(t.id);
$$;

revoke all on function public.niva_geofence_check(uuid, double precision, double precision) from public, anon;
grant execute on function public.niva_geofence_check(uuid, double precision, double precision) to authenticated;
