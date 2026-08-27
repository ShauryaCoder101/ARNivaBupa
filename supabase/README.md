# NIVA Field Execution — Supabase backend

This folder is the database behind `niva-merch-app.html`. The app itself is
still a single vanilla-JS file with no build step; it will talk to Supabase
directly over the PostgREST and Storage HTTP APIs. There is **no server of our
own in between**, so everything that decides "who may see or change what" lives
in this folder, as Postgres row-level security policies and triggers.

Written for someone who has never used Supabase. Follow it top to bottom.

```
supabase/
  migrations/
    0001_schema.sql      tables, enums, foreign keys, RLS switched on
    0002_rls.sql         authorization helpers, grants, every policy
    0003_storage.sql     the two buckets and their object policies
    0004_functions.sql   triggers, the status state machine, dashboard rollups
  seed.sql               the prototype's demo data: 3 campaigns, 24 stores, 9 users
  tests/rls_test.sql     proves the policies work — run this after seeding
  README.md              you are here
```

---

## 1. Create a Supabase project

1. Go to <https://supabase.com> and sign up (the free tier is enough).
2. **New project**. Pick an organisation, a project name, a region close to
   your users (`ap-south-1` / Mumbai for an India-facing app), and a database
   password. **Write the database password down** — you need it for `psql`, and
   Supabase will not show it to you again.
3. Wait ~2 minutes for the project to finish provisioning.

### Turn off email confirmation for the demo

**Authentication → Sign In / Providers → Email**, and switch **Confirm email**
off. The seeded accounts are created already-confirmed, so this only matters if
you later sign someone up from the app. Turn it back on for anything real.

---

## 2. Find your project URL and keys

**Project Settings → API**. Three things matter:

| Thing | Looks like | Goes where |
| --- | --- | --- |
| Project URL | `https://abcdefgh.supabase.co` | in the client, in plain sight |
| `anon` / publishable key | a long JWT starting `eyJ...` | in the client, in plain sight |
| `service_role` / secret key | another long JWT | **nowhere near the client** |

**Why the `anon` key is safe to ship in your HTML.** It is not a password. It
is a bearer token that says only "I am an anonymous visitor to this project".
Every request made with it is executed as the Postgres role `anon`, which this
schema grants *nothing*: `0002_rls.sql` runs `revoke all on all tables in schema
public from anon`. After a user signs in, Supabase Auth hands the browser a
second, short-lived JWT identifying *that user*; PostgREST switches to the
`authenticated` role and stamps `auth.uid()` from that JWT, and the policies do
the rest. So the anon key gets you as far as the login form and no further.
That is the entire security model of a Supabase client app, and it only holds
if the policies are right — which is what `tests/rls_test.sql` is for.

**Why the `service_role` key must never ship.** It bypasses row-level security
entirely. Anyone holding it can read every task, every geotagged photograph and
every user record in the project. It belongs in a server environment variable
or a CI secret, never in HTML, never in a public repo, never in a Vercel
`NEXT_PUBLIC_*`-style variable. This project does not need it at runtime at
all — the only things that use it are the optional user-creation script in
step 4 and any admin tooling you write later.

> Note: even `service_role` cannot edit `audit_events` or `placements` here.
> `0002_rls.sql` revokes UPDATE/DELETE/TRUNCATE on those tables from
> `service_role` explicitly, and a trigger blocks the operation for every role
> on top of that. A leaked service key is a catastrophic *confidentiality*
> failure, but it still cannot quietly rewrite the evidence.

---

## 3. Apply the migrations

Run them **in numeric order**. All four are idempotent — re-running them is
safe and is the normal way to apply an edit.

### Option A — the SQL Editor (no tools to install)

1. **SQL Editor → New query** in the Supabase dashboard.
2. Open `migrations/0001_schema.sql`, copy the whole file, paste, **Run**.
3. Repeat for `0002_rls.sql`, `0003_storage.sql`, `0004_functions.sql`.

Each should end with `Success. No rows returned.`

### Option B — the Supabase CLI

```bash
npm install -g supabase          # or: brew install supabase/tap/supabase
supabase login                   # opens a browser
supabase link --project-ref <your-project-ref>   # the abcdefgh in your URL
supabase db push                 # applies everything in migrations/ in order
```

