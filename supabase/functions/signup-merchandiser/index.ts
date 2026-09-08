/* ============================================================================
   signup-merchandiser — a person creates their OWN account, from the login
   screen, with nobody signed in.

   THIS FUNCTION IS PUBLIC ON PURPOSE. Deploy it with verify_jwt OFF:

       supabase functions deploy signup-merchandiser --no-verify-jwt

   WHY THE BROWSER MAY NOT JUST CALL GoTrue
   ----------------------------------------
   The obvious implementation is supabase.auth.signUp() from the login page,
   and it is a privilege-escalation hole. GoTrue's public /auth/v1/signup takes
   a `data` object and copies it into auth.users.raw_user_meta_data verbatim;
   0004's trg_niva_on_auth_user_created reads the new profile's ROLE straight
   back out of that column. The anon key that authorises the call is published
   in the app's own HTML. So a sign-up form built on signUp() is a form on
   which anybody can post {"role":"Admin"} and become an administrator.

   Sign-up therefore comes here instead, and here 'Merchandiser' is a CONSTANT.
   There is no code path in this file that reads a role from the request; an
   unexpected key in the body is ignored, never merged, and there is nothing a
   caller can send that changes what gets created.

   AND THE HOLE IS CLOSED BEHIND US. This file being careful is not enough
   while the raw endpoint still exists, so 0009_self_signup.sql rewrites
   niva_handle_new_user: a privileged role must arrive in raw_app_meta_data,
   which only the service role can write, and a role in raw_user_meta_data is
   honoured only when it asks for 'Merchandiser'. Belt here, braces there.
   Turn "Enable email signups" off in Authentication -> Providers as well —
   admin.createUser is not gated by that switch, so it costs this function
   nothing and closes the raw endpoint.

   NO CALLER IDENTITY IS READ, DELIBERATELY
   ----------------------------------------
   create-merchandiser resolves the Authorization header to a manager and
   refuses everyone else, because what it does needs authority. This function
   does not: the entire premise is that the person has no account yet. So the
   header is IGNORED — not checked and allowed, ignored — and passing a
   manager's token changes nothing about the outcome. Anyone who reads this
   file should be able to see that in one pass, which is why there is no
   getUser() call in it at all.

   WHAT THIS DOES NOT DEFEND AGAINST, SAID OUT LOUD
   -----------------------------------------------
   Anyone can create an account, and anyone can register any phone number that
   is not already taken. That is what open sign-up means and the client asked
   for it. What matters is that it cannot matter: every account minted here is
   a Merchandiser, and RLS shows a Merchandiser only the tasks assigned to
   them. Volume is left to the platform's own rate limiting; the validation
   below is ordered cheapest-first so an abusive caller is refused before any
   database work happens.

   Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY are injected by the
   platform. Requires supabase/migrations/0009_self_signup.sql.
   ========================================================================== */
import { createClient } from "jsr:@supabase/supabase-js@2";

/* MUST MATCH phoneDigits() in niva-merch-app.html, and matches the copy in
   create-merchandiser/index.ts character for character. The mapping from a
   typed number to an account is the primary key of the login: if the app and
   this function disagree about what "098765 43210" normalises to, the account
   is created under one address and signed into under another. The app's
   self-tests pin the same cases. */
const PHONE_CC_DEFAULT   = "91";
const PHONE_NSN_LEN      = 10;
const PHONE_EMAIL_DOMAIN = "phone.niva.internal";

function phoneDigits(raw: unknown): string | null {
  let d = String(raw ?? "").replace(/[^0-9]/g, "");
  if (!d) return null;
  /* No E.164 number begins with zero, so a leading one is always a trunk
     prefix — dropped whether or not a country code follows it. */
  d = d.replace(/^0+/, "");
  if (d.length === PHONE_NSN_LEN) d = PHONE_CC_DEFAULT + d;
  if (d.length < 11 || d.length > 15) return null;
  return d;
}

/* The office address bounds, mirrored from the check constraint 0009 adds and
   from signupCheck() in the app. Three places, one rule, and the innermost one
   is the database. */
const OFFICE_MIN = 2;
const OFFICE_MAX = 200;

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

