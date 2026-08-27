# NIVA Field Ops — localStorage → Supabase

`niva-merch-app.html` used to be a self-contained prototype: one HTML file, all
state in a `localStorage` blob, a role dropdown in the header, and photographs
stored as base64 data URLs. It now talks to the Supabase project defined by
`supabase/migrations/0001…0004` + `supabase/seed.sql`.

It is still one HTML file. What changed is where the truth lives.

---

## 1. Paste your project values here

Open `niva-merch-app.html` and edit **lines 610–611**:

```js
const SUPABASE_URL  = "https://YOUR-PROJECT.supabase.co";
const SUPABASE_ANON = "YOUR-ANON-KEY";
```

Both values are in the Supabase dashboard under **Project Settings → API**:

| Constant          | Dashboard field                        |
| ----------------- | -------------------------------------- |
| `SUPABASE_URL`    | **Project URL**                        |
| `SUPABASE_ANON`   | **Project API keys → `anon` `public`** |

Nothing else in the file needs editing.

**The `anon` key is publishable by design.** Every table runs
`force row level security` with policies granted only to `authenticated`, so a
request carrying nothing but this key can read and write nothing at all.
Authority comes from the signed-in user's own JWT.

**The `service_role` key must never appear in this file**, or in anything a
browser loads. It bypasses RLS entirely. If one is ever pasted here, treat it as
compromised and rotate it.

Leave the placeholders alone and the app boots into a **setup panel** that shows
exactly this instruction. That is a configuration state, not an error: no
request is attempted and nothing is written to the console.

### Seed logins

`supabase/seed.sql` contains **no password**. You choose one when you seed, and
it is shared by all nine demo accounts:

```bash
PGOPTIONS="-c niva.seed_password=the-password-you-choose" \
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql
```

| Email                          | Role         |
| ------------------------------ | ------------ |
| `vikram.rao@niva.example`      | Admin        |
| `rohan.mehta@niva.example`     | Manager      |
| `priya.nair@niva.example`      | Manager      |
| `aditya.kulkarni@niva.example` | Merchandiser |
| `sneha.iyer@niva.example`      | Merchandiser |
| `imran.sheikh@niva.example`    | Merchandiser |
| `kavya.reddy@niva.example`     | Merchandiser |
| `rahul.verma@niva.example`     | Merchandiser |
| `meera.joshi@niva.example`     | Merchandiser |

Turn **off** email confirmation for a demo project (Authentication → Providers →
Email), or the first sign-in fails with `email_not_confirmed`. The app names
that failure specifically and tells you where to fix it.

Full backend setup is in `supabase/README.md`, sections 1–5.

---

## 2. What changed

### Identity and role

- A real **login screen** is now the entry point. There are three gate states —
  *unconfigured* (setup panel), *signed out* (email + password form), and
  *expired* (sign in and resume) — and exactly one is ever in front of the app.
- **The "Viewing as" role switcher is gone.** Role comes from
  `profiles.role` on the authenticated user's own row and from nowhere else.
  `myRole()` reads `Session.profile().role`; there is no other writer.
  Nav, view routing and button gating all key off it, and every one of those
  rules is *also* enforced server-side by RLS and the guard triggers — the
  client gating is an affordance, not the control.
- Session tokens live in `localStorage` next to the refresh token, refreshed
  silently a minute before expiry. A refresh that fails for a *network* reason
  backs off and retries; one that fails for an *auth* reason marks the session
  **expired** rather than dropping it. The app shell, the local cache, the field
  workspace and every queued write stay exactly where they are.

### Reads

`Repo.prime()` / `Repo.refresh()` pull the RLS-filtered rows and assemble them
into the denormalised shape the (unchanged) view layer already renders:

```
profiles · stores · campaigns        masters, re-read every 10 min
tasks · placements · task_images · audit_events · notifications
niva_dashboard_kpis / niva_dashboard_rollup / niva_campaign_rollup   (RPC)
```

**An empty array is a legitimate answer.** RLS filters, it does not error. A
merchandiser genuinely sees a handful of profiles and one campaign; an account
with no visible rows sees an empty state, never "loading failed".

### Writes

Nothing writes to PostgREST directly. Every mutation applies to the local cache
**and** appends to a durable **Outbox**, which is the only thing that talks to
the server. See §3.

### Images