`supabase db push` tracks which migrations have been applied, so it will not
re-run 0001 once it has. To iterate locally instead, `supabase start` gives you
the whole stack in Docker and `supabase db reset` replays migrations + seed.

### Option C — plain `psql`

Get the connection string from **Project Settings → Database → Connection
string → URI**, and substitute your database password for `[YOUR-PASSWORD]`.

```bash
export DATABASE_URL='postgresql://postgres:...@db.abcdefgh.supabase.co:5432/postgres'

for f in supabase/migrations/*.sql; do
  echo "== $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done
```

---

## 4. Create the seed users

Postgres cannot invent a working login on its own: an account is a row in
`auth.users` *plus* a matching row in `auth.identities` *plus* a bcrypt hash in
the right column, and GoTrue (Supabase's auth service) is the thing that
normally writes all three. There are three honest ways to do it. Pick one.

### 4a. Let `seed.sql` do it (easiest, and it works)

`seed.sql` will insert the nine accounts itself — `auth.users` with a bcrypt
hash from `pgcrypto`, plus the `auth.identities` row that GoTrue needs to
recognise the email provider. It reads the password from a session setting, so
**no password is stored in this repository**; you choose one at run time.

With `psql`:

```bash
PGOPTIONS="-c niva.seed_password=<the-password-you-choose>" \
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql
```

In the **SQL Editor**: paste the contents of `seed.sql`, then add this as the
very first line before running it:

```sql
set niva.seed_password = '<the-password-you-choose>';
```

Choose something at least 8 characters — Supabase Auth rejects shorter
passwords at sign-in time.

### 4b. Create them in the dashboard, then seed

**Authentication → Users → Add user → Create new user.** Tick *Auto Confirm
User*. Create all nine with these exact email addresses:

| Email | Name | Role |
| --- | --- | --- |
| `rohan.mehta@niva.example` | Rohan Mehta | Manager |
| `priya.nair@niva.example` | Priya Nair | Manager |
| `vikram.rao@niva.example` | Vikram Rao | Admin |
| `aditya.kulkarni@niva.example` | Aditya Kulkarni | Merchandiser |
| `sneha.iyer@niva.example` | Sneha Iyer | Merchandiser |
| `imran.sheikh@niva.example` | Imran Sheikh | Merchandiser |
| `kavya.reddy@niva.example` | Kavya Reddy | Merchandiser |
| `rahul.verma@niva.example` | Rahul Verma | Merchandiser |
| `meera.joshi@niva.example` | Meera Joshi | Merchandiser |

Then run `seed.sql` **without** setting `niva.seed_password`. It matches the
accounts by email, fills in the correct name/role/title on each profile, and
carries on. (A trigger creates a `Merchandiser` profile automatically the
moment an `auth.users` row appears; the seed corrects the two Managers and the
Admin.)

### 4c. The Auth Admin API (what you would use in CI)

```bash
# Requires the service_role key. Never run this from a browser.
for u in "rohan.mehta@niva.example:Rohan Mehta:Manager" \
         "priya.nair@niva.example:Priya Nair:Manager" \
         "vikram.rao@niva.example:Vikram Rao:Admin"; do
  IFS=: read -r email name role <<< "$u"
  curl -s -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SERVICE_ROLE_KEY" \
    -H "Authorization: Bearer $SERVICE_ROLE_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"email\":\"$email\",\"password\":\"$SEED_PASSWORD\",\"email_confirm\":true,
         \"user_metadata\":{\"full_name\":\"$name\",\"role\":\"$role\"}}"
done
```

The `user_metadata.role` is picked up by the `niva_handle_new_user` trigger, so
profiles come out with the right role without any further step. Then run
`seed.sql` without `niva.seed_password`.

### The seeded credentials

- **Usernames**: the nine `@niva.example` addresses in the table above.
- **Password**: whichever one you chose in 4a / 4b / 4c. It is the same for all
  nine. Nothing in this repository contains a password, and nothing should.

`@niva.example` is a reserved, non-routable domain (RFC 2606), so these
addresses can never collide with a real inbox.

---

## 5. Run the RLS tests

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql
```

Or paste the whole file into the SQL Editor and run it. The suite ends in
`ROLLBACK`, so it changes nothing — it is safe to run against a seeded project
as often as you like.

The run prints a `PASS` / `FAIL` table of every assertion, and then:

```
NOTICE:  =====================================================
NOTICE:  ALL RLS TESTS PASSED  (81 assertions)
NOTICE:  =====================================================
```

Any failure raises at the end with the full list of failed assertion names, so
the run exits non-zero and CI notices. Nothing is left behind — the results
table is created and rolled back with everything else.

> **What has already been verified, and what has not.** The four migrations,
> `seed.sql` (both user-creation paths), and all 81 assertions were executed
> against a real PostgreSQL 18 instance during development, using a stub `auth`
> schema (`auth.uid()`, `auth.users`) and a stub `storage` schema. Migrations
> and seed were each applied twice to confirm idempotency. What could **not**
> be exercised without a live Supabase project is GoTrue actually accepting the
> seeded bcrypt credentials at `/auth/v1/token`, PostgREST's own role switching,
> and the Storage service's signed-URL issuance. Those are the things the
> command above confirms on your project — run it once after seeding.

What it proves, in both directions, for each role:

| Group | Asserts |
| --- | --- |
| A | a merchandiser sees *only* their own tasks, cannot read another's task or placement, cannot enumerate the store master; cannot reassign a task to or away from themselves, self-approve, jump to Closed, widen their own capture brief, rewrite the manager's remarks, escalate their role, edit or delete an audit row, edit or delete a placement, create a task, or forge an audit entry in someone else's name — and *can* do the things the workflow needs |
| B | a merchandiser cannot write into another task's storage prefix, cannot forge a prefix with `..`, cannot write into the manager-only `before/` folder, and *can* write into their own open task's `after/` folder |
| C | a manager sees a scoped slice rather than everything, cannot edit placements or audit rows, cannot make an illegal transition, cannot approve a task they neither own nor manage, cannot promote themselves — and *can* approve then close a task they manage |
| D | a manager who is also the assignee still cannot approve their own work |
| E | an admin sees everything and still cannot edit or delete audit rows or placements, cannot `TRUNCATE` the audit trail, and cannot make an illegal transition |
| F | `anon` can read nothing at all |
| G | the `SECURITY DEFINER` dashboard rollup returns exactly the same row count as RLS does, for a merchandiser, a manager and an admin — this is the drift detector for the duplicated visibility predicate |
| H | a notification recipient can mark it read but cannot rewrite its body |

Two of these were only correct on the second attempt, which is the argument for
writing them at all:

- **A23** originally *passed the forgery through*. A `BEFORE INSERT` trigger
  runs before the RLS `WITH CHECK`, so a trigger that silently overwrote
  `actor_id` made the check vacuously true — the row came out correctly
  attributed, but the attempt to write history in someone else's name was
  accepted rather than refused. The stamping triggers now raise
  `NIVA_ACTOR_MISMATCH` instead of silently correcting.
- **C3** was a bad fixture, not a bad policy: it picked a task managed by the
  *other* manager but sitting in a campaign this manager **owns**. Campaign
  ownership is a second, independent grant, so she could legitimately see it.
  The test now uses a task that is foreign on both axes, and a companion
  assertion (C3b) pins down the ownership grant explicitly.

---

## 6. What each migration does

### `0001_schema.sql` — the shape of the data

The prototype keeps one denormalised array of tasks in `localStorage`, each
task inlining its store, its images, its AR measurement and its audit trail.
RLS cannot protect elements inside a JSON blob, so that blob is decomposed
into eight tables:

| Table | Holds | Notable rule |
| --- | --- | --- |
| `profiles` | identity + role, 1:1 with `auth.users` | `role` is the authorization principal |
| `stores` | the store master | merchandisers see only their own stores |
| `campaigns` | brand cycle + the poster brief a task inherits | `owner_id` anchors manager scope |
| `tasks` | one store × one campaign | carries the status FSM |
| `task_images` | pointers into Storage | bytes never live in Postgres |
| `placements` | the AR verification record | **immutable** |
| `audit_events` | the evidentiary log | **append-only** |
| `notifications` | per-user / per-role inbox | only `read_at` is mutable |

Real enums are used for the four vocabularies the app branches on — `niva_role`,
`task_status`, `image_kind`, `verification_tier` (plus `capture_mode` and
`notification_kind`) — with labels byte-identical to the prototype's JS
constants (`'Rework Required'`, `'Asd'`, `'single-frame'`), so the migrated
client is a rename of property paths rather than a redesign.

`ON DELETE` behaviour is chosen per relationship rather than by habit:

- `tasks.campaign_id`, `tasks.store_id`, `tasks.assignee_id`, `tasks.manager_id`
  → `RESTRICT`. Deleting a campaign, a store or a user must never silently take
  field history with it. Deactivate (`is_active`) instead.
- `audit_events.task_id` → `RESTRICT`. **This is what makes a task with any
  history undeletable, by anyone, including an admin.** The referential
  constraint does the work, not a policy.
- `profiles.id → auth.users` → `CASCADE`. Deleting the login deletes the
  profile; the `RESTRICT`s above then block that too if the user has history.
- `task_images.task_id` → `CASCADE`. An image row is meaningless without its
  task, and a task can only be deleted while it is an untouched Draft.

`placements` carries three stored generated columns — `is_verified`,
`is_same_frame`, `is_unverified` — that encode `placementVerified()`,
`placementSingleFrame()` and `placementUnverified()` from the prototype, plus a
`tier_rank` that encodes `bestPlacement()`'s ranking. Computing them once, in
one place, is what stops the dashboard, a report and the client from ever
disagreeing about what "verified" means.

Every table gets `ENABLE ROW LEVEL SECURITY` **and** `FORCE ROW LEVEL
SECURITY`. `ENABLE` alone exempts the table owner, and in Supabase the owner is
`postgres` — the role the SQL Editor runs as. `FORCE` means a careless
dashboard query cannot read across tenants either. (One practical consequence:
see §8.)

### `0002_rls.sql` — who may do what

Helper functions first, then grants, then one policy per table per operation.

**The recursion problem.** The obvious "admins can read everything" policy on
`profiles` selects from `profiles`, which re-evaluates the policies, which
selects from `profiles`. Postgres aborts the whole query with *"infinite
recursion detected in policy for relation profiles"* — so the symptom is not a
leak but that every read fails, including allowed ones. The fix here has two
parts, both in `niva_current_role()`:

1. `SECURITY DEFINER` + `STABLE` + `set search_path = ''` (with every name
   fully qualified, which an empty search path forces). The lookup runs as the
   owner, so the caller's policies do not apply to it, and a hostile user
   cannot shadow `profiles` with an object in a schema they control.
2. A transaction-local re-entrancy flag. `SECURITY DEFINER` alone is only
   enough if the owning role carries `BYPASSRLS`, and `FORCE ROW LEVEL
   SECURITY` deliberately subjects the owner to policies. Rather than depend on
   that platform detail, a nested call returns `NULL` instead of recursing; the
   outer call still resolves correctly because the `profiles_select_self`
   policy is a bare `id = auth.uid()` predicate that needs no role lookup. The
   result is correct and terminating with or without `BYPASSRLS`.

   This was tested rather than assumed. Flipping `niva_current_role()` to
   `SECURITY INVOKER` — which is exactly the situation an owner without
   `BYPASSRLS` produces — the guarded version still resolves every role
   correctly (an admin still sees all 24 tasks). Removing the guard from that
   same function degrades a merchandiser's role lookup to `NULL` (silent
   denial) and makes an admin's `select count(*) from tasks` abort the backend
   with `ERRORDATA_STACK_SIZE exceeded`. Both failure modes are exactly what
   the guard exists to prevent.

**Every policy is written per operation with an explicit `WITH CHECK`.** On an
`UPDATE`, a policy with `USING` but no `WITH CHECK` inherits `USING` as its
check — which is the classic hole where a user rewrites a row into a shape they
could not have read. The checks are spelled out even where they would have been
inherited, so the intent is visible in the file.

The attacks each policy is aimed at are named in comments next to the policy.
The four the brief called out specifically:

| Attack | Defence |
| --- | --- |
| write a row you cannot read (missing `WITH CHECK`) | every INSERT/UPDATE policy has an explicit `WITH CHECK`, and the RLS tests assert the post-image constraints (A9, A12, A13, C11) |
| a merchandiser reassigning a task to themselves | `tasks_update_field`'s `USING` never matches a row the caller is not already the assignee of, so the row is invisible to the UPDATE and zero rows change (test A8); the reverse — giving a task away — is blocked by the `WITH CHECK` and by `niva_tasks_column_guard` (test A9) |
| inserting an audit row in another user's name | `audit_insert_actor` requires `actor_id = auth.uid()`, *and* `niva_stamp_audit_actor` overwrites `actor_id`/`actor_name`/`actor_role` from the caller's own profile, so even a policy mistake cannot produce a mis-attributed row (tests A23, A27) |
| escalating your own `profiles.role` | a policy cannot compare `NEW.role` to `OLD.role`, so `niva_profiles_guard` refuses the change unless the caller is an Admin; self-provisioned profiles are forced to `Merchandiser` on insert (tests A14, A15, C11) |

### `0003_storage.sql` — the two buckets

| Bucket | Public? | Path convention |
| --- | --- | --- |
| `poster-artwork` | **public** | `campaigns/<campaign_id>/<file>` |
| `evidence` | **private** | `tasks/<task_id>/<kind>/<file>`, `kind ∈ before, after, clean` |

Poster artwork is the key visual that is about to be printed at A1 and stuck in
a shop window; public read leaks nothing and saves the client a signed-URL
round trip.

Evidence is the opposite. These are geotagged photographs of real retail sites
with a store code, a merchandiser's name and a GPS fix burned into the frame.
Public read on that bucket would publish a map of a client's retail estate and
put a name to who was standing in it. The bucket is private and is served only
through short-lived signed URLs
(`/storage/v1/object/sign/evidence/<path>`), which are themselves gated by the
`niva_evidence_read` policy — so a signed URL can only be minted for an object
whose task the requester can already see.

**The task id is in the path on purpose.** `storage.objects` has no foreign key
to `public.tasks`, so the object's own name has to carry the join key; that is
the only thing a storage policy can decide on. Uploads are checked against it:
a merchandiser may only write under `tasks/<a task assigned to them>/after/`
or `.../clean/`, and only while that task is `In Progress` or `Rework
Required`. Managers own the `before/` prefix. There is **no UPDATE policy** on
the evidence bucket, so an upload with `upsert: true` is refused — clients must
generate a fresh UUID filename per capture, which is what makes an evidence
photo un-swappable.

`FORCE ROW LEVEL SECURITY` is deliberately **not** applied to
`storage.objects`: that table is owned and operated by
`supabase_storage_admin`, and forcing RLS would apply these policies to the
Storage service's own bookkeeping and break it. RLS is already `ENABLE`d there,
which is what gates client requests.

### `0004_functions.sql` — the rules RLS cannot express

A policy is a boolean over a single row image. It cannot compare `OLD` to
`NEW`, so anything of the form "you may not *change* X" has to be a trigger.
Triggers also fire for the table owner and for `service_role`, which policies
do not — so they are the last line that still holds if a service key leaks.

**The status state machine.** `Draft → Assigned → In Progress → Submitted →
Approved → Closed`, plus `Submitted → Rework Required → In Progress`. Anything
else raises `NIVA_ILLEGAL_TRANSITION`. `Closed` is terminal. The trigger
enforces three separate things:

1. **the shape of the graph** — is this edge in the map at all;
2. **who may traverse it** — assignment/approval edges require the task's
   manager or an admin; submit requires the assignee; `Assigned → In Progress`
   additionally requires a *passing geofenced check-in* in the same statement;
3. **the lifecycle stamps** — `submitted_at`, `approved_at`, `closed_at` and
   `completion_ref` are written by the server and never accepted from the
   client, so they cannot be back-dated.

Separation of duties is enforced independently of RLS: `Submitted → Approved`
raises `NIVA_SELF_APPROVAL` when the approver is the assignee, *even for an
Admin*. Signing off your own work is the single most valuable fraud in a
field-execution system, so it has two locks — the RLS policy (a merchandiser's
UPDATE can never produce an `Approved` post-image) and this trigger.

**Immutability.** `niva_block_mutation` raises on any UPDATE or DELETE of
`audit_events` or `placements`, for every role including the owner.

**The dashboard rollup.** `niva_dashboard_kpis()`, `niva_dashboard_rollup(
granularity, campaign)` and `niva_campaign_rollup()` return the nine KPI counts
and the region/state/city breakdown the prototype renders, so the client never
pulls every task row to draw the national dashboard. They are `SECURITY
DEFINER` — which is exactly the shape of bug that leaks a national total to a
merchandiser, so three things keep them honest:

1. the underlying `niva_visible_tasks()` restates the visibility predicate
   **explicitly in its `WHERE` clause** and does not rely on RLS at all;
2. `auth.uid()` and `niva_current_role()` still resolve the *caller's* identity
   inside a definer function (they read the request GUC, not the session role);
3. `EXECUTE` on `niva_visible_tasks()` is revoked from `authenticated`, so the
   row source is reachable only through the aggregates, which never return a
   task id or a store name (test G8).

Because the predicate is stated twice — once in the `tasks_select` policy and
once here — tests **G1–G7** assert that the rollup's total equals a plain
`select count(*) from tasks` under RLS, for all three roles. If somebody edits
one and forgets the other, the suite fails.

---

## 7. Data model quick reference for the client

```
profiles(id=auth.uid, full_name, role, title, region)
stores(id, store_code, name, city, state, state_code, region, lat, lng, geofence_m)
campaigns(id, code, name, brand, starts_on, ends_on, owner_id, poster_*, standoff_*)
tasks(id, task_code, campaign_id, store_id, assignee_id, manager_id,
      exec_date, display_type, width_ft, height_ft, standoff_ft, standoff_tol_ft,
      angle_tol_deg, instructions, status, merch_remarks, review_remarks,
      checkin_*, submitted_at, approved_at, closed_at, completion_ref,
      best_placement_id)
placements(id, task_id, tier, tier_label, capture_mode, distance_ft, target_ft,
      tol_ft, distance_ok, distance_source, pitch_deg, roll_deg, yaw_deg,
      angle_tol_deg, pitch_ok, roll_ok, yaw_ok, yaw_verified, angle_source,
      attitude_assumed, focal_px, focal_source, poster_w_ft, poster_h_ft,
      passed, geofence_pass, geofence_m, arm_ms, camera_w, camera_h,
      camera_readback_ms, camera_path, camera_aspect_agrees,
      camera_diagnostics, note, captured_at, recorded_at,
      is_verified, is_same_frame, is_unverified, tier_rank)     -- generated
task_images(id, task_id, kind, bucket_id, storage_path, clean_storage_path,
      placement_id, lat, lng, device, is_guided, captured_at, uploaded_by)
audit_events(id, task_id, actor_id, actor_name, actor_role, action, detail,
      gps_lat, gps_lng, occurred_at, recorded_at)
notifications(id, kind, target_role, target_user_id, task_id, body,
      created_by, occurred_at, read_at)
```

Two timestamps everywhere it matters: `occurred_at` / `captured_at` is
**device** time (useful, forgeable) and `recorded_at` is **server** time
stamped by trigger (not forgeable). Keeping both is what lets a reviewer notice
a device clock that disagrees with reality.

Seeded `task_images` rows are **metadata only** — there are no bytes in the
buckets, because the prototype generates its imagery procedurally. Point the
existing generator at any seeded row whose signed URL 404s and the app looks
exactly as it does today.

---

## 8. Things to know before you go further

**Working in the SQL Editor after this is applied.** Because every table has
`FORCE ROW LEVEL SECURITY` and every policy is granted `to authenticated`, the
`postgres` role that the SQL Editor runs as matches no policy and can read
nothing from these tables. That is intentional. To do admin work by hand, lift
it for the duration of a transaction, exactly as `seed.sql` does:

```sql
begin;
alter table public.tasks no force row level security;
--   ... your queries ...
alter table public.tasks force row level security;
commit;
```

Never leave `FORCE` off.

**Gaps the RLS-only model leaves.** With no trusted server tier, some things
simply cannot be enforced in the database, and you should know which:

1. **Measurement values are asserted by the client.** The database enforces
   *who* may write a placement, *when*, and that it can never be edited
   afterwards. It cannot verify that a device claiming `tier = 'As'`,
   `distance_ft = 6.02` actually measured that — an attacker with a valid
   merchandiser JWT and `curl` can POST any numbers they like. What the schema
   guarantees is that the number is attributable, timestamped by the server,
   and permanent. Closing this properly needs an attestation the client cannot
   forge (a signed capture from a trusted app build, or a server-side re-check
   of the image), which means a trusted tier.
2. **GPS is self-reported.** `checkin_lat/lng` come from
   `navigator.geolocation`, which a determined user can spoof. The FSM trigger
   requires `checkin_pass = true` before `In Progress`, and
   `niva_geofence_check()` lets the client ask the *server* to compute the
   distance rather than trusting its own arithmetic — but the coordinates
   themselves still originate on the device.
3. **Notifications are client-raised.** The manager's "Approval Required"
   notification is inserted by the merchandiser's browser at submit time.
   The blast radius is capped (the sender is recorded in `created_by`, and the
   notification must hang off a task the sender can already see), but a
   merchandiser can send a *misleading body* to their own manager. Moving
   notification creation into a database trigger on `tasks` would remove this;
   it is a small, clearly-scoped follow-up.
4. **Immutability is trigger-deep, not storage-deep.** A superuser or the table
   owner can `alter table ... disable trigger` and then edit history. Postgres
   has no owner-proof immutability. What the design buys is that tampering must
   be a deliberate, separately-auditable DDL act rather than an accidental
   `UPDATE`. If you need more than that, ship `audit_events` to an append-only
   sink (S3 Object Lock, or a WORM log) on a schedule.
5. **Deleted storage bytes vs. surviving rows.** `task_images` rows and
   `storage.objects` are kept in step by matching policies, not by a foreign
   key. If someone deletes an object through the Storage API while the row
   survives, you get a dangling pointer. The policies make this only possible
   for the assigned merchandiser on their own un-submitted task, which is the
   case where it does not matter.
6. **Rate limiting and abuse.** PostgREST will happily accept as many requests
   as the client sends. Supabase's platform limits are the only backstop; if
   this grows, put the API behind a gateway.

---

## 9. What changes in the app next

This pass deliberately does not touch `niva-merch-app.html`. Here is the work
this foundation enables, in the order it should be done.

1. **Add a Supabase client shim.** ~80 lines of `fetch` wrappers over
   `/rest/v1/...` and `/auth/v1/...` — no SDK needed, and no build step, which
   keeps the single-file property. Store the project URL and anon key as two
   constants at the top of the file.
2. **Replace `state.currentUserId` with a real session.** Add a login screen
   (email + password → `/auth/v1/token?grant_type=password`), keep the access
   token in memory with the refresh token in `localStorage`, and drop the
   user-switcher — the role now comes from the JWT, not from a dropdown. The
   existing `myRole()` becomes "read `role` off the profile row".
3. **Replace `load()`/`save()` with per-entity fetches.** The blob write on
   every mutation goes away. `visibleTasks()` becomes `GET /tasks?select=...`
   with **no client-side filter at all** — RLS has already done the filtering,
   and a filter in the client would now be misleading rather than protective.
4. **Replace the dashboard aggregation with the rollup RPCs.**
   `POST /rest/v1/rpc/niva_dashboard_kpis` and `.../niva_dashboard_rollup` with
   `{"p_granularity":"Region"}` return exactly the tiles and bars
   `viewDashboard()` renders today.
5. **Make `transition()` optimistic-then-confirmed.** Keep the client-side
   `TRANSITIONS` map for UI affordances (greying out buttons), but treat the
   database as the authority: a `PATCH /tasks?id=eq.<id>` that comes back with
   `NIVA_ILLEGAL_TRANSITION` or `NIVA_SELF_APPROVAL` should surface the
   message in the existing `toast()` and re-fetch.
6. **Upload real bytes.** The guided-capture flow already produces a stamped
   JPEG and a clean one. Upload both to
   `evidence/tasks/<task_id>/after/<uuid>.jpg` and `.../clean/<uuid>.jpg`, then
   insert the `task_images` row and the `placements` row. Render evidence
   through signed URLs (`POST /storage/v1/object/sign/evidence/<path>` with a
   60-second expiry) rather than public URLs.
7. **Stop writing the audit trail into the task.** Every place that calls
   `audit(t, ...)` becomes a `POST /audit_events`. Do not send `actor_*` — the
   trigger fills them in, and anything you send is discarded.
8. **Keep the offline path.** A field app loses signal. The current
   `localStorage` layer is a good outbox: queue writes when a request fails and
   replay them on reconnect. The database is designed for it — every write is
   idempotent-friendly, and `occurred_at` preserves the device time of the
   original action even when `recorded_at` is hours later.
