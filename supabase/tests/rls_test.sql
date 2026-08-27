-- =====================================================================
-- NIVA Field Execution — tests/rls_test.sql
--
-- Proves the policies, not just exercises them. For every role the suite
-- asserts BOTH directions: what the role can see and do, and what it must be
-- refused. A refusal only counts if the statement raised OR changed zero rows;
-- a statement that quietly changed a row is a failure even if it "looked" like
-- it was denied.
--
-- Run it (one command, nothing is left behind — the whole file rolls back):
--
--     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql
--
-- ...or paste the whole file into the Supabase SQL Editor and run it.
--
-- Requires: 0001-0004 applied and seed.sql run.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Harness
--
-- Results go into a table rather than into RAISE NOTICE, because notices are
-- not always visible (the Supabase SQL Editor hides them, and some drivers
-- drop them). The table is created inside this transaction and disappears with
-- the ROLLBACK at the bottom; the run prints it as an ordinary result set just
-- before finishing, so you get a readable PASS/FAIL list wherever you run it.
-- ---------------------------------------------------------------------
create table public._niva_rls_test_log (
  seq    serial primary key,
  name   text    not null,
  passed boolean not null
);
grant insert, select on public._niva_rls_test_log to authenticated, anon;
grant usage, select on sequence public._niva_rls_test_log_seq_seq to authenticated, anon;

create function pg_temp.ok(p_name text, p_cond boolean) returns void
language plpgsql as $$
begin
  insert into public._niva_rls_test_log (name, passed) values (p_name, p_cond);
  if p_cond then
    raise notice 'PASS  %', p_name;
  else
    raise warning 'FAIL  %', p_name;
  end if;
end $$;

-- The statement must NOT succeed in changing anything: either it raises, or it
-- matches zero rows because the USING clause hid them. Anything else fails.
create function pg_temp.must_be_blocked(p_name text, p_sql text) returns void
language plpgsql as $$
declare v_rows bigint;
begin
  begin
    execute p_sql;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then
      perform pg_temp.ok(p_name || '  (blocked: 0 rows affected)', true);
    else
      perform pg_temp.ok(p_name || '  (!!! ' || v_rows || ' row(s) changed)', false);
    end if;
  exception when others then
    perform pg_temp.ok(p_name || '  (blocked: ' || sqlstate || ' ' ||
                       left(replace(sqlerrm, E'\n', ' '), 90) || ')', true);
  end;
end $$;

create function pg_temp.must_succeed(p_name text, p_sql text) returns void
language plpgsql as $$
declare v_rows bigint;
begin
  begin
    execute p_sql;
    get diagnostics v_rows = row_count;
    if v_rows > 0 then
      perform pg_temp.ok(p_name || '  (' || v_rows || ' row(s))', true);
    else
      perform pg_temp.ok(p_name || '  (!!! 0 rows affected)', false);
    end if;
  exception when others then
    perform pg_temp.ok(p_name || '  (!!! raised ' || sqlstate || ' ' ||
                       left(replace(sqlerrm, E'\n', ' '), 90) || ')', false);
  end;
end $$;

create function pg_temp.must_raise(p_name text, p_sql text) returns void
language plpgsql as $$
begin
  begin
    execute p_sql;
    perform pg_temp.ok(p_name || '  (!!! did not raise)', false);
  exception when others then
    perform pg_temp.ok(p_name || '  (raised ' || sqlstate || ': ' ||
                       left(replace(sqlerrm, E'\n', ' '), 90) || ')', true);
  end;
end $$;

create function pg_temp.login(p_uid text) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated',
                      'aud', 'authenticated')::text, true);
end $$;

-- ---------------------------------------------------------------------
-- Fixtures. FORCE ROW LEVEL SECURITY is lifted only to read the ids (the
-- `postgres` role matches no policy, every policy being granted `to
-- authenticated`), then immediately restored, so every assertion below runs
-- against exactly the production configuration.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['profiles','stores','campaigns','tasks',
                           'placements','task_images','audit_events','notifications'] loop
    execute format('alter table public.%I no force row level security', t);
  end loop;
end $$;

do $$
declare
  v record;