- Evidence lives in the **private** `evidence` bucket at
  `tasks/<task_id>/<kind>/<uuid>.jpg` (`kind` ∈ `before` / `after` / `clean`).
  Campaign key visuals live in the **public** `poster-artwork` bucket at
  `campaigns/<campaign_id>/<uuid>.jpg`.
- Private objects are fetched with **batched signed URLs**, cached for 15
  minutes (re-signed at 11), persisted across reloads, and looked up
  synchronously by `resolveImg()` — so the approvals screen signs a dozen
  objects once, not per `<img>` per render.
- A capture is written to **IndexedDB first**, keyed by its eventual Storage
  path. `resolveImg()` reads that store before it reaches for a signed URL, so
  a photograph taken with no signal renders from the device; the moment the
  outbox uploads it, the local copy is dropped and the same call transparently
  starts returning a signed URL. `localStorage` is the fallback when IndexedDB
  is unavailable, and the app says out loud when even that fails.

### The AR capture engine

Untouched. `GEO.*`, `arc*`, the XR frame loop and the single-frame readback are
byte-for-byte what they were, and still pass their assertions (**180/180** now —
see "Automatic reference detection" below for the ones that were added). Only
the handoff changed: `arcAttach()` stages `c.imgs.stamped` / `c.imgs.clean` into
IndexedDB against their Storage paths instead of stuffing data URLs into a
localStorage blob. `c.rec` becomes a `placements` row through `placementRow()`.

The one edit inside `runSelfTest()` is a bug fix, not a behaviour change: the
"gate arithmetic on a real task" block indexed `state.tasks[0]` blindly, which
threw against a real backend whenever the cache was legitimately empty (fresh
device, RLS visibility of zero rows, offline first run). It now falls back to
`normalizeTask()`'s own defaults.

---

## Automatic reference detection, and the re-tiering that follows

ARCore excludes a large slice of the budget and older Android fleet, and iOS has
no WebXR at all, so reference scaling — not AR — is the path most devices will
actually use. It used to demand that a merchandiser find a known-width object
and drag handles on *every* capture, which is why it mostly did not get used.

`DET` (section 2b-bis) now finds the reference rectangle on its own: downscale to
a work plane, halve again for detection, blur, Sobel, a percentile threshold,
one dilation to close the outline, Moore-neighbourhood border following,
Douglas–Peucker at three tolerances, and a score based on how well each
candidate fits a rectangle **of the known aspect ratio under the known
intrinsics**. The winner's corners are then re-derived at work resolution by
fitting a line to sub-pixel edge crossings along each side and intersecting
adjacent lines — corner localisation is a direct term in the distance error
budget, and that step is worth several percent on obliquely-viewed references.

Two reference sources matter in the field:

* **the installed poster itself**, for after-shots. Its true size is already on
  the task, it needs no extra kit, and it is centred in frame by construction.
  This is the default.
* **a printed A4 sheet** (210 × 297 mm) taped flat, for before-shots.

Manual 2-handle and 4-handle modes remain, and a failed or rejected detection
hands its corners straight to the 4 handles rather than resetting.

Nothing is accepted silently. The outline is drawn with a confidence figure and
the merchandiser confirms it once; the lock then survives only while the
detection keeps agreeing with itself, and a jump large enough to be a different
object breaks it and asks again.

**Every capture now carries a derived error bar**, not a constant:
`sqrt(focal² + refDim² + corner² + barrel²)`, where the focal term comes from
whatever produced the focal length (a device calibration records its own
tape-measure and handle uncertainty when it is saved), `refDim` is the
reference's own dimensional tolerance, `corner` is the measured line-fit
residual, and `barrel` is uncorrected radial distortion growing as r² from the
optical centre — which is also why the HUD nudges an off-centre reference back
toward the middle.

### The re-tiering

A **calibrated** reference-scale capture that passes every gate now counts as
VERIFIED, equal to AR for the placement KPI. `TIER_META[*].verified` is the
single definition, and `placementVerified()` reads it. AR remains the strongest
tier: `rank` is untouched, so `bestPlacement()` still prefers it, and it keeps
its own badge and the same-frame provenance chip. Tier `Be` (assumed focal
length, worth roughly ±12 %) and tier `C` (typed by hand) stay unverified.

