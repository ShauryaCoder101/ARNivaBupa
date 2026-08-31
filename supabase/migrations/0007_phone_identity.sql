-- =====================================================================
-- NIVA Field Execution — 0007_phone_identity.sql
-- Merchandisers identified by PHONE NUMBER, photos tagged with an OFFICE.
-- Idempotent and safe to re-run.
--
-- Depends on: 0001_schema.sql, 0002_rls.sql, 0006_profile_height.sql
--
-- What this migration is for
-- --------------------------
-- Three field-driven changes arrive together because they touch the same two
-- tables:
--
--   1. profiles.phone — a merchandiser signs in with a phone number, not an
--      email. GoTrue still authenticates on an address, so the app maps the
--      number to a synthetic one (919876543210@phone.niva.internal) that is
--      never delivered to and never displayed. The COLUMN here is the readable,
--      queryable copy: it is what a manager sorts and searches on, and what the
--      create-merchandiser Edge Function checks for collisions before it mints
--      a login.
--
--   2. task_images.office_name — the location a photo was taken at, typed by
--      the merchandiser. Offices are small interior rooms; GPS indoors is
--      20-50 m at best and frequently unavailable, so a coordinate cannot be
--      the organising fact. The typed name is the sort key and this is where it
--      lives.
--
--   3. task_images.location_source — HOW that location was established. The app
--      used to substitute a jittered coordinate near the store whenever the
--      device refused to give one, which reads in the database as a real fix.
--      It no longer does: either the device gave a position, or the person
--      stated it, and the row says which.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. profiles.phone
-- ---------------------------------------------------------------------
-- Nullable on purpose. Managers and admins sign in with real email addresses
-- and legitimately have no phone on file; only a merchandiser's account is
-- keyed to one. A NOT NULL here would make every existing manager row invalid
-- the moment this ran.
alter table public.profiles
  add column if not exists phone text;

comment on column public.profiles.phone is
  'Canonical E.164 digits, no + and no separators (e.g. 919876543210). The '
  'merchandiser''s login identity: the app derives the GoTrue address from it. '
  'Null for accounts that sign in with an email.';

-- Digits only, and long enough to carry a country code. The app normalises
-- before it ever gets here (phoneDigits in niva-merch-app.html, reimplemented
-- in the create-merchandiser function) — this CHECK is the backstop for a row
-- written by hand in the SQL editor, which is exactly how a "+91 " prefix or a
-- stray space would otherwise get in and split one person into two accounts.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.profiles'::regclass
       and conname  = 'profiles_phone_digits'
  ) then
    alter table public.profiles
      add constraint profiles_phone_digits
      check (phone is null or phone ~ '^[1-9][0-9]{10,14}$');
  end if;
end $$;

-- UNIQUE, because the phone number IS the login. Two profiles sharing one
-- number would mean two accounts resolving to the same synthetic address, and
-- whichever was created second could never be signed into. Partial, so the many
-- email-based accounts with a null phone do not collide with one another.
create unique index if not exists profiles_phone_key
  on public.profiles (phone)
  where phone is not null;

-- ---------------------------------------------------------------------
-- 2. task_images.office_name and .location_source
-- ---------------------------------------------------------------------
alter table public.task_images
  add column if not exists office_name text;

alter table public.task_images
  add column if not exists location_source text;

comment on column public.task_images.office_name is
  'Where the photo was taken, as typed by the merchandiser. The sort key for '
  'the manager''s photo list; lat/lng corroborate it but cannot replace it '
  'because indoor GPS is neither reliable nor readable.';

comment on column public.task_images.location_source is
  'How the position was established: device = a real fix from the handset, '
  'stated = the device would not give one and the merchandiser entered the '
  'location by hand. Null on rows written before 0007.';

-- 'simulated' is accepted but is NOT a value the field app can write any more.
-- It exists so that seed and demo rows created by the prototype remain legal
-- and keep saying what they are, rather than being silently re-labelled as
-- device fixes by a constraint that refused to admit they existed.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.task_images'::regclass
       and conname  = 'task_images_location_source'
  ) then
    alter table public.task_images
      add constraint task_images_location_source
      check (location_source is null
             or location_source in ('device', 'stated', 'simulated'));
  end if;
end $$;

-- The manager's photo list sorts by office, then by recency, across every
-- merchandiser. Without this that page is a full scan of every image row in the
-- programme on each sort click.
create index if not exists task_images_office_captured_idx
  on public.task_images (office_name, captured_at desc);

commit;

-- =====================================================================
-- Verification — run these after applying, they should all return true
-- =====================================================================
-- select count(*) = 1 from information_schema.columns
--  where table_schema='public' and table_name='profiles' and column_name='phone';
--
-- select count(*) = 2 from information_schema.columns
--  where table_schema='public' and table_name='task_images'
--    and column_name in ('office_name','location_source');
--
-- -- the unique index really is partial, so many null phones can coexist
-- select indexdef like '%WHERE (phone IS NOT NULL)%'
--   from pg_indexes where indexname='profiles_phone_key';
--
-- -- and the digits check actually bites
-- -- (expect: ERROR  new row violates check constraint "profiles_phone_digits")
-- -- update public.profiles set phone = '+91 98765 43210' where role='Merchandiser';