begin
  for v in
    select p.role, p.full_name, p.id
      from public.profiles p
     order by p.role, p.full_name
  loop
    null;
  end loop;

  -- users, by the emails seed.sql uses
  perform set_config('niva.t_s1', (select id::text from public.profiles where full_name = 'Aditya Kulkarni'), true);
  perform set_config('niva.t_s2', (select id::text from public.profiles where full_name = 'Sneha Iyer'), true);
  perform set_config('niva.t_m1', (select id::text from public.profiles where full_name = 'Rohan Mehta'), true);
  perform set_config('niva.t_m2', (select id::text from public.profiles where full_name = 'Priya Nair'), true);
  perform set_config('niva.t_a1', (select id::text from public.profiles where full_name = 'Vikram Rao'), true);

  if current_setting('niva.t_s1', true) is null or current_setting('niva.t_s1', true) = '' then
    raise exception 'Seed data not found. Run supabase/seed.sql before the RLS tests.';
  end if;

  -- tasks (deterministic seed ids: 71000000-0000-4000-8000-<12-digit index>)
  perform set_config('niva.t_task_s1_progress',  '71000000-0000-4000-8000-000000000002', true); -- i=2  In Progress, assignee s1, manager m1
  perform set_config('niva.t_task_s1_submitted', '71000000-0000-4000-8000-000000000001', true); -- i=1  Submitted,   assignee s1, manager m2
  perform set_config('niva.t_task_s1_assigned',  '71000000-0000-4000-8000-000000000003', true); -- i=3  Assigned,    assignee s1, manager m2
  perform set_config('niva.t_task_s2_submitted', '71000000-0000-4000-8000-000000000009', true); -- i=9  Submitted,   assignee s2, manager m2
  perform set_config('niva.t_task_m1_draft',     '71000000-0000-4000-8000-000000000010', true); -- i=10 Draft,       assignee s2, manager m1, campaign cmp2
  -- A task that is foreign to Priya (m2) on BOTH axes: managed by Rohan (m1)
  -- AND in cmp3, which Rohan owns. Note that i=10 above is NOT foreign to her
  -- even though Rohan manages it, because she owns cmp2 — campaign ownership
  -- is a second, independent grant, and an earlier draft of this test used
  -- i=10 here and correctly failed.
  perform set_config('niva.t_task_foreign_m2',   '71000000-0000-4000-8000-000000000018', true); -- i=18 Submitted,   assignee s1, manager m1, campaign cmp3

  -- one audit row and one placement row belonging to a task s1 can see
  perform set_config('niva.t_audit_id',
    (select id::text from public.audit_events
      where task_id = '71000000-0000-4000-8000-000000000001' order by id limit 1), true);
  perform set_config('niva.t_placement_id',
    (select id::text from public.placements
      where task_id = '71000000-0000-4000-8000-000000000001' limit 1), true);
  perform set_config('niva.t_placement_other',
    (select id::text from public.placements
      where task_id = '71000000-0000-4000-8000-000000000009' limit 1), true);

  perform set_config('niva.t_s1_task_count',
    (select count(*)::text from public.tasks
      where assignee_id = current_setting('niva.t_s1')::uuid), true);
  perform set_config('niva.t_all_task_count',  (select count(*)::text from public.tasks), true);
  perform set_config('niva.t_all_store_count', (select count(*)::text from public.stores), true);
end $$;

do $$
declare t text;
begin
  foreach t in array array['profiles','stores','campaigns','tasks',
                           'placements','task_images','audit_events','notifications'] loop
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- =====================================================================
-- A. MERCHANDISER (Aditya Kulkarni)
-- =====================================================================
select pg_temp.login(current_setting('niva.t_s1'));
set local role authenticated;

do $$
declare
  v_me     uuid := current_setting('niva.t_s1')::uuid;
  v_seen   bigint;
  v_mine   bigint := current_setting('niva.t_s1_task_count')::bigint;
  v_all    bigint := current_setting('niva.t_all_task_count')::bigint;
  v_stores bigint;
