/* ============================================================================
   reset-merchandiser-password — a merchandiser who has forgotten their
   password sets a new one from the sign-in screen, with nothing but the phone
   number their account is registered under.

   WHY THIS EXISTS AT ALL
   ----------------------
   Changing the password on an account you are not signed in to is a GoTrue
   ADMIN operation (auth.admin.updateUserById), and admin operations need the
   SERVICE_ROLE key. That key bypasses row-level security completely, so it can
   never be shipped to a browser — and this app is one static HTML file. The
   privilege therefore lives here, in a function that does exactly one thing.

   THIS FUNCTION IS DELIBERATELY UNAUTHENTICATED
   ---------------------------------------------
   Every other function in this project starts by resolving the caller's JWT
   and reading their profile. This one CANNOT: the whole point is that the
   caller has no session — they cannot sign in, which is why they are here.
   There is no OTP, no email link and no security question, because the
   programme asked for none: a merchandiser in the field has the phone number
   and nothing else, and a reset they cannot complete is a reset that does not
   exist.

   So the phone number IS the credential. That is a decision taken with the
   consequence understood: anyone who knows a merchandiser's number can set
   their password. Do not "improve" this into a challenge flow without asking —
   and if it is ever wanted, see the one-line note in requireName below.

   WHAT IS NOT NEGOTIABLE
   ----------------------
   This function must NEVER touch a Manager or an Admin account. That is
   checked twice, because one check is a check and two is a rule:

     1. the profile row found by phone must have role = 'Merchandiser' and
        is_active = true;
     2. the GoTrue user behind it must authenticate on the SYNTHETIC address
        <digits>@phone.niva.internal that phoneToEmail() mints. Managers sign in
        with real work addresses, which can never match that pattern — so even
        a profiles.phone hand-edited onto a manager's row in the SQL editor
        cannot steer this function onto their login.

   TWO MODES, ONE ENDPOINT
   -----------------------
     mode:"check"  is this number registered? Always 200 —
                   { registered:boolean, name?, phone?, why? }. "Not
                   registered" is an ANSWER, not an error, so the app has one
                   code path and can say so plainly.
     mode:"set"    set the password. 200 { ok:true, name, phone }, or a 4xx
                   carrying a sentence meant for the person reading it.

   Deploy:  supabase functions deploy reset-merchandiser-password
   Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY are injected by the platform.

   NOTE ON verify_jwt: this project has no supabase/config.toml, so the CLI
   deploys with verify_jwt on. The app satisfies that by sending the ANON key as
   the Bearer token (see doForgotLookup/doForgotSet in niva-merch-app.html) —
   the anon key is a valid project JWT and proves nothing about who is calling,
   which is correct here. Deploying with --no-verify-jwt also works and changes
   nothing about the checks below.
   ========================================================================== */
import { createClient } from "jsr:@supabase/supabase-js@2";

/* MUST MATCH phoneDigits() in niva-merch-app.html — and it already matches the
   copy in create-merchandiser/index.ts. The mapping from a typed number to an
   account is the primary key of the login: if this function and the app
   disagree about what "098765 43210" normalises to, a reset changes the
   password on an account nobody ever signs into. The app's self-tests pin the
   same cases. */
const PHONE_CC_DEFAULT   = "91";
const PHONE_NSN_LEN      = 10;
const PHONE_EMAIL_DOMAIN = "phone.niva.internal";

function phoneDigits(raw: unknown): string | null {
  let d = String(raw ?? "").replace(/[^0-9]/g, "");
  if (!d) return null;
  /* No E.164 number begins with zero, so a leading one is always a trunk prefix
     — dropped whether or not a country code follows it. */
  d = d.replace(/^0+/, "");
  if (d.length === PHONE_NSN_LEN) d = PHONE_CC_DEFAULT + d;
  if (d.length < 11 || d.length > 15) return null;
  return d;
}

/* The programme's floor, the same number create-merchandiser enforces. GoTrue's
   own is 6; saying 8 here beats a 500 from further down the stack. */
const PW_MIN_LEN = 8;

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

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "Expected a JSON body." });
  }

  const mode = String(body.mode ?? "check").toLowerCase() === "set" ? "set" : "check";
  const phone = phoneDigits(body.phone);
  if (!phone) return reply(400, { error: `Enter a ${PHONE_NSN_LEN}-digit phone number.` });

  /* ---- 1. is there an account on this number, and may it be reset? ----
     profiles.phone is UNIQUE where not null (profiles_phone_key, 0007), so this
     is single-row by construction. maybeSingle rather than single: "nobody" is
     an answer this endpoint returns, not an error it raises. */
  const { data: profile, error: profErr } = await admin
    .from("profiles")
    .select("id, full_name, role, is_active, phone")
    .eq("phone", phone)
    .maybeSingle();

  if (profErr) return reply(500, { error: "Could not look that number up. Try again shortly." });

  /* Not registered, not a merchandiser, or deactivated: all three are the same
     shape of answer in `check` mode, and all three are a flat refusal in `set`
     mode. The `why` is written for the person reading it on a phone. */
  let why: string | null = null;
  if (!profile) {
    why = "That number is not registered. Check it with your manager.";
  } else if (profile.role !== "Merchandiser") {
    /* Managers and admins reset their passwords through Supabase, not here.
       Near-impossible in practice — profiles.phone is null on those rows — but
       it is the whole of the rule this function is built around, so it is
       checked rather than assumed. */
    why = "That number belongs to a manager account. A manager's password cannot be reset from here.";
  } else if (profile.is_active === false) {
    why = "That account has been deactivated. Ask your manager to reactivate it.";
  }

  if (mode === "check") {
    return why
      ? reply(200, { registered: false, why })
      : reply(200, { registered: true, name: profile!.full_name, phone });
  }

  /* ---- 2. set mode ---- */
  if (why) return reply(404, { registered: false, error: why });

  const password = String(body.password ?? "");
  if (password.length < PW_MIN_LEN) {
    return reply(400, { error: `The password must be at least ${PW_MIN_LEN} characters.` });
  }

  /* IF THEY EVER WANT A SECOND FACTOR, IT GOES HERE AND IT IS ONE LINE:
       const claimed = String(body.name ?? "").trim().toLowerCase();
       if (claimed !== String(profile!.full_name).trim().toLowerCase())
         return reply(403, { error: "That name does not match the account." });
     Not enabled: the programme asked for phone number only, twice. */

  /* ---- 3. the second check: the login behind the profile ----
     A merchandiser's GoTrue address is minted by phoneToEmail() and is nothing
     else. Verifying it before touching the password means this function cannot
     be steered onto an email-based account by a bad profiles row, whatever put
     that row there. */
  const { data: got, error: getErr } = await admin.auth.admin.getUserById(profile!.id);
  if (getErr || !got?.user) {
    return reply(404, { error: "That number has a profile but no login. Ask your manager to recreate the account." });
  }
  const expectedEmail = `${phone}@${PHONE_EMAIL_DOMAIN}`;
  if (String(got.user.email || "").toLowerCase() !== expectedEmail) {
    return reply(403, { error: "That account does not sign in with a phone number, so its password cannot be reset from here." });
  }

  /* ---- 4. change it ---- */
  const { error: updErr } = await admin.auth.admin.updateUserById(profile!.id, { password });
  if (updErr) {
    const msg = updErr.message || "Could not change that password.";
    /* GoTrue refuses a password it considers too weak or identical to the
       current one; both are worth repeating verbatim rather than flattening. */
    return reply(400, { error: msg });
  }

  return reply(200, { ok: true, name: profile!.full_name, phone, email: expectedEmail });
});
