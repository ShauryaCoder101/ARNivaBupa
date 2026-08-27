-- =====================================================================
-- NIVA Field Execution — 0002_rls.sql
-- Authorization. Idempotent and safe to re-run.
--
-- There is NO trusted server tier in this architecture: the vanilla client
-- talks to PostgREST directly with the anon key plus the user's JWT. Every
-- authorization decision therefore has to be a row-level policy or a trigger.
-- If a rule is not written here, it is not enforced anywhere.
--
-- This file contains:
--   A. the authorization helper functions (they must exist before any policy
--      that references them can be created, which is why they live here and
--      not in 0004)
--   B. table grants
--   C. per-table, per-operation policies
-- =====================================================================

set local check_function_bodies = off;

-- =====================================================================
-- A. AUTHORIZATION HELPERS
-- =====================================================================
--
-- THE RECURSION PROBLEM, AND WHY THESE FUNCTIONS LOOK LIKE THIS
-- -------------------------------------------------------------
-- The obvious way to write "admins can read everything" is:
--
--     using (exists (select 1 from public.profiles p
--                     where p.id = auth.uid() and p.role = 'Admin'))
--
-- put on `profiles` itself. That is a trap. When Postgres evaluates a SELECT
-- on `profiles`, it ORs together every SELECT policy on `profiles`; this one
-- selects from `profiles`, which re-evaluates the policies, which selects from
-- `profiles`... Postgres detects the cycle and aborts the whole query with
-- "infinite recursion detected in policy for relation profiles" — so the
-- symptom is not a leak, it is that *every* read of profiles fails, including
-- reads that would have been allowed. Put the same helper on a policy for
-- another table and you get a silent, per-row `exists` subquery that is also
-- subject to RLS, which can deny rows it should have allowed.
--
-- The fix has two parts:
--
--   1. SECURITY DEFINER. The lookup runs as the function owner (`postgres` in
--      Supabase), not as the caller, so the caller's policies do not apply to
--      the lookup itself. STABLE so the planner may evaluate it once per
--      statement instead of once per row. `set search_path = ''` so a hostile
--      user cannot shadow `profiles` or `=` with objects in a schema they
--      control and hijack a definer function — every name below is fully
--      qualified, which is required once search_path is empty.
--
--   2. A re-entrancy guard. SECURITY DEFINER alone is only sufficient if the
--      owner bypasses RLS. These tables use FORCE ROW LEVEL SECURITY, which
--      deliberately subjects the owner to policies too, so whether step 1 is
--      enough depends on whether the owning role happens to carry BYPASSRLS.
--      Rather than depend on a platform detail, niva_current_role() sets a
--      transaction-local flag while it runs. If policy evaluation re-enters it,
--      the nested call returns NULL instead of recursing; the outer call still
--      gets the right answer because the `profiles_select_self` policy is a
--      plain `id = auth.uid()` predicate that needs no role lookup. The result
--      is correct and terminating with or without BYPASSRLS.
--
-- Every helper is revoked from PUBLIC/anon and granted only to `authenticated`.

create or replace function public.niva_current_role()
returns public.niva_role
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.niva_role;
begin
  -- Re-entrancy guard (see the block comment above).
  if coalesce(current_setting('niva.in_role_lookup', true), '') = 'on' then
    return null;
  end if;

  perform set_config('niva.in_role_lookup', 'on', true);
  begin
    select p.role
      into v_role
      from public.profiles p
     where p.id = (select auth.uid());
  exception when others then
    perform set_config('niva.in_role_lookup', 'off', true);
    raise;
  end;
  perform set_config('niva.in_role_lookup', 'off', true);

  return v_role;   -- NULL for anon or for a JWT with no profile row => deny
end;
$$;

create or replace function public.niva_is_admin() returns boolean
language sql stable security definer set search_path = ''
as $$ select public.niva_current_role() = 'Admin' $$;

create or replace function public.niva_is_manager() returns boolean
language sql stable security definer set search_path = ''
as $$ select public.niva_current_role() = 'Manager' $$;