**This disagrees with the database as shipped.** `0001_schema.sql` defines
`placements.is_verified` as `passed and tier in ('Asd','As','Ad','A')`.
`supabase/migrations/0005_retier_reference_scale.sql` corrects it, and until it
is applied the server rollup will under-count placement-verified relative to
what the client shows. The migration is a table rewrite (a stored generated
column's expression cannot be altered in place) and it re-classifies historical
passing `Bq`/`B` rows by design, so the KPI steps up the moment it lands.

`is_same_frame` deliberately does **not** widen: same-frame provenance means the
photograph was read back out of the XR frame that produced the measurement, and
no camera-tier path can do that. The client had exactly this bug for one commit
— `placementSingleFrame()` was derived from `placementVerified()` and silently
inherited the reference tiers the moment they became verified — and a self-test
assertion now pins it.

### What the new assertions cover

The suite went from 107 to **180**. The additions pin the detector primitives
(corner ordering, convexity, area, the rectangularity residual, contour
following, polygon approximation, workspace buffer reuse), the error algebra
against hand-computed arithmetic, the degradation ladder, the re-tiering
bookkeeping, the `[ref …]` note round-trip, and — the ones that would actually
catch a sign error — three **end-to-end** cases that render a rectangle at a
known pose and assert that the whole detect → refine → homography → pose chain
recovers the distance and yaw that went in.

---

## 3. The offline-first model

Merchandisers work in shops with no signal. The design consequence:

**The local cache is the rendering source of truth. The server is where writes
eventually land.**

### The outbox

`Outbox` is a FIFO queue in `localStorage` (`niva.outbox.v1`) with photo bytes
in IndexedDB (`niva.blobs`). It survives a reload, a browser restart, an expired
token and a flat battery.

- **Idempotency.** Every insert carries a **client-generated UUID primary key**,
  so a retry whose response was lost comes back `409 / 23505` on `*_pkey` and is
  treated as success. Storage uploads use a fresh UUID filename and never set
  `upsert`, so a duplicate `POST` is likewise a benign 409 (there is
  deliberately **no UPDATE policy** on the evidence bucket, which is what makes
  an evidence photo unswappable). `audit_events` has a `bigint identity` PK and
  cannot work that way, so a *retry* there probes for an identical row first.
- **Grouping.** A submission is one group and drains in this order, because the
  storage and RLS policies both require the task to still be open:

  ```
  bytes → placements → task_images rows → status patch → notifications
  ```

  If any step fails **permanently**, the whole group is cancelled together. A
  task can never end up `Submitted` with half its evidence missing.
- **Backoff.** Retryable failures (offline / timeout / 5xx / 429) back off
  exponentially to 60 s with jitter. Permanent failures (403, RLS, a guard
  trigger) are never retried — they are surfaced to a human in the sync panel,
  where they can be retried explicitly or discarded.
- **Per-user tagging.** Ops carry the `userId` that queued them and are never
  drained under a different identity. Sign in as someone else on a shared device
  and the previous user's queue parks until they sign back in — and the app says
  so rather than pretending it synced.
- **Self-healing.** Parking on a transient blocker (no session, no radio)
  re-arms a 15 s heartbeat, so a silent token refresh or a network that returned
  without firing an `online` event cannot leave work stranded.

### Submission is deliberately NOT optimistic

Every other mutation applies locally at once. Submission does not. The task
stays **In Progress**, the capture form is replaced by a read-only *"Submission
queued on this device"* panel that says **"THIS IS NOT SUBMITTED YET"**, and the
status flips only when the server has the evidence *and* accepts the change.

Showing "Submitted" the instant the button is pressed would be a lie in exactly
the situation this app exists for.

### Honest sync state, everywhere

| Surface | What it says |
| --- | --- |
| header chip | `Synced` / `N syncing` / `Offline · N queued` / `Can't reach the server` / `Sign-in expired` / `N failed` |
| sync panel | queued ops, refused ops with the server's own reason, last successful write, last read, photos held locally, whether durable storage works at all |
| task detail | a banner: `Submitting · N steps left`, `N queued`, or `N changes refused` |
| task lists | the same chip beside the status chip |
| audit timeline | entries this device wrote but has not flushed are labelled **"not yet on the server"** |
| dashboard | says whether the numbers came from the **server rollup** or from **this device** |

An empty write queue does **not** make the app "Synced": if the last *read*
failed for a transport reason, the chip says `Can't reach the server` and names
how stale the screen is.

### Dashboard numbers

`niva_dashboard_kpis` / `niva_dashboard_rollup` / `niva_campaign_rollup` are the
authority — they count exactly the rows the session can see, using the stored
`is_verified` / `is_same_frame` / `tier_rank` generated columns, so the
definition of "placement verified" cannot drift between the browser and a
report. For an Admin that is one small response rather than a national task
dump.

What the server cannot know is what is still in this device's outbox. So the
**moment anything is queued the dashboard counts locally and says so** —
understating the user's own work is the same class of lie as overstating it.

### Realtime

This build **polls** (45 s, plus on reconnect, on tab focus and after a drain)
rather than driving Supabase Realtime. Realtime is Phoenix channels over a
WebSocket: join, heartbeat, `postgres_changes` config, per-topic token refresh,
reconnect/backoff — several hundred lines that cannot be tested against anything
but a live project, for an app whose dashboard is already authoritative through
a server-side rollup. **Latency to another user's change is therefore up to
45 seconds, not instant.** That is a deliberate trade, and it is the first thing
to revisit if the approvals queue needs to feel live.

---

## 4. How to verify each layer against a real project

Work upwards. Each step assumes the one before it passed.

### 4.1 Schema, RLS and rollups (no browser)

```bash
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls_test.sql
```

This is the backend's own suite and it is the authority on whether the policies
and guard triggers behave. Nothing in the client can compensate for it failing.

### 4.2 Unconfigured boot

Open the file with the placeholders untouched. Expect the **setup panel**, and
**zero** console output and **zero** network requests.

### 4.3 Sign-in and role

Paste the config, reload, sign in as `vikram.rao@niva.example` (Admin).

- The header shows the name and role from `profiles`, and there is **no way to
  change role in the UI**.
- Sign in as `aditya.kulkarni@niva.example` — nav collapses to **My Tasks** only.
- Sign in as `rohan.mehta@niva.example` — **Approvals** and **Create Task**
  appear, **Users & Roles** and **Audit Trail** do not.

If sign-in works but you get *"that login worked, but the account has no profile
row"*, `seed.sql` did not run, or ran before the auth user existed.

### 4.4 Reads and RLS

As a merchandiser, `All Tasks` is not reachable, and `My Tasks` shows only rows
where you are the assignee. As a manager, the task register shows the union of
{tasks you manage} and {tasks in campaigns you own}. **Empty is not an error** —
an account with no visible rows should show an empty state, never a failure.

Confirm the dashboard header says **"Counted by the server across every row your
account can see"**. If it says "counted from this device's cache" with nothing
queued, the RPCs are not reachable — check that `0004_functions.sql` ran and
that `grant execute … to authenticated` at the end of it applied.

### 4.5 Storage and signed URLs

As a manager, create a task with a BEFORE photo and a poster key visual. Then in
the Supabase dashboard:

- `evidence` → `tasks/<task_id>/before/<uuid>.jpg` exists and the bucket is
  **private**;
- `poster-artwork` → `campaigns/<campaign_id>/<uuid>.jpg` exists and is public;
- in the browser Network tab, one `POST /storage/v1/object/sign/evidence` per
  page of evidence, **not one per image per render**. Re-render the page: no new
  sign request for 11 minutes.

If the poster upload 403s, you are not the campaign's `owner_id` — that is
`niva_artwork_write` doing its job, and the outbox surfaces it as a named
failure rather than a silent drop.

### 4.6 The full lifecycle

As a merchandiser: check in (geofence), start work, guided capture (or
*Simulate photo capture* on a desktop), remarks, submit. As the manager:
approve, then generate the completion record.

Then check in SQL:

```sql
select status, submitted_at, approved_at, closed_at, completion_ref,
       best_placement_id
  from public.tasks where task_code = '...';

select action, actor_name, actor_role, occurred_at, recorded_at
  from public.audit_events where task_id = '...' order by occurred_at;
```

- `completion_ref` is minted **by the FSM trigger**, not the client.
- `best_placement_id` is maintained **by trigger**; the client never sets it.
- Every `audit_events` row has `actor_id` / `actor_name` / `actor_role` filled
  in by `niva_stamp_audit_actor()` — the client never sends them, and claiming
  someone else's id raises `NIVA_ACTOR_MISMATCH`.
- `occurred_at` (device time) and `recorded_at` (server time) will differ by
  hours for anything queued offline. That is the point.

### 4.7 Offline → reload → online

The one that matters most.

1. DevTools → Network → **Offline**.
2. Take a capture and submit it. Expect: the task stays **In Progress**, the
   banner reads *"Submitting · N steps left"*, the header chip reads *"Offline ·
   N queued"*, and the photograph still renders (from IndexedDB).
3. **Reload the page.** Still offline. The queue count, the submitting banner
   and the photograph must all come back.
4. **Close the browser entirely and reopen it.** Same again.
5. Go back **Online**. The queue drains, the task becomes Submitted, and the
   banner disappears.
6. In SQL, confirm **exactly one** `task_images` row per photo, **one**
   `placements` row per capture and **one** `Execution submitted` audit row.
   Duplicates here mean the idempotency story is broken.

### 4.8 Session expiry mid-use

In the Supabase dashboard, revoke the user's sessions while the app is open (or
wait out the JWT). Expect the **"Session expired"** gate over a still-mounted
app, the queue **paused not lost**, and syncing resuming on sign-in as the same
user.