begin
  perform pg_temp.ok('A0  role lookup resolves without recursion',
    public.niva_current_role() = 'Merchandiser');

  ---------------------------------------------------------------- CAN
  select count(*) into v_seen from public.tasks;
  perform pg_temp.ok('A1  merchandiser sees exactly their own tasks ('
                     || v_seen || ' of ' || v_all || ')',
    v_seen = v_mine and v_mine > 0 and v_mine < v_all);

  perform pg_temp.ok('A2  merchandiser can read their own assigned task',
    exists (select 1 from public.tasks
             where id = current_setting('niva.t_task_s1_progress')::uuid));

  ---------------------------------------------------------------- CANNOT
  perform pg_temp.ok('A3  merchandiser CANNOT read another merchandiser''s task',
    not exists (select 1 from public.tasks
                 where id = current_setting('niva.t_task_s2_submitted')::uuid));

  perform pg_temp.ok('A4  merchandiser CANNOT read a task row by any predicate',
    (select count(*) from public.tasks where assignee_id <> v_me) = 0);

  select count(*) into v_stores from public.stores;
  perform pg_temp.ok('A5  merchandiser CANNOT enumerate the store master ('
                     || v_stores || ' of ' || current_setting('niva.t_all_store_count') || ')',
    v_stores <= v_mine and v_stores < current_setting('niva.t_all_store_count')::bigint);

  perform pg_temp.ok('A6  merchandiser CANNOT read another merchandiser''s placement',
    not exists (select 1 from public.placements
                 where id = current_setting('niva.t_placement_other')::uuid));

  perform pg_temp.ok('A7  merchandiser CANNOT browse the user directory',
    (select count(*) from public.profiles) <
    (select 9));
end $$;

-- --- writes a merchandiser must not be able to make -------------------
select pg_temp.must_be_blocked(
  'A8  merchandiser CANNOT reassign another user''s task to themselves',
  format('update public.tasks set assignee_id = %L where id = %L',
         current_setting('niva.t_s1'), current_setting('niva.t_task_s2_submitted')));

select pg_temp.must_be_blocked(
  'A9  merchandiser CANNOT hand their own task to someone else',
  format('update public.tasks set assignee_id = %L where id = %L',
         current_setting('niva.t_s2'), current_setting('niva.t_task_s1_progress')));

select pg_temp.must_be_blocked(
  'A10 merchandiser CANNOT approve their own submitted task (self-approval)',
  format('update public.tasks set status = ''Approved'' where id = %L',
         current_setting('niva.t_task_s1_submitted')));

select pg_temp.must_be_blocked(
  'A11 merchandiser CANNOT jump straight to Closed',
  format('update public.tasks set status = ''Closed'' where id = %L',
         current_setting('niva.t_task_s1_progress')));

select pg_temp.must_be_blocked(
  'A12 merchandiser CANNOT widen their own capture brief (standoff tolerance)',
  format('update public.tasks set standoff_tol_ft = 99 where id = %L',
         current_setting('niva.t_task_s1_progress')));

select pg_temp.must_be_blocked(
  'A13 merchandiser CANNOT rewrite the manager''s review remarks',
  format('update public.tasks set review_remarks = ''looks fine to me'' where id = %L',
         current_setting('niva.t_task_s1_progress')));

select pg_temp.must_be_blocked(
  'A14 merchandiser CANNOT escalate their own role to Admin',
  format('update public.profiles set role = ''Admin'' where id = %L',
         current_setting('niva.t_s1')));

select pg_temp.must_be_blocked(
  'A15 merchandiser CANNOT promote someone else either',
  format('update public.profiles set role = ''Admin'' where id = %L',
         current_setting('niva.t_s2')));

select pg_temp.must_be_blocked(
  'A16 merchandiser CANNOT update an audit row',
  format('update public.audit_events set detail = ''tampered'' where id = %s',
         current_setting('niva.t_audit_id')));

select pg_temp.must_be_blocked(
  'A17 merchandiser CANNOT delete an audit row',
  format('delete from public.audit_events where id = %s',
         current_setting('niva.t_audit_id')));

select pg_temp.must_be_blocked(
  'A18 merchandiser CANNOT update a placement (turn a FAIL into a PASS)',
  format('update public.placements set passed = true, distance_ft = target_ft where id = %L',
         current_setting('niva.t_placement_id')));

