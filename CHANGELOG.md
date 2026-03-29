# CHANGELOG

Complete history of the netbird-qnap project, documenting every commit, what was
tried, what worked, what failed, and the current state.

---

## Commit-by-Commit History (oldest first)

### 1. `197b27c` -- QNAP Netbird, when this builds

**Date:** 2026-03-26

The initial commit. Created the entire project skeleton from scratch:

- **`.github/workflows/build.yml`**: CI pipeline with three jobs:
  - `check-version`: queries the latest netbird release tag from GitHub, compares
    against existing releases, skips build if already released (unless forced).
  - `build`: clones upstream netbird source, detects Go version from `go.mod`,
    cross-compiles a static `CGO_ENABLED=0 GOOS=linux GOARCH=amd64` binary,
    generates icons with ImageMagick, builds the QPKG using QDK's `qbuild`.
  - `release`: downloads the built artifact and creates a GitHub release with
    checksums.
- **`qpkg/qpkg.cfg`**: QPKG metadata -- name `netbird`, display name
  `Netbird VPN`, version `0.0.0` (updated by CI), service program `netbird.sh`,
  PID file at `/var/run/netbird.pid`, minimum QTS 4.3.0. No web UI settings at
  this point.
- **`qpkg/shared/netbird.sh`**: Service script handling start/stop/restart/status.
  Sources `netbird.conf` to get `SETUP_KEY`, `MANAGEMENT_URL`, etc. Starts the
  daemon with `netbird service run`, waits for `/var/run/netbird.sock`, then runs
  `netbird up` if a setup key is configured.
- **`qpkg/shared/netbird.conf`**: User-editable config template with commented
  options for `SETUP_KEY`, `MANAGEMENT_URL`, `ADMIN_URL`, `HOSTNAME`, `LOG_LEVEL`,
  `LOG_FILE`, `EXTRA_ARGS`.
- **`qpkg/package_routines`**: Install/remove hooks -- chmod binaries, preserve
  user config across upgrades, create `/etc/netbird`, clean up symlinks on remove.
- **`README.md`**: Extensive documentation covering architecture, why Docker does
  not work on QNAP (read-only `/proc/sys`, no iptables in containers), installation
  instructions, configuration reference, local build guide.
- **`.gitignore`**: Ignores `src/`, compiled binaries, `*.qpkg`, build output, and
  generated icons.

**Web UI settings:** None. No `QPKG_WEBUI`, no web interface at all.

---

### 2. `b0aac9d` -- dirs

**Date:** 2026-03-26

**Problem:** The CI build failed because `qpkg/x86_64/` and `qpkg/icons/` directories
did not exist on the CI runner (they were gitignored and empty).

**Fix:**
- Added `mkdir -p qpkg/x86_64` before the Go build step.
- Added `mkdir -p qpkg/icons` before the icon generation step.
- Added `.gitkeep` files in `qpkg/icons/` and `qpkg/x86_64/` so the directories
  exist in the repo.

---

### 3. `be63fe6` -- dirs

**Date:** 2026-03-26

**Problem:** QDK build tooling was not being found correctly. Also updated action
versions.

**Changes:**
- Updated `actions/checkout` from v4 to v6, `actions/setup-go` from v5 to v6,
  `actions/upload-artifact` from v4 to v5, `actions/download-artifact` from v4 to v5.
- Changed QDK build approach: instead of using `qbuild` from `/tmp/qdk/bin/`, now
  builds QDK from source (`make -C /tmp/qdk/src`), copies `qpkg_encrypt` to
  `/usr/local/bin/`, and uses `/tmp/qdk/shared/bin/qbuild`.
- Removed `fakeroot` and `pv` from apt dependencies (kept `rsync` and `bsdmainutils`).

---

### 4. `bb08a6a` -- fix: QDK build setup for CI

**Date:** 2026-03-26

**Problem:** The QDK setup was still fragile and inline in the workflow.

**Fix:** Extracted all QDK setup into a standalone `build-qpkg.sh` script:
- Clones QDK to `/tmp/qdk`, symlinks `shared` into `qpkg/QDK`.
- Builds `qpkg_encrypt` from source if not available.
- Installs `rsync` and `hexdump` if missing.
- Runs `qbuild --root .` from the `qpkg/` directory.
- Added `qpkg/QDK` to `.gitignore`.

