-- =====================================================================
-- NIVA Field Execution — 0009_self_signup.sql
-- The office a merchandiser works out of, and the hole that letting them
-- create their own account would otherwise open.
-- Idempotent and safe to re-run.
--
-- Depends on: 0001_schema.sql, 0004_functions.sql, 0007_phone_identity.sql
--
-- Two changes arrive together because self-service sign-up needs both of them:
--
--   1. profiles.office_address — asked once, on the sign-up form, so that the
--      capture screen does not ask a second time for something the person has
--      already typed.
--
--   2. A rewritten niva_handle_new_user, because as 0004 shipped it the
--      BROWSER chooses its own role. That is the whole security content of
--      this migration and it is explained at length below.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. profiles.office_address
-- ---------------------------------------------------------------------
-- Nullable, because it has to be: every account that exists today was made by
-- a manager who was never asked for one, and a manager has no field office at
-- all. "Not stated" is a real answer and the client falls back to asking.
alter table public.profiles
  add column if not exists office_address text;

comment on column public.profiles.office_address is
  'Where this person works, as they typed it when they created their account. '
  'The DEFAULT offered for task_images.office_name (0007), not a replacement '
  'for it: a merchandiser shoots in more than one place, and the location on a '
  'photograph has to be a fact about that photograph. Null for accounts made '
  'before self-service sign-up, and for everyone who signs in with an email.';

-- Bounds, not a format. An address is prose and the database has no business
-- having an opinion about its shape; what it can usefully refuse is the empty
-- string dressed up as whitespace, and a paste of an entire document. The
-- client mirrors these bounds in signupCheck() and refuses first.
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conrelid = 'public.profiles'::regclass
       and conname  = 'profiles_office_address_len'
  ) then
    alter table public.profiles
      add constraint profiles_office_address_len
      check (office_address is null
             or char_length(btrim(office_address)) between 2 and 200);
  end if;
end $$;

-- NO BACKFILL, for the same reason 0006 refused one. task_images.office_name
-- holds offices these merchandisers really did type, and copying the most
-- recent one onto their profile would put an answer in the account that
-- nobody gave to the question the account is asking.

-- NO NEW POLICY AND NO NEW GRANT, for the reason set out at length in
-- 0006_profile_height.sql §2: `grant select, insert, update on public.profiles
-- to authenticated` is column-unrestricted and a new column inherits it;
-- profiles_update_self scopes writes to the caller's own row; and column-level
-- authority lives in trg_profiles_guard, which inspects `id` and `role` and
-- nothing else. Adding office_address neither widens nor narrows any of that.

-- ---------------------------------------------------------------------
-- 2. THE ROLE MUST NOT COME FROM THE BROWSER
-- ---------------------------------------------------------------------
-- ATTACK PREVENTED, and it is not hypothetical — it is one curl against a key
-- that is published in the app's own HTML:
--
--   POST /auth/v1/signup
--   apikey: <the anon key, which is in niva-merch-app.html by design>
--   { "email": "...", "password": "...", "data": { "role": "Admin" } }
--
-- GoTrue copies `data` into auth.users.raw_user_meta_data verbatim, and
-- niva_handle_new_user as written in 0004 read the new profile's role straight
-- back out of that column. So the caller of a PUBLIC endpoint was choosing
-- their own row in a table the entire authorisation model is keyed off.
--
-- niva_profiles_guard does not catch it. Its INSERT branch forces
-- 'Merchandiser' only when auth.uid() is non-null; a GoTrue signup runs with
-- no request JWT, the guard takes its `v_uid is null -> return new` early exit
-- as a trusted server context, and the role survives.
--
-- THE FIX IS TO CHANGE WHICH COLUMN IS TRUSTED. auth.users has two metadata
-- columns and they differ in exactly the way that matters here:
--
--   raw_user_meta_data   the signing-up client writes it. Untrusted.
--   raw_app_meta_data    only the service role can write it — the GoTrue admin
--                        API, i.e. our Edge Functions. Trusted.
--
-- So a privileged role must arrive in app metadata. Anything the browser says
-- about itself is a REQUEST, and it is granted only when it asks for the least
-- privilege we have, so that a hand-rolled signup posting {"role":"Admin"}
-- lands as a Merchandiser instead of as an administrator.
--
-- create-merchandiser is unaffected: it passes user_metadata
-- {role:'Merchandiser'}, which is exactly the one value still honoured, and it
-- then upserts the same role, so trg_profiles_guard sees no change either.
--
-- ALSO TURN "Enable email signups" OFF (Authentication -> Providers). Both
-- Edge Functions use the ADMIN API, which that switch does not gate, so
-- disabling it closes the raw GoTrue endpoint without closing sign-up in the
-- app. That is configuration and cannot be asserted from a migration, which is
-- precisely why the trigger below has to hold on its own.

create or replace function public.niva_handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claimed text;
  v_role    public.niva_role;
begin
  -- Trusted channel first: app metadata is service-role-only.
  v_claimed := nullif(new.raw_app_meta_data ->> 'role', '');

  -- Untrusted channel second, and clamped. 'Merchandiser' is the only thing a
  -- self-registering client may ask to be; every other answer, including a
  -- misspelt one, is discarded rather than argued with.
  if v_claimed is null then
    v_claimed := nullif(new.raw_user_meta_data ->> 'role', '');
    if v_claimed is distinct from 'Merchandiser' then
      v_claimed := null;
    end if;
  end if;

  begin
    v_role := v_claimed::public.niva_role;
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

  -- phone (0007) and office_address (here) are deliberately NOT taken from
  -- metadata. Both are client-supplied on the sign-up path, phone is UNIQUE,
  -- and a collision raised inside an AFTER INSERT trigger on auth.users fails
  -- the whole signup with a message nobody can act on. The Edge Function
  -- upserts them afterwards, where a duplicate is an answer rather than a 500.
  return new;
end;
$$;

-- Re-created rather than assumed: the trigger points at the function by name,
-- so replacing the body is enough, but a project that applied 0004 before
-- auth.users existed has no trigger at all and this is where it notices.
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

commit;

-- =====================================================================
-- Verification — run these after applying
-- =====================================================================
-- select count(*) = 1 from information_schema.columns
--  where table_schema='public' and table_name='profiles' and column_name='office_address';
--
-- -- the length check bites (expect: violates check constraint)
-- -- update public.profiles set office_address = ' ' where role = 'Merchandiser';
--
-- -- THE ESCALATION TEST. With email signups temporarily enabled, against the
-- -- anon key and no session:
-- --   POST /auth/v1/signup {"email":"x@example.com","password":"...",
-- --                         "data":{"role":"Admin","full_name":"x"}}
-- -- then, as an admin:
-- --   select role from public.profiles where id = '<the new user>';
-- --   -- expect: Merchandiser.  Before 0009 this returned Admin.
-- =====================================================================