select pg_temp.must_be_blocked(
  'A19 merchandiser CANNOT delete a placement',
  format('delete from public.placements where id = %L',
         current_setting('niva.t_placement_id')));

select pg_temp.must_be_blocked(
  'A20 merchandiser CANNOT create a task',
  format($q$insert into public.tasks
             (task_code, campaign_id, store_id, assignee_id, manager_id,
              display_type, width_ft, height_ft, status)
           select 'HACK-1', t.campaign_id, t.store_id, %L, %L,
                  'Standee', 3, 6, 'Closed'
             from public.tasks t where t.id = %L$q$,
         current_setting('niva.t_s1'), current_setting('niva.t_s1'),
         current_setting('niva.t_task_s1_progress')));

select pg_temp.must_be_blocked(
  'A21 merchandiser CANNOT insert a placement onto a task that is not theirs',
  format($q$insert into public.placements
             (task_id, tier, tier_label, capture_mode, target_ft, tol_ft, angle_tol_deg, passed)
           values (%L, 'As', 'AR single-frame', 'single-frame', 6, 0.5, 5, true)$q$,
         current_setting('niva.t_task_s2_submitted')));

select pg_temp.must_be_blocked(
  'A22 merchandiser CANNOT back-fill a placement onto their own SUBMITTED task',
  format($q$insert into public.placements
             (task_id, tier, tier_label, capture_mode, target_ft, tol_ft, angle_tol_deg, passed)
           values (%L, 'As', 'AR single-frame', 'single-frame', 6, 0.5, 5, true)$q$,
         current_setting('niva.t_task_s1_submitted')));

-- Audit forgery: the INSERT policy demands actor_id = auth.uid(), so naming
-- someone else is refused outright.
select pg_temp.must_be_blocked(
  'A23 merchandiser CANNOT forge an audit row in the manager''s name',
  format($q$insert into public.audit_events
             (task_id, actor_id, actor_name, actor_role, action, detail)
           values (%L, %L, 'Rohan Mehta', 'Manager', 'Execution approved', 'approved by me')$q$,
         current_setting('niva.t_task_s1_submitted'), current_setting('niva.t_m1')));

select pg_temp.must_be_blocked(
  'A24 merchandiser CANNOT attach an audit row to a task they cannot see',
  format($q$insert into public.audit_events (task_id, actor_id, action, actor_name)
           values (%L, %L, 'Snooping', 'x')$q$,
         current_setting('niva.t_task_s2_submitted'), current_setting('niva.t_s1')));

-- --- writes a merchandiser SHOULD be able to make ---------------------
select pg_temp.must_succeed(
  'A25 merchandiser CAN record a placement on their own In Progress task',
  format($q$insert into public.placements
             (task_id, tier, tier_label, capture_mode, distance_ft, target_ft, tol_ft,
              distance_ok, angle_tol_deg, pitch_ok, roll_ok, yaw_ok, yaw_verified, passed)
           values (%L, 'As', 'AR single-frame', 'single-frame', 8.0, 8.0, 0.75,
                   true, 5, true, true, true, true, true)$q$,
         current_setting('niva.t_task_s1_progress')));

select pg_temp.must_succeed(
  'A26 merchandiser CAN append an audit row for their own task',
  format($q$insert into public.audit_events (task_id, actor_id, actor_name, action, detail)
           values (%L, %L, 'ignored', 'Guided capture recorded', 'tier As')$q$,
         current_setting('niva.t_task_s1_progress'), current_setting('niva.t_s1')));

do $$
declare v_actor uuid; v_name text;
begin
  select actor_id, actor_name into v_actor, v_name
    from public.audit_events
   where task_id = current_setting('niva.t_task_s1_progress')::uuid
     and action = 'Guided capture recorded'
   order by id desc limit 1;
  perform pg_temp.ok('A27 audit actor is stamped from the JWT, not the request body',
    v_actor = current_setting('niva.t_s1')::uuid and v_name = 'Aditya Kulkarni');
end $$;

select pg_temp.must_succeed(
  'A28 merchandiser CAN submit their own In Progress task (legal transition)',
  format('update public.tasks set status = ''Submitted'', merch_remarks = ''done'' where id = %L',
         current_setting('niva.t_task_s1_progress')));