The workflow now just calls `./build-qpkg.sh`.

---

### 5. `41c532a` -- add QNAP app repository for auto-updates via App Center

**Date:** 2026-03-26

**What:** Added a QNAP App Center repository so users can get automatic updates
instead of manually downloading `.qpkg` files.

**Changes:**
- Created `repo.xml` with QNAP plugin metadata: name, description, icons,
  firmware version requirement, and platform entries for `TS-NASX86`, `TS-X28A`,
  `TS-X41`, `TS-X73`. Download URLs pointed to
  `https://github.com/ZachHandley/netbird-qnap/releases/latest/download/netbird.qpkg`
  (this URL format turned out to be wrong -- the filename is versioned, not just
  `netbird.qpkg`).
- Updated the workflow's release job to:
  - Add `pages: write` and `id-token: write` permissions.
  - Update `repo.xml` with the new version number and a cache-busting timestamp.
  - Deploy `repo.xml` to GitHub Pages by creating a temporary git repo on the
    `gh-pages` branch and force-pushing it.
- Updated release notes to include the App Center repository URL.
- Updated `README.md` with "Option A: Add the app repository" instructions.

---

### 6. `7d789f9` -- use actions/deploy-pages for repo.xml

**Date:** 2026-03-26

**Problem:** The manual git-push-to-gh-pages approach for deploying `repo.xml` was
clunky and required manual git operations in CI.

**Fix:** Replaced the manual `git init`/`git push --force` approach with the
official GitHub Pages actions:
- `actions/upload-pages-artifact@v4` to upload the `_pages/` directory.
- `actions/deploy-pages@v4` to deploy to GitHub Pages.
- Added the `github-pages` environment with URL output.

---

### 7. `cecdaed` -- add web UI settings page for QNAP App Center

**Date:** 2026-03-26

**What:** First attempt at a web-based settings UI for configuring Netbird from the
QNAP App Center "Open" button.

**Web UI approach #1: QTS web root symlink**

**Changes:**
- Added `QPKG_WEBUI="/netbird/"` to `qpkg.cfg`. This tells QTS that clicking "Open"
  in the App Center should navigate to `/netbird/` on the QTS management server.
- In `netbird.sh` start, added:
  `ln -sf "${QPKG_ROOT}/web" /home/Qhttpd/Web/netbird`
  This symlinks the web directory into QTS's built-in web server root so it serves
  the files at `/netbird/`.
- Created `qpkg/shared/web/index.html`: A single-page settings UI with fields for
  Setup Key, Management URL, Admin URL, Hostname, Log Level, Log File, Extra Args.
  Shows connection status, has Save and Save & Restart buttons. Calls a CGI API at
  `/netbird/cgi-bin/netbird-api.cgi`.
- Created `qpkg/shared/web/cgi-bin/netbird-api.cgi`: A shell-based CGI script that
  handles `load` (read config), `save` (write config), `status` (run
  `netbird status`), and `restart` (call `netbird.sh restart`). Uses a simple JSON
  parser with `sed`.
- Updated `package_routines` to chmod the CGI script on install and clean up the
  symlink on remove.

**Problem with this approach:** The QTS built-in web server (thttpd/Qhttpd) may not
execute CGI scripts from symlinked directories, and the `/netbird/` path relies on
the QTS web root being writable and the server being configured to serve from
symlinked subdirectories.

---

### 8. `f4f4765` -- fix repo.xml download URL, add concurrency limit

**Date:** 2026-03-26

**Changes:**
- Added `concurrency: group: build-qpkg, cancel-in-progress: true` to the workflow
  to prevent parallel builds from conflicting.
- Fixed a problem where re-releasing the same version would fail: now deletes any
  existing release before creating a new one
  (`gh release delete "$VERSION" --yes --cleanup-tag`).
- Changed `repo.xml` download URLs from hardcoded
  `https://github.com/.../releases/latest/download/netbird.qpkg` to a
  `__QPKG_URL__` placeholder that gets replaced at build time with the actual
  release asset URL (fetched via `gh release view ... --json assets`).

**Problem:** The `__QPKG_URL__` approach required querying the release API after
creating the release, which added complexity. This was changed again in the next
commit.

