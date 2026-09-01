-- =====================================================================
-- NIVA Field Execution — 0008_poster_audience.sql
-- "Publish this poster to everyone, including people hired later."
-- Idempotent and safe to re-run.
--
-- Depends on: 0001_schema.sql
--
-- Why a column and not a list
-- ---------------------------
-- A manager publishing a poster picks who gets it, and the ordinary case is a
-- tick-list of merchandisers — which needs no schema at all, because ticking
-- somebody just means provisioning them a task. "Everyone" is different: it is
-- a STANDING RULE, not a set of names. The people it applies to do not all
-- exist yet.
--
-- So when a merchandiser is created months later, something has to answer
-- "which posters should this new person already have?" — and the honest answer
-- cannot be reconstructed from the tasks that exist, because a poster ticked
-- for every current merchandiser and a poster published to everyone look
-- identical the day they are made and diverge on the next hire. That
-- distinction is a fact about the poster, so it is stored on the poster.
--
-- A poster is a campaign: campaigns already carry the poster's size, its
-- artwork bucket and is_active (which is what archiving toggles).
-- =====================================================================

begin;

alter table public.campaigns
  add column if not exists audience_all boolean not null default false;

comment on column public.campaigns.audience_all is
  'True when this poster was published to every merchandiser rather than to a '
  'chosen few. Read when a NEW merchandiser is created, to provision the '
  'posters they should already have. False means the audience is exactly the '
  'set of tasks that exist for this campaign.';

-- Partial: the provisioning path for a new hire asks only for posters that are
-- both open to everyone and not archived, and that is a small slice of a table
-- that only grows.
create index if not exists campaigns_audience_all_idx
  on public.campaigns (audience_all)
  where audience_all and is_active;

commit;

-- =====================================================================
-- Verification — expect one row, audience_all = false on existing campaigns
-- =====================================================================
-- select code, name, is_active, audience_all from public.campaigns order by created_at;