do $$
declare v_sub timestamptz;
begin
  select submitted_at into v_sub from public.tasks
   where id = current_setting('niva.t_task_s1_progress')::uuid;
  perform pg_temp.ok('A29 submitted_at is stamped by the server on transition',
    v_sub is not null and v_sub > now() - interval '1 minute');
end $$;

-- Check-in gate: Assigned -> In Progress without a passing geofence must fail.
select pg_temp.must_be_blocked(
  'A30 merchandiser CANNOT start execution without a passing geofenced check-in',
  format('update public.tasks set status = ''In Progress'' where id = %L',
         current_setting('niva.t_task_s1_assigned')));

select pg_temp.must_succeed(
  'A31 merchandiser CAN start execution with a passing check-in in the same PATCH',
  format($q$update public.tasks
              set status = 'In Progress', checkin_at = now(), checkin_pass = true,
                  checkin_distance_m = 42, checkin_accuracy_m = 9,
                  checkin_lat = 19.0, checkin_lng = 72.9,
                  checkin_device = 'test', checkin_source = 'device'
            where id = %L$q$,
         current_setting('niva.t_task_s1_assigned')));

reset role;

-- =====================================================================
-- B. STORAGE — path-prefix ownership
-- =====================================================================
do $$
begin
  if to_regclass('storage.objects') is null then
    raise notice 'SKIP  storage tests: storage.objects not present (non-Supabase database)';
    return;
  end if;
  -- Plant one evidence object under a task this merchandiser must not see, so
  -- the read test below has something real to fail to find. Inserted here as
  -- the table owner; storage.objects is not FORCEd (see 0003_storage.sql).
  insert into storage.objects (bucket_id, name, owner_id)
  values ('evidence',
          'tasks/' || current_setting('niva.t_task_s2_submitted') || '/after/private.jpg',
          current_setting('niva.t_s2'))
  on conflict do nothing;
end $$;

select pg_temp.login(current_setting('niva.t_s1'));
set local role authenticated;

select pg_temp.must_be_blocked(
  'B1  merchandiser CANNOT write into ANOTHER task''s evidence prefix',
  format($q$insert into storage.objects (bucket_id, name, owner_id)
           values ('evidence', 'tasks/%s/after/planted.jpg', %L)$q$,
         current_setting('niva.t_task_s2_submitted'), current_setting('niva.t_s1')))
where to_regclass('storage.objects') is not null;

select pg_temp.must_be_blocked(
  'B2  merchandiser CANNOT dodge the convention with a forged prefix',
  format($q$insert into storage.objects (bucket_id, name, owner_id)
           values ('evidence', 'tasks/../%s/after/planted.jpg', %L)$q$,
         current_setting('niva.t_task_s2_submitted'), current_setting('niva.t_s1')))
where to_regclass('storage.objects') is not null;

select pg_temp.must_be_blocked(
  'B3  merchandiser CANNOT write a "before" image (manager-only prefix)',
  format($q$insert into storage.objects (bucket_id, name, owner_id)
           values ('evidence', 'tasks/%s/before/x.jpg', %L)$q$,
         current_setting('niva.t_task_s1_assigned'), current_setting('niva.t_s1')))
where to_regclass('storage.objects') is not null;

select pg_temp.must_succeed(
  'B4  merchandiser CAN write into their OWN open task''s after/ prefix',
  format($q$insert into storage.objects (bucket_id, name, owner_id)
           values ('evidence', 'tasks/%s/after/legit.jpg', %L)$q$,
         current_setting('niva.t_task_s1_assigned'), current_setting('niva.t_s1')))
where to_regclass('storage.objects') is not null;

-- This is the assertion the whole "private bucket + signed URL" story rests
-- on: a signed URL can only be minted for an object the requester passes the
-- SELECT policy for, so if the row is invisible the URL cannot be created.
do $$
begin
  if to_regclass('storage.objects') is null then return; end if;

  perform pg_temp.ok('B5  merchandiser CANNOT see another task''s evidence object',
    not exists (select 1 from storage.objects
                 where bucket_id = 'evidence'
                   and name = 'tasks/' || current_setting('niva.t_task_s2_submitted')
                              || '/after/private.jpg'));

  perform pg_temp.ok('B6  merchandiser CAN see the object they just uploaded to their own task',
    exists (select 1 from storage.objects
             where bucket_id = 'evidence'
               and name = 'tasks/' || current_setting('niva.t_task_s1_assigned')
                          || '/after/legit.jpg'));