---

### 9. `f49f39e` -- fix web UI: use busybox httpd on port 8090, stable download URL

**Date:** 2026-03-26

**Web UI approach #2: busybox httpd on custom port**

The QTS web root symlink approach was abandoned. This commit switched to running a
dedicated web server.

**Changes to qpkg.cfg:**
- Changed `QPKG_WEBUI` from `"/netbird/"` to `"/"`.
- Added `QPKG_WEB_PORT="8090"`.
- The combination of `QPKG_WEBUI="/"` and `QPKG_WEB_PORT="8090"` tells QTS that
  clicking "Open" in App Center should open `http://<nas-ip>:8090/`.

**Changes to netbird.sh:**
- Replaced the symlink approach (`ln -sf ... /home/Qhttpd/Web/netbird`) with
  starting busybox's built-in HTTP server:
  `busybox httpd -p 8090 -h "${QPKG_ROOT}/web" -c "${QPKG_ROOT}/web/httpd.conf"`
- On stop, kills the httpd process: `kill $(pidof "busybox httpd")`

**Added `httpd.conf`:** A busybox httpd config file with:
```
A:*
/cgi-bin:admin
*.cgi:CGI
```

**Removed** the `/home/Qhttpd/Web/netbird` symlink cleanup from `package_routines`
(no longer used).

**Download URL fix:** Abandoned the `__QPKG_URL__` placeholder approach. Instead:
- Creates a stable-named copy of the QPKG as `netbird_x86_64.qpkg` alongside the
  versioned one.
- Changed `repo.xml` URLs to
  `https://github.com/ZachHandley/netbird-qnap/releases/latest/download/netbird_x86_64.qpkg`
  which always points to the latest release.

---

### 10. `f604743` -- fix artifact upload path

**Date:** 2026-03-26

**Problem:** The artifact upload step was listing individual files with complex path
expressions, which was fragile.

**Fix:** Simplified the upload path to just `qpkg/build/` to upload the entire build
output directory.

---

### 11. `82d584d` -- fix: remove invalid httpd.conf, busybox httpd needs no config

**Date:** 2026-03-26

**Problem:** The `httpd.conf` file created in commit `f49f39e` was likely causing
busybox httpd to fail. The QNAP busybox httpd may not support the config file
format used, or the CGI directives were not working.

**Fix:**
- Removed `qpkg/shared/web/httpd.conf` entirely.
- Changed the httpd start command from
  `busybox httpd -p 8090 -h "${QPKG_ROOT}/web" -c "${QPKG_ROOT}/web/httpd.conf"`
  to just `busybox httpd -p 8090 -h "${QPKG_ROOT}/web"` (no config file).

**Implication:** Without the config file, busybox httpd would serve static files but
would NOT execute CGI scripts. This means the settings page HTML would load, but
the API calls to `/cgi-bin/netbird-api.cgi` would fail (the CGI script would be
served as a download or return an error instead of being executed). The web UI was
effectively broken at this point -- it could display the form but could not load,
save, or query status.

---

### 12. `311e2d2` -- auto-increment packaging version suffix on forced rebuilds

**Date:** 2026-03-27

**What:** Improved the version numbering for forced rebuilds so they do not collide
with previous releases.

**Changes:**
- Added a `release_tag` output to the `check-version` job.
- When no prior release exists for a version, uses the version as-is (e.g., `v0.67.1`).
- When a prior release exists and force is true:
  - If the prior release is the bare version (`v0.67.1`), the new tag becomes
    `v0.67.1-2`.
  - If the prior release already has a suffix (`v0.67.1-2`), increments to
    `v0.67.1-3`.
- The QPKG version converts dashes to dots for QNAP compatibility
  (e.g., `v0.67.1-2` becomes `0.67.1.2`).
- The `release_tag` is used for the GitHub release tag and the repo.xml version.

---

### 13. `f1254bb` -- embed settings UI inline in QTS desktop

**Date:** 2026-03-27

**Web UI approach #2.5: busybox httpd + desktop app mode**

An attempt to make the web UI appear as an inline window inside the QTS desktop
instead of opening a new browser tab.

