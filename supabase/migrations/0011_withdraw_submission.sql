-- =====================================================================
-- NIVA Field Execution — 0011_withdraw_submission.sql
-- One new edge in the task state machine: Submitted -> In Progress,
-- performed by the ASSIGNEE. Idempotent and safe to re-run.
--
-- Depends on: 0001_schema.sql, 0002_rls.sql, 0004_functions.sql
--
-- What this migration is for
-- --------------------------
-- A merchandiser takes a mockup, presses Send, and the task moves to
-- Submitted. If the photo is wrong — the wall is half out of frame, the
-- shutter caught a passer-by, the poster was drawn over a doorway — there is
-- at present NO WAY BACK. The graph as 0004 wrote it is:
--
--   Draft            -> Assigned            (manager)
--   Assigned         -> In Progress         (assignee — the geofenced check-in)
--   In Progress      -> Submitted           (assignee)
--   Submitted        -> Approved            (manager, and NOT the assignee)
--   Submitted        -> Rework Required     (manager)
--   Rework Required  -> In Progress         (assignee)
--   Approved         -> Closed              (manager)
--
-- The only door out of Submitted is a manager's decision, and in the build the
-- client is actually running the manager has no approve/reject screen any more
-- — their job is to publish posters and look at what came back. So a Submitted
-- task is frozen: it cannot be approved, it cannot be sent back for rework,
-- and the merchandiser standing in the shop with the camera in their hand
-- cannot redo the one thing they came to do. The work is simply lost.
--
-- This migration adds exactly one edge and changes nothing else:
--
--   Submitted        -> In Progress         (assignee ONLY)
--
-- Think of it as WITHDRAWING a submission, not as un-approving one. That
-- distinction is the whole safety argument, and it is worth spelling out:
--
--   1. NOBODY HAS RULED ON IT YET. Submitted means "sent, awaiting a
--      decision". Pulling something back before anyone has read it destroys no
--      judgement, contradicts no sign-off and reverses nobody else's work. The
--      moment a manager DOES decide, the task is Approved or Rework Required,
--      which are different statuses, so this edge stops existing for that task
--      — there is no Approved -> anything-but-Closed edge and there never will
--      be here. An approved task, and a closed one, stay untouchable.
--
--   2. IT IS THE ASSIGNEE'S OWN WORK. The actor rule below is strict equality
--      with old.assignee_id: not "the assignee or their manager", not an
--      admin. A manager who wants a task redone already has
--      Submitted -> Rework Required, which is the edge that carries remarks and
--      blame; letting a manager silently rewind a submission instead would be
--      that same action with the audit trail filed off.
--
--   3. THE AUDIT TRAIL RECORDS IT. audit_events is append-only for every
--      principal that reaches the database through PostgREST (0002 revokes
--      UPDATE and DELETE, 0004 blocks mutation), and tasks.submitted_at is a
--      server-owned stamp. Withdrawing therefore cannot erase the fact that a
--      submission happened, only supersede it — a manager who later looks at
--      the trail sees "Execution submitted" followed by "Submission withdrawn"
--      followed by a second submission, in order, with times and actors.
--
--   4. IT IS STRICTLY SAFER THAN THE STATUS QUO. Today the alternative to
--      redoing a bad capture is that the bad capture is the permanent record of
--      that store. A withdrawal that leaves a visible trail is better evidence
--      than a wrong photo nobody could replace.
--
-- What the edge does NOT need, and deliberately does not get
-- ---------------------------------------------------------
-- No geofence re-check. The Assigned -> In Progress edge demands a passing
-- checkin_pass because that is the check-in; a withdrawal is a return to a
-- visit that already checked in, and the original checkin_* columns are
-- untouched by it. Demanding a fresh check-in here would lock out exactly the
-- person we are trying to help — someone who has walked out of the shop,
-- noticed the photo is bad on the bus, and needs the task open before they can
-- go back in. The guard's existing geofence clause is already written as
-- `new.status = 'In Progress' and old.status = 'Assigned'`, so it ignores this
-- edge without any change.
--
-- No stamp rewriting. submitted_at keeps whatever the first submission wrote,
-- and the next submission overwrites it with now(). The stamps stay
-- server-owned either way; a client still cannot send them.
--
-- Why this is NOT gated on verification mode
-- ------------------------------------------
-- The app ships in two modes (a mockup survey and a verification programme),
-- but the database has no idea which one is in front of it: APP_MODE is a
-- client constant, it is not in the JWT, it is not a column, and inventing a
-- flag the client sets would be a permission the client grants itself — which
-- is not a permission at all. So the choice is to allow the edge in both modes
-- or in neither, and it should be both:
--
--   * In VERIFICATION mode, evidence and an approval workflow are the point.
--     Withdrawing does not touch either. The decision has not been made yet, so
--     no approval is being undone; the evidence of the withdrawal itself is
--     written to the audit trail. The images and placements from the first
--     attempt are append-only rows that survive it (a merchandiser may DELETE
--     their own 'after' image while the task is open again — see
--     task_images_delete_field in 0002 — but a placements row can never be
--     deleted or edited by anyone, so the measurement history stands).
--
--   * In MOCKUP mode it is the entire fix: the manager is not going to send
--     anything back, so the assignee is the only person who can.
--
-- And separation of duties is untouched in both. The one fraud that matters in
-- a field-execution system is signing off your own work; withdrawing your own
-- unread submission is the opposite — it delays a sign-off, it cannot produce
-- one. NIVA_SELF_APPROVAL below is re-stated verbatim.
--
-- The second half: RLS has to be let in on it
-- -------------------------------------------
-- The trigger is not the only lock, and on its own it would have changed
-- nothing observable. tasks_update_field in 0002 reads:
--
--     using       (... and status in ('Assigned', 'In Progress', 'Rework Required'))
--     with check  (... and status in ('In Progress', 'Submitted'))
--
-- 'Submitted' is absent from the USING clause, so a Submitted task is not
-- merely un-transitionable for the assignee — it is INVISIBLE to their UPDATE.
-- The PATCH matches zero rows and returns 200 with an empty body, which is the
-- worst possible failure: silent success. So section 2 below re-states that one
-- policy with 'Submitted' added to USING, and nothing else touched. The WITH
-- CHECK is unchanged and still refuses to let 'Approved' or 'Closed' ever be
-- the post-image of a field write, which is the separation-of-duties lock.
--
-- Widening USING has one side effect that must be closed, and section 1 closes
-- it. USING admits the row for ANY update, not only a status change, so a
-- merchandiser could now PATCH merch_remarks on a task they had already sent —
-- a same-status edit, which the transition guard's "not a transition" branch
-- previously only policed for lifecycle stamps. Rewriting what you said about a
-- job after filing it, with no trace, is exactly the kind of quiet revision this
-- schema exists to prevent. So the guard now refuses every merchandiser write
-- to a task sitting in Submitted except the withdrawal itself: take it back in
-- the open, or leave it alone. That restores the invariant 0002 had by accident
-- and states it on purpose.
--
-- Note on method: this file RE-STATES niva_tasks_transition_guard() in full
-- rather than patching it. The function is the authority on seven edges, three
-- actor rules, a geofence gate and four lifecycle stamps; a partial redefinition
-- is not possible in Postgres anyway (create or replace replaces the whole
-- body), so the honest thing is to show the whole body with the one added line
-- visible in context. Everything below except the marked block is byte-identical
-- to 0004.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. The state machine
-- ---------------------------------------------------------------------
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

    -- 0011: A SUBMITTED TASK IS READ-ONLY FOR THE FIELD.
    -- Before 0011 this needed saying nowhere, because tasks_update_field did
    -- not admit a Submitted row for update at all. Section 2 below has to widen
    -- that policy so the withdrawal can happen, and widening it would otherwise
    -- open a door nobody asked for: editing merch_remarks on a job already
    -- filed, invisibly, after the fact. A merchandiser who wants to change what
    -- they sent withdraws it — Submitted -> In Progress, which is one audit
    -- event and one visible status — and changes it in the open.
    if v_uid is not null and old.status = 'Submitted' and v_role = 'Merchandiser' then
      raise exception 'NIVA_FORBIDDEN: a submitted task cannot be edited in place; withdraw it first'
        using errcode = 'insufficient_privilege',
              hint = 'Move the task Submitted -> In Progress, make the change, then submit again.';
    end if;

    return new;
  end if;

  -- (a) Is the edge in the graph?
  --     The last line is new in 0011: withdrawing an unread submission.
  if not (
       (old.status = 'Draft'           and new.status = 'Assigned')
    or (old.status = 'Assigned'        and new.status = 'In Progress')
    or (old.status = 'In Progress'     and new.status = 'Submitted')
    or (old.status = 'Submitted'       and new.status = 'Approved')
    or (old.status = 'Submitted'       and new.status = 'Rework Required')
    or (old.status = 'Rework Required' and new.status = 'In Progress')
    or (old.status = 'Approved'        and new.status = 'Closed')
    or (old.status = 'Submitted'       and new.status = 'In Progress')   -- 0011
  ) then
    raise exception 'NIVA_ILLEGAL_TRANSITION: % -> % is not a legal task transition (task %)',
      old.status, new.status, old.task_code
      using errcode = 'check_violation',
            hint = 'Legal edges: Draft->Assigned, Assigned->In Progress, In Progress->Submitted, Submitted->Approved, Submitted->Rework Required, Submitted->In Progress (assignee withdraws), Rework Required->In Progress, Approved->Closed.';
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

    -- ---- 0011: WITHDRAWAL IS THE ASSIGNEE'S ALONE ---------------------
    -- Checked BEFORE the general In Progress rule below, because that rule is
    -- deliberately looser: it also admits the task's manager, which is correct
    -- for Assigned -> In Progress (a manager may start a visit on behalf of
    -- the field) and for Rework Required -> In Progress (they just asked for
    -- the rework). It is NOT correct here. A manager who wants this task
    -- reopened has Submitted -> Rework Required, which records who asked and
    -- why; quietly rewinding someone else's submission would be the same
    -- action with the reason and the name left out.
    if old.status = 'Submitted' and new.status = 'In Progress'
       and old.assignee_id is distinct from v_uid then
      raise exception 'NIVA_FORBIDDEN: only the assigned merchandiser may withdraw their own submission'
        using errcode = 'insufficient_privilege',
              hint = 'A manager returns a submitted task with Submitted -> Rework Required, which carries review remarks.';
    end if;
    -- -------------------------------------------------------------------

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
  -- Scoped to the Assigned edge on purpose: see the header. A withdrawal
  -- returns to a visit that has already checked in, and the checkin_* columns
  -- it checked in with are still on the row.
  if new.status = 'In Progress' and old.status = 'Assigned'
     and coalesce(new.checkin_pass, false) is not true then
    raise exception 'NIVA_GEOFENCE: a passing geofenced check-in is required before starting execution'
      using errcode = 'check_violation',
            hint = 'Write checkin_at/checkin_lat/checkin_lng/checkin_distance_m/checkin_pass in the same PATCH that moves the task to In Progress.';
  end if;

  -- (c) Server-owned lifecycle stamps.
  -- Unchanged by 0011. A withdrawal leaves submitted_at reading the time of
  -- the submission it withdrew, which is the truth until the task is submitted
  -- again and this branch overwrites it. Clearing it would delete the only
  -- column that says the first attempt ever happened.
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