---

## 5. The offline test harness (no live project needed)

`tools/` contains a fixture backend so the request-building and response-parsing
paths can be exercised without a Supabase project. **It is test scaffolding and
is excluded from deployment by `.vercelignore` — `mock-supabase.js` replaces
`window.fetch` and must never be served from the app's origin.**

```bash
node tools/extract.js         # pull the <script> body out for `node --check`
node --check tools/app.extracted.js
node tools/make-harness.js    # build tools/harness.html (config + mock + test hooks)
node tools/serve.js 8787      # a real origin, so localStorage/IndexedDB behave
```

Then open `http://localhost:8787/tools/harness.html`, load `tools/verify.js`,
and run the phases on `window.__VERIFY__`. `tools/reset.html` wipes device state
between runs (it has no app on it, so nothing can rewrite storage after the
wipe).

The mock reproduces the *shapes* the real schema produces: snake_case columns,
the real enum labels, the generated `is_verified` / `is_same_frame` /
`is_unverified` / `tier_rank` columns, the exact return signature of the three
rollup functions, RLS as a row **filter**, `409 / 23505` on duplicate PKs, `409`
on re-POSTing an existing object, `NIVA_*` named exceptions, server-assigned
identity PKs, and trigger-stamped `actor_id` / `uploaded_by` / `created_by` /
`completion_ref` / `best_placement_id`.