end $$;

reset role;

-- =====================================================================
-- C. MANAGER (Priya Nair — owns cmp2, manages the odd-indexed tasks)
-- =====================================================================
select pg_temp.login(current_setting('niva.t_m2'));
set local role authenticated;

do $$
declare v_seen bigint; v_all bigint := current_setting('niva.t_all_task_count')::bigint;
begin
  perform pg_temp.ok('C0  manager role resolves', public.niva_current_role() = 'Manager');

  select count(*) into v_seen from public.tasks;
  perform pg_temp.ok('C1  manager sees a scoped slice, not everything ('
                     || v_seen || ' of ' || v_all || ')',
    v_seen > 0 and v_seen < v_all);

  perform pg_temp.ok('C2  manager CAN see a task they manage',
    exists (select 1 from public.tasks where id = current_setting('niva.t_task_s1_submitted')::uuid));

  perform pg_temp.ok('C3  manager CANNOT see a task in another manager''s campaign that they do not manage',
    not exists (select 1 from public.tasks where id = current_setting('niva.t_task_foreign_m2')::uuid));

  perform pg_temp.ok('C3b manager CAN see a task in a campaign they own even when someone else manages it',
    exists (select 1 from public.tasks where id = current_setting('niva.t_task_m1_draft')::uuid));

  perform pg_temp.ok('C4  manager CAN see the store master',
    (select count(*) from public.stores) = current_setting('niva.t_all_store_count')::bigint);
end $$;

select pg_temp.must_be_blocked(
  'C5  manager CANNOT edit a placement',
  format('update public.placements set passed = true where id = %L',
         current_setting('niva.t_placement_id')));

select pg_temp.must_be_blocked(
  'C6  manager CANNOT delete a placement',
  format('delete from public.placements where id = %L', current_setting('niva.t_placement_id')));

select pg_temp.must_be_blocked(
  'C7  manager CANNOT edit an audit row',
  format('update public.audit_events set action = ''Nothing happened'' where id = %s',
         current_setting('niva.t_audit_id')));

select pg_temp.must_be_blocked(
  'C8  manager CANNOT delete an audit row',
  format('delete from public.audit_events where id = %s', current_setting('niva.t_audit_id')));

-- t_task_m1_draft is still Draft and sits in cmp2, which this manager owns —
-- so she is fully authorised to touch it, and the ONLY thing standing between
-- her and 'Closed' is the state machine.
select pg_temp.must_be_blocked(
  'C9  manager CANNOT jump a task from Draft to Closed (illegal transition)',
  format('update public.tasks set status = ''Closed'' where id = %L',
         current_setting('niva.t_task_m1_draft')));

select pg_temp.must_succeed(
  'C9b the same manager CAN make the legal Draft -> Assigned move on that task',
  format('update public.tasks set status = ''Assigned'' where id = %L',
         current_setting('niva.t_task_m1_draft')));

select pg_temp.must_be_blocked(
  'C10 manager CANNOT approve a submitted task they neither own nor manage',
  format('update public.tasks set status = ''Approved'' where id = %L',
         current_setting('niva.t_task_foreign_m2')));

select pg_temp.must_be_blocked(
  'C11 manager CANNOT promote themselves to Admin',
  format('update public.profiles set role = ''Admin'' where id = %L',
         current_setting('niva.t_m2')));

select pg_temp.must_succeed(
  'C12 manager CAN approve a submitted task they manage (legal transition)',
  format('update public.tasks set status = ''Approved'' where id = %L',
         current_setting('niva.t_task_s1_submitted')));

select pg_temp.must_succeed(
  'C13 manager CAN then close the approved task',
  format('update public.tasks set status = ''Closed'' where id = %L',
         current_setting('niva.t_task_s1_submitted')));

