# Running NIVA — guided poster capture

`niva-merch-app.html` is one self-contained file. No build step, no dependencies, no network calls.

---

## 1. Desktop, one command

From the folder containing the file:

```bash
python -m http.server 8731
```

Open <http://localhost:8731/niva-merch-app.html>.

Use `localhost`, not `127.0.0.1` if you want the shortest path to a secure context — both work,
but some Chrome flags only whitelist `localhost`.

> **Do not just double-click the file.** On a `file://` origin Chrome refuses `getUserMedia`, and
> `localStorage` is an opaque origin. The app still runs and explains why capture is limited, but
> you will only ever see Tier C.

Alternatives if you have no Python:

```bash
npx --yes serve -l 8731 .        # Node
php -S localhost:8731            # PHP
```

---

## 2. On a real phone, over HTTPS, on the same LAN

Camera, motion sensors, geolocation and WebXR **all require a secure context**. `http://192.168.x.x`
is not one. You need either a tunnel or a self-signed cert.

### Option A — USB port forwarding (Android only, best)

`adb reverse` maps a port on the **phone's own localhost** to your laptop. Browsers treat
`localhost` as a secure context regardless of TLS, so camera, motion sensors, geolocation and
WebXR all work with **no certificate and no internet connection**.

```bash
adb reverse tcp:8731 tcp:8731
```

Then on the phone, open <http://localhost:8731/niva-merch-app.html>.

That `localhost` is the phone's, forwarded down the USB cable to your laptop. Requirements:

- **USB debugging** on: Settings → About phone → tap *Build number* 7×, then
  Settings → System → Developer options → USB debugging.
- Plug in, and accept the *Allow USB debugging?* prompt on the phone.
- Confirm the phone is seen: `adb devices -l` should list it as `device` (not `unauthorized`).
- Re-run `adb reverse` after every unplug — the mapping does not survive a disconnect.

This is the fastest loop for AR work: no tunnel to restart, no URL to retype, and
`chrome://inspect/#devices` on the laptop gives you the phone's console over the same cable.

### Option B — tunnel (works for Android *and* iPhone)

```bash
python -m http.server 8731                 # terminal 1
cloudflared tunnel --url http://localhost:8731   # terminal 2
#   → https://random-words-1234.trycloudflare.com
```

or

```bash
ngrok http 8731
```

You get a real, publicly-trusted HTTPS URL. Open it on the phone. Nothing to trust, nothing to
install on the device. This is the only path that works painlessly on **iOS Safari**, which will not
let you accept a self-signed certificate for a camera prompt.

### Option C — self-signed cert on your LAN (last resort)

```bash
# 1. generate a cert for your machine's LAN IP (replace 192.168.1.42)
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 365 \
  -subj "/CN=192.168.1.42" -addext "subjectAltName=IP:192.168.1.42"

# 2. serve it
npx --yes http-server -S -C cert.pem -K key.pem -p 8443 .
```

Open `https://192.168.1.42:8443/niva-merch-app.html` on the phone.

**The trust caveat:** the browser will show a certificate warning.

- **Android Chrome** — tap *Advanced → Proceed*. Powerful features (camera, sensors) work after
  you proceed, but **WebXR `immersive-ar` is refused on a cert-error origin**, so you will get
  Tier B, not Tier A. To actually test Tier A over a LAN cert you must install the CA into the
  Android user trust store (Settings → Security → Encryption & credentials → Install a certificate
  → CA certificate) — at which point use the tunnel instead, it is less work.
- **iOS Safari** — proceeding past the warning is *not* enough for camera access. You must email
  yourself the `.pem`, install it as a profile (Settings → General → VPN & Device Management), and
  then explicitly enable full trust (Settings → General → About → Certificate Trust Settings).
  Use the tunnel.

### Desktop Chrome escape hatch (development only)

```
chrome://flags/#unsafely-treat-insecure-origin-as-secure
```

Add `http://192.168.1.42:8731`, relaunch. This affects your desktop browser only — it does not help
the phone.

---

## 2b. Android: same-frame capture (Tier A, raw camera access)

This is the best case: the poster is measured **and photographed in the same XR frame**, so there
is no gap at all between the measurement and the evidence photo. It needs three things.

### Requirements

| Thing | Requirement |
|---|---|
| Browser | **Chrome for Android 93+** (`camera-access` shipped in 93; ARCore-backed `immersive-ar` since 81, `hit-test` since 83, `depth-sensing` since 90). Chrome 100+ recommended. |
| ARCore | **Google Play Services for AR** installed and up to date. Play Store → search "Google Play Services for AR" → *Update*. A stale ARCore is the single most common cause of `immersive-ar` reporting unsupported. |
| Origin | **HTTPS with a certificate the phone already trusts.** A self-signed cert that you click through does *not* work: Chrome refuses `immersive-ar` on an origin with a certificate error, so you silently drop to Tier B. Use a tunnel. |

