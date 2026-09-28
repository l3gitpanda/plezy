---
name: verify
description: Build, launch and drive the Linux desktop app headlessly against a stub Jellyfin/Emby server to observe a change at the real UI. Use for /verify or any "does it work in the app" check on this repo.
---

# Verify a change in the running Linux app

Cold-started 2026-09-28 in a claude.ai cloud container (Ubuntu 24.04, root, no
Docker daemon, no LAN). Everything below worked as written.

## Build (about 2 min after deps)

```bash
# Toolchain: the CI package list lives in .github/workflows/build.yml (LINUX_APT_PACKAGES).
apt-get update && apt-get install -y --no-install-recommends $(awk '/LINUX_APT_PACKAGES: >/{f=1;next} f&&!/^    [a-z]/{f=0} f{print}' .github/workflows/build.yml) zstd scrot xdotool x11-apps
python3 scripts/fetch_linux_libmpv.py --dest libmpv-prefix        # pinned prebuilt libmpv (needs zstd)
export PKG_CONFIG_PATH="$PWD/libmpv-prefix/lib/pkgconfig:$PWD/libmpv-prefix/lib/x86_64-linux-gnu/pkgconfig"
flutter build linux --debug --dart-define=PLEZY_AGENT_CONTROL=true  # agent controls need this define
```

Flutter itself: `flutter_linux_<FLUTTER_VERSION from ci.yml>-stable.tar.xz` from
storage.googleapis.com extracts fine; add `flutter/bin` to PATH. `packages/wakelock_plus`
needs its own `flutter pub get --enforce-lockfile --no-example` before the analyzer is clean.

## Server

No real Jellyfin is reachable (repo.jellyfin.org and the GitHub API are blocked by the
proxy). `stub_jellyfin.py` beside this file is enough for sign-in, home, library, series
detail and the season episode list; it logs every request with its query string:

```bash
python3 .claude/skills/verify/stub_jellyfin.py 8096 /tmp/stub.log         # Jellyfin dialect
python3 .claude/skills/verify/stub_jellyfin.py 8097 /tmp/stub-emby.log emby  # Emby dialect (TagItems only)
```

Credentials `verifier` / `verifier`. One series, one season, five episodes (tags:
Manga Canon, Filler, Mixed Canon/Filler, Anime Canon + Fansub, none). Extend `EPISODES`
or the routing in `do_GET` for other fixtures; `UNHANDLED` lines in the log show what
the app asked for that the stub guessed at.

## Launch and drive

```bash
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp &
export DISPLAY=:99 NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
       LD_LIBRARY_PATH="$PWD/libmpv-prefix/lib/x86_64-linux-gnu:$PWD/libmpv-prefix/lib"
./build/linux/x64/debug/bundle/plezy > /tmp/app.log 2>&1 &
# VM service URI (for scripts/agent.mjs) is printed in app.log: grep -o 'http://127.0.0.1:[0-9]*/[A-Za-z0-9_=-]*/' /tmp/app.log
scrot -o /tmp/shot.png                       # screenshot; view it with Read
xdotool mousemove X Y click 1                # click; xdotool type --delay 20 "text"; click 5 = wheel down
```

The window is 1280x720 at launch; the bottom 80px of the 800px screen is black.

Onboarding clicks that worked: "Connect to Jellyfin" (840,382) → URL field (640,92), type
URL → wait ~3 s for local discovery to finish (the "Find server" button moves from y=200 to
y=164 when it does) → Find server (640,164) → Username (640,224) → Password (640,276) →
Sign in (640,328). Home shows the series card at (190,258). Series detail: episode rows
start around y=570; wheel down 6 clicks at (640,600) shows all five. Sidebar: hovering
x=40 expands a drawer; Settings is (89,292) in the drawer, then move the mouse to
(700,400) to collapse it before clicking rows. Settings → Appearance is row 2 (700,157).

Settings without the UI, once the app is up:

```bash
export PLEZY_VM_SERVICE_URI='<uri from app.log>'
bun scripts/agent.mjs settings list | python3 -c "import sys,json; print([s for s in json.load(sys.stdin)['settings'] if s['key']=='episode_tags'])"
bun scripts/agent.mjs settings set episode_tags '"all"'   # applies live, no navigation needed
```

## Gotchas

- `apt-get` works; `docker` CLI exists but there is no daemon.
- D-Bus is absent: connectivity and secret-service warnings in app.log are noise.
- The stub answers `/socket` / `/embywebsocket` with 404; the app copes.
- `flutter analyze` unfiltered reports errors in `packages/wakelock_plus/test`; use
  `dart run scripts/checks/check_analyzer.dart` as CI does.