do $$
declare v_ref text;
begin
  select completion_ref into v_ref from public.tasks
   where id = current_setting('niva.t_task_s1_submitted')::uuid;
  perform pg_temp.ok('C14 completion_ref is generated server-side on Closed',
    v_ref like 'NIVA-CR-%');
end $$;

select pg_temp.must_be_blocked(
  'C15 Closed is terminal — no transition out of it',
  format('update public.tasks set status = ''In Progress'' where id = %L',
         current_setting('niva.t_task_s1_submitted')));

reset role;

-- =====================================================================
-- D. SEPARATION OF DUTIES — a manager who is also the assignee
-- =====================================================================
-- The FSM trigger refuses Submitted -> Approved when the approver is the
-- assignee, regardless of role. Set that situation up and prove it.
do $$
declare t text;
begin
  foreach t in array array['tasks'] loop
    execute format('alter table public.%I no force row level security', t);
  end loop;
  update public.tasks
     set assignee_id = current_setting('niva.t_m2')::uuid
   where id = current_setting('niva.t_task_s2_submitted')::uuid;
  foreach t in array array['tasks'] loop
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

select pg_temp.login(current_setting('niva.t_m2'));
set local role authenticated;

select pg_temp.must_be_blocked(
  'D1  a manager CANNOT approve a task assigned to themselves',
  format('update public.tasks set status = ''Approved'' where id = %L',
         current_setting('niva.t_task_s2_submitted')));

reset role;

-- =====================================================================
-- E. ADMIN (Vikram Rao)
-- =====================================================================
select pg_temp.login(current_setting('niva.t_a1'));
set local role authenticated;

do $$
declare v_seen bigint;
begin
  perform pg_temp.ok('E0  admin role resolves', public.niva_current_role() = 'Admin');

  select count(*) into v_seen from public.tasks;
  perform pg_temp.ok('E1  admin sees every task (' || v_seen || ')',
    v_seen = current_setting('niva.t_all_task_count')::bigint);

  perform pg_temp.ok('E2  admin sees every store',
    (select count(*) from public.stores) = current_setting('niva.t_all_store_count')::bigint);
end $$;

select pg_temp.must_be_blocked(
  'E3  admin CANNOT edit an audit row',
  format('update public.audit_events set detail = ''redacted'' where id = %s',
         current_setting('niva.t_audit_id')));

select pg_temp.must_be_blocked(
  'E4  admin CANNOT delete an audit row',
  format('delete from public.audit_events where id = %s', current_setting('niva.t_audit_id')));

select pg_temp.must_be_blocked(
  'E5  admin CANNOT edit a placement',
  format('update public.placements set passed = true where id = %L',
         current_setting('niva.t_placement_id')));

select pg_temp.must_be_blocked(
  'E6  admin CANNOT truncate the audit trail',
  'truncate public.audit_events');

select pg_temp.must_be_blocked(
  'E7  even an admin cannot make an illegal transition',
  format('update public.tasks set status = ''Closed'' where id = %L',
         current_setting('niva.t_task_m1_draft')));

reset role;

-- =====================================================================
-- F. ANON — an unauthenticated holder of the publishable anon key
-- =====================================================================
select set_config('request.jwt.claims', null, true);
set local role anon;

select pg_temp.must_be_blocked('F1  anon CANNOT read tasks',         'select * from public.tasks');
select pg_temp.must_be_blocked('F2  anon CANNOT read stores',        'select * from public.stores');
select pg_temp.must_be_blocked('F3  anon CANNOT read profiles',      'select * from public.profiles');
select pg_temp.must_be_blocked('F4  anon CANNOT read audit_events',  'select * from public.audit_events');
select pg_temp.must_be_blocked('F5  anon CANNOT call the dashboard rollup',
                               'select * from public.niva_dashboard_kpis()');

reset role;

-- =====================================================================
-- G. DASHBOARD ROLLUP — SECURITY DEFINER must not leak across roles
-- =====================================================================
-- This is the drift detector for the "KEEP IN SYNC" comment: the rollup's
-- explicit WHERE clause must return exactly the row set the tasks_select
-- policy returns, for every role. If somebody edits one and not the other,
-- these three assertions fail.

