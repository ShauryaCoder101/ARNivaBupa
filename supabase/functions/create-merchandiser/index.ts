/* ============================================================================
   create-merchandiser — the ONLY way a merchandiser account comes into being.

   WHY THIS EXISTS AT ALL
   ----------------------
   Creating a login means calling GoTrue's admin API, and that needs the
   SERVICE_ROLE key. That key bypasses row-level security completely: anything
   holding it can read and rewrite every table in the project, so it can never
   be shipped to a browser, and the app it belongs to is one static HTML file.
   So the privilege lives here instead, behind a function that does exactly one
   thing and checks who is asking before it does it.

   THE AUTHORISATION IS DONE HERE, NOT BY RLS
   ------------------------------------------
   RLS protects TABLES. auth.users is not one of ours, and admin.createUser does
   not go through PostgREST at all — so no policy in 0002_rls.sql constrains this
   path. The check below is therefore the whole of the access control, and it is
   deliberately written the long way round:

     1. take the caller's JWT from the Authorization header — never a user id
        from the body, which the caller controls;
     2. resolve it to a real user through GoTrue, so a forged or expired token
        fails at the source rather than against our own parsing;
     3. read THAT user's profile row and require role Manager or Admin.

   A caller who is not signed in, or is a Merchandiser, gets 403 and nothing
   happens. This is why `verify_jwt` being on is not sufficient on its own: a
   valid token proves who you are, not what you may do.

   THE PROFILE ROW MAKES ITSELF
   ----------------------------
   Creating the auth user is enough to create the profile: 0004 installs
   trg_niva_on_auth_user_created, an AFTER INSERT trigger on auth.users that
   mirrors the new login into public.profiles and reads its name and role out of
   raw_user_meta_data. So this function does not insert that row — it fills in
   the one column that trigger predates, `phone`, which 0007 added and which is
   the whole of the merchandiser's login identity.

   Getting this wrong is not subtle: an INSERT here fails on profiles_pkey every
   single time, because the trigger has already run inside the same transaction.

   If that update fails, the auth user is DELETED again rather than left behind.
   A login whose profile carries no phone number cannot sign in at all — the app
   derives the address from the number — and cannot be repaired from inside the
   app, so a half-made account is worse than none.

   Deploy:  supabase functions deploy create-merchandiser
   Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY are injected by the platform.
   ========================================================================== */
import { createClient } from "jsr:@supabase/supabase-js@2";

/* MUST MATCH phoneDigits() in niva-merch-app.html. The mapping from a typed
   number to an account is the primary key of the login: if the app and this
   function disagree about what "098765 43210" normalises to, the account gets
   created under one address and signed into under another. The app's self-tests
   pin the same cases. */
const PHONE_CC_DEFAULT = "91";
const PHONE_NSN_LEN    = 10;
const PHONE_EMAIL_DOMAIN = "phone.niva.internal";

