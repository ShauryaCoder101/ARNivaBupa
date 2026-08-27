-- ============================================================================
--  EDIT THE PASSWORD ON THE NEXT LINE BEFORE RUNNING THIS FILE.
--  It becomes the login password for all nine demo accounts.
--  Minimum 6 characters. Do not reuse a password you use anywhere else.
-- ============================================================================
set niva.seed_password = 'REPLACE-THIS-PASSWORD';
-- ============================================================================

-- =====================================================================
-- NIVA Field Execution — seed.sql
-- Ports the prototype's demo dataset: 3 campaigns, 15 Indian cities with real
-- coordinates, 24 stores, 24 tasks, the same 9 users, and a matching audit
-- trail / placement record / notification set, so the migrated app renders
-- identically to niva-merch-app.html on first run.
--
-- Idempotent: re-running replaces the seeded rows in place (ON CONFLICT
-- upserts keyed on natural keys) and does not duplicate anything. It does NOT
-- delete rows you created yourself.
--
-- ---------------------------------------------------------------------
-- BEFORE YOU RUN THIS: CHOOSE A PASSWORD
-- ---------------------------------------------------------------------
-- This file contains no password. You supply one, and it is used for all nine
-- demo logins. Set it for the session before running the script:
--
--     set niva.seed_password = 'the-password-you-choose';
--
-- In the Supabase SQL Editor, paste that line as the first line of the script.
-- With psql:
--
--     psql "$DATABASE_URL" \
--       -c "set niva.seed_password = 'the-password-you-choose'" \
--       -f supabase/seed.sql
--
-- ...except that `set` does not survive between -c and -f, so with psql use
-- the documented one-liner in README.md instead:
--
--     psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
--       -c "\set pw 'the-password-you-choose'" ...
--
-- The simplest reliable form, and the one README.md recommends:
--
--     PGOPTIONS="-c niva.seed_password=the-password-you-choose" \
--       psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql
--
-- If niva.seed_password is not set, the script SKIPS creating auth users and
-- expects the nine accounts to already exist (created via the Dashboard or the
-- Auth Admin API — see README.md). It matches them by email address, so any
-- creation route works.
-- ---------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------
-- FORCE ROW LEVEL SECURITY is on for every table (0001). FORCE deliberately
-- applies policies to the table OWNER too, and every policy is granted `to
-- authenticated` — so `postgres`, the role the SQL Editor and psql run as,
-- matches no policy and can insert nothing. Lift FORCE for the duration of the
-- seed and put it back. Because this whole file is one transaction, a failure
-- anywhere rolls the ALTERs back as well; FORCE can never be left off.
-- ---------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'stores', 'campaigns', 'tasks',
    'placements', 'task_images', 'audit_events', 'notifications'
  ] loop
    execute format('alter table public.%I no force row level security', t);
  end loop;
end $$;

-- The immutability triggers on audit_events/placements only fire on UPDATE and
-- DELETE. The seed only INSERTs, so they stay armed throughout.

-- =====================================================================
-- 0. The nine users
-- =====================================================================
create temporary table _seed_users (
  code       text primary key,
  seed_uuid  uuid not null,
  email      text not null unique,
  full_name  text not null,
  role       public.niva_role not null,
  title      text not null,
  region     text,
  id         uuid
) on commit drop;

insert into _seed_users (code, seed_uuid, email, full_name, role, title, region) values
  ('u_m1', 'a1000000-0000-4000-8000-000000000001', 'rohan.mehta@niva.example',     'Rohan Mehta',     'Manager',      'Regional Trade Marketing Manager', null),
  ('u_m2', 'a1000000-0000-4000-8000-000000000002', 'priya.nair@niva.example',      'Priya Nair',      'Manager',      'Zonal Merchandising Lead',        null),
  ('u_a1', 'a1000000-0000-4000-8000-000000000003', 'vikram.rao@niva.example',      'Vikram Rao',      'Admin',        'NIVA Platform Administrator',     null),
  ('u_s1', 'a1000000-0000-4000-8000-000000000004', 'aditya.kulkarni@niva.example', 'Aditya Kulkarni', 'Merchandiser', 'Field Merchandiser · West',       'West'),
  ('u_s2', 'a1000000-0000-4000-8000-000000000005', 'sneha.iyer@niva.example',      'Sneha Iyer',      'Merchandiser', 'Field Merchandiser · South',      'South'),
  ('u_s3', 'a1000000-0000-4000-8000-000000000006', 'imran.sheikh@niva.example',    'Imran Sheikh',    'Merchandiser', 'Field Merchandiser · North',      'North'),
  ('u_s4', 'a1000000-0000-4000-8000-000000000007', 'kavya.reddy@niva.example',     'Kavya Reddy',     'Merchandiser', 'Field Merchandiser · South',      'South'),
  ('u_s5', 'a1000000-0000-4000-8000-000000000008', 'rahul.verma@niva.example',     'Rahul Verma',     'Merchandiser', 'Field Merchandiser · North',      'North'),
  ('u_s6', 'a1000000-0000-4000-8000-000000000009', 'meera.joshi@niva.example',     'Meera Joshi',     'Merchandiser', 'Field Merchandiser · East',       'East');

