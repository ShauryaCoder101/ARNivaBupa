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

   TWO WRITES, ONE OUTCOME
   -----------------------
   An auth user and a profile row are created together, and a profile row is the
   only thing that gives a login a role (see 0001_schema.sql). If the profile
   insert fails, the auth user is DELETED again rather than left behind — an
   account that can sign in but has no profile is exactly the state
   Session.loadProfile refuses to start from, and it cannot be repaired from
   inside the app.

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
    .select("role, is_active")
    .eq("id", caller.user.id)
    .single();

  if (profErr || !callerProfile) return reply(403, { error: "This account has no profile." });
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
    user_metadata: { full_name: name, phone },
  });

  if (createErr || !created?.user) {
    const msg = createErr?.message || "Could not create that login.";
    const dupe = /already|registered|exists/i.test(msg);
    return reply(dupe ? 409 : 400, { error: dupe ? "That number already has an account." : msg });
  }

  /* ---- 5. …and the profile that gives it a role ---- */
  const { data: profile, error: insErr } = await admin
    .from("profiles")
    .insert({
      id: created.user.id,
      full_name: name,
      role: "Merchandiser",
      phone,
      is_active: true,
    })
    .select("id, full_name, role, phone, is_active")
    .single();

  if (insErr) {
    /* Roll the login back. A user who can authenticate but has no profile row
       cannot be fixed from the app and cannot be seen by the manager who just
       made them, so leaving it would be worse than failing. */
    await admin.auth.admin.deleteUser(created.user.id);
    return reply(400, { error: `Created the login but not the profile (${insErr.message}). Nothing was saved.` });
  }

  return reply(200, { profile });
});