create or replace function public.niva_is_merchandiser() returns boolean
language sql stable security definer set search_path = ''
as $$ select public.niva_current_role() = 'Merchandiser' $$;

-- Does the caller own this campaign? Definer, so campaigns' own policies do
-- not have to be consulted (which would recurse via tasks).
create or replace function public.niva_owns_campaign(p_campaign_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.campaigns c
     where c.id = p_campaign_id
       and c.owner_id = (select auth.uid())
  );
$$;

-- Campaign visibility: owned, or referenced by a task the caller is on.
create or replace function public.niva_campaign_visible(p_campaign_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.niva_current_role() = 'Admin'
      or exists (select 1 from public.campaigns c
                  where c.id = p_campaign_id and c.owner_id = (select auth.uid()))
      or exists (select 1 from public.tasks t
                  where t.campaign_id = p_campaign_id
                    and ((select auth.uid()) in (t.assignee_id, t.manager_id)));
$$;

-- ---------------------------------------------------------------------
-- >>> CANONICAL TASK VISIBILITY RULE <<<
-- Admin sees everything. A merchandiser sees only the tasks assigned to them.
-- A manager sees tasks they are named on plus every task in a campaign they
-- own. Nobody else sees anything.
--
-- KEEP IN SYNC with the `tasks_select` policy below and with the WHERE clause
-- in public.niva_visible_tasks() in 0004_functions.sql. The RLS test suite
-- asserts that all three agree (test R10) precisely so this comment cannot rot
-- into a lie.
-- ---------------------------------------------------------------------
create or replace function public.niva_task_visible(p_task_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
      from public.tasks t
      left join public.campaigns c on c.id = t.campaign_id
     where t.id = p_task_id
       and (
            public.niva_current_role() = 'Admin'
         or t.assignee_id = (select auth.uid())
         or t.manager_id  = (select auth.uid())
         or (public.niva_current_role() = 'Manager' and c.owner_id = (select auth.uid()))
       )
  );
$$;

-- Is this task assigned to the caller AND currently in a state where field
-- work is legitimate? Used by placements/task_images/storage insert policies
-- so evidence cannot be back-filled onto an already-approved task.
create or replace function public.niva_task_open_for_me(p_task_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.tasks t
     where t.id = p_task_id
       and t.assignee_id = (select auth.uid())
       and t.status in ('In Progress', 'Rework Required')
  );
$$;

-- Does the caller manage this task (named manager, campaign owner, or admin)?
create or replace function public.niva_task_managed_by_me(p_task_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
      from public.tasks t
      left join public.campaigns c on c.id = t.campaign_id
     where t.id = p_task_id
       and (
            public.niva_current_role() = 'Admin'
         or t.manager_id = (select auth.uid())
         or (public.niva_current_role() = 'Manager' and c.owner_id = (select auth.uid()))
       )
  );
$$;

-- Store visibility. Managers and admins get the store master; a merchandiser
-- only ever sees the stores their own tasks point at. This is the rule that
-- stops a field device from exfiltrating the retail footprint.
create or replace function public.niva_store_visible(p_store_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.niva_current_role() in ('Admin', 'Manager')
      or exists (select 1 from public.tasks t
                  where t.store_id = p_store_id
                    and ((select auth.uid()) in (t.assignee_id, t.manager_id)));
$$;

-- Do the caller and p_profile_id appear together on any task? Lets a
-- merchandiser resolve their manager's name without exposing the org chart.
create or replace function public.niva_shares_task_with(p_profile_id uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.tasks t
     where ((select auth.uid()) in (t.assignee_id, t.manager_id))
       and (p_profile_id in (t.assignee_id, t.manager_id))
  );
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'niva_current_role()', 'niva_is_admin()', 'niva_is_manager()',
    'niva_is_merchandiser()', 'niva_owns_campaign(uuid)',
    'niva_campaign_visible(uuid)', 'niva_task_visible(uuid)',
    'niva_task_open_for_me(uuid)', 'niva_task_managed_by_me(uuid)',
    'niva_store_visible(uuid)', 'niva_shares_task_with(uuid)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('revoke all on function public.%s from anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- =====================================================================
-- B. GRANTS
-- =====================================================================
-- RLS filters rows; GRANT decides whether the verb is available at all. Both
-- matter. Revoking UPDATE on audit_events/placements from `authenticated` AND
-- from `service_role` is what makes those tables append-only even for a leaked
-- service key, because service_role bypasses RLS but not table privileges.

grant usage on schema public to anon, authenticated, service_role;

-- `anon` (an unauthenticated visitor holding only the publishable anon key)
-- gets nothing at all. Every read requires a signed-in user.
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;

revoke all on all tables in schema public from authenticated;

grant select, insert, update         on public.profiles      to authenticated;
grant select, insert, update, delete on public.stores        to authenticated;
grant select, insert, update, delete on public.campaigns     to authenticated;
grant select, insert, update, delete on public.tasks         to authenticated;
grant select, insert, update, delete on public.task_images   to authenticated;
grant select, insert, update, delete on public.notifications to authenticated;

-- INSERT only. No UPDATE, no DELETE, no TRUNCATE — for anybody.
grant select, insert on public.placements   to authenticated;
grant select, insert on public.audit_events to authenticated;

revoke update, delete, truncate on public.placements   from authenticated, anon, service_role;
revoke update, delete, truncate on public.audit_events from authenticated, anon, service_role;

-- =====================================================================
-- C. POLICIES
-- =====================================================================
-- Convention used throughout:
--   * one policy per (table, operation, role-intent) so each can be read and
--     tested in isolation;
--   * every INSERT and UPDATE policy has an explicit WITH CHECK. A policy with
--     USING but no WITH CHECK on an UPDATE inherits USING as the check, which
--     is the classic hole where a user rewrites a row into a shape they could
--     not have read — the checks below are written out even where they would
--     have been inherited, so that the intent is visible;
--   * `(select auth.uid())` and `(select public.niva_is_x())` are wrapped in a
--     scalar subquery so the planner hoists them into an InitPlan and
--     evaluates them once per statement rather than once per row.

-- ---------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------
drop policy if exists profiles_select_self       on public.profiles;
drop policy if exists profiles_select_staff      on public.profiles;
drop policy if exists profiles_select_teammate   on public.profiles;
drop policy if exists profiles_insert_self       on public.profiles;
drop policy if exists profiles_update_self       on public.profiles;
drop policy if exists profiles_update_admin      on public.profiles;

-- Deliberately a bare predicate with no function call: this is the policy the
-- re-entrancy guard in niva_current_role() relies on to still resolve the
-- caller's own row if a nested lookup ever happens.
create policy profiles_select_self on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

-- Managers and admins need the user list to populate the assignee picker.
create policy profiles_select_staff on public.profiles
  for select to authenticated
  using ((select public.niva_current_role()) in ('Manager', 'Admin'));

-- A merchandiser may resolve the name of someone they share a task with
-- (their manager) but not browse the directory.
create policy profiles_select_teammate on public.profiles
  for select to authenticated
  using (public.niva_shares_task_with(id));

-- Self-provisioning only. The role a new row claims is overwritten by
-- niva_profiles_guard (0004), so `role` cannot be chosen at sign-up either.
create policy profiles_insert_self on public.profiles
  for insert to authenticated
  with check (id = (select auth.uid()));

-- ATTACK PREVENTED: privilege escalation via `PATCH /profiles?id=eq.me`
-- with body {"role":"Admin"}. The WITH CHECK below keeps the row owned by the
-- caller; trigger niva_profiles_guard (0004) is what refuses the role change
-- itself, because a policy expression cannot compare NEW.role to OLD.role.
create policy profiles_update_self on public.profiles
  for update to authenticated
  using      (id = (select auth.uid()))
  with check (id = (select auth.uid()));

create policy profiles_update_admin on public.profiles
  for update to authenticated
  using      ((select public.niva_is_admin()))
  with check ((select public.niva_is_admin()));

-- No DELETE policy: profiles die only when their auth.users row is deleted
-- (ON DELETE CASCADE), which is an Admin API operation, not a client one.

-- ---------------------------------------------------------------------
-- stores
-- ---------------------------------------------------------------------
drop policy if exists stores_select        on public.stores;
drop policy if exists stores_insert_staff  on public.stores;
drop policy if exists stores_update_staff  on public.stores;
drop policy if exists stores_delete_admin  on public.stores;

-- ATTACK PREVENTED: a field device pulling the entire store master
-- (`GET /stores?select=*`) and walking away with the retail footprint. The
-- first disjunct is a per-statement constant for staff; the row-wise function
-- is only reached for merchandisers.
create policy stores_select on public.stores
  for select to authenticated
  using (
    (select public.niva_current_role()) in ('Admin', 'Manager')
    or public.niva_store_visible(id)
  );

create policy stores_insert_staff on public.stores
  for insert to authenticated
  with check ((select public.niva_current_role()) in ('Admin', 'Manager'));

create policy stores_update_staff on public.stores
  for update to authenticated
  using      ((select public.niva_current_role()) in ('Admin', 'Manager'))
  with check ((select public.niva_current_role()) in ('Admin', 'Manager'));

create policy stores_delete_admin on public.stores
  for delete to authenticated
  using ((select public.niva_is_admin()));

-- ---------------------------------------------------------------------
-- campaigns
-- ---------------------------------------------------------------------
drop policy if exists campaigns_select        on public.campaigns;
drop policy if exists campaigns_insert_mgr    on public.campaigns;
drop policy if exists campaigns_update_owner  on public.campaigns;
drop policy if exists campaigns_delete_admin  on public.campaigns;

create policy campaigns_select on public.campaigns
  for select to authenticated
  using (
    (select public.niva_is_admin())
    or owner_id = (select auth.uid())
    or public.niva_campaign_visible(id)
  );

-- WITH CHECK pins owner_id to the creator: a manager cannot create a campaign
-- owned by someone else and thereby hand themselves a task surface later.
create policy campaigns_insert_mgr on public.campaigns
  for insert to authenticated
  with check (
    (select public.niva_is_admin())
    or ((select public.niva_is_manager()) and owner_id = (select auth.uid()))
  );

-- USING controls which rows may be touched; WITH CHECK controls what they may
-- become. Both are required, and they are different: a manager may edit their
-- own campaign but may NOT set owner_id to another user (that would be a way
-- to launder ownership), so the check repeats the ownership predicate against
-- the post-image.
create policy campaigns_update_owner on public.campaigns
  for update to authenticated
  using (
    (select public.niva_is_admin())
    or ((select public.niva_is_manager()) and owner_id = (select auth.uid()))
  )
  with check (
    (select public.niva_is_admin())
    or ((select public.niva_is_manager()) and owner_id = (select auth.uid()))
  );

create policy campaigns_delete_admin on public.campaigns
  for delete to authenticated
  using ((select public.niva_is_admin()));

-- ---------------------------------------------------------------------
-- tasks
-- ---------------------------------------------------------------------
drop policy if exists tasks_select            on public.tasks;
drop policy if exists tasks_insert_mgr        on public.tasks;
drop policy if exists tasks_update_field      on public.tasks;
drop policy if exists tasks_update_mgr        on public.tasks;
drop policy if exists tasks_delete_draft      on public.tasks;

-- KEEP IN SYNC with public.niva_task_visible() and niva_visible_tasks().
-- Written inline rather than as a function call so it stays a join-friendly
-- predicate the planner can push into the index scan.
create policy tasks_select on public.tasks
  for select to authenticated
  using (
    (select public.niva_is_admin())
    or assignee_id = (select auth.uid())
    or manager_id  = (select auth.uid())
    or ((select public.niva_is_manager()) and public.niva_owns_campaign(campaign_id))
  );

-- ATTACK PREVENTED: skipping the state machine entirely by POSTing a brand new
-- row with {"status":"Closed"}. New tasks may only be born in Draft, and the
-- lifecycle timestamp columns must be empty.
create policy tasks_insert_mgr on public.tasks
  for insert to authenticated
  with check (
    (select public.niva_current_role()) in ('Admin', 'Manager')
    and manager_id = (select auth.uid())
    and public.niva_campaign_visible(campaign_id)
    and status = 'Draft'
    and submitted_at is null
    and approved_at  is null
    and closed_at    is null
    and completion_ref is null
    and best_placement_id is null
  );

-- MERCHANDISER UPDATE.
-- ATTACK PREVENTED (1): reassigning someone else's task to yourself
--   (`PATCH /tasks?id=eq.OTHER` body {"assignee_id":"me"}). The USING clause
--   never matches a row the caller is not already the assignee of, so the row
--   is invisible to the UPDATE and zero rows change.
-- ATTACK PREVENTED (2): handing your own task to someone else, or off your
--   own books, to escape a rework. WITH CHECK re-asserts assignee_id = me on
--   the post-image.
-- ATTACK PREVENTED (3): self-approval. The post-image status must be one of
--   the two states field work can legitimately land in. 'Approved' and
--   'Closed' are unreachable through this policy no matter what the FSM
--   trigger does, and the FSM trigger independently refuses the transition —
--   two independent locks on the single most valuable fraud in the system.
create policy tasks_update_field on public.tasks
  for update to authenticated
  using (
    (select public.niva_is_merchandiser())
    and assignee_id = (select auth.uid())
    and status in ('Assigned', 'In Progress', 'Rework Required')
  )
  with check (
    (select public.niva_is_merchandiser())
    and assignee_id = (select auth.uid())
    and status in ('In Progress', 'Submitted')
  );

-- MANAGER / ADMIN UPDATE. Which rows (USING) and what they may become
-- (WITH CHECK) are both scoped to tasks the caller manages, so a manager
-- cannot move a task into a campaign they own in order to capture it.
create policy tasks_update_mgr on public.tasks
  for update to authenticated
  using (
    (select public.niva_is_admin())
    or ((select public.niva_is_manager())
        and (manager_id = (select auth.uid())
             or public.niva_owns_campaign(campaign_id)))
  )
  with check (
    (select public.niva_is_admin())
    or ((select public.niva_is_manager())
        and (manager_id = (select auth.uid())
             or public.niva_owns_campaign(campaign_id)))
  );

-- Only an unstarted Draft may be deleted, and only by its manager. Admins may
-- delete any task row, but audit_events.task_id is ON DELETE RESTRICT, so any
-- task that has ever been acted on is undeletable by anyone — the referential
-- constraint, not a policy, is what protects the history.
create policy tasks_delete_draft on public.tasks
  for delete to authenticated
  using (
    (select public.niva_is_admin())
    or ((select public.niva_is_manager())
        and manager_id = (select auth.uid())
        and status = 'Draft')
  );

-- ---------------------------------------------------------------------
-- placements  (INSERT + SELECT ONLY)
-- ---------------------------------------------------------------------
drop policy if exists placements_select        on public.placements;
drop policy if exists placements_insert_field  on public.placements;

create policy placements_select on public.placements
  for select to authenticated
  using (public.niva_task_visible(task_id));

-- Only the assigned merchandiser, only while the task is genuinely open for
-- field work. A manager cannot manufacture a passing measurement for a task
-- they want signed off, and nobody can back-fill evidence onto an Approved or
-- Closed task.
create policy placements_insert_field on public.placements
  for insert to authenticated
  with check (public.niva_task_open_for_me(task_id));

-- NO UPDATE POLICY AND NO DELETE POLICY — deliberately.
-- ATTACK PREVENTED: a merchandiser (or a manager, or an admin) editing a
-- failed measurement into a passing one after the fact. Combined with the
-- REVOKE above and trigger niva_block_mutation (0004), a placement row is
-- write-once for every principal that reaches the database through PostgREST,
-- including one holding the service_role key.

-- ---------------------------------------------------------------------
-- task_images
-- ---------------------------------------------------------------------
drop policy if exists task_images_select        on public.task_images;
drop policy if exists task_images_insert_field  on public.task_images;
drop policy if exists task_images_insert_mgr    on public.task_images;
drop policy if exists task_images_delete_field  on public.task_images;

create policy task_images_select on public.task_images
  for select to authenticated
  using (public.niva_task_visible(task_id));

-- ATTACK PREVENTED: attributing an upload to another user. uploaded_by is
-- pinned to the caller here and additionally overwritten by trigger
-- niva_stamp_actor (0004).
create policy task_images_insert_field on public.task_images
  for insert to authenticated
  with check (
    kind = 'after'
    and uploaded_by = (select auth.uid())
    and public.niva_task_open_for_me(task_id)
  );

create policy task_images_insert_mgr on public.task_images
  for insert to authenticated
  with check (
    kind in ('before', 'poster')
    and uploaded_by = (select auth.uid())
    and public.niva_task_managed_by_me(task_id)
  );

-- A merchandiser may discard a bad shot before submitting. Once the task
-- leaves the field states, the image is evidence and nobody can remove it.
create policy task_images_delete_field on public.task_images
  for delete to authenticated
  using (
    kind = 'after'
    and uploaded_by = (select auth.uid())
    and public.niva_task_open_for_me(task_id)
  );

-- No UPDATE policy: an image row's path, geotag and placement link are fixed
-- at upload time.

-- ---------------------------------------------------------------------
-- audit_events  (INSERT + SELECT ONLY)
-- ---------------------------------------------------------------------
drop policy if exists audit_select        on public.audit_events;
drop policy if exists audit_insert_actor  on public.audit_events;

create policy audit_select on public.audit_events
  for select to authenticated
  using (
    (select public.niva_is_admin())
    or actor_id = (select auth.uid())
    or (task_id is not null and public.niva_task_visible(task_id))
  );

-- ATTACK PREVENTED: forging an audit entry that blames someone else —
-- `POST /audit_events` with {"actor_id": "<the manager>", "action":
-- "Execution approved"}. actor_id must equal the caller, and the caller must
-- already be able to see the task the event is attached to. Trigger
-- niva_stamp_actor (0004) additionally overwrites actor_id, actor_name and
-- actor_role from the caller's own profile, so even a policy mistake here
-- cannot produce a mis-attributed row.
create policy audit_insert_actor on public.audit_events
  for insert to authenticated
  with check (
    actor_id = (select auth.uid())
    and (task_id is null or public.niva_task_visible(task_id))
  );

-- NO UPDATE POLICY AND NO DELETE POLICY — deliberately, and this is the whole
-- point of the table. An audit trail that anyone can edit is not evidence, it
-- is decoration. See also the REVOKE above (which binds service_role too) and
-- trigger niva_block_mutation (which binds the table owner).

-- ---------------------------------------------------------------------
-- notifications
-- ---------------------------------------------------------------------
drop policy if exists notifications_select        on public.notifications;
drop policy if exists notifications_insert        on public.notifications;
drop policy if exists notifications_update_own    on public.notifications;
drop policy if exists notifications_delete_own    on public.notifications;

create policy notifications_select on public.notifications
  for select to authenticated
  using (
    (select public.niva_is_admin())
    or target_user_id = (select auth.uid())
    or (target_user_id is null and target_role = (select public.niva_current_role()))
  );

-- The client raises the manager's "Approval Required" notification at submit
-- time, so authenticated users must be able to insert. The blast radius is
-- capped: the sender is recorded (created_by, trigger-stamped) and the
-- notification must hang off a task the sender can already see.
create policy notifications_insert on public.notifications
  for insert to authenticated
  with check (
    created_by = (select auth.uid())
    and (task_id is null or public.niva_task_visible(task_id))
  );

-- Only your own inbox, and trigger niva_notifications_guard (0004) narrows
-- this further to the read_at column so a recipient cannot rewrite the body of
-- a notification they received and then screenshot it.
create policy notifications_update_own on public.notifications
  for update to authenticated
  using      (target_user_id = (select auth.uid()))
  with check (target_user_id = (select auth.uid()));

create policy notifications_delete_own on public.notifications
  for delete to authenticated
  using (
    target_user_id = (select auth.uid())
    or (select public.niva_is_admin())
  );
