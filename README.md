# Netbird QPKG for QNAP NAS

A build pipeline that produces a native QNAP package (QPKG) for the [Netbird](https://netbird.io/) WireGuard-based mesh VPN client. The QPKG installs Netbird directly on the QNAP host OS rather than running it inside Docker.

## Why not Docker?

QNAP's Container Station (Docker) environment locks down kernel interfaces that Netbird requires to function:

- `/proc/sys` is mounted read-only, preventing sysctl tuning
- `iptables` and `nftables` are not exposed to containers
- Network namespace restrictions block WireGuard tunnel creation

This causes the Netbird client to crash with `"no firewall manager found"` and similar errors related to missing kernel facilities. Running natively on the QNAP host gives the Netbird client full access to the kernel networking stack, WireGuard, and firewall management -- exactly what it needs to create and maintain mesh VPN tunnels.

## How it works

The QPKG wraps a statically-linked Netbird client binary with a QNAP service script. When installed:

1. The Netbird binary is placed on the NAS filesystem
2. A configuration file is created where you set your setup key, management URL, and other options
3. A service script handles starting and stopping Netbird through QNAP's standard service management

Netbird runs as a background daemon, connecting your QNAP NAS to your Netbird mesh network. It creates a WireGuard tunnel interface and manages routes, DNS, and firewall rules natively on the host.

## Project structure

```
netbird-qnap/
  README.md                          # This file
  qpkg/
    qpkg.cfg                         # QPKG metadata (name, version, author, etc.)
    package_routines                 # QDK install/remove hooks
    icons/
      netbird_80.png                 # QPKG icon for QNAP App Center (80x80)
      netbird_gray.png               # Disabled state icon
    shared/
      netbird.sh                     # Service start/stop/restart script
      netbird.conf                   # User-editable configuration file
    x86_64/
      netbird                        # Statically-linked Netbird client binary
  src/                               # Upstream netbird source (cloned from netbirdio/netbird)
  .github/
    workflows/
      build.yml                      # CI workflow: check version, build, package, release
```

## CI/CD pipeline

The pipeline runs on GitHub Actions:

### Build workflow (`build.yml`)

Triggered on push to `main`, on a schedule (to pick up upstream Netbird releases), or manually via `workflow_dispatch`.

1. **Check upstream version** -- Queries the latest Netbird release tag from `github.com/netbirdio/netbird`. Compares against the last version this repo built. Skips the build if the version has not changed (unless forced).
2. **Clone upstream source** -- Shallow-clones the upstream Netbird repo at the target release tag into `src/`.
3. **Build the binary** -- Compiles the Netbird client with:
   ```
   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o netbird ./client/
   ```
   This produces a fully static binary that runs on any Linux kernel without external library dependencies -- critical for QNAP's minimal userland.
4. **Package the QPKG** -- Assembles the binary, service script, config file, and metadata into a `.qpkg` archive using QNAP's QDK (QPKG Development Kit) tooling.
5. **Upload artifact** -- Stores the built `.qpkg` file as a workflow artifact for the release job to consume.

### Release (integrated into build workflow)

After a successful build of a new upstream version, the workflow automatically:

1. **Create release** -- Creates a GitHub release tagged with the upstream version.
2. **Upload QPKG** -- Attaches the `.qpkg` file to the release as a downloadable asset.
3. **Generate checksum** -- Produces a SHA-256 checksum file alongside the QPKG for verification.

### Runner labels

All jobs use `ubuntu-latest` (standard GitHub-hosted runner). No specialized hardware is needed since the Go cross-compilation produces a static binary on any Linux host.

### Secrets

| Secret | Purpose |
|--------|---------|
| `GITHUB_TOKEN` | Automatically provided by GitHub Actions for creating releases and uploading assets |

### Upstream tracking

The build workflow runs on a schedule (daily or weekly cron) to check for new Netbird releases. When a new upstream tag is detected that has not already been built and released, the pipeline automatically triggers a build-and-release cycle. The version scheme mirrors upstream: if Netbird releases `v0.35.1`, this project releases `v0.35.1` with the corresponding QPKG.

You can also force a rebuild at any time via `workflow_dispatch`, optionally specifying a particular upstream version to build.

## Installation

### Prerequisites

- A QNAP NAS running QTS (x86_64 architecture)
- SSH access to the NAS (for initial setup) or the QNAP web UI
- A Netbird account with a setup key (from [app.netbird.io](https://app.netbird.io/) or your self-hosted management server)

### Install the QPKG

1. Download the latest `.qpkg` file from the [Releases](../../releases) page.
2. In the QNAP web UI, open **App Center** and click **Install Manually** (the gear icon in the upper right).
3. Browse to the downloaded `.qpkg` file and install it.

Alternatively, via SSH:

```bash
# Copy the .qpkg to your NAS
scp netbird_*.qpkg admin@your-nas-ip:/tmp/

# SSH into the NAS and install
ssh admin@your-nas-ip
sh /tmp/netbird_*.qpkg
```

### Configure

After installation, edit the configuration file on the NAS:

```bash
ssh admin@your-nas-ip
vi /etc/config/qpkg/netbird/netbird.conf
```

At minimum, set your setup key:

```
SETUP_KEY=your-netbird-setup-key-here
```

See the [Configuration reference](#configuration-reference) below for all available options.

### Start the service

Start Netbird from the QNAP web UI (App Center, find Netbird, click Start) or via SSH:

```bash
/etc/init.d/netbird.sh start
```

### Verify

Check that Netbird is running and connected:

```bash
/etc/config/qpkg/netbird/netbird status
```

You should see your NAS appear in your Netbird dashboard at [app.netbird.io](https://app.netbird.io/) (or your self-hosted management UI).

## Configuration reference

The configuration file is located at `/etc/config/qpkg/netbird/netbird.conf` on the NAS. All values are read by the service script at startup. Edit this file and restart the service to apply changes.

| Option | Required | Description |
|--------|----------|-------------|
| `SETUP_KEY` | Yes | Your Netbird setup key. Obtain from the Netbird management dashboard under Setup Keys. Used for initial registration of this peer. |
| `MANAGEMENT_URL` | No | URL of the Netbird management server. Defaults to `https://api.wiretrustee.com:443` (Netbird's hosted service). Set this if you run a self-hosted management server. |
| `HOSTNAME` | No | Override the hostname this peer registers with. Defaults to the NAS system hostname. Useful if you want the Netbird peer name to differ from the NAS name. |
| `ADMIN_URL` | No | URL of the Netbird admin dashboard. Only needed for self-hosted setups. |
| `LOG_LEVEL` | No | Logging verbosity. One of `panic`, `fatal`, `error`, `warn`, `info`, `debug`, `trace`. Defaults to `info`. |
| `LOG_FILE` | No | Path to write logs. Defaults to `/var/log/netbird.log`. |
| `EXTRA_ARGS` | No | Any additional command-line arguments to pass to the `netbird up` command. |

Example configuration for a self-hosted setup:

```
SETUP_KEY=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
MANAGEMENT_URL=https://netbird.example.com:443
HOSTNAME=my-qnap-nas
LOG_LEVEL=info
LOG_FILE=/var/log/netbird.log
```

Example configuration for Netbird's hosted service:

```
SETUP_KEY=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
HOSTNAME=qnap-home
```

## Building locally

If you want to build the Netbird binary and QPKG yourself without the CI pipeline:

### Build the binary

```bash
# Clone the upstream Netbird source (or use a specific tag)
git clone --depth 1 --branch v0.35.1 https://github.com/netbirdio/netbird.git src

# Build a static binary for QNAP (x86_64 Linux)
cd src
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o ../qpkg/x86_64/netbird ./client/

cd ..
```

The `-s -w` linker flags strip debug symbols, reducing binary size. `CGO_ENABLED=0` ensures a fully static binary with no glibc dependency.

### Package the QPKG

If you have the QNAP QDK installed:

```bash
qbuild --root qpkg
```

Without QDK, you can manually transfer the binary and service files to the NAS:

```bash
# Copy the binary
scp qpkg/x86_64/netbird admin@your-nas-ip:/etc/config/qpkg/netbird/netbird

# Copy the service script
scp qpkg/shared/netbird.sh admin@your-nas-ip:/etc/init.d/netbird.sh

# Copy the config template
scp qpkg/shared/netbird.conf admin@your-nas-ip:/etc/config/qpkg/netbird/netbird.conf

# Make executable
ssh admin@your-nas-ip "chmod +x /etc/config/qpkg/netbird/netbird /etc/init.d/netbird.sh"
```

## How upstream updates are tracked

This project does not fork or modify the Netbird source code. It simply:

1. Clones the upstream release at a specific tag
2. Cross-compiles the client binary for QNAP's platform
3. Wraps it in a QPKG with a service script and config file

When `netbirdio/netbird` publishes a new release, the scheduled CI pipeline detects the new tag, builds the updated binary, and publishes a new QPKG release. No manual intervention is needed for routine upstream updates.

To pin a specific upstream version, trigger a manual `workflow_dispatch` build with the desired version tag.

## License

The Netbird client is licensed under [BSD-3-Clause](https://github.com/netbirdio/netbird/blob/main/LICENSE). The QPKG packaging scripts and CI configuration in this repository are provided as-is.
