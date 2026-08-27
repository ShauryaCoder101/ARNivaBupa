-- =====================================================================
-- NIVA Field Execution — 0003_storage.sql
-- Buckets + storage.objects policies. Idempotent and safe to re-run.
--
-- TWO BUCKETS
-- -----------
--   poster-artwork   PUBLIC.  Campaign key visuals. These are the artwork the
--                    brand wants on the wall; they are already going to be
--                    printed at A1 and stuck in a shop window. Public read
--                    keeps the client simple (a plain <img src> with no signed
--                    URL round-trip) and leaks nothing.
--
--   evidence         PRIVATE. Geotagged photographs of real retail sites,
--                    with a store code, a merchandiser's name and a GPS fix
--                    stamped into the frame. Public read on this bucket would
--                    publish a map of a client's retail estate and put a name
--                    to who was standing in it. Served exclusively through
--                    short-lived signed URLs created per view
--                    (`/storage/v1/object/sign/evidence/<path>`), which are
--                    themselves gated by the SELECT policy below.
--
-- PATH CONVENTION  (this is the contract the policies enforce — the client
-- must build paths exactly like this or the upload is refused)
-- ---------------------------------------------------------------------
--   evidence:        tasks/<task_id>/<kind>/<uuid>.jpg
--                    kind in ('before', 'after', 'clean')
--                      before — baseline store photo, uploaded by the manager
--                      after  — the stamped execution photo
--                      clean  — the un-stamped original of a guided capture,
--                               kept so a reviewer can check the overlay
--                    e.g. tasks/7c1f.../after/0f3a9b12-....jpg
--
--   poster-artwork:  campaigns/<campaign_id>/<uuid>.jpg
--                    e.g. campaigns/a91b.../key-visual-2026-monsoon.jpg
--
-- The task id is IN THE PATH on purpose. It is the only way a storage policy
-- can decide anything: storage.objects has no foreign key to public.tasks, so
-- the object's own name has to carry the join key. Everything after the third
-- segment is free-form and the policies ignore it.
-- =====================================================================

set local check_function_bodies = off;

do $$
begin
  if to_regclass('storage.objects') is null then
    raise exception
      'storage.objects not found. Run 0003_storage.sql against a Supabase project (the Storage extension provides the storage schema).';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Path helpers
-- ---------------------------------------------------------------------
-- split_part lives in pg_catalog, which is always on the search_path even when
-- search_path is empty, so these are safe with a pinned empty search_path and
-- have no dependency on storage.foldername().

create or replace function public.niva_path_segment(p_name text, p_index integer)
returns text
language sql immutable
set search_path = ''
as $$ select split_part(p_name, '/', p_index) $$;

-- A path segment that is not a UUID must not blow up policy evaluation with a
-- cast error (which would surface as a 500, not a 403). Return NULL instead;
-- every downstream visibility helper treats NULL as "no such task" => deny.
create or replace function public.niva_uuid_or_null(p_text text)
returns uuid
language plpgsql immutable
set search_path = ''
as $$
begin
  return p_text::uuid;
exception when others then
  return null;
end;
$$;

-- The task a given evidence object belongs to, or NULL if the path does not
-- follow the convention.
create or replace function public.niva_evidence_task_id(p_name text)
returns uuid
language sql immutable
set search_path = ''
as $$
  select case
           when public.niva_path_segment(p_name, 1) = 'tasks'
             then public.niva_uuid_or_null(public.niva_path_segment(p_name, 2))
           else null
         end;
$$;

