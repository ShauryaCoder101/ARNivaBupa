/* ============================================================================
   sync-posters — make the standing rule true, again and again.

   WHAT IT IS FOR
   --------------
   "Publish this poster to everyone" is a rule about PEOPLE WHO DO NOT EXIST
   YET (0008_poster_audience.sql says why it has to be a column and not a list
   of names). provision-poster applies that rule to whoever exists the minute
   the manager presses the button. This is the other half: given a
   merchandiser, it hands them every live audience_all poster they do not
   already have.

   WHY IT RUNS AT SIGN-IN AND NOT ONLY AT ACCOUNT CREATION
   -------------------------------------------------------
   Account creation is one moment, and a moment can fail. It fails when the
   network drops between creating the login and provisioning the poster; it
   fails when the account is made by something that is not
   create-merchandiser at all — a self-signup form, a row typed into the SQL
   editor, a build deployed before 0008 existed; it fails for a merchandiser
   who was deactivated on the day a poster went out to everyone and
   reactivated the week after, because provision-poster's `all` branch only
   ever sees active people. Every one of those leaves a person who can sign in
   and will never, by any path the app offers, see a poster their colleagues
   have.

   Sign-in happens again tomorrow. So the reconciliation lives there: cheap,
   idempotent, self-healing, and it needs nobody to remember to press
   anything.

   IDEMPOTENT, WHICH IS THE WHOLE DESIGN
   -------------------------------------
   tasks are unique on (campaign_id, store_id) and this function reads before
   it writes, at both levels: one synthetic store per merchandiser reused if
   it is there, one task per (poster x merchandiser) reused if it is there,
   one artwork row per task reused if it is there. Running it a hundred times
   hands out nothing twice. That is what makes it safe to fire on every single
   sign-in, and what makes it safe for create-merchandiser to have already
   done the same work a second earlier.

   WHO MAY ASK, AND FOR WHOM
   -------------------------
   A merchandiser may ask for THEMSELVES and only themselves — the body is
   ignored for them, so there is no argument they can pass that provisions
   somebody else, and the worst they can do to their own account is give
   themselves posters their manager already published to everyone. A manager
   or admin may name one person (`merchandiserId`) or everybody (`all: true`),
   which is the top-up path create-merchandiser's caller uses.

   Authorisation is done here, in the same shape as create-merchandiser and
   provision-poster: the caller's JWT out of the Authorization header, resolved
   through GoTrue so a forged token fails at the source, then THAT user's
   profile row.

   BEST EFFORT, PER PERSON AND PER POSTER. Nothing here is allowed to turn
   into a failed sign-in. Every failure is collected and reported in a 200.

   Deploy:  supabase functions deploy sync-posters
   Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY are injected by the platform.
   ========================================================================== */
import { createClient } from "jsr:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...CORS, "Content-Type": "application/json" },
  });
}

/* MUST MATCH provision-poster's short(). The synthetic store's code is derived
   from the merchandiser's uuid, and if the two functions disagree about how,
   the same person ends up with two stores and therefore two tasks for one
   poster — which the (campaign_id, store_id) unique index cannot catch,
   because the store ids differ. */
const short = (id: string) => String(id).replace(/-/g, "").slice(0, 6).toUpperCase();

const ARTWORK_BUCKET = "poster-artwork";

/* artwork_path is 0009 and may be absent; everything else is 0001. */
const CAMPAIGN_COLS =
  "id, name, owner_id, poster_w_ft, poster_h_ft, standoff_ft, standoff_tol_ft, angle_tol_deg";