**Changes to qpkg.cfg:**
- Kept `QPKG_WEBUI="/"` and `QPKG_WEB_PORT="8090"` (still using busybox httpd).
- Added `QPKG_DESKTOP_APP="1"` -- tells QTS to open the web UI inside an iframe
  in the QTS desktop rather than in a new browser tab.
- Added `QPKG_USE_PROXY="1"` -- tells QTS to proxy requests through the QTS
  management port so the custom port (8090) does not need to be exposed directly.

**Problem:** This approach still relied on busybox httpd (without a config file, so
no CGI support). The `QPKG_USE_PROXY="1"` setting tells QTS to proxy requests to
port 8090, which means the page would load in the desktop, but the CGI API would
still not work because busybox httpd was not configured to execute CGI scripts.

---

### 14. `7fc8e8d` -- fix web UI: use QTS management server, inline desktop app

**Date:** 2026-03-27

**Web UI approach #3: QTS management server with symlinks (return to approach #1, enhanced)**

Abandoned the busybox httpd approach entirely and returned to using the QTS
built-in web server, but with a more complete setup.

**Changes to qpkg.cfg:**
- Removed `QPKG_WEB_PORT="8090"` (no more custom port).
- Changed `QPKG_WEBUI` from `"/"` back to `"/netbird/"`.
- Kept `QPKG_USE_PROXY="1"`.
- Added `QPKG_DESKTOP_APP="1"`.
- Added `QPKG_DESKTOP_APP_WIN_WIDTH="700"` and `QPKG_DESKTOP_APP_WIN_HEIGHT="500"`.

**Changes to netbird.sh:**
- Removed busybox httpd start (`busybox httpd -p 8090 ...`).
- Replaced with two symlinks:
  - `ln -sf "${QPKG_ROOT}/web" /home/Qhttpd/Web/netbird` -- serves static files at
    `/netbird/`.
  - `ln -sf "${QPKG_ROOT}/web/cgi-bin/netbird-api.cgi" /home/httpd/cgi-bin/netbird-api.cgi`
    -- places the CGI script in QTS's CGI directory where the management server
    (thttpd) can execute it.
- On stop, removes both symlinks.
- On remove (in `package_routines`), also cleans up both symlinks.

**Changes to index.html:**
- Changed the API endpoint from `'/netbird/cgi-bin/netbird-api.cgi'` to
  `'/cgi-bin/netbird-api.cgi'` because the CGI script is now symlinked into the
  system CGI directory, not served from within the `/netbird/` web root.

**Key insight:** QTS has two separate web server components:
1. `/home/Qhttpd/Web/` -- the static file root served by QTS's thttpd/Qhttpd
   (serves HTML, CSS, JS).
2. `/home/httpd/cgi-bin/` -- the CGI directory where QTS's thttpd can execute
   scripts.

By symlinking the web directory and the CGI script separately into these two
locations, both static file serving and CGI execution should work through the QTS
management port (typically 8080 or 443).

---

### 15. `af5f3ad` -- [release] build on commit with [release] tag, fix web UI symlinks

**Date:** 2026-03-27

**Changes:**
- Modified the build trigger logic: now builds if the commit message contains
  `[release]` (case-insensitive), in addition to the existing triggers (first
  build, forced, new upstream version). This allows triggering a release build by
  including `[release]` in the commit message.
- Simplified the version suffix logic: always computes the release tag (even when
  not building), then decides whether to build based on the trigger conditions.

This commit had `[release]` in its message, so it triggered a CI build to test the
web UI changes from the previous commit.

---

### 16. `643699c` -- [release] remove QPKG_USE_PROXY, serve directly via QTS thttpd

**Date:** 2026-03-28

**Web UI approach #3.5: QTS management server, no proxy**

**Changes to qpkg.cfg:**
- Removed `QPKG_USE_PROXY="1"`.
- Kept `QPKG_WEBUI="/netbird/"`.
- Kept `QPKG_DESKTOP_APP="1"` with window dimensions.
- Updated comment to clarify: "Web UI served through QTS management server via
  symlink into /home/Qhttpd/Web/."

**Rationale:** The `QPKG_USE_PROXY` setting may have been causing issues. Without
it, QTS should serve `/netbird/` directly from the web root symlink rather than
trying to proxy requests to a backend port.