-- The trigger itself is unchanged and already points at this function, but it
-- is re-created for the same reason the whole body is re-stated: so that
-- applying 0011 to a database that somehow lost the trigger repairs it rather
-- than silently leaving the guard unenforced.
drop trigger if exists trg_tasks_transition on public.tasks;
create trigger trg_tasks_transition
  before update on public.tasks
  for each row execute function public.niva_tasks_transition_guard();

-- ---------------------------------------------------------------------
-- 2. RLS: let the assignee's UPDATE see a Submitted row at all
-- ---------------------------------------------------------------------
-- Re-stated verbatim from 0002 except for one added value in USING. The
-- ATTACK PREVENTED notes are carried over unchanged because they still hold:
--
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
--
-- 0011 adds 'Submitted' to USING only. That is the smallest change that makes
-- a withdrawal possible: the row becomes visible to the assignee's UPDATE, and
-- everything about WHAT it may become is still decided by the unchanged WITH
-- CHECK and by the trigger above — which allows exactly one post-image for a
-- Submitted pre-image, 'In Progress', and refuses every same-status edit from
-- a merchandiser outright.
drop policy if exists tasks_update_field on public.tasks;
create policy tasks_update_field on public.tasks
  for update to authenticated
  using (
    (select public.niva_is_merchandiser())
    and assignee_id = (select auth.uid())
    and status in ('Assigned', 'In Progress', 'Rework Required', 'Submitted')
  )
  with check (
    (select public.niva_is_merchandiser())
    and assignee_id = (select auth.uid())
    and status in ('In Progress', 'Submitted')
  );