type Campaign = {
  id: string;
  name: string;
  owner_id: string | null;
  poster_w_ft: number;
  poster_h_ft: number;
  standoff_ft: number;
  standoff_tol_ft: number;
  angle_tol_deg: number;
  artwork_path?: string | null;
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "POST only." });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply(500, { error: "Function is not configured." });

  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  /* ---- 1. who is asking? ---- */
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return reply(401, { error: "Sign in first." });

  const { data: caller, error: callerErr } = await admin.auth.getUser(jwt);
  if (callerErr || !caller?.user) return reply(401, { error: "That sign-in is not valid any more." });

  const { data: me } = await admin.from("profiles")
    .select("id, role, is_active").eq("id", caller.user.id).single();
  if (!me) return reply(403, { error: "This account has no profile." });
  if (me.is_active === false) return reply(403, { error: "This account is not active." });

  /* ---- 2. …and for whom? ----
     An empty body is legal and is the merchandiser's own case; the app sends
     `{}` on every sign-in. */
  let body: Record<string, unknown> = {};
  try { body = (await req.json()) || {}; } catch { body = {}; }

  const isManager = me.role === "Manager" || me.role === "Admin";
  let targets: string[];

  if (me.role === "Merchandiser") {
    /* THE BODY IS IGNORED HERE, DELIBERATELY. A merchandiser reconciles their
       own account and nothing else, so there is no id they can pass that
       provisions anybody. */
    targets = [me.id];
  } else if (isManager) {
    if (body.all === true) {
      const { data: everyone } = await admin.from("profiles")
        .select("id").eq("role", "Merchandiser").eq("is_active", true);
      targets = (everyone || []).map((r: { id: string }) => r.id);
    } else if (body.merchandiserId) {
      targets = [String(body.merchandiserId)];
    } else {
      return reply(400, { error: "Which merchandiser?" });
    }
  } else {
    return reply(403, { error: "This account cannot be given posters." });
  }

  /* Nobody to reconcile is not a failure. A manager asking for `all` on a
     project with no merchandisers yet has asked a perfectly sensible question
     and the answer is zero. */
  if (!targets.length) return reply(200, { provisioned: 0, posters: [], failed: [] });

  /* ---- 3. which posters are open to everyone? ----
     THE DOWNGRADE IS ON PURPOSE, twice over. artwork_path is 0009 and
     audience_all is 0008, and a project missing either must not turn a
     sign-in into an error the person cannot act on. Missing artwork_path
     costs one extra lookup per poster; missing audience_all means there is no
     standing rule in this project at all, so there is nothing to reconcile. */
  const openQuery = (cols: string) => admin.from("campaigns")
    .select(cols).eq("audience_all", true).eq("is_active", true);

  let posters: Campaign[] = [];
  const withArt = await openQuery(CAMPAIGN_COLS + ", artwork_path");
  if (!withArt.error) {
    posters = (withArt.data || []) as unknown as Campaign[];
  } else {
    const plain = await openQuery(CAMPAIGN_COLS);
    if (!plain.error) {
      posters = (plain.data || []) as unknown as Campaign[];
    } else {
      return reply(200, {
        provisioned: 0, posters: [], failed: [],
        unsupported: plain.error.message,
      });
    }
  }
  if (!posters.length) return reply(200, { provisioned: 0, posters: [], failed: [] });

  /* ---- 4. who gets attributed as the manager on a task made this way? ----
     tasks.manager_id is NOT NULL. At publish time it is the manager pressing
     the button; here there may be no manager in the room at all, because the
     caller is the merchandiser signing in. The poster's own owner is the
     honest answer; a manager caller is the next best; any active manager is
     the last resort, and if a project somehow has none the poster is skipped
     rather than attributed to a merchandiser. */
  let fallbackManager: string | null = isManager ? me.id : null;
  let fallbackLookedUp = false;
  async function managerFor(c: Campaign): Promise<string | null> {
    if (c.owner_id) return c.owner_id;
    if (fallbackManager) return fallbackManager;
    if (fallbackLookedUp) return null;
    fallbackLookedUp = true;
    const { data } = await admin.from("profiles")
      .select("id").in("role", ["Manager", "Admin"]).eq("is_active", true)
      .order("created_at", { ascending: true }).limit(1);
    fallbackManager = data && data.length ? data[0].id : null;
    return fallbackManager;
  }

  /* ---- 5. where is each poster's artwork? ----
     Resolved once per poster per request, in descending order of how much the
     answer is worth trusting:

       1. campaigns.artwork_path (0009) — the poster saying so itself;
       2. a task_images row on any task of this campaign — what the poster's
          existing holders are actually looking at, and what backfilled (1);
       3. the bucket. poster-artwork is laid out campaigns/<id>/<uuid>.jpg
          (0003_storage.sql), so a poster published to everyone on a day when
          nobody existed — no tasks, therefore no task_images, therefore
          nothing for (2) to find — is still recoverable from the object that
          publish uploaded.

     Null is a legitimate answer: a poster with no artwork yet is legal, and
     the mockup screen simply has nothing to superimpose. */
  const artCache = new Map<string, string | null>();
  async function artworkFor(c: Campaign): Promise<string | null> {
    if (artCache.has(c.id)) return artCache.get(c.id) as string | null;
    let path: string | null = c.artwork_path ? String(c.artwork_path) : null;

    if (!path) {
      /* The embedded filter, not a two-step `in (…)`: the id list of a
         long-running campaign is unbounded, and an empty one would send
         PostgREST `task_id=in.()`. */
      const { data: rows } = await admin.from("task_images")
        .select("storage_path, tasks!inner(campaign_id)")
        .eq("kind", "poster")
        .eq("bucket_id", ARTWORK_BUCKET)
        .eq("tasks.campaign_id", c.id)
        .order("recorded_at", { ascending: true })
        .limit(1);
      if (rows && rows.length && rows[0].storage_path) path = String(rows[0].storage_path);
    }

    if (!path) {
      const { data: objs } = await admin.storage.from(ARTWORK_BUCKET)
        .list("campaigns/" + c.id, { limit: 100, sortBy: { column: "created_at", order: "asc" } });
      /* `id: null` is a folder, and a leading dot is Storage's own empty-folder
         placeholder. Neither is artwork. */
      const file = (objs || []).find((o) => o && o.id && o.name && o.name[0] !== ".");
      if (file) path = "campaigns/" + c.id + "/" + file.name;
    }

    artCache.set(c.id, path);
    return path;
  }

  /* ---- 6. the work ---- */
  let provisioned = 0;
  const names: string[] = [];
  const failed: { who: string; poster: string; why: string }[] = [];

  for (const uid of targets) {
    try {
      const { data: who } = await admin.from("profiles")
        .select("id, full_name, region, role, is_active").eq("id", uid).single();
      if (!who || who.role !== "Merchandiser") {
        failed.push({ who: uid, poster: "—", why: "not a merchandiser" });
        continue;
      }
      if (who.is_active === false) {
        /* Not an error: an account that has been switched off should not be
           handed new work. It reconciles the next time it is switched on and
           somebody signs in with it. */
        continue;
      }

      /* A STORE THAT IS NOT A SHOP — identical to provision-poster's, including
         the region, because whichever function gets there first is the one that
         creates it and the two must not disagree. */
      const storeCode = "FLD-" + short(uid);
      let storeId: string;
      const { data: existingStore } = await admin.from("stores")
        .select("id").eq("store_code", storeCode).maybeSingle();
      if (existingStore) {
        storeId = existingStore.id;
      } else {
        const { data: madeStore, error: sErr } = await admin.from("stores").insert({
          store_code: storeCode,
          name: (who.full_name || "Merchandiser") + " — field",
          city: "—", state: "—", state_code: "--",
          region: who.region || "West",
          /* Null Island, on purpose — see provision-poster. */
          lat: 0, lng: 0, geofence_m: 5000, is_active: true,
        }).select("id").single();
        if (sErr) { failed.push({ who: uid, poster: "—", why: sErr.message }); continue; }
        storeId = madeStore.id;
      }

      for (const c of posters) {
        try {
          /* READ BEFORE WRITE. This is what makes running on every sign-in
             free, and it is also the only thing standing between a second
             attempt and a 23505 on the (campaign_id, store_id) unique index. */
          const { data: existingTask } = await admin.from("tasks")
            .select("id").eq("campaign_id", c.id).eq("store_id", storeId).maybeSingle();

          let taskId: string;
          let isNew = false;
          if (existingTask) {
            taskId = existingTask.id;
          } else {
            const mgr = await managerFor(c);
            if (!mgr) {
              failed.push({ who: uid, poster: c.name, why: "no manager to attribute this poster to" });
              continue;
            }
            const { data: madeTask, error: tErr } = await admin.from("tasks").insert({
              task_code: "MK-" + short(c.id) + "-" + short(uid),
              campaign_id: c.id,
              store_id: storeId,
              assignee_id: uid,
              manager_id: mgr,
              created_by: mgr,
              display_type: "In-shop Branding",
              width_ft: c.poster_w_ft,
              height_ft: c.poster_h_ft,
              standoff_ft: c.standoff_ft,
              standoff_tol_ft: c.standoff_tol_ft,
              angle_tol_deg: c.angle_tol_deg,
              instructions: "Mock this poster up on a clear wall.",
              /* STRAIGHT TO OPEN — niva_task_open_for_me() in 0002 will not let
                 a merchandiser photograph anything else. Same reasoning, at
                 length, in provision-poster. */
              status: "In Progress",
            }).select("id").single();
            if (tErr) {
              /* A duplicate here means somebody else provisioned the same pair
                 between the read and the write. That is the outcome we wanted;
                 it is not a failure. */
              if (tErr.code === "23505") continue;
              failed.push({ who: uid, poster: c.name, why: tErr.message });
              continue;
            }
            taskId = madeTask.id;
            isNew = true;
          }

          /* The artwork row. One per task, all pointing at ONE stored object —
             task_images is unique on (task_id, bucket_id, storage_path), which
             0001 chose precisely so several tasks can share a key visual.
             Attempted even for a task that already existed: a task provisioned
             before the artwork was attached is exactly the case this is for. */
          const artPath = await artworkFor(c);
          if (artPath) {
            const { data: haveArt } = await admin.from("task_images")
              .select("id").eq("task_id", taskId).eq("kind", "poster")
              .eq("storage_path", artPath).maybeSingle();
            if (!haveArt) {
              const mgr = await managerFor(c);
              const { error: iErr } = await admin.from("task_images").insert({
                task_id: taskId, kind: "poster",
                bucket_id: ARTWORK_BUCKET, storage_path: artPath,
                is_guided: false, captured_at: new Date().toISOString(),
                uploaded_by: mgr,
              });
              if (iErr && iErr.code !== "23505") {
                failed.push({ who: uid, poster: c.name, why: "artwork: " + iErr.message });
              }
            }
          }

          if (isNew) { provisioned++; names.push(c.name); }
        } catch (e) {
          failed.push({ who: uid, poster: c.name, why: (e as Error)?.message || "unknown" });
        }
      }
    } catch (e) {
      failed.push({ who: uid, poster: "—", why: (e as Error)?.message || "unknown" });
    }
  }

  /* `provisioned` counts TASKS ACTUALLY CREATED, not posters looked at, so a
     caller can use it to decide whether a re-read is worth doing. On the
     ordinary sign-in it is zero and the client does nothing. */
  return reply(200, { provisioned, posters: names, failed });
});