```bash
python -m http.server 8731                        # terminal 1
cloudflared tunnel --url http://localhost:8731    # terminal 2  → https://xyz.trycloudflare.com
```

Open that HTTPS URL on the phone. `ngrok http 8731` works identically.

### Remote devtools (optional)

Enable *Developer options → USB debugging* on the phone, plug it into the machine, then open
`chrome://inspect/#devices` in desktop Chrome and hit **inspect** next to the tab. You get a
normal console. The on-screen diagnostics panel below exists so you don't have to.

### The diagnostics panel — what "good" looks like

⋮ (top right) → **AR capture diagnostics** → **Run live XR probe**. Point the phone at a wall and
move it slowly for two or three seconds; the probe ends itself and prints the report. Field by field:

| Field | Healthy | Unhealthy — and what it means |
|---|---|---|
| Secure context | `yes` | `no` ⇒ not HTTPS. Nothing else will work. |
| navigator.xr present | `yes` | `no` ⇒ not Chrome for Android. |
| immersive-ar supported | `yes` | `no` ⇒ ARCore missing/outdated, or the origin has a cert error. |
| Granted | includes **`camera-access`** | missing `camera-access` ⇒ Chrome < 93, or the runtime declined. You still get Tier A measurement, but capture falls back to `handover`. |
| Not granted | `dom-overlay`/`anchors`/`depth-sensing` may be missing — all fine | `hit-test` missing would have failed the session outright. |
| XRWebGLBinding created | `yes` | `no` ⇒ `XRWebGLBinding` undefined; no same-frame capture. |
| getCameraImage available | `yes` | `no` ⇒ the binding exists but the method doesn't; browser too old. |
| Version | `WebGL 2.0 …` | WebGL 1 also works, just less strictly defined. |
| Frames observed | 30–90 | `0` ⇒ the session started but never produced a frame. |
| Viewport fx / fy | two numbers within ~1 px of each other | wildly different ⇒ non-square pixels; still handled, but unusual. |
| **view.camera present** | `yes` | `no` ⇒ raw camera access not actually delivering; capture uses `handover`. |
| **Camera image size** | e.g. `1920 × 1080`, often larger than the viewport — **that is normal and fine** | `0 × 0` ⇒ no camera image. |
| **Aspect agrees with frustum** | `yes` (skew < 2%) | `no` ⇒ the camera image is cropped relative to the viewport. The poster is still projected correctly (separate `fx`/`fy`), but say so in your report — it means the passthrough you saw and the pixels you got are framed differently. |
| Camera fx / fy | two numbers scaled up from the viewport values by the same ratio as the resolution | — |
| **Path used** | `direct` | `shader-blit` ⇒ the direct framebuffer attach was refused and the fallback ran. Still correct, slightly slower. Worth reporting. |
| **Framebuffer status** | `FRAMEBUFFER_COMPLETE` | anything else ⇒ the direct path failed; check whether the blit path picked it up. |
| Readback time | roughly **20–150 ms** for 1080p | > 400 ms ⇒ slow GPU readback; it only happens once per shutter press so it is survivable. |
| Bytes read | `width × height × 4` (8,294,400 for 1080p) | `0` ⇒ nothing was read. |
| GL error after readPixels | `none` | any hex code ⇒ the read was rejected; the blit fallback should have taken over. |
| **First 8 pixels RGBA** | varied non-zero values | all `[0,0,0,0]` ⇒ **the classic silent failure.** The app detects this, refuses the capture and falls back to handover rather than storing a black photo. |
| Mean luma | well above 2 in a lit room | ≤ 2 ⇒ black frame, same as above. |
| Hit-test results | `1` or more | `0` ⇒ no wall found yet. Move the phone slowly across the wall, don't hold it still. |
| Distance | a plausible number in feet | `—` ⇒ no hit-test result. |
| Last error | `None.` | a name + message + stack — copy the whole report. |

**Copy report** puts the whole thing on the clipboard as plain text (there is also a selectable
text box at the bottom if the clipboard is blocked). **Run geometry self-test** runs the same 107
assertions on the phone, including a real WebGL framebuffer readback and Y-flip round trip.

### What gets recorded

Every capture records how the photo was obtained, and the manager sees it:

- **`single-frame`** — badge **AR single-frame**, provenance chip *SAME FRAME AS THE MEASUREMENT*,
  footer stamped `[SAME-FRAME]`. Counts toward the **Same-frame captures** dashboard KPI.
- **`handover`** — badge **AR measured**, provenance chip *measured, then re-opened the camera*,
  footer `[HANDOVER]`. Still placement-verified, but the frame is a fraction of a second later
  than the measurement, and the record says so.

A handover is never labelled as single-frame. If `camera-access` is refused, `view.camera` is null,
the readback throws, or the pixels come back black, the app falls through to handover and writes the
reason into the placement note and the diagnostics `notes[]`.

---

## 3. Capability matrix