function phoneDigits(raw: unknown): string | null {
  let d = String(raw ?? "").replace(/[^0-9]/g, "");
  if (!d) return null;
  /* No E.164 number begins with zero, so a leading one is always a trunk prefix
     — dropped whether or not a country code follows it. Kept identical to
     phoneDigits() in niva-merch-app.html; the app's self-tests pin both. */
  d = d.replace(/^0+/, "");
  if (d.length === PHONE_NSN_LEN) d = PHONE_CC_DEFAULT + d;
  if (d.length < 11 || d.length > 15) return null;
  return d;
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "POST only." });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply(500, { error: "Function is not configured." });

  /* The service client. Never handed a user's token — it IS the privilege. */
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  /* ---- 1. who is asking? ---- */
  const authHeader = req.headers.get("Authorization") || "";
  const jwt = authHeader.replace(/^Bearer\s+/i, "").trim();
  if (!jwt) return reply(401, { error: "Sign in first." });

  const { data: caller, error: callerErr } = await admin.auth.getUser(jwt);
  if (callerErr || !caller?.user) return reply(401, { error: "That sign-in is not valid any more." });

  /* ---- 2. …and are they allowed to? ---- */
  const { data: callerProfile, error: profErr } = await admin
    .from("profiles")
    .select("id, role, is_active")
    .eq("id", caller.user.id)
    .single();

  if (profErr || !callerProfile) return reply(403, { error: "This account has no profile." });
  const me = callerProfile;
  if (callerProfile.is_active === false) return reply(403, { error: "This account is not active." });
  if (callerProfile.role !== "Manager" && callerProfile.role !== "Admin") {
    return reply(403, { error: "Only a manager can create accounts." });
  }

  /* ---- 3. what are they asking for? ---- */
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "Expected a JSON body." });
  }

  const name = String(body.name ?? "").trim();
  const phone = phoneDigits(body.phone);
  const password = String(body.password ?? "");

  if (name.length < 2) return reply(400, { error: "Enter the merchandiser's name." });
  if (!phone) return reply(400, { error: `Enter a ${PHONE_NSN_LEN}-digit phone number.` });
  /* GoTrue's own floor is 6; 8 is the programme's, and saying so beats a 500
     from further down the stack. */
  if (password.length < 8) return reply(400, { error: "The password must be at least 8 characters." });

  const email = `${phone}@${PHONE_EMAIL_DOMAIN}`;

  /* A number already in use is the ONE failure a manager will actually hit, and
     "duplicate key value violates unique constraint" is not an answer. Checked
     up front for the message; the unique index on profiles.phone is what makes
     it true under a race. */
  const { data: clash } = await admin
    .from("profiles")
    .select("id, full_name")
    .eq("phone", phone)
    .maybeSingle();
  if (clash) {
    return reply(409, { error: `That number already belongs to ${clash.full_name}.` });
  }

  /* ---- 4. create the login ----
     email_confirm: true because nothing is ever delivered to this address — it
     is a synthetic identifier, and leaving the account unconfirmed would make it
     unable to sign in while waiting for a mail that cannot arrive. */
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    /* `role` is read back out of this by trg_niva_on_auth_user_created, which
       is what actually creates the profile row (see below). Passing it here
       means the row is born with the right role instead of defaulting into it. */
    user_metadata: { full_name: name, phone, role: "Merchandiser" },
  });

  if (createErr || !created?.user) {
    const msg = createErr?.message || "Could not create that login.";
    const dupe = /already|registered|exists/i.test(msg);
    return reply(dupe ? 409 : 400, { error: dupe ? "That number already has an account." : msg });
  }

  /* ---- 5. …and the phone number on the profile ----
     THE PROFILE ROW ALREADY EXISTS BY NOW. 0004 installs
     trg_niva_on_auth_user_created, an AFTER INSERT trigger on auth.users that
     mirrors every new login into public.profiles, taking full_name and role
     out of raw_user_meta_data. It runs inside the same transaction as the
     insert above, so by the time createUser() returns, the row is there.

     That trigger predates 0007 and knows nothing about `phone`, so what is
     left to do is fill it in — an INSERT here races nothing and collides with
     everything, failing on profiles_pkey, which is precisely what it did.

     UPSERT rather than UPDATE so this still works on a project where 0004's
     bootstrap trigger is absent: then there is no row and one gets made. */
  const { data: profile, error: insErr } = await admin
    .from("profiles")
    .upsert({
      id: created.user.id,
      full_name: name,
      role: "Merchandiser",
      phone,
      is_active: true,
    }, { onConflict: "id" })
    .select("id, full_name, role, phone, is_active")
    .single();

  if (insErr) {
    /* Roll the login back. A user who can authenticate but whose profile does
       not carry their phone number cannot sign in at all — the app derives the
       address from the number — and cannot be repaired from inside the app, so
       leaving it would be worse than failing. Deleting the auth user cascades
       the trigger's profile row away with it. */
    await admin.auth.admin.deleteUser(created.user.id);
    /* The one collision worth naming: two people, one number. The up-front
       check catches the ordinary case; this catches the race, and the case
       where a number is on a row the check could not see. */
    const dupePhone = insErr.code === "23505" || /profiles_phone_key|phone/i.test(insErr.message || "");
    return reply(dupePhone ? 409 : 400, {
      error: dupePhone
        ? "That phone number is already registered to another account."
        : `Created the login but could not save the profile (${insErr.message}). Nothing was saved.`,
    });
  }

  /* ---- 6. the posters this person should already have ----
     "Publish to everyone" is a STANDING RULE, not a set of names, so it has to
     be applied to people who did not exist when it was made. campaigns.
     audience_all (0008) is that rule; provisioning here is what makes a new
     hire's first sign-in show the same posters as everybody else's.

     BEST EFFORT, DELIBERATELY. The account is already created and usable by
     this point, and a poster that fails to provision is fixed by the manager
     re-publishing it — losing the whole account over it would be far worse. Any
     failures are reported alongside the profile rather than swallowed. */
  const provisioned: string[] = [];
  const provisionFailed: { poster: string; why: string }[] = [];
  const { data: openPosters } = await admin
    .from("campaigns")
    .select("id, name, poster_w_ft, poster_h_ft, standoff_ft, standoff_tol_ft, angle_tol_deg")
    .eq("audience_all", true)
    .eq("is_active", true);

  for (const c of openPosters || []) {
    try {
      const storeCode = "FLD-" + created.user.id.replace(/-/g, "").slice(0, 6).toUpperCase();
      let storeId: string;
      const { data: haveStore } = await admin.from("stores")
        .select("id").eq("store_code", storeCode).maybeSingle();
      if (haveStore) {
        storeId = haveStore.id;
      } else {
        const { data: madeStore, error: sErr } = await admin.from("stores").insert({
          store_code: storeCode, name: name + " — field",
          city: "—", state: "—", state_code: "--", region: "West",
          lat: 0, lng: 0, geofence_m: 5000, is_active: true,
        }).select("id").single();
        if (sErr) { provisionFailed.push({ poster: c.name, why: sErr.message }); continue; }
        storeId = madeStore.id;
      }

      const { data: madeTask, error: tErr } = await admin.from("tasks").insert({
        task_code: "MK-" + String(c.id).replace(/-/g, "").slice(0, 6).toUpperCase()
                 + "-" + created.user.id.replace(/-/g, "").slice(0, 6).toUpperCase(),
        campaign_id: c.id, store_id: storeId,
        assignee_id: created.user.id, manager_id: me.id, created_by: me.id,
        display_type: "In-shop Branding",
        width_ft: c.poster_w_ft, height_ft: c.poster_h_ft,
        standoff_ft: c.standoff_ft, standoff_tol_ft: c.standoff_tol_ft,
        angle_tol_deg: c.angle_tol_deg,
        instructions: "Mock this poster up on a clear wall.",
        status: "In Progress",
      }).select("id").single();
      if (tErr) { provisionFailed.push({ poster: c.name, why: tErr.message }); continue; }

      /* Carry the artwork across from any task that already has it, so the new
         person sees the same key visual rather than a blank overlay. */
      const { data: art } = await admin.from("task_images")
        .select("storage_path").eq("kind", "poster")
        .in("task_id", (await admin.from("tasks").select("id").eq("campaign_id", c.id))
              .data?.map((t: { id: string }) => t.id) || [])
        .limit(1).maybeSingle();
      if (art?.storage_path) {
        await admin.from("task_images").insert({
          task_id: madeTask.id, kind: "poster",
          bucket_id: "poster-artwork", storage_path: art.storage_path,
          is_guided: false, captured_at: new Date().toISOString(), uploaded_by: me.id,
        });
      }
      provisioned.push(c.name);
    } catch (e) {
      provisionFailed.push({ poster: c.name, why: (e as Error)?.message || "unknown" });
    }
  }

  return reply(200, { profile, posters: provisioned, posterFailures: provisionFailed });
});