-- ---------------------------------------------------------------------
-- 0a. Create the auth.users rows, if a password was supplied.
--
-- The SQL Editor cannot "cleanly" create auth users in the sense that there is
-- no supported SQL API for it — but a direct insert into auth.users +
-- auth.identities with a bcrypt hash in encrypted_password is exactly what
-- GoTrue itself writes, and the resulting accounts sign in normally with
-- email+password. The two things people usually get wrong, and that are
-- handled here, are:
--   * the NOT NULL token columns (confirmation_token, recovery_token,
--     email_change, email_change_token_new) which have no defaults on some
--     versions and must be '' rather than NULL;
--   * the matching auth.identities row — without it GoTrue does not consider
--     the account to have an email provider and the login fails.
-- auth.identities.provider_id only exists on newer GoTrue schemas, so it is
-- added dynamically.
--
-- If you would rather not insert into auth.* at all, skip this by not setting
-- niva.seed_password and create the nine accounts through the Dashboard or the
-- Auth Admin API first. See README.md.
-- ---------------------------------------------------------------------
do $$
declare
  v_pw        text := nullif(current_setting('niva.seed_password', true), '');
  v_crypt_ns  text;
  v_hash      text;
  v_has_provider_id boolean;
  u           record;
begin
  if v_pw is null then
    raise notice 'niva.seed_password not set — skipping auth.users creation. The nine demo accounts must already exist.';
    return;
  end if;

  if to_regclass('auth.users') is null then
    raise notice 'auth.users not present — skipping auth user creation (non-Supabase database).';
    return;
  end if;

  -- pgcrypto lives in `extensions` on Supabase and in `public` on a plain
  -- Postgres; find wherever crypt() actually is rather than assuming.
  select n.nspname into v_crypt_ns
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where p.proname = 'crypt' limit 1;

  if v_crypt_ns is null then
    begin
      execute 'create extension if not exists pgcrypto';
    exception when others then
      null;   -- reported properly just below
    end;
    select n.nspname into v_crypt_ns
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where p.proname = 'crypt' limit 1;
  end if;

  if v_crypt_ns is null then
    raise exception
      'pgcrypto is not available, so this script cannot hash the seed password.'
      using hint = 'Every Supabase project ships pgcrypto. On another Postgres, install the contrib package and run: create extension pgcrypto; -- or create the nine accounts through the Auth Admin API instead and re-run seed.sql without niva.seed_password (see README.md section 4).';
  end if;

  select exists (
    select 1 from information_schema.columns
     where table_schema = 'auth' and table_name = 'identities' and column_name = 'provider_id'
  ) into v_has_provider_id;

  for u in select * from _seed_users loop
    if exists (select 1 from auth.users where lower(email) = lower(u.email)) then
      continue;
    end if;

    execute format('select %I.crypt($1, %I.gen_salt(''bf''))', v_crypt_ns, v_crypt_ns)
      into v_hash using v_pw;

    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data,
      created_at, updated_at,
      confirmation_token, recovery_token, email_change, email_change_token_new
    ) values (
      '00000000-0000-0000-0000-000000000000',
      u.seed_uuid, 'authenticated', 'authenticated', lower(u.email), v_hash, now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      jsonb_build_object('full_name', u.full_name, 'role', u.role::text,
                         'title', u.title, 'region', u.region),
      now(), now(), '', '', '', ''
    );

    if v_has_provider_id then
      insert into auth.identities (id, user_id, provider_id, identity_data, provider,
                                   last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), u.seed_uuid, u.seed_uuid::text,
              jsonb_build_object('sub', u.seed_uuid::text, 'email', lower(u.email),
                                 'email_verified', true, 'phone_verified', false),
              'email', now(), now(), now());
    else
      insert into auth.identities (id, user_id, identity_data, provider,
                                   last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), u.seed_uuid,
              jsonb_build_object('sub', u.seed_uuid::text, 'email', lower(u.email)),
              'email', now(), now(), now());
    end if;

    raise notice 'created auth user %', u.email;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 0b. Resolve every seeded user to a real auth.users id, by email. This is
-- what makes the seed work no matter how the accounts were created.
-- ---------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  if to_regclass('auth.users') is not null then
    update _seed_users s
       set id = a.id
      from auth.users a
     where lower(a.email) = lower(s.email);
  else
    update _seed_users set id = seed_uuid;   -- non-Supabase test database
  end if;

  select string_agg(email, E'\n  ') into v_missing from _seed_users where id is null;
  if v_missing is not null then
    raise exception E'These demo accounts do not exist yet:\n  %\n\nEither set niva.seed_password before running this script, or create them via the Dashboard / Auth Admin API first. See README.md, "Creating the seed users".', v_missing;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 0c. Profiles. Upserted by id, so it also corrects the role of an account
-- that was created through the Dashboard (where the bootstrap trigger would
-- have defaulted it to Merchandiser).
-- ---------------------------------------------------------------------
insert into public.profiles (id, full_name, role, title, region)
select id, full_name, role, title, region from _seed_users
on conflict (id) do update
  set full_name = excluded.full_name,
      role      = excluded.role,
      title     = excluded.title,
      region    = excluded.region,
      updated_at = now();

-- =====================================================================
-- 1. Cities — the prototype's CITIES map, real coordinates
-- =====================================================================
create temporary table _seed_cities (
  key text primary key, city text, state text, sc text, region text,
  lat double precision, lng double precision
) on commit drop;

