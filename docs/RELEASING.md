# Releasing a sideload build

The checklist for cutting a sideload build and putting it on the wrist. The
failure modes here are quiet — a build that installs happily and then never
fetches, a "generic" defaults slip, a stale reading shown as current — and
each one is caught by a specific step below, in order. Work top to bottom;
don't skip a gate because the last build was fine.

> This covers the **personal sideload** flow (values baked in, flashed over
> USB). A store submission is the generic `monkey.jungle` build with empty
> defaults, configured from the phone — out of scope here.

## 1. Pre-build

**Pick the right jungle.** Two live side by side and they are not
interchangeable:

- **`personal.jungle`** — the sideload build. Adds the gitignored
  `resources-personal/` overlay on top of `resources`, so your real
  `serverUrl` / `watchToken` get baked in. Later `resourcePath` entries win
  on duplicate ids, so the overlay only carries the values you're
  overriding. **This is the one `tools/build.*` uses.**
- **`monkey.jungle`** — the generic/store build. Ships the blank defaults
  from `resources/settings/properties.xml`. Sideloading *this* gives you a
  watch stuck on "Set server URL": it compiles and installs, then never
  fetches because the defaults are empty. Only build it deliberately, for
  the store.

The VS Code build button is pinned to `personal.jungle` in
`.vscode/settings.json`; the CLI does not read that, so **name the jungle
explicitly** on the command line (or use `tools/build.ps1` / `tools/build.sh`,
which always target it).

**Use a recent SDK explicitly.** An old `monkeyc` on `PATH` may be too old
for a newer watch and will mis-build or reject the device. Check
`monkeyc --version` and, if your SDK manager installs versioned SDKs
side by side, invoke the specific version's binary by full path rather than
whatever resolves first on `PATH`.

**Persisted properties — anything new this release?** The stored settings
are: `serverUrl`, `watchToken`, `glanceTitle`, `useMmol`, `useNsThresholds`,
`lowThreshold`, `highThreshold`, `urgentLow`, `urgentHigh`, `diagnostics`
(`resources/settings/properties.xml`).