Useful controls: `__MOCK__.setOnline(false)`, `__MOCK__.offline = true` (radio
dead but `navigator.onLine` still true), `__MOCK__.failNext`,
`__MOCK__.revokeAll()`, `?fixture=persist` (survive a reload), `?offline=1`
(boot already offline), `?fixture=fresh`.

---

## 6. What is NOT verified without a live backend

Be blunt about this. The harness proves the client builds the right requests and
parses the right responses. It cannot prove the server agrees.

**Not verified here — verify against a real project:**

1. **That the SQL is correct.** `supabase/tests/rls_test.sql` is the authority
   on the policies and guard triggers. The mock re-implements an *approximation*
   of them; if the two ever disagree, the SQL is right and the mock is wrong.
2. **PostgREST's real query grammar.** The mock understands the operators this
   app actually emits (`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `in`, `is`,
   `order`, `limit`). Anything else, and every embedding/resource-embedding
   form, is untested.
3. **GoTrue's real behaviour** — token lifetimes, refresh-token rotation and
   reuse detection, rate limiting, `email_not_confirmed`, lockout. The app has
   named branches for these; only the happy path and a hard revoke are exercised.
4. **Real Storage** — multipart, the 20 MB `file_size_limit`, MIME-type
   enforcement, real signed-URL expiry and its 400/404 shapes, and CORS. Signed
   URLs are minted by the mock as strings and never fetched.
5. **`niva_geofence_check`** is exposed by `0004_functions.sql` and is **not
   called by the client** — check-in still uses the browser's own haversine and
   sends the result as data for the transition guard to validate. Moving the
   authority server-side is an open item.
6. **Numeric round-tripping.** PostgREST returns `numeric` as a JSON *string*
   (`"6.00"`). `num()` coerces on the way in and the mock mimics the strings,
   but real precision behaviour on `numeric(8,3)` at the boundaries is untested.
7. **Concurrency between two real devices** — two merchandisers on one task, a
   manager approving while a submission is in flight. The `updated_at`
   never-move-backwards rule in `Repo.assemble()` is exercised only
   synthetically.
8. **The AR capture path on device.** WebXR `immersive-ar`, `camera-access`, the
   opaque camera texture and the single-frame readback cannot run in a desktop
   browser at all. The 180 geometry assertions cover the *maths* and the WebGL
   readback/Y-flip pipeline against a texture we control; they do not cover a
   real phone. Use the on-device diagnostics panel (⋮ → Diagnostics) for that.
9. **The reference detector against real optics and real lighting.** Its accuracy
   and timing are measured against synthetic frames rendered through the same
   pinhole model the app uses, so they exercise the geometry and the code but not
   rolling shutter, motion blur, autofocus hunting, JPEG/ISP sharpening halos,
   glare on a laminated poster, or a badly lit aisle. Nor do they exercise the
   real cost of `drawImage` from a live camera texture on a budget SoC. Use
   ⋮ → Diagnostics → **Benchmark detector** on the target handset, and treat the
   degradation ladder as the safety net it is.
10. **Real geolocation.** Desktop runs use the simulated fallback.
11. **IndexedDB eviction under real storage pressure.** `navigator.storage
    .persist()` is requested at boot, but it is a request, not a guarantee.

---

## 7. Where the offline model could still lose or duplicate data

Known and deliberate, in rough order of how much they should worry you.

1. **A device that is wiped, lost or has its site data cleared loses everything
   still queued.** There is no server-side draft. The sync panel reports the
   pending count and whether durable storage is even working, so a user can see
   the exposure — but this is the fundamental limit of a client-only queue.
2. **Two browsers, one account.** The queue is per-device. Work queued on a
   phone does not sync from a laptop, and the sign-out dialog says so
   explicitly.
3. **`audit_events` retries are matched by probe, not by key.** It has a
   server-assigned `bigint` PK, so a retry looks for a row with the same
   `task_id` + `action` + `occurred_at` before re-posting. Two *genuinely
   distinct* events sharing all three (same task, same action, same
   millisecond) would collapse into one. Vanishingly unlikely from a UI, but it
   is a real hole, and the fix is a client-supplied idempotency key column.
4. **A cancelled group leaves already-landed rows behind.** If step 3 of 5 is
   refused, steps 1–2 have already committed. The task stays In Progress and the
   captures stay on the device, so a resubmit is safe (the re-POSTs collide with
   themselves and are treated as landed) — but the database keeps an orphan
   `placements` / `task_images` row from the first attempt. `placements` is
   immutable by design and cannot be cleaned up.
5. **`Blobs.sweep()` runs once at boot.** It is deliberately over-inclusive
   (outbox + failed ops + every field-workspace capture + every task's image
   paths), but any future code path that holds a blob key outside those places
   would have its bytes swept.
6. **Blob loss between upload and the image row.** Once bytes upload, the local
   copy is dropped. If the `task_images` insert is then refused, a resubmit's
   upload has no bytes — so it asks Storage whether the object is already there
   and continues if so. If Storage says no *and* the bytes are gone, the op
   fails **loudly and permanently**. That is correct: silently succeeding would
   mark a task submitted with no photograph.
7. **`storage.objects` orphans.** An upload that succeeds inside a group that is
   later cancelled leaves the object in the bucket with no `task_images` row
   pointing at it. Harmless, invisible, and it accumulates.
8. **Polling latency (up to 45 s).** Two managers can both open the same
   submission and both press Approve. The second one's `PATCH` is refused by
   `niva_tasks_transition_guard` with `NIVA_ILLEGAL_TRANSITION`; the outbox
   re-reads the row, sees the target status already applied, and treats it as a
   benign duplicate. No data is lost — but the second manager's *audit event*
   still lands, so the trail shows two approval attempts. That is arguably
   correct.
9. **Notifications broadcast to a role have no server-side read state.** Only
   `read_at` on rows addressed to you personally is writable
   (`notifications_update_own` + `niva_notifications_guard`). Role broadcasts
   are marked read locally only, so they come back unread on another device.
   Honest, and what the schema supports.
10. **`localStorage` unavailable** (private mode, quota, enterprise policy)
    means the queue does not survive a reload. The app detects this, toasts
    once, and the sync panel shows **"Durable storage: NO"**. It does not
    refuse to work — a merchandiser standing in a shop still needs the app.