-- NOT CHANGED, and the omission is deliberate: niva_task_open_for_me() still
-- answers true only for 'In Progress' and 'Rework Required'. That function
-- gates the placements insert, the task_images insert, the task_images delete
-- and the Storage object policies in 0003. So nothing can be attached to, or
-- removed from, a task while it sits in Submitted — the withdrawal has to
-- actually land before the evidence becomes editable again, and the moment it
-- does, task_images_delete_field lets the assignee discard their own bad 'after'
-- shot exactly as it does during a first attempt. placements stay append-only
-- for everyone regardless, so the measurement history of the withdrawn attempt
-- survives it.

commit;

-- =====================================================================
-- Verification — run these after applying
-- =====================================================================
-- -- 1. The guard really does know about the new edge (expect: true)
-- select prosrc like '%old.status = ''Submitted''       and new.status = ''In Progress''%'
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public' and p.proname = 'niva_tasks_transition_guard';
--
-- -- 2. The trigger is attached and enabled (expect: true)
-- select tgenabled = 'O' from pg_trigger
--  where tgrelid = 'public.tasks'::regclass and tgname = 'trg_tasks_transition';
--
-- -- 3. Every OLD edge still refuses what it refused before. As the assignee of
-- --    a Draft task (expect: ERROR NIVA_ILLEGAL_TRANSITION):
-- -- update public.tasks set status = 'Closed' where status = 'Draft';
--
-- -- 4. An APPROVED task cannot be reopened by anybody — this is the edge the
-- --    header promises does not exist (expect: ERROR NIVA_ILLEGAL_TRANSITION):
-- -- update public.tasks set status = 'In Progress' where status = 'Approved';
--
-- -- 5. Signed in as the ASSIGNEE of a Submitted task (expect: 1 row updated,
-- --    and submitted_at unchanged):
-- -- update public.tasks set status = 'In Progress'
-- --  where status = 'Submitted' and assignee_id = auth.uid();
--
-- -- 6. Signed in as that task's MANAGER (expect: ERROR NIVA_FORBIDDEN,
-- --    'only the assigned merchandiser may withdraw their own submission'):
-- -- update public.tasks set status = 'In Progress' where status = 'Submitted';
--
-- -- 7. Self-approval is still impossible (expect: ERROR NIVA_SELF_APPROVAL):
-- -- update public.tasks set status = 'Approved'
-- --  where status = 'Submitted' and assignee_id = auth.uid();
--
-- -- 8. The field UPDATE policy now admits a Submitted row, and still refuses
-- --    to let one become Approved or Closed (expect: true, true)
-- select qual::text like '%Submitted%' as using_has_submitted,
--        with_check::text not like '%Approved%' as check_excludes_approved
--   from pg_policies
--  where schemaname = 'public' and tablename = 'tasks'
--    and policyname = 'tasks_update_field';
--
-- -- 9. Editing a submitted task in place is refused as the assignee
-- --    (expect: ERROR NIVA_FORBIDDEN, 'cannot be edited in place'):
-- -- update public.tasks set merch_remarks = 'second thoughts'
-- --  where status = 'Submitted' and assignee_id = auth.uid();
--
-- -- 10. Evidence is still frozen while the task is Submitted — the withdrawal
-- --     has to land first (expect: false for every submitted task)
-- select bool_or(public.niva_task_open_for_me(id)) is not true
--   from public.tasks where status = 'Submitted' and assignee_id = auth.uid();