insert into _seed_cities values
  ('MUM', 'Mumbai',      'Maharashtra',    'MH', 'West',  19.0760, 72.8777),
  ('PNQ', 'Pune',        'Maharashtra',    'MH', 'West',  18.5204, 73.8567),
  ('DEL', 'Delhi',       'Delhi',          'DL', 'North', 28.6139, 77.2090),
  ('GGN', 'Gurugram',    'Haryana',        'HR', 'North', 28.4595, 77.0266),
  ('JAI', 'Jaipur',      'Rajasthan',      'RJ', 'North', 26.9124, 75.7873),
  ('LKO', 'Lucknow',     'Uttar Pradesh',  'UP', 'North', 26.8467, 80.9462),
  ('BLR', 'Bengaluru',   'Karnataka',      'KA', 'South', 12.9716, 77.5946),
  ('MAA', 'Chennai',     'Tamil Nadu',     'TN', 'South', 13.0827, 80.2707),
  ('HYD', 'Hyderabad',   'Telangana',      'TS', 'South', 17.3850, 78.4867),
  ('COK', 'Kochi',       'Kerala',         'KL', 'South',  9.9312, 76.2673),
  ('CCU', 'Kolkata',     'West Bengal',    'WB', 'East',  22.5726, 88.3639),
  ('BBI', 'Bhubaneswar', 'Odisha',         'OR', 'East',  20.2961, 85.8245),
  ('GAU', 'Guwahati',    'Assam',          'AS', 'East',  26.1445, 91.7362),
  ('AMD', 'Ahmedabad',   'Gujarat',        'GJ', 'West',  23.0225, 72.5714),
  ('IDR', 'Indore',      'Madhya Pradesh', 'MP', 'West',  22.7196, 75.8577);

-- =====================================================================
-- 2. Campaigns
-- =====================================================================
insert into public.campaigns
  (id, code, name, brand, starts_on, ends_on, note, owner_id,
   poster_w_ft, poster_h_ft, standoff_ft, standoff_tol_ft, angle_tol_deg)
select v.id, v.code, v.name, v.brand, v.starts_on, v.ends_on, v.note,
       (select id from _seed_users where code = v.owner_code),
       v.pw, v.ph, v.so, v.tol, v.atol
from (values
  ('c1000000-0000-4000-8000-000000000001'::uuid, 'cmp1', 'Monsoon Refresh 2026',  'Aquaflow Beverages', date '2026-07-01', date '2026-09-15',
   'Refresh all primary shelving and end caps with the monsoon key visual.', 'u_m1', 4.0, 3.0, 6.0, 0.50, 5.0),
  ('c1000000-0000-4000-8000-000000000002'::uuid, 'cmp2', 'Festive Gondola Blitz', 'Ghar Foods',         date '2026-08-05', date '2026-10-30',
   'Gondola end caps + floor stacks ahead of the festive season peak.',      'u_m2', 3.0, 4.0, 6.0, 0.50, 5.0),
  ('c1000000-0000-4000-8000-000000000003'::uuid, 'cmp3', 'Q3 Window Takeover',    'Nova Personal Care', date '2026-07-20', date '2026-09-30',
   'Front-of-store window vinyls and standees in metro flagship outlets.',   'u_m1', 6.0, 4.0, 8.0, 0.75, 5.0)
) as v(id, code, name, brand, starts_on, ends_on, note, owner_code, pw, ph, so, tol, atol)
on conflict (id) do update
  set name = excluded.name, brand = excluded.brand, starts_on = excluded.starts_on,
      ends_on = excluded.ends_on, note = excluded.note, owner_id = excluded.owner_id,
      poster_w_ft = excluded.poster_w_ft, poster_h_ft = excluded.poster_h_ft,
      standoff_ft = excluded.standoff_ft, standoff_tol_ft = excluded.standoff_tol_ft,
      angle_tol_deg = excluded.angle_tol_deg, updated_at = now();

-- =====================================================================
-- 3. The 24 seed rows (prototype SEED_ROWS, in order — i is 0-based)
-- =====================================================================
create temporary table _seed_rows (
  i int primary key, campaign_code text, store_name text, city_key text,
  display_type text, w numeric, h numeric, assignee_code text, status public.task_status,
  store_id uuid, task_id uuid
) on commit drop;

insert into _seed_rows (i, campaign_code, store_name, city_key, display_type, w, h, assignee_code, status) values
  ( 0, 'cmp1', 'Sahakari Bhandar — Dadar',   'MUM', 'Gondola End Cap',  6,  7, 'u_s1', 'Closed'),
  ( 1, 'cmp1', 'D-Mart Kandivali West',      'MUM', 'Floor Stack',      4,  5, 'u_s1', 'Submitted'),
  ( 2, 'cmp1', 'Reliance Smart Baner',       'PNQ', 'In-shop Branding', 8,  6, 'u_s1', 'In Progress'),
  ( 3, 'cmp1', 'Star Bazaar Aundh',          'PNQ', 'Shelf Strip',     12,  1, 'u_s1', 'Assigned'),
  ( 4, 'cmp1', 'Modern Bazaar Vasant Kunj',  'DEL', 'Gondola End Cap',  6,  7, 'u_s3', 'Approved'),
  ( 5, 'cmp1', 'Le Marche Defence Colony',   'DEL', 'Window Display',   9,  8, 'u_s3', 'Rework Required'),
  ( 6, 'cmp1', 'Spencer''s Sector 29',       'GGN', 'Floor Stack',      5,  5, 'u_s5', 'In Progress'),
  ( 7, 'cmp1', 'Big Bazaar Malviya Nagar',   'JAI', 'In-shop Branding', 7,  6, 'u_s5', 'Assigned'),
  ( 8, 'cmp2', 'More Megastore Gomti Nagar', 'LKO', 'Gondola End Cap',  6,  7, 'u_s5', 'Closed'),
  ( 9, 'cmp2', 'Nilgiris Indiranagar',       'BLR', 'Floor Stack',      4,  6, 'u_s2', 'Submitted'),
  (10, 'cmp2', 'MK Retail Jayanagar',        'BLR', 'Shelf Strip',     10,  1, 'u_s2', 'Draft'),
  (11, 'cmp2', 'Nilgiris Adyar',             'MAA', 'Standee',          3,  6, 'u_s4', 'In Progress'),
  (12, 'cmp2', 'Ratnadeep Jubilee Hills',    'HYD', 'Gondola End Cap',  6,  7, 'u_s4', 'Approved'),
  (13, 'cmp2', 'Q-Mart Kondapur',            'HYD', 'In-shop Branding', 8,  5, 'u_s4', 'Rework Required'),
  (14, 'cmp2', 'Lulu Hypermarket Edappally', 'COK', 'Window Display',  12,  9, 'u_s2', 'Assigned'),
  (15, 'cmp2', 'Spencer''s Park Street',     'CCU', 'Floor Stack',      5,  5, 'u_s6', 'Submitted'),
  (16, 'cmp2', 'Big Bazaar Patia',           'BBI', 'Shelf Strip',      9,  1, 'u_s6', 'Assigned'),
  (17, 'cmp3', 'Vishal Mega Mart GS Road',   'GAU', 'Standee',          3,  6, 'u_s6', 'Closed'),
  (18, 'cmp3', 'D-Mart Satellite',           'AMD', 'Window Display',  10,  8, 'u_s1', 'Submitted'),
  (19, 'cmp3', 'Osia Hypermart Bopal',       'AMD', 'In-shop Branding', 7,  6, 'u_s1', 'Draft'),
  (20, 'cmp3', 'Best Price Vijay Nagar',     'IDR', 'Gondola End Cap',  6,  7, 'u_s1', 'In Progress'),
  (21, 'cmp3', 'Pantaloons Phoenix Kurla',   'MUM', 'Window Display',  14, 10, 'u_s1', 'Assigned'),
  (22, 'cmp3', 'Health & Glow Nungambakkam', 'MAA', 'Standee',          3,  6, 'u_s4', 'Closed'),
  (23, 'cmp3', 'Reliance Trends Elgin Road', 'CCU', 'In-shop Branding', 8,  6, 'u_s6', 'Draft');