> ⚠️ **Changing the default of an EXISTING property does nothing either —
> and this is a real trap, not a theoretical one.** The gotcha below is
> written about *adding* a property; the same mechanism means a **stored
> value beats the baked-in default forever**.
>
> `watchToken` is read with `Application.Properties.getValue()`
> (`BGData.mc`). If you rotate the token server-side, update
> `resources-personal/properties.xml`, rebuild, and reflash — every fetch
> will still 401, because the watch keeps using the token stored at its
> *first* install. **Reflashing cannot rotate a credential.** Nothing in
> the PRG can.
>
> The fix is to remove the stored settings file over USB (device/app-id
> folder names vary; look for a `.SET` file under `GARMIN\Apps\SETTINGS\`
> matching this app):
>
> ```
> GARMIN\Apps\SETTINGS\<appid>.SET      <- delete this
> GARMIN\Apps\DATA\<appid>.{DAT,IDX,IMT}  <- LEAVE THESE
> ```
>
> `SETTINGS` holds Properties (the token); `DATA` holds
> `Application.Storage` — the diagnostic ring and the last reading. Deleting
> `DATA` throws away the blackout history the ring exists to preserve. A
> full uninstall clears both, so prefer deleting just the settings file.
>
> ⚠️ **Bump `BUILD_VERSION` (`source/BGData.mc`) on every flash, even when
> no code changed.** If a rotated token and a code change ship in the same
> version string, an auth failure after a flash is ambiguous — you can't
> tell "the new build has a bug" from "the server also rotated the token at
> the same time." A distinct build string per flash breaks that tie
> immediately.

Adding a **new** persisted property is the trap to watch for generally: on
an **overwrite-update** over an existing install, `Application.Storage` /
Properties are **not** re-initialized from the manifest, so a newly-added
property reads back as `null` on every existing watch until something
writes it. If a release adds one, it must either (a) default safely when
read `null` in code, or (b) be written on first run — never assume the XML
default reaches an upgraded install. The swipe window (60 / 3 h / 6 h) is
deliberately an **in-memory** field (resets to 60 min on open), specifically
to dodge this trap — keep it that way unless you also handle the
null-on-upgrade path.

**Smoke-test the live contract.** Before building, prove the deployed
endpoint still honours the payload shape `BGData.mc` parses and fits the
watch's memory budget:

```bash
WATCH_ENDPOINT_URL=https://<host>/api/watch/glucose \
WATCH_TOKEN=<your token> \
python tools/check_endpoint.py
```

It reads the token from the env (never prints it), asserts the no-history /
frames / out-of-range / bad-token cases, and exits non-zero on any failure.
**Run it green before you build** — against the same host the baked-in
`serverUrl` points at, right before flashing.

## 2. Build

```bash
# fills in resources-personal/ from config.local.json, then builds
./tools/build.sh          # or: tools\build.ps1 on Windows
```

Output PRG: **`BGGlance.prg`**.

## 3. Hardware gate

Flash `BGGlance.prg` to `GARMIN/Apps` over USB (see README → Installing),
then walk these **in order**. Each is a distinct failure mode; a pass on
one does not imply the next.

1. **Overwrite-update over the existing install.** Copy the new PRG over
   the one already on the watch (same app id). It re-verifies and installs
   without an uninstall. Confirm settings survive and no property reads
   back blank — the persisted-property trap from §1 shows up here first.
   Use `tools/sideload.ps1` rather than dragging by hand: it verifies the
   on-watch byte count against the source. Run it **non-elevated** — an
   elevated shell has its own session view and may lose mapped drives or
   fail to enumerate MTP devices at all.
2. **Open the widget ONCE, immediately, to re-arm the background service.**
   `registerForTemporalEvent()` runs only from `getInitialView()` /
   `getGlanceView()` (`BGWidgetApp.mc`), so opening the widget or its glance
   is what schedules the 5-minute fetch. **A freshly sideloaded widget may
   have no background service until opened — do it every time.** When it
   happens it is silent and looks exactly like a phone-link failure: the
   number just sits there aging. Whether an overwrite-update preserves an
   existing registration has been observed to go either way across
   different SDK/firmware combinations — don't rely on it. Do this before
   step 3.
3. **Glance renders after a real 5-min background fetch.** Leave it on the
   glance stack and wait out one real background cycle (~5 min, phone
   paired). The glance must render the fetched reading — glances can't
   fetch, so this proves the background service stored a value.
4. **Full view fetches on open.** Tap into the full view; it must fetch
   immediately (not just show the stored glance value).
5. **Swipe all three frames, each loading its own series.** From the full
   view, swipe through **60 min → 3 h → 6 h**. Each window loads and draws
   its **own** series; the top label and page-dots track the window. A
   frame must not reuse the previous window's data.
6. **BLE off → number ages into STALE.** Turn the phone's Bluetooth off (or
   walk out of range) and leave it. With no fresh data, the number must
   dim/`!` at the warn threshold and become `--- STALE Xm` past the stale
   threshold — verified live, not just in sim.
7. **Out of range → "No phone link (-104)" AFTER reconnecting.** Turn the
   phone's Bluetooth off in **Settings** (Control Centre / quick-toggle does
   NOT sever the link on some platforms), leave it off through a few
   background firings, then reconnect and open the menu before the next
   firing clears the error. The Auto-fetch row should read the phone-link
   error even though the phone is reconnected now — it reports the link
   state at *fetch* time, not at menu-render time.
8. **A widened diagnostics payload actually gets off the watch (if you use
   the Diagnostics toggle).** With Diagnostics ON and after step 7 has
   produced a real run of failures, the first background request after the
   blackout should carry more than the healthy baseline of diagnostic
   entries in your server's access log.
9. **Blank token → "Set watch token".** Build (or temporarily configure)
   with an empty `watchToken` and confirm the watch surfaces **"Set watch
   token"** rather than failing silently — the missing-setting path is
   never quiet.

## 4. Evidence to capture

- The exact **build command** used (jungle, device, SDK version).
- The **PRG name** (`BGGlance.prg`) and app version.
- The green `tools/check_endpoint.py` run (byte lengths per response; token
  not shown).
- Photos from the wrist: **glance**, **full view**, and a **stale state**
  (`--- STALE Xm`).

---

See also: [README.md](../README.md) (build/sideload details,
troubleshooting), [ARCHITECTURE.md](ARCHITECTURE.md) (data path), and
`tools/check_endpoint.py` (the pre-build contract check).