select pg_temp.login(current_setting('niva.t_s1'));
set local role authenticated;
do $$
declare v_rls bigint; v_roll bigint;
begin
  select count(*) into v_rls from public.tasks;
  select total_planned into v_roll from public.niva_dashboard_kpis();
  perform pg_temp.ok('G1  rollup total == RLS-visible task count for a merchandiser ('
                     || v_roll || ' vs ' || v_rls || ')', v_roll = v_rls);
  perform pg_temp.ok('G2  rollup does not leak the national total to a merchandiser',
    v_roll < current_setting('niva.t_all_task_count')::bigint);
  perform pg_temp.ok('G3  region breakdown sums to the same number',
    (select coalesce(sum(total_planned), 0) from public.niva_dashboard_rollup('Region')) = v_rls);
end $$;
reset role;

select pg_temp.login(current_setting('niva.t_m2'));
set local role authenticated;
do $$
declare v_rls bigint; v_roll bigint;
begin
  select count(*) into v_rls from public.tasks;
  select total_planned into v_roll from public.niva_dashboard_kpis();
  perform pg_temp.ok('G4  rollup total == RLS-visible task count for a manager ('
                     || v_roll || ' vs ' || v_rls || ')', v_roll = v_rls);
  perform pg_temp.ok('G5  city granularity also agrees',
    (select coalesce(sum(total_planned), 0) from public.niva_dashboard_rollup('City')) = v_rls);
end $$;
reset role;

select pg_temp.login(current_setting('niva.t_a1'));
set local role authenticated;
do $$
declare v_rls bigint; v_roll bigint;
begin
  select count(*) into v_rls from public.tasks;
  select total_planned into v_roll from public.niva_dashboard_kpis();
  perform pg_temp.ok('G6  rollup total == RLS-visible task count for an admin ('
                     || v_roll || ' vs ' || v_rls || ')', v_roll = v_rls);
  perform pg_temp.ok('G7  admin rollup equals the national total',
    v_roll = current_setting('niva.t_all_task_count')::bigint);
end $$;

select pg_temp.must_be_blocked(
  'G8  the raw row source behind the rollup is not callable by a client',
  'select * from public.niva_visible_tasks()');

reset role;

-- =====================================================================
-- H. NOTIFICATIONS
-- =====================================================================
select pg_temp.login(current_setting('niva.t_s1'));
set local role authenticated;

do $$
declare v_id uuid;
begin
  select id into v_id from public.notifications
   where target_user_id = current_setting('niva.t_s1')::uuid limit 1;
  perform set_config('niva.t_notif', coalesce(v_id::text, ''), true);
  perform pg_temp.ok('H1  merchandiser sees their own notifications', v_id is not null);
end $$;

select pg_temp.must_be_blocked(
  'H2  recipient CANNOT rewrite the body of a notification they received',
  format('update public.notifications set body = ''Approved by manager'' where id = %L',
         nullif(current_setting('niva.t_notif'), '')))
where nullif(current_setting('niva.t_notif'), '') is not null;

select pg_temp.must_succeed(
  'H3  recipient CAN mark their notification read',
  format('update public.notifications set read_at = now() where id = %L',
         nullif(current_setting('niva.t_notif'), '')))
where nullif(current_setting('niva.t_notif'), '') is not null;

reset role;

-- =====================================================================
-- Summary
-- =====================================================================
-- The full result list, as an ordinary result set.
select seq, case when passed then 'PASS' else 'FAIL' end as result, name
  from public._niva_rls_test_log
 order by seq;

do $$
declare
  v_pass int;
  v_fail int;
  v_list text;
begin
  select count(*) filter (where passed), count(*) filter (where not passed)
    into v_pass, v_fail
    from public._niva_rls_test_log;

  select coalesce(string_agg('  - ' || name, E'\n' order by seq), '')
    into v_list from public._niva_rls_test_log where not passed;

  raise notice '=====================================================';
  if v_fail = 0 then
    raise notice 'ALL RLS TESTS PASSED  (% assertions)', v_pass;
    raise notice '=====================================================';
  else
    raise exception E'RLS TEST SUITE FAILED: % of % assertions failed\n%',
      v_fail, v_pass + v_fail, v_list;
  end if;
end $$;

-- Nothing is persisted: every write above, and the result log itself, is
-- thrown away.
rollback;