create or replace function public.niva_artwork_campaign_id(p_name text)
returns uuid
language sql immutable
set search_path = ''
as $$
  select case
           when public.niva_path_segment(p_name, 1) = 'campaigns'
             then public.niva_uuid_or_null(public.niva_path_segment(p_name, 2))
           else null
         end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'niva_path_segment(text,integer)', 'niva_uuid_or_null(text)',
    'niva_evidence_task_id(text)', 'niva_artwork_campaign_id(text)'
  ] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('revoke all on function public.%s from anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Buckets
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('poster-artwork', 'poster-artwork', true,  20971520,
   array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']),
  ('evidence',       'evidence',       false, 20971520,
   array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------------------------------------------------------------------
-- Policies on storage.objects
-- ---------------------------------------------------------------------
-- NOTE ON `FORCE ROW LEVEL SECURITY`: it is applied to every table in
-- public (0001) but deliberately NOT to storage.objects. That table is owned
-- and operated by `supabase_storage_admin`, and forcing RLS on it would apply
-- these policies to the Storage service's own bookkeeping (multipart cleanup,
-- bucket deletion, migrations) and break it. RLS is already ENABLEd there by
-- Supabase, which is what gates client requests; the owner is the service
-- itself and is trusted by construction.

drop policy if exists niva_artwork_read      on storage.objects;
drop policy if exists niva_artwork_write     on storage.objects;
drop policy if exists niva_artwork_update    on storage.objects;
drop policy if exists niva_artwork_delete    on storage.objects;
drop policy if exists niva_evidence_read     on storage.objects;
drop policy if exists niva_evidence_write_field on storage.objects;
drop policy if exists niva_evidence_write_mgr   on storage.objects;
drop policy if exists niva_evidence_delete_field on storage.objects;

-- ---- poster-artwork -------------------------------------------------
-- The bucket is public, so anonymous GETs on /object/public/... are served by
-- the Storage service without consulting RLS at all. This policy governs
-- authenticated listing and the signed-URL path.
create policy niva_artwork_read on storage.objects
  for select to authenticated
  using (bucket_id = 'poster-artwork');

-- Only the campaign's owner (or an admin) may put artwork under that
-- campaign's prefix. ATTACK PREVENTED: any signed-in user overwriting a rival
-- campaign's key visual, which would then be printed and installed in shops.
create policy niva_artwork_write on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'poster-artwork'
    and public.niva_artwork_campaign_id(name) is not null
    and (
      (select public.niva_is_admin())
      or public.niva_owns_campaign(public.niva_artwork_campaign_id(name))
    )
  );

create policy niva_artwork_update on storage.objects
  for update to authenticated
  using (
    bucket_id = 'poster-artwork'
    and ((select public.niva_is_admin())
         or public.niva_owns_campaign(public.niva_artwork_campaign_id(name)))
  )
  with check (
    bucket_id = 'poster-artwork'
    and public.niva_artwork_campaign_id(name) is not null
    and ((select public.niva_is_admin())
         or public.niva_owns_campaign(public.niva_artwork_campaign_id(name)))
  );

create policy niva_artwork_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'poster-artwork'
    and ((select public.niva_is_admin())
         or public.niva_owns_campaign(public.niva_artwork_campaign_id(name)))
  );

-- ---- evidence -------------------------------------------------------
-- READ. Exactly the same audience as the task itself: the assigned
-- merchandiser, the task's manager, the owning campaign's manager, and admins.
-- A signed URL can only be minted for an object the requester passes this
-- policy for, so the "private bucket + signed URL" story is only as strong as
-- this line — which is why it reuses the canonical task-visibility helper
-- rather than restating the rule.
create policy niva_evidence_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'evidence'
    and public.niva_task_visible(public.niva_evidence_task_id(name))
  );

-- WRITE (field). ATTACK PREVENTED: a merchandiser uploading into another
-- merchandiser's task prefix — either to plant evidence on a colleague's job
-- or to fill someone else's storage quota. The prefix must resolve to a task
-- that is assigned to THIS caller and is currently In Progress or Rework
-- Required, so evidence also cannot be back-filled onto an approved task.
create policy niva_evidence_write_field on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'evidence'
    and public.niva_path_segment(name, 1) = 'tasks'
    and public.niva_path_segment(name, 3) in ('after', 'clean')
    and public.niva_path_segment(name, 4) <> ''      -- a filename must follow
    and public.niva_task_open_for_me(public.niva_evidence_task_id(name))
  );

-- WRITE (manager). Baseline "before" photos are attached by the manager while
-- the task is still being prepared.
create policy niva_evidence_write_mgr on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'evidence'
    and public.niva_path_segment(name, 1) = 'tasks'
    and public.niva_path_segment(name, 3) = 'before'
    and public.niva_path_segment(name, 4) <> ''
    and public.niva_task_managed_by_me(public.niva_evidence_task_id(name))
  );

-- NO UPDATE POLICY on the evidence bucket. An upload with `upsert: true`
-- issues an UPDATE against an existing object; refusing it means an evidence
-- photo can never be swapped for a different one at the same path. Clients
-- MUST generate a fresh UUID filename per capture and MUST NOT set upsert.
--
-- DELETE is allowed only for the assigned merchandiser, only for their own
-- object, and only while the task is still open — mirroring
-- public.task_images_delete_field so the row and the byte stay in step. Once
-- the task is Submitted, nobody (manager, admin, or service_role via
-- PostgREST) can remove the photograph.
create policy niva_evidence_delete_field on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'evidence'
    and public.niva_path_segment(name, 3) in ('after', 'clean')
    and owner_id = (select auth.uid())::text
    and public.niva_task_open_for_me(public.niva_evidence_task_id(name))
  );