**Problem:** Without `QPKG_USE_PROXY`, QTS may need the proxy setting to properly
route requests to the web content when `QPKG_DESKTOP_APP` is enabled. The desktop
app iframe may need the proxy mechanism to display content correctly.

---

### 17. `a99c5e9` -- [release] fix web UI: proxy through QTS management port, no custom server (HEAD)

**Date:** 2026-03-28

**Web UI approach #4 (current): QTS management server with proxy, desktop app**

**Changes to qpkg.cfg:**
- Re-added `QPKG_USE_PROXY="1"` (was removed in the previous commit).
- Kept everything else the same.

**Rationale:** The proxy setting was needed after all. `QPKG_USE_PROXY="1"` tells
QTS to proxy the web UI path through the management port, which is necessary for
the desktop app iframe to work properly. Without it, the previous commit's approach
apparently did not work.

---

### 18. (uncommitted) -- fix web UI: add busybox httpd backend for QTS proxy

**Date:** 2026-03-29

**Web UI approach #5: busybox httpd + QTS proxy (the actual fix)**

**Root cause identified:** Per the QDK template documentation, `QPKG_USE_PROXY="1"`
is for "when the QPKG has its own HTTP service port." It creates Apache `ProxyPass`
directives forwarding requests to `http://127.0.0.1:<QPKG_WEB_PORT>`. Every prior
approach that used `QPKG_USE_PROXY="1"` without `QPKG_WEB_PORT` was telling QTS to
reverse-proxy to nothing -- hence 503 Service Unavailable.