| Platform | Tier you get | What is genuinely measured | Requires |
|---|---|---|---|
| **Android Chrome 93+** with ARCore, `camera-access` granted | **A — AR single-frame** | Everything below, **plus the photo is read back out of the same XR frame that produced the measurement** — no session handover, no gap. | HTTPS with a **trusted** cert (tunnel). See §2b. |
| **Android Chrome 81+** with ARCore ("Google Play Services for AR") installed | **A — AR measured** (handover) | Distance from the WebXR hit-test pose (metres, real). Yaw and tilt from the detected wall-plane normal. Roll from the gravity-aligned XR viewer pose. Focal length from the XR view projection matrix. Photo comes from `getUserMedia` a fraction of a second after the session ends. | HTTPS with a **trusted** cert (tunnel), `immersive-ar` + `hit-test`. Falls back to Tier B automatically if the session is refused. |
| Android Chrome, depth-sensing granted (Pixel 4+, some Samsung) | **A — AR depth** | As above, but distance comes from the depth buffer's central sample instead of the hit-test pose. Badge says so. | `depth-sensing` in `optionalFeatures`; silently skipped where unsupported. |
| **iOS Safari 14.3+** | **B — Reference-scaled** (or *Estimated*) | Distance from the pinhole model against a known-width reference you outline on screen. Yaw from the 4-handle quad homography. Tilt/roll from `DeviceOrientationEvent`. | HTTPS. Tap **Enable motion sensors** — iOS 13+ gates `DeviceOrientationEvent.requestPermission()` behind a user gesture, and only asks once per page load. Safari has no WebXR AR. |
| Android Chrome without ARCore, Firefox mobile, Samsung Internet | **B — Reference-scaled** | Same as iOS. | HTTPS + camera permission. |
| **Desktop with a webcam** | **B**, but angle-blind | Distance and yaw are real. There is no accelerometer, so tilt and roll cannot be measured — the shutter stays locked until you tap **Assume level (not verified)**, and the capture is then permanently recorded as *not verified*. | `localhost` or HTTPS. |
| **Desktop, no camera / `file://` / plain-HTTP LAN IP** | **C — Unverified** | Nothing. Distance and angles are typed in. The composite is built over the same generated store image the "Simulate photo capture" button uses. | Nothing. The whole flow stays demoable and every artefact is flagged `⚠ UNVERIFIED PLACEMENT`. |

### Tier B accuracy: calibrate once per phone

Tier B's distance is only as good as the focal length. The app looks for one in this order:

1. `MediaStreamTrack.getSettings()` / `getCapabilities()` — no UA standardises focal length or FOV,
   so this almost never hits. Probed defensively.
2. **Your stored calibration** — `localStorage["niva.calib.v1"]`, keyed by device string + capture
   resolution, so it is a genuine once-per-phone step. Reach it from the capture view's tool row
   (*Calibrate — readings are estimated*) or the start panel.
3. An assumed 66° horizontal FOV. The badge then reads **Estimated**, never *Reference-scaled*.

Calibration procedure: tape an A4 sheet (or a credit card) flat to a wall, stand a **tape-measured**
distance back, drag handles **A** and **B** onto its left and right edges, enter the width in mm and
the distance in ft, tap *Solve & save*. It solves `f = pixelWidth × knownDistance / realWidth` and
rejects results implying an implausible field of view.

### Yaw is the one that bites

Device orientation alone cannot tell you whether you are square to the wall in yaw — you can be 30°
off to the side and perfectly level. So:

- Tier A gets it from the hit-test plane normal. Real.
- Tier B gets it **only in 4-handle quad mode**, from the keystone of a rectangle of known
  proportions (shelf face, door leaf, A1 frame). In 2-handle mode yaw is reported
  `YAW UNVERIFIED` and the shutter will not arm. It never claims square when it does not know.

---

## 4. Verifying the maths

⋮ menu → **Run geometry self-test**. 107 assertions covering the pinhole identities, the wall-normal
decomposition, quaternion rotation, device-attitude derivation (including the `beta = ±90` gimbal and
screen-rotation compensation), the linear solver, poster projection, a full
project → homography → pose round-trip, XR-projection-matrix → intrinsics extraction,
camera-image-space projection equivalence, and a **real WebGL framebuffer readback + Y-flip round
trip** that fails if the composite would come out upside down. Results also land in the console via
`console.table`. Runs on the phone too.

⋮ menu → **Capture capability report** shows what this browser exposes and any stored calibrations.
⋮ menu → **AR capture diagnostics** runs the live XR probe described in §2b.

---

## 5. Storage

State lives in `localStorage["niva.state.v2"]`; a `v1` blob from an earlier build is migrated in
place on first load. Captures are downscaled to 1280 px on the long edge at JPEG quality 0.70
(plus a footer-free 1024-ish copy at 0.62 for the before/after slider) — roughly 70 KB per capture.
A quota failure still raises the existing toast rather than losing the session.

⋮ menu → **Reset demo data** clears both keys and re-seeds.
