/* ============================================================================
   provision-poster — give a set of merchandisers a poster to mock up.

   WHY THIS IS NOT DONE FROM THE BROWSER
   -------------------------------------
   A merchandiser can only attach photos to a task that is assigned to them and
   is OPEN: niva_task_open_for_me() in 0002_rls.sql demands
   `assignee_id = auth.uid() and status in ('In Progress','Rework Required')`.
   So every merchandiser who is to shoot a poster needs their own task, in that
   state, before they can do anything at all.

   A manager cannot make one. tasks_insert_mgr accepts `status = 'Draft'` and
   nothing else, and the way out of Draft is the state machine in
   trg_tasks_transition: Draft -> Assigned by a manager, then Assigned -> In
   Progress by the ASSIGNEE, as a geofenced check-in against the store's
   registered coordinates. That sequence exists to make field evidence
   trustworthy and it is right for verification mode. Here it is ceremony
   protecting nothing: there is no store, no geofence and no assignment — a
   manager is handing out artwork.

   The service role bypasses RLS, and the FSM guard is BEFORE UPDATE, so an
   INSERT lands a ready-to-shoot task without touching either. That is the whole
   reason this function exists.

   WHAT A "POSTER" IS
   ------------------
   A campaign. It already carries the poster's true size (poster_w_ft/h_ft), the
   artwork bucket, is_active for archiving, and — after 0008 — audience_all.
   The browser creates the campaign and uploads the artwork, both of which RLS
   permits a manager to do; this function only does the part it cannot.

   ONE TASK PER (POSTER x MERCHANDISER), reused for every office that person
   shoots that poster in: tasks are unique on (campaign_id, store_id), so each
   merchandiser gets a synthetic store of their own. The office is recorded per
   PHOTO (task_images.office_name, 0007), which is what the manager's list
   reads, so one task holding many mockups loses nothing.

   Deploy: supabase functions deploy provision-poster
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
const short = (id: string) => String(id).replace(/-/g, "").slice(0, 6).toUpperCase();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "POST only." });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply(500, { error: "Function is not configured." });
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  /* ---- who is asking, and may they? Same shape as create-merchandiser: the
     caller's JWT, resolved through GoTrue, then their own profile row. ---- */
  const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return reply(401, { error: "Sign in first." });
  const { data: caller, error: callerErr } = await admin.auth.getUser(jwt);
  if (callerErr || !caller?.user) return reply(401, { error: "That sign-in is not valid any more." });

  const { data: me } = await admin.from("profiles")
    .select("id, role, is_active").eq("id", caller.user.id).single();
  if (!me) return reply(403, { error: "This account has no profile." });
  if (me.is_active === false) return reply(403, { error: "This account is not active." });
  if (me.role !== "Manager" && me.role !== "Admin") {
    return reply(403, { error: "Only a manager can publish posters." });
  }

  let body: Record<string, unknown>;
  try { body = await req.json(); } catch { return reply(400, { error: "Expected a JSON body." }); }

  const campaignId = String(body.campaignId ?? "").trim();
  if (!campaignId) return reply(400, { error: "Which poster?" });

  /* `artworkPath` is the storage object the browser has already uploaded.
     Optional: topping a new hire up passes it, a first publish passes it, and a
     poster with no artwork yet is still legal — the mockup screen simply has
     nothing to superimpose until one arrives. */
  const artworkPath = body.artworkPath ? String(body.artworkPath) : null;

  const { data: campaign, error: cErr } = await admin.from("campaigns")
    .select("id, name, poster_w_ft, poster_h_ft, standoff_ft, standoff_tol_ft, angle_tol_deg, is_active")
    .eq("id", campaignId).single();
  if (cErr || !campaign) return reply(404, { error: "That poster no longer exists." });

  /* ---- who is it for? ----
     Either an explicit list, or everyone. `all` resolves to every active
     merchandiser AT THIS MOMENT; the standing rule for people hired later is
     campaigns.audience_all, which create-merchandiser reads. This function only
     provisions people who already exist. */
  let targets: string[];
  if (body.all === true) {
    const { data: everyone } = await admin.from("profiles")
      .select("id").eq("role", "Merchandiser").eq("is_active", true);
    targets = (everyone || []).map((r: { id: string }) => r.id);
  } else {
    targets = Array.isArray(body.merchandiserIds) ? body.merchandiserIds.map(String) : [];
  }
  if (!targets.length) return reply(400, { error: "Nobody was selected for this poster." });

  const provisioned: string[] = [];
  const failed: { id: string; why: string }[] = [];

  for (const uid of targets) {
    try {
      const { data: who } = await admin.from("profiles")
        .select("id, full_name, region, role").eq("id", uid).single();
      if (!who || who.role !== "Merchandiser") {
        failed.push({ id: uid, why: "not a merchandiser" });
        continue;
      }

      /* A STORE THAT IS NOT A SHOP. tasks.store_id is NOT NULL and tasks are
         unique on (campaign_id, store_id), so one synthetic store per person is
         what lets the same poster go to everybody. It is never shown to anyone:
         the location on record is the office typed onto each photo. */
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
          /* Null Island, on purpose. The geofence is a verification-mode idea
             that mockup mode never evaluates, and a plausible made-up
             coordinate would be worse: it would look like somewhere. */
          lat: 0, lng: 0, geofence_m: 5000, is_active: true,
        }).select("id").single();
        if (sErr) { failed.push({ id: uid, why: sErr.message }); continue; }
        storeId = madeStore.id;
      }

      /* Already has this poster? Then this is a re-publish, or a new hire being
         topped up, and there is nothing to do. */
      const { data: existingTask } = await admin.from("tasks")
        .select("id").eq("campaign_id", campaignId).eq("store_id", storeId).maybeSingle();

      let taskId: string;
      if (existingTask) {
        taskId = existingTask.id;
      } else {
        const { data: madeTask, error: tErr } = await admin.from("tasks").insert({
          task_code: "MK-" + short(campaignId) + "-" + short(uid),
          campaign_id: campaignId,
          store_id: storeId,
          assignee_id: uid,
          manager_id: me.id,
          created_by: me.id,
          display_type: "In-shop Branding",
          width_ft: campaign.poster_w_ft,
          height_ft: campaign.poster_h_ft,
          standoff_ft: campaign.standoff_ft,
          standoff_tol_ft: campaign.standoff_tol_ft,
          angle_tol_deg: campaign.angle_tol_deg,
          instructions: "Mock this poster up on a clear wall.",
          /* STRAIGHT TO OPEN. Draft and Assigned exist so a manager can stage
             work and a merchandiser can check in against a real store; neither
             is true here, and a task left in Draft is one the merchandiser is
             forbidden by RLS to photograph. */
          status: "In Progress",
        }).select("id").single();
        if (tErr) { failed.push({ id: uid, why: tErr.message }); continue; }
        taskId = madeTask.id;
      }

      /* The artwork row. One per task, all pointing at ONE stored object —
         task_images is unique on (task_id, bucket_id, storage_path), which 0001
         chose precisely so several tasks can share a campaign's key visual. */
      if (artworkPath) {
        const { data: haveArt } = await admin.from("task_images")
          .select("id").eq("task_id", taskId).eq("kind", "poster")
          .eq("storage_path", artworkPath).maybeSingle();
        if (!haveArt) {
          await admin.from("task_images").insert({
            task_id: taskId, kind: "poster",
            bucket_id: "poster-artwork", storage_path: artworkPath,
            is_guided: false, captured_at: new Date().toISOString(), uploaded_by: me.id,
          });
        }
      }
      provisioned.push(uid);
    } catch (e) {
      failed.push({ id: uid, why: (e as Error)?.message || "unknown" });
    }
  }

  return reply(200, { provisioned: provisioned.length, failed, campaignId });
});