The symlink-based approach (commits `7fc8e8d`, `643699c`, `a99c5e9`) was the wrong
model entirely. Symlinks into `/home/Qhttpd/Web/` are for the NON-proxy model
(static file serving by QTS's built-in thttpd). `QPKG_USE_PROXY` and symlinks are
mutually exclusive approaches that were being combined, causing the conflict.

**Source:** QDK template at
`https://github.com/qnap-dev/QDK/blob/master/shared/template/qpkg.cfg` and
Perplexity deep research on QNAP QPKG web UI configuration confirming that
`QPKG_USE_PROXY` requires a backend HTTP service listening on `QPKG_WEB_PORT`.

**Changes to qpkg.cfg:**
- Added `QPKG_WEB_PORT="58090"` -- tells QTS what port to proxy to.
- Kept `QPKG_USE_PROXY="1"` and `QPKG_DESKTOP_APP="1"`.
- Updated comment to reference busybox httpd.

**Changes to netbird.sh:**
- Replaced symlinks (`/home/Qhttpd/Web/netbird`, `/home/httpd/cgi-bin/...`) with:
  `pkill -f "busybox httpd -p 58090"` (kill stale instance)
  `busybox httpd -p 58090 -h "${QPKG_ROOT}/web"` (start httpd)
- Stop now does `pkill -f "busybox httpd -p 58090"` instead of removing symlinks.

**Changes to index.html:**
- Changed API URL from `'/cgi-bin/netbird-api.cgi'` (absolute) to
  `'cgi-bin/netbird-api.cgi'` (relative). When the page loads at `/netbird/`, the
  browser resolves this to `/netbird/cgi-bin/netbird-api.cgi`, which QTS proxies
  to `http://127.0.0.1:58090/cgi-bin/netbird-api.cgi`, which busybox httpd
  handles as CGI.

**Changes to package_routines:**
- Replaced symlink cleanup in `PKG_POST_REMOVE` with `pkill -f 'busybox httpd -p 58090'`.

**Why busybox httpd:**
- Already built into QTS on every QNAP device (QTS is BusyBox-based).
- Serves static files and executes CGI scripts from `cgi-bin/` by default -- no
  config file needed (the httpd.conf from commit `f49f39e` was unnecessary and
  its removal in `82d584d` was a red herring).
- Zero additional disk space, negligible memory, instant startup.
- No external dependencies (unlike Node.js, Python, etc.).

**Request flow:**
```
User clicks "Open" in QTS App Center
  -> QTS desktop opens iframe to /netbird/ (QPKG_DESKTOP_APP="1")
  -> QTS proxy forwards /netbird/* to http://127.0.0.1:58090/* (QPKG_USE_PROXY="1", QPKG_WEB_PORT="58090")
  -> busybox httpd serves index.html (static) or executes cgi-bin/netbird-api.cgi (CGI)
```

---

## Web UI / Settings Panel Saga -- Summary

| # | Commit | Approach | QPKG_WEBUI | WEB_PORT | USE_PROXY | DESKTOP_APP | Served By | Result |
|---|--------|----------|------------|----------|-----------|-------------|-----------|--------|
| 1 | `cecdaed` | QTS web root symlink | `/netbird/` | -- | -- | -- | QTS thttpd via symlink | Unknown -- CGI unlikely to work from symlinked dirs |
| 2 | `f49f39e` | busybox httpd + httpd.conf | `/` | `8090` | -- | -- | busybox httpd | httpd.conf format probably invalid |
| 3 | `82d584d` | busybox httpd, no config | `/` | `8090` | -- | -- | busybox httpd | HTML loads, CGI broken without config (wrong -- CGI works by default) |
| 4 | `f1254bb` | busybox + desktop + proxy | `/` | `8090` | `1` | `1` | busybox proxied by QTS | Would have worked but inherited broken CGI assumption |
| 5 | `7fc8e8d` | QTS server + dual symlinks | `/netbird/` | -- | `1` | `1` | QTS thttpd via symlinks | 503 -- proxy enabled but no backend port/server |
| 6 | `643699c` | QTS server, no proxy | `/netbird/` | -- | -- | `1` | QTS thttpd via symlinks | Broke desktop app embedding |
| 7 | `a99c5e9` | QTS server + proxy | `/netbird/` | -- | `1` | `1` | QTS thttpd via symlinks | 503 -- same as #5, proxy still has no backend |
| 8 | (this) | busybox httpd + proxy | `/netbird/` | `58090` | `1` | `1` | busybox httpd proxied by QTS | Should work -- proxy has a real backend |

**Key lessons learned:**
- `QPKG_USE_PROXY="1"` requires `QPKG_WEB_PORT` and a running HTTP server. It is
  NOT compatible with symlinks into `/home/Qhttpd/Web/`.
- Busybox httpd executes CGI from `cgi-bin/` by default. No httpd.conf needed.
- The httpd.conf removal (commit `82d584d`) was the wrong fix for the wrong problem.
  The real issue in commit `f49f39e` was probably the httpd.conf syntax, not CGI
  support itself.
- API URLs in the HTML must be relative (not absolute) when served behind a proxy
  that rewrites the path prefix.

---

## Current State (as of this uncommitted change)

### Architecture

**Core VPN service:**
- Statically-linked Netbird client binary for x86_64.
- Service script (`netbird.sh`) starts daemon, waits for gRPC socket, brings tunnel up.
- Configuration in `netbird.conf` (shell variables).

**Web UI:**
- `qpkg.cfg`: `QPKG_WEBUI="/netbird/"`, `QPKG_WEB_PORT="58090"`,
  `QPKG_USE_PROXY="1"`, `QPKG_DESKTOP_APP="1"` (700x500).
- On start: `busybox httpd -p 58090 -h "${QPKG_ROOT}/web"` serves the web UI.
- `index.html`: single-page settings form, calls `cgi-bin/netbird-api.cgi` (relative URL).
- `netbird-api.cgi`: shell CGI script for load/save/status/restart.
- On stop/remove: `pkill -f "busybox httpd -p 58090"`.

**CI/CD:**
- Triggers: push to main, daily cron, manual dispatch, `[release]` in commit message.
- Auto-increments version suffix on forced rebuilds.
- Deploys `repo.xml` to GitHub Pages for QNAP App Center auto-updates.
- Stable download URL: `netbird_x86_64.qpkg` in latest release.

### Files

```
.github/workflows/build.yml              -- CI pipeline
build-qpkg.sh                            -- QDK setup and qbuild wrapper
repo.xml                                 -- QNAP App Center repository manifest
CHANGELOG.md                             -- This file
qpkg/qpkg.cfg                            -- QPKG metadata and web UI settings
qpkg/package_routines                    -- Install/remove hooks
qpkg/shared/netbird.sh                   -- Service start/stop/restart script
qpkg/shared/netbird.conf                 -- Config file template
qpkg/shared/web/index.html              -- Settings UI (single-page HTML/JS)
qpkg/shared/web/cgi-bin/netbird-api.cgi  -- CGI API for settings UI
```
