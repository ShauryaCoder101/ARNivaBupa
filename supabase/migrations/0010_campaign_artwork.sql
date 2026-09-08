
-- =====================================================================
-- NIVA Field Execution — 0010_campaign_artwork.sql
-- Where a poster's artwork lives, written on the poster.
-- Idempotent and safe to re-run.
--
-- Depends on: 0001_schema.sql, 0003_storage.sql
--
-- Why this column exists
-- ----------------------
-- Until now the ONLY record of a campaign's key visual was the task_images
-- rows hanging off the tasks it had been handed to. That is a fine place to
-- keep it once somebody has the poster, and no place at all before anybody
-- does: "publish to everyone" pressed on a project with no merchandisers yet
-- uploads the artwork to Storage, sets audience_all, and creates not one row
-- that points at the object. The first person hired afterwards then gets the
-- poster with a blank overlay — the campaign knows it is for everyone and has
-- forgotten what it looks like.
--
-- The artwork is a fact about the poster, exactly as its printed size and its
-- audience are, so it is stored on the poster. task_images stays: it is what
-- a TASK shows, and it is per-task by design (one stored object, many tasks
-- pointing at it — see task_images_task_path_unique in 0001).
--
-- Nullable, deliberately. A poster with no artwork yet is legal; the mockup
-- screen simply has nothing to superimpose, which is what
-- provision-poster's `artworkPath` being optional already says.
-- =====================================================================

begin;

alter table public.campaigns
  add column if not exists artwork_path text;

comment on column public.campaigns.artwork_path is
  'Storage object key of this poster''s artwork in the poster-artwork bucket, '
  'laid out as campaigns/<campaign_id>/<uuid>.jpg. Written by the browser '
  'after it uploads, read by sync-posters when it hands the poster to a '
  'merchandiser who did not exist when it was published. Null means no '
  'artwork has been attached yet, which is legal.';

-- Backfill from the artwork rows that already exist, so posters published
-- before this migration are not left looking artwork-less to the next hire.
-- distinct on: any one of a campaign's poster rows will do — they all point at
-- the same object — and the oldest is the one the publish actually wrote.
update public.campaigns c
   set artwork_path = a.storage_path
  from (
    select distinct on (t.campaign_id) t.campaign_id, i.storage_path
      from public.task_images i
      join public.tasks t on t.id = i.task_id
     where i.kind = 'poster'
       and i.bucket_id = 'poster-artwork'
     order by t.campaign_id, i.recorded_at
  ) a
 where a.campaign_id = c.id
   and c.artwork_path is null;

commit;

-- =====================================================================
-- Verification
-- =====================================================================
-- select code, name, audience_all, artwork_path from public.campaigns
--  order by created_at;
-- Expect: every campaign that has ever been handed to somebody now carries a
-- path; ones published to nobody yet are null until the next publish, and
-- sync-posters finds those by listing the bucket.

NOTE ON GRANTS: none needed. 0002 already grants `select, insert, update, delete on public.campaigns to authenticated` at table level and campaigns_update_owner permits a whole-row update by the owner, so a manager may PATCH the new column. No column guard trigger exists on campaigns.