const short = (id: string) => String(id).replace(/-/g, "").slice(0, 6).toUpperCase();

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return reply(405, { error: "POST only." });

  /* Cheapest possible refusal, before a JSON parse and before any client is
     built. Five short strings do not weigh 8 KB. */
  const declared = Number(req.headers.get("content-length") || "0");
  if (declared > 8192) return reply(413, { error: "That request is too large." });

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return reply(500, { error: "Function is not configured." });

  /* The service client. Never handed a user's token — it IS the privilege, and
     on this path there is no user to hand it. */
  const admin = createClient(url, serviceKey, { auth: { persistSession: false } });

  /* ---- 1. what is being asked for? ----
     Note what is NOT read here: body.role, body.user_metadata, body.id. They
     are not read because there is nothing they could be allowed to say. */
  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "Expected a JSON body." });
  }

  const name     = String(body.name ?? "").trim();
  const phone    = phoneDigits(body.phone);
  const office   = String(body.office ?? "").trim();
  const password = String(body.password ?? "");

  if (name.length < 2)  return reply(400, { error: "Enter your full name." });
  if (!phone)           return reply(400, { error: `Enter a ${PHONE_NSN_LEN}-digit phone number.` });
  if (office.length < OFFICE_MIN)
    return reply(400, { error: "Enter the office you work out of." });
  if (office.length > OFFICE_MAX)
    return reply(400, { error: `Keep the office address under ${OFFICE_MAX} characters.` });
  /* GoTrue's own floor is 6; 8 is the programme's, and saying so beats a 500
     from further down the stack. The ceiling is bcrypt's 72-byte input limit,
     which newer GoTrue versions reject outright rather than truncating. */
  if (password.length < 8)
    return reply(400, { error: "Choose a password of at least 8 characters." });
  if (password.length > 72)
    return reply(400, { error: "That password is too long — 72 characters is the limit." });
  /* The confirm box is NOT checked here, and that is not an oversight. A
     mistyped confirmation is a fact about typing, not about the server, and it
     belongs where the typing happened — signupCheck() in the app refuses it
     without a round trip. Sending a second copy of a password across the wire
     to compare it to the first would add a risk and prevent nothing. */

  const email = `${phone}@${PHONE_EMAIL_DOMAIN}`;

  /* A number already in use is the ONE failure a real person will hit, and
     "duplicate key value violates unique constraint" is not an answer. Checked
     up front for the message; the unique index on profiles.phone (0007) is
     what makes it true under a race. */
  const { data: clash } = await admin
    .from("profiles")
    .select("id")
    .eq("phone", phone)
    .maybeSingle();
  if (clash) {
    /* No name is echoed back. create-merchandiser tells a MANAGER whose number
       it is because they are entitled to know and are about to fix it; an
       anonymous caller is not, and this endpoint is reachable by anybody. */
    return reply(409, { error: "That number already has an account." });
  }

  /* ---- 2. create the login ----
     email_confirm: true because nothing is ever delivered to this address — it
     is a synthetic identifier, and leaving the account unconfirmed would make
     it unable to sign in while waiting for a mail that cannot arrive. */
  const { data: created, error: createErr } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    /* Both metadata columns say Merchandiser, and both are literals. app is
       the one 0009's trigger TRUSTS (only the service role can write it); user
       is what the trigger falls back to and is the one value it still accepts
       from that side. Neither is derived from anything the caller sent. */
    app_metadata:  { role: "Merchandiser" },
    user_metadata: { full_name: name, phone, role: "Merchandiser" },
  });

  if (createErr || !created?.user) {
    const msg = createErr?.message || "Could not create that account.";
    const dupe = /already|registered|exists/i.test(msg);
    return reply(dupe ? 409 : 400, {
      error: dupe ? "That number already has an account." : msg,
    });
  }

  const uid = created.user.id;

  /* ---- 3. …and the profile ----
     THE ROW ALREADY EXISTS BY NOW. trg_niva_on_auth_user_created fires inside
     the same transaction as the insert above, so an INSERT here races nothing
     and collides with everything, failing on profiles_pkey. What is left to do
     is fill in the columns that trigger deliberately does not touch: `phone`
     (0007) and `office_address` (0009), both of which are client-supplied and
     therefore both of which have to be able to fail with an answer rather than
     with a 500 inside an auth trigger.

     UPSERT rather than UPDATE so this still works on a project where 0004's
     bootstrap trigger is absent: then there is no row and one gets made. */
  const profileRow: Record<string, unknown> = {
    id: uid,
    full_name: name,
    role: "Merchandiser",
    phone,
    office_address: office,
    is_active: true,
  };

  let { data: profile, error: insErr } = await admin
    .from("profiles")
    .upsert(profileRow, { onConflict: "id" })
    .select("id, full_name, role, phone, office_address, is_active")
    .single();

  /* 0009 NOT APPLIED YET. The column is the only part of this that is optional
     — the account works without it, the merchandiser is simply asked for their
     office at capture time as they were before — and losing a whole account
     over a migration that has not run is the wrong trade. Same posture as the
     app's own profileColRecovered(). Retried once, narrowly, and only when the
     error actually names the column. */
  if (insErr && /office_address/i.test(insErr.message || "")) {
    delete profileRow.office_address;
    const retry = await admin
      .from("profiles")
      .upsert(profileRow, { onConflict: "id" })
      .select("id, full_name, role, phone, is_active")
      .single();
    profile = retry.data;
    insErr = retry.error;
  }

  if (insErr) {
    /* Roll the login back. An account that can authenticate but whose profile
       carries no phone number cannot sign in at all — the app derives the
       address from the number — and cannot be repaired from inside the app, so
       a half-made account is worse than none. Deleting the auth user cascades
       the trigger's profile row away with it. */
    await admin.auth.admin.deleteUser(uid);
    const dupePhone = insErr.code === "23505" ||
                      /profiles_phone_key/i.test(insErr.message || "");
    return reply(dupePhone ? 409 : 400, {
      error: dupePhone
        ? "That number already has an account."
        : `Could not save your details (${insErr.message}). Nothing was created.`,
    });
  }

  /* ---- 4. the posters this person should already have ----
     IDENTICAL IN EVERY RESPECT to step 6 of create-merchandiser, and it has to
     be: the store code, the task code and the task's opening status are what
     decide whether a person ends up with one synthetic store or two. The only
     difference is forced by the situation — there is no manager in the room.

     "Publish to everyone" is a STANDING RULE, not a set of names, so it has to
     be applied to people who did not exist when it was made. campaigns.
     audience_all (0008) is that rule, and this is what makes a new sign-up's
     first screen show the same posters as everybody else's.

     BEST EFFORT, DELIBERATELY. The account is created and usable by this
     point, and a poster that fails to provision is fixed by a manager
     re-publishing it — losing the account over it would be far worse. */

  /* tasks.manager_id is NOT NULL (0001) and nobody assigned this work. The
     poster's owner is the honest answer: it is their poster and they are who
     will read the photographs. Any active manager is the fallback for a
     campaign whose owner_id was never set, and if the project has neither the
     poster is skipped — never the account. */
  const { data: anyManager } = await admin
    .from("profiles")
    .select("id")
    .in("role", ["Manager", "Admin"])
    .eq("is_active", true)
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  const fallbackManagerId: string | null = anyManager?.id ?? null;

  const provisioned: string[] = [];
  const provisionFailed: { poster: string; why: string }[] = [];

  const { data: openPosters } = await admin
    .from("campaigns")
    .select("id, name, owner_id, poster_w_ft, poster_h_ft, standoff_ft, standoff_tol_ft, angle_tol_deg")
    .eq("audience_all", true)
    .eq("is_active", true);

  for (const c of openPosters || []) {
    try {
      const managerId: string | null = c.owner_id || fallbackManagerId;
      if (!managerId) {
        provisionFailed.push({ poster: c.name, why: "no manager on this project to own the task" });
        continue;
      }

      /* A STORE THAT IS NOT A SHOP. tasks.store_id is NOT NULL and tasks are
         unique on (campaign_id, store_id), so one synthetic store per person
         is what lets the same poster go to everybody. Null Island on purpose:
         the geofence is a verification-mode idea that mockup mode never
         evaluates, and a plausible made-up coordinate would look like
         somewhere. */
      const storeCode = "FLD-" + short(uid);
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
        task_code: "MK-" + short(c.id) + "-" + short(uid),
        campaign_id: c.id, store_id: storeId,
        assignee_id: uid,
        manager_id: managerId,
        /* Null, and it is the true answer: nobody typed this task into being.
           A standing rule on the poster did, and writing a manager's id here
           would say a person made a decision they were not present for. */
        created_by: null,
        display_type: "In-shop Branding",
        width_ft: c.poster_w_ft, height_ft: c.poster_h_ft,
        standoff_ft: c.standoff_ft, standoff_tol_ft: c.standoff_tol_ft,
        angle_tol_deg: c.angle_tol_deg,
        instructions: "Mock this poster up on a clear wall.",
        /* STRAIGHT TO OPEN. Draft and Assigned exist so a manager can stage
           work and a merchandiser can check in against a real store; neither
           is true here, and a task left in Draft is one RLS forbids the
           merchandiser to photograph. */
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
          is_guided: false, captured_at: new Date().toISOString(),
          /* Whoever owns the poster is who put this artwork in the bucket. */
          uploaded_by: managerId,
        });
      }
      provisioned.push(c.name);
    } catch (e) {
      provisionFailed.push({ poster: c.name, why: (e as Error)?.message || "unknown" });
    }
  }

  /* 201: something was created. The app signs the person in immediately
     afterwards with the password they just typed, so nothing here is a
     credential — `profile` is the same row shape create-merchandiser returns,
     and `posters` is what the toast counts. */
  return reply(201, { profile, posters: provisioned, posterFailures: provisionFailed });
});