-- Deterministic ids so re-running the seed updates the same rows.
update _seed_rows
   set store_id = ('51000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid,
       task_id  = ('71000000-0000-4000-8000-' || lpad(i::text, 12, '0'))::uuid;

-- =====================================================================
-- 4. Stores
-- =====================================================================
-- The prototype jitters each store off its city centre with a seeded PRNG so
-- the map is not 24 pins on 15 dots. That exact PRNG is not reproducible in
-- SQL, so the same effect is produced deterministically from the row index:
-- +/- 0.05 degrees, which is a few kilometres — the same visual result.
insert into public.stores (id, store_code, name, city, state, state_code, region, lat, lng, geofence_m)
select
  r.store_id,
  c.sc || '-' || r.city_key || '-' || lpad((140 + r.i * 7)::text, 4, '0'),
  r.store_name, c.city, c.state, c.sc, c.region,
  round((c.lat + ((r.i * 37 % 101) - 50) / 1000.0)::numeric, 5)::double precision,
  round((c.lng + ((r.i * 53 % 101) - 50) / 1000.0)::numeric, 5)::double precision,
  150
from _seed_rows r join _seed_cities c on c.key = r.city_key
on conflict (id) do update
  set store_code = excluded.store_code, name = excluded.name, city = excluded.city,
      state = excluded.state, state_code = excluded.state_code, region = excluded.region,
      lat = excluded.lat, lng = excluded.lng, updated_at = now();

-- =====================================================================
-- 5. Tasks
-- =====================================================================
-- Statuses are inserted directly at their final value. That is legal: the FSM
-- trigger guards UPDATE, not INSERT, precisely so that an import or a seed can
-- land historical state without replaying twenty years of transitions —
-- while a client, which can only ever INSERT via the tasks_insert_mgr policy,
-- is pinned to status = 'Draft'.
insert into public.tasks (
  id, task_code, campaign_id, store_id, assignee_id, manager_id, created_by,
  exec_date, display_type, width_ft, height_ft,
  standoff_ft, standoff_tol_ft, angle_tol_deg, instructions, status,
  merch_remarks, review_remarks,
  checkin_at, checkin_lat, checkin_lng, checkin_distance_m, checkin_accuracy_m,
  checkin_pass, checkin_device, checkin_source,
  submitted_at, approved_at, closed_at, completion_ref, created_at
)
select
  r.task_id,
  'T' || (1001 + r.i)::text,
  cam.id,
  r.store_id,
  ua.id,
  um.id,
  um.id,
  current_date + ((r.i % 9) - 4),
  r.display_type,
  r.w, r.h,
  case when r.i % 5 = 2 then 8.00 else 6.00 end,
  case when r.i % 5 = 2 then 0.75 else 0.50 end,
  5.0,
  (array[
    'Clear existing POSM. Fix the header board flush to the fixture top rail. Ensure the key visual is not obstructed by price rails.',
    'Install the vinyl edge-to-edge with no bubbles. Face up all SKUs to a minimum of two facings before shooting the after photo.',
    'Build a 5-tier stack, brand side facing the aisle entry. Secure the base with the supplied plinth. Do not block fire exits.',
    'Fit shelf strips across the full bay width. Align the strip baseline with the shelf lip. Remove all competitor strips first.',
    'Position the standee within 2 m of the category entry, weighted base engaged. Confirm store manager sign-off before leaving.',
    'Apply window vinyl from inside. Measure and mark before peeling. Squeegee from centre outwards, then trim the excess cleanly.'
  ])[(r.i % 6) + 1],
  r.status,
  case when r.status in ('Submitted', 'Rework Required', 'Approved', 'Closed') then
    (array[
      'Installation complete as per brief. Store manager approved placement. All SKUs faced up.',
      'Completed with minor adjustment — moved the unit 1 m left to clear the fire exit signage per store policy.',
      'Done. Header board fitted, all six facings live. Old competitor POSM removed and handed to the store.',
      'Executed fully. Slight bubble on the lower-left corner of the vinyl, smoothed on second pass.',
      'Display built and merchandised. Photos taken after full faceup. Awaiting your review.'
    ])[(r.i % 5) + 1]
  else '' end,
  case when r.status = 'Rework Required' then
    (array[
      'Header board is visibly misaligned and the left edge of the key visual is cut off. Please refit flush to the top rail and re-shoot in landscape.',
      'After photo does not show the full bay and two shelves are still carrying competitor stock. Clear the bay, face up and resubmit.'
    ])[(r.i % 2) + 1]
  else '' end,
  -- check-in exists for anything that has left 'Assigned'
  case when r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed')
       then now() - make_interval(days => (14 - (r.i % 12))) else null end,
  case when r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed')
       then round((st.lat + ((r.i * 11 % 21) - 10) / 10000.0)::numeric, 5)::double precision else null end,
  case when r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed')
       then round((st.lng + ((r.i * 17 % 21) - 10) / 10000.0)::numeric, 5)::double precision else null end,
  case when r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed')
       then 6 + (r.i * 13 % 120) else null end,
  case when r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed')
       then 5 + (r.i * 7 % 24) else null end,
  case when r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed')
       then true else null end,
  case when r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed')
       then 'Android · Chrome · NIVA Field 1.0' else null end,
  case when r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed')
       then 'device' else null end,
  case when r.status in ('Submitted', 'Rework Required', 'Approved', 'Closed')
       then now() - make_interval(days => (12 - (r.i % 10))) else null end,
  case when r.status in ('Approved', 'Closed')
       then now() - make_interval(days => (9 - (r.i % 8))) else null end,
  case when r.status = 'Closed'
       then now() - make_interval(days => (7 - (r.i % 6))) else null end,
  case when r.status = 'Closed'
       then 'NIVA-CR-T' || (1001 + r.i)::text || '-' ||
            lpad((abs(hashtext('T' || (1001 + r.i)::text)) % 9000 + 1000)::text, 4, '0')
       else null end,
  now() - make_interval(days => (16 - (r.i % 12)))
from _seed_rows r
join _seed_cities  c   on c.key = r.city_key
join public.stores st  on st.id = r.store_id
join public.campaigns cam on cam.code = r.campaign_code
join _seed_users ua on ua.code = r.assignee_code
join _seed_users um on um.code = case when r.i % 2 = 0 then 'u_m1' else 'u_m2' end
on conflict (id) do update
  set campaign_id = excluded.campaign_id, store_id = excluded.store_id,
      assignee_id = excluded.assignee_id, manager_id = excluded.manager_id,
      exec_date = excluded.exec_date, display_type = excluded.display_type,
      width_ft = excluded.width_ft, height_ft = excluded.height_ft,
      standoff_ft = excluded.standoff_ft, standoff_tol_ft = excluded.standoff_tol_ft,
      angle_tol_deg = excluded.angle_tol_deg, instructions = excluded.instructions,
      status = excluded.status, merch_remarks = excluded.merch_remarks,
      review_remarks = excluded.review_remarks,
      checkin_at = excluded.checkin_at, checkin_lat = excluded.checkin_lat,
      checkin_lng = excluded.checkin_lng, checkin_distance_m = excluded.checkin_distance_m,
      checkin_accuracy_m = excluded.checkin_accuracy_m, checkin_pass = excluded.checkin_pass,
      checkin_device = excluded.checkin_device, checkin_source = excluded.checkin_source,
      submitted_at = excluded.submitted_at, approved_at = excluded.approved_at,
      closed_at = excluded.closed_at, completion_ref = excluded.completion_ref,
      updated_at = now();

-- =====================================================================
-- 6. Placements, images, audit trail, notifications
-- =====================================================================
-- Re-running the seed rebuilds these three tables' seeded rows. Because
-- placements and audit_events are immutable (no UPDATE, no DELETE — for
-- anyone), they can only be inserted if they are not already there; the guards
-- below skip a task that already has them rather than trying to replace them.
-- That is the immutability guarantee working as designed, visible in the seed.

do $$
declare
  r            record;
  v_task       public.tasks%rowtype;
  v_tier       public.verification_tier;
  v_passed     boolean;
  v_mode       public.capture_mode;
  v_placement  uuid;
  v_ts         timestamptz;
  v_n_after    int;
  v_k          int;
  v_assignee   record;
  v_manager    record;
  v_dist       numeric;
  v_tol        numeric;
  v_atol       numeric;
  v_pitch      numeric;
  v_roll       numeric;
  v_yaw        numeric;
  v_yawver     boolean;
  v_rand       numeric;
begin
for r in select * from _seed_rows order by i loop
  select * into v_task from public.tasks where id = r.task_id;
  select * into v_assignee from _seed_users where code = r.assignee_code;
  select * into v_manager  from _seed_users
    where code = case when r.i % 2 = 0 then 'u_m1' else 'u_m2' end;

  v_ts   := v_task.created_at;
  v_tol  := v_task.standoff_tol_ft;
  v_atol := v_task.angle_tol_deg;
  v_rand := ((r.i * 29) % 100) / 100.0;         -- deterministic stand-in for the JS PRNG

  -- ---------- placement ----------
  v_placement := null;
  if r.status in ('Submitted', 'Rework Required', 'Approved', 'Closed')
     and not exists (select 1 from public.placements where task_id = r.task_id) then

    v_tier   := (array['As','A','B','As','Be','C','As','B'])[(r.i % 8) + 1]::public.verification_tier;
    v_passed := (r.i % 7) <> 5;

    v_mode := case
      when v_tier = 'As' then 'single-frame'::public.capture_mode
      when v_tier = 'A'  then 'handover'::public.capture_mode
      when v_tier = 'C'  then 'manual'::public.capture_mode
      else 'camera'::public.capture_mode
    end;

    if v_tier = 'C' then
      v_dist   := round(v_task.standoff_ft + (v_rand - 0.5) * 1.4, 2);
      v_passed := false;
      v_pitch  := null; v_roll := null; v_yaw := null; v_yawver := false;
    else
      v_dist := round(
        v_task.standoff_ft +
        case when v_passed then (v_rand - 0.5) * v_tol * 1.4
             else (v_tol + 0.4 + v_rand * 1.1) * (case when v_rand < 0.5 then -1 else 1 end) end, 2);
      v_pitch := round((v_rand - 0.5) * (case when v_passed then v_atol * 1.2 else v_atol * 3.4 end), 1);
      v_roll  := round((v_rand - 0.5) * (case when v_passed then v_atol * 1.0 else v_atol * 2.6 end), 1);
      if v_tier = 'Be' then
        v_yaw := null; v_yawver := false;
      else
        v_yaw := round((v_rand - 0.5) * (case when v_passed then v_atol * 1.1 else v_atol * 3.0 end), 1);
        v_yawver := true;
      end if;
      -- The overall gate is the AND of every gate, exactly as the client computes it.
      v_passed := abs(v_dist - v_task.standoff_ft) <= v_tol
                  and abs(v_pitch) <= v_atol
                  and abs(v_roll)  <= v_atol
                  and v_yawver and abs(v_yaw) <= v_atol;
    end if;

    insert into public.placements (
      task_id, tier, tier_label, capture_mode,
      distance_ft, target_ft, tol_ft, distance_ok, distance_source,
      pitch_deg, roll_deg, yaw_deg, angle_tol_deg,
      pitch_ok, roll_ok, yaw_ok, yaw_verified, angle_source, attitude_assumed,
      focal_px, focal_source, poster_w_ft, poster_h_ft,
      passed, geofence_pass, geofence_m, arm_ms,
      camera_w, camera_h, camera_readback_ms, camera_path, camera_aspect_agrees,
      camera_diagnostics, note, captured_at, created_by
    ) values (
      r.task_id, v_tier,
      case v_tier when 'Asd' then 'AR single-frame · depth'
                  when 'As'  then 'AR single-frame'
                  when 'Ad'  then 'AR depth'
                  when 'A'   then 'AR measured'
                  when 'Bq'  then 'Reference-scaled'
                  when 'B'   then 'Reference-scaled'
                  when 'Be'  then 'Estimated'
                  else 'Unverified' end,
      v_mode,
      v_dist, v_task.standoff_ft, v_tol,
      case when v_tier = 'C' then false else abs(v_dist - v_task.standoff_ft) <= v_tol end,
      case v_tier
        when 'C'  then 'manual entry (unverified)'
        when 'As' then 'WebXR hit-test (AR measured)'
        when 'A'  then 'WebXR hit-test (AR measured)'
        when 'B'  then 'reference-scaled — 4-handle quad (door leaf 900 × 2100 mm)'
        else           'reference-scaled — 2-handle (A4 short edge 210 mm)' end,
      v_pitch, v_roll, v_yaw, v_atol,
      coalesce(abs(v_pitch) <= v_atol, false),
      coalesce(abs(v_roll)  <= v_atol, false),
      coalesce(v_yawver and abs(v_yaw) <= v_atol, false),
      v_yawver,
      case when v_tier in ('As','A') then
             'yaw + tilt from the hit-test plane normal; roll from the gravity-aligned XR viewer pose'
           when v_tier = 'C' then 'assumed level (no sensor)'
           else 'device motion sensor' end,
      v_tier = 'C',
      case v_tier when 'C' then null
                  when 'Be' then 986
                  when 'B'  then 780 + (r.i * 19 % 180)
                  else 900 + (r.i * 23 % 220) end,
      case v_tier
        when 'C'  then '—'
        when 'As' then 'XR view projection matrix, rasterised over the raw camera image'
        when 'A'  then 'XR view projection matrix'
        when 'Be' then 'assumed 66° HFOV (estimated)'
        else           'device calibration' end,
      v_task.width_ft, v_task.height_ft,
      v_passed, true, v_task.checkin_distance_m,
      case when v_tier = 'C' then null else 800 end,
      case when v_tier = 'As' then 1920 else null end,
      case when v_tier = 'As' then 1080 else null end,
      case when v_tier = 'As' then 40 + (r.i * 31 % 70) else null end,
      case when v_tier = 'As' then 'direct' else null end,
      case when v_tier = 'As' then true else null end,
      case when v_tier = 'As'
           then jsonb_build_object('viewportW', 1920, 'viewportH', 1080,
                                   'aspectSkewPct', 0.4, 'attempts', 1)
           else '{}'::jsonb end,
      case v_tier
        when 'C'  then 'Captured on a device with no camera or sensor access. Distance and angle were entered by hand.'
        when 'Be' then 'Yaw obliqueness not verified — 2-handle reference mode cannot see keystone.'
        when 'A'  then 'Photographed after the AR session handed the camera back, so the frame is a fraction of a second later than the measurement.'
        else '' end,
      v_task.submitted_at,
      v_assignee.id
    ) returning id into v_placement;
  else
    select id into v_placement from public.placements where task_id = r.task_id
     order by tier_rank desc limit 1;
  end if;

  -- ---------- images ----------
  delete from public.task_images where task_id = r.task_id;

  if r.status <> 'Draft' or r.i % 2 = 0 then
    insert into public.task_images
      (task_id, kind, bucket_id, storage_path, lat, lng, device, captured_at, uploaded_by)
    values
      (r.task_id, 'before', 'evidence',
       'tasks/' || r.task_id || '/before/seed-000.jpg',
       (select lat from public.stores where id = r.store_id),
       (select lng from public.stores where id = r.store_id),
       'NIVA Web Console', v_task.created_at, v_manager.id);
  end if;

  insert into public.task_images
    (task_id, kind, bucket_id, storage_path, captured_at, uploaded_by)
  values
    (r.task_id, 'poster', 'poster-artwork',
     'campaigns/' || (select id from public.campaigns where code = r.campaign_code)
       || '/key-visual-' || r.campaign_code || '.jpg',
     v_task.created_at, v_manager.id);

  if r.status in ('Submitted', 'Rework Required', 'Approved', 'Closed') then
    v_n_after := 1 + (r.i % 3);
    for v_k in 0 .. v_n_after - 1 loop
      insert into public.task_images
        (task_id, kind, bucket_id, storage_path, clean_storage_path, placement_id,
         lat, lng, device, is_guided, captured_at, uploaded_by)
      values
        (r.task_id, 'after', 'evidence',
         'tasks/' || r.task_id || '/after/seed-' || lpad(v_k::text, 3, '0') || '.jpg',
         case when v_k = 0 and v_placement is not null
              then 'tasks/' || r.task_id || '/clean/seed-000.jpg' else null end,
         case when v_k = 0 then v_placement else null end,
         v_task.checkin_lat, v_task.checkin_lng,
         'Android · Chrome · NIVA Field 1.0',
         v_k = 0 and v_placement is not null,
         v_task.submitted_at, v_assignee.id);
    end loop;
  end if;

  -- ---------- audit trail ----------
  -- Immutable: only written if this task has no trail yet.
  if not exists (select 1 from public.audit_events where task_id = r.task_id) then
    v_ts := v_task.created_at;

    insert into public.audit_events (task_id, actor_id, actor_name, actor_role, action, detail, occurred_at)
    values (r.task_id, v_manager.id, v_manager.full_name, v_manager.role,
            'Task created',
            'Draft created for ' || r.store_name || ' · ' || r.display_type, v_ts);

    if r.status <> 'Draft' then
      v_ts := v_ts + interval '3 hours';
      insert into public.audit_events (task_id, actor_id, actor_name, actor_role, action, detail, occurred_at)
      values (r.task_id, v_manager.id, v_manager.full_name, v_manager.role,
              'Before image attached',
              'Baseline store photo captured and geo-tagged', v_ts);

      v_ts := v_ts + interval '5 hours';
      insert into public.audit_events (task_id, actor_id, actor_name, actor_role, action, detail, occurred_at)
      values (r.task_id, v_manager.id, v_manager.full_name, v_manager.role,
              'Task assigned',
              'Assigned to ' || v_assignee.full_name || ' · execution ' ||
              to_char(v_task.exec_date, 'DD Mon YYYY'), v_ts);
    end if;

    if r.status in ('In Progress', 'Submitted', 'Rework Required', 'Approved', 'Closed') then
      insert into public.audit_events
        (task_id, actor_id, actor_name, actor_role, action, detail, gps_lat, gps_lng, occurred_at)
      values (r.task_id, v_assignee.id, v_assignee.full_name, v_assignee.role,
              'Checked in at store',
              'Geofence PASS · ' || v_task.checkin_distance_m || ' m from store coordinates (device)',
              v_task.checkin_lat, v_task.checkin_lng, v_task.checkin_at);

      insert into public.audit_events (task_id, actor_id, actor_name, actor_role, action, detail, occurred_at)
      values (r.task_id, v_assignee.id, v_assignee.full_name, v_assignee.role,
              'Execution started', 'Status moved to In Progress',
              v_task.checkin_at + interval '2 minutes');
    end if;

    if r.status in ('Submitted', 'Rework Required', 'Approved', 'Closed') then
      if v_placement is not null then
        insert into public.audit_events
          (task_id, actor_id, actor_name, actor_role, action, detail, gps_lat, gps_lng, occurred_at)
        select r.task_id, v_assignee.id, v_assignee.full_name, v_assignee.role,
               'Guided capture recorded',
               'Tier ' || p.tier || ' (' || p.tier_label || ') · distance ' ||
               coalesce(to_char(p.distance_ft, 'FM9990.0'), '—') || ' ft vs target ' ||
               to_char(p.target_ft, 'FM9990.0') || ' ± ' || to_char(p.tol_ft, 'FM9990.00') ||
               ' ft [' || (case when p.distance_ok then 'PASS' else 'FAIL' end) || ']' ||
               ' · tilt ' || coalesce(to_char(p.pitch_deg, 'FM9990.0'), '—') ||
               '° [' || (case when p.pitch_ok then 'PASS' else 'FAIL' end) || ']' ||
               ' · roll ' || coalesce(to_char(p.roll_deg, 'FM9990.0'), '—') ||
               '° [' || (case when p.roll_ok then 'PASS' else 'FAIL' end) || ']' ||
               ' · yaw ' || (case when p.yaw_verified
                                  then coalesce(to_char(p.yaw_deg, 'FM9990.0'), '—') || '° [' ||
                                       (case when p.yaw_ok then 'PASS' else 'FAIL' end) || ']'
                                  else 'unverified' end) ||
               ' · poster ' || to_char(p.poster_w_ft, 'FM9990.0') || '×' ||
               to_char(p.poster_h_ft, 'FM9990.0') || ' ft' ||
               ' · f ' || coalesce(p.focal_px::text, '—') || ' px from ' || p.focal_source ||
               ' · distance from ' || p.distance_source ||
               ' · overall ' || (case when p.passed then 'VERIFIED' else 'NOT VERIFIED' end),
               v_task.checkin_lat, v_task.checkin_lng,
               v_task.submitted_at - interval '20 minutes'
          from public.placements p where p.id = v_placement;
      end if;

      insert into public.audit_events
        (task_id, actor_id, actor_name, actor_role, action, detail, gps_lat, gps_lng, occurred_at)
      values (r.task_id, v_assignee.id, v_assignee.full_name, v_assignee.role,
              'Execution submitted',
              (1 + (r.i % 3))::text || ' after image' || (case when (r.i % 3) > 0 then 's' else '' end) ||
              ' uploaded · awaiting manager approval',
              v_task.checkin_lat, v_task.checkin_lng, v_task.submitted_at);
    end if;

    if r.status = 'Rework Required' then
      insert into public.audit_events (task_id, actor_id, actor_name, actor_role, action, detail, occurred_at)
      values (r.task_id, v_manager.id, v_manager.full_name, v_manager.role,
              'Rework required', v_task.review_remarks,
              v_task.submitted_at + interval '9 hours');
    end if;

    if r.status in ('Approved', 'Closed') then
      insert into public.audit_events (task_id, actor_id, actor_name, actor_role, action, detail, occurred_at)
      values (r.task_id, v_manager.id, v_manager.full_name, v_manager.role,
              'Execution approved', 'Geofence PASS · imagery verified against brief',
              v_task.approved_at);
    end if;

    if r.status = 'Closed' then
      insert into public.audit_events (task_id, actor_id, actor_name, actor_role, action, detail, occurred_at)
      values (r.task_id, v_manager.id, v_manager.full_name, v_manager.role,
              'Task closed', 'Completion record ' || v_task.completion_ref || ' generated',
              v_task.closed_at);
    end if;
  end if;

  -- ---------- notifications ----------
  delete from public.notifications where task_id = r.task_id;

  if r.status = 'Submitted' then
    insert into public.notifications (kind, target_role, target_user_id, task_id, body, created_by, occurred_at, read_at)
    values ('Task Submitted', 'Manager', v_manager.id, r.task_id,
            r.store_name || ' (' || (select store_code from public.stores where id = r.store_id) ||
            ') submitted by ' || v_assignee.full_name, v_assignee.id, v_task.submitted_at, null),
           ('Approval Required', 'Manager', v_manager.id, r.task_id,
            'Approval required for ' || r.store_name || ' · ' || r.display_type,
            v_assignee.id, v_task.submitted_at, null);

  elsif r.status = 'Rework Required' then
    insert into public.notifications (kind, target_role, target_user_id, task_id, body, created_by, occurred_at, read_at)
    values ('Rework Required', 'Merchandiser', v_assignee.id, r.task_id,
            r.store_name || ' was returned for rework by ' || v_manager.full_name,
            v_manager.id, v_task.submitted_at + interval '9 hours', null);

  elsif r.status = 'Assigned' then
    insert into public.notifications (kind, target_role, target_user_id, task_id, body, created_by, occurred_at, read_at)
    values ('Task Assigned', 'Merchandiser', v_assignee.id, r.task_id,
            r.store_name || ' · ' || r.display_type || ' · due ' ||
            to_char(v_task.exec_date, 'DD Mon YYYY'),
            v_manager.id, v_task.created_at + interval '8 hours', null);

  elsif r.status = 'In Progress' then
    insert into public.notifications (kind, target_role, target_user_id, task_id, body, created_by, occurred_at, read_at)
    values ('Task Assigned', 'Merchandiser', v_assignee.id, r.task_id,
            r.store_name || ' · ' || r.display_type || ' · due ' ||
            to_char(v_task.exec_date, 'DD Mon YYYY'),
            v_manager.id, v_task.created_at + interval '8 hours', now());

  elsif r.status = 'Closed' then
    insert into public.notifications (kind, target_role, target_user_id, task_id, body, created_by, occurred_at, read_at)
    values ('Task Closed', 'Manager', v_manager.id, r.task_id,
            r.store_name || ' closed · record ' || v_task.completion_ref,
            v_manager.id, v_task.closed_at, now());
  end if;

end loop;
end $$;

-- =====================================================================
-- 7. Restore FORCE ROW LEVEL SECURITY
-- =====================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'stores', 'campaigns', 'tasks',
    'placements', 'task_images', 'audit_events', 'notifications'
  ] loop
    execute format('alter table public.%I force row level security', t);
  end loop;
end $$;

-- =====================================================================
-- 8. Summary
-- =====================================================================
do $$
declare
  v_forced int;
begin
  select count(*) into v_forced
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relforcerowsecurity
     and c.relname in ('profiles','stores','campaigns','tasks',
                       'placements','task_images','audit_events','notifications');

  raise notice 'seed complete: % profiles, % stores, % campaigns, % tasks, % placements, % images, % audit events, % notifications; %/8 tables have FORCE RLS',
    (select count(*) from public.profiles),
    (select count(*) from public.stores),
    (select count(*) from public.campaigns),
    (select count(*) from public.tasks),
    (select count(*) from public.placements),
    (select count(*) from public.task_images),
    (select count(*) from public.audit_events),
    (select count(*) from public.notifications),
    v_forced;

  if v_forced <> 8 then
    raise exception 'FORCE ROW LEVEL SECURITY was not restored on every table (% of 8)', v_forced;
  end if;
end $$;

commit;
