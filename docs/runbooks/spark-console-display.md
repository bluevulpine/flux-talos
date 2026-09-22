# DGX Spark: always-on console display (btop with GPU)

The HDMI console on `spark-ab23` runs `btop` permanently on tty1 as a status
display. `Alt+F2`..`Alt+F5` still give a normal login; `Alt+F1` returns to btop.

This is **not** in Flux. The Spark is not a cluster node, and nothing reconciles
it — treat this document as the source of truth and re-apply by hand.

## Why not autologin

The obvious approach is autologin on tty1 plus `btop` in `~/.bash_profile`.
Rejected, for two reasons that only show up later:

- It leaves a **real login session** on tty1, so physical access to the HDMI port
  yields a shell as a sudo-capable user, with no password.
- If btop ever fails to start — renamed binary, broken config, bad upgrade — the
  profile falls through to the next line and **hands over that shell**. The
  failure mode of the security control is "grant more access".

`exec btop` closes most of the second problem but not the first, and btop's F9
"kill" would still signal that user's processes.

Running btop as a service under an unprivileged account has neither property:
there is no session to escape to, btop dying is handled by `Restart=always`, and
F9 can only signal processes owned by `btopdisplay`, which owns nothing but btop.

## Setup

### 1. btop must be built from source

The packaged builds **cannot** show GPU, and no runtime flag changes that —
`GPU_SUPPORT` is compile-time:

| build | version | NVML symbols |
| --- | --- | --- |
| snap | 1.4.7 | 0 (`GPU_SUPPORT=false`) |
| apt | 1.3.0 | 0 |
| source (below) | 1.4.7 | 17 |

Upstream only auto-enables GPU support for `linux x86_64` and `macos arm64` —
there is **no `linux arm64` case**, so both flags must be forced. Forcing
`GPU_SUPPORT` alone fails at link with `undefined reference to 'pmu_calc'`,
because the Intel GPU call sites in `btop_collect.cpp` are not `#ifdef`-guarded.
`INTEL_GPU_SUPPORT=true` compiles the Intel C sources so the linker is satisfied;
they are dead code on this hardware.

It also needs **GCC 14+** — `std::ranges::to` is C++23 and Ubuntu 24.04's default
g++ 13.3 does not have it.

```bash
sudo snap remove btop                     # if present
sudo apt-get install -y g++-14
git clone --depth 1 https://github.com/aristocratos/btop.git /tmp/btop-src
cd /tmp/btop-src
make CXX=g++-14 GPU_SUPPORT=true INTEL_GPU_SUPPORT=true -j"$(nproc)"
sudo make install                         # -> /usr/local/bin/btop
```

Verify GPU support actually linked, rather than trusting the build log:

```bash
strings /usr/local/bin/btop | grep -cE '^nvml[A-Z]'   # expect ~17, not 0
```

### 2. Unprivileged display account

```bash
sudo useradd --system --shell /usr/sbin/nologin \
    --home-dir /var/lib/btopdisplay --create-home btopdisplay
sudo install -d -o btopdisplay -g btopdisplay -m 0755 \
    /var/lib/btopdisplay/.config/btop

sudo -u btopdisplay /usr/local/bin/btop --default-config \
  | sed -e 's/^shown_boxes = .*/shown_boxes = "cpu mem net proc gpu0"/' \
        -e 's/^nvml_measure_pcie_speeds = .*/nvml_measure_pcie_speeds = false/' \
  | sudo -u btopdisplay tee /var/lib/btopdisplay/.config/btop/btop.conf >/dev/null
```

`gpu0` is **not** in the default `shown_boxes` — without it the GPU box never
draws even on a GPU-enabled build, which looks exactly like a failed build.

`nvml_measure_pcie_speeds` is off because GB10 reports PCIe RX/TX as `N/A`
(unified memory, no discrete link), so the probe costs cycles for nothing.

### 3. The service

`/etc/systemd/system/btop-console.service`:

```ini
[Unit]
Description=btop status display on tty1
After=systemd-user-sessions.service
Conflicts=getty@tty1.service

[Service]
User=btopdisplay
Environment=HOME=/var/lib/btopdisplay
Environment=TERM=linux
ExecStart=/usr/local/bin/btop
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/btopdisplay
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

Then:

```bash
sudo systemctl daemon-reload
sudo systemctl disable --now getty@tty1.service
sudo systemctl enable --now btop-console.service
```

`Conflicts=getty@tty1.service` stops the two ever fighting over the tty.

> ⚠️ `disable --now` on tty1's getty, combined with the unit's `TTYVHangup=yes`,
> sends SIGHUP to everything on that console. **Any login session currently open
> on tty1 is killed**, including one you are sitting at. SSH sessions are
> unaffected. Warn whoever is at the machine before running this.

## Alt+F2 still works — and why it looks like it does not

`systemctl is-active getty@tty2` reports **inactive**, which reads alarming
after disabling tty1's getty. It is normal: logind spawns `getty@ttyN` **on
demand** when you switch to an unused VT, via `autovt@.service` symlinked to
`getty@.service`, up to `NAutoVTs=6`.

Confirm without needing a keyboard at the machine:

```bash
systemd-analyze cat-config systemd/logind.conf | grep -E '^NAutoVTs|^ReserveVT'
sudo systemctl start getty@tty2.service && ps -eo tty,comm | grep tty2
sudo systemctl stop getty@tty2.service    # release it back to on-demand
```

## What GB10 cannot show

`MEM [N/A]` in the GPU box is **correct, not a fault**. Unified memory has no
separate GPU pool to compute a percentage against — the same reason `nvidia-smi`
prints "Not Supported" for memory and for every power limit field. Use
`free -g` for memory; it is one pool. Per-process GPU memory does report.

`nvtop` is also installed and gives the same telemetry in a GPU-only view.

## Troubleshooting

**GPU box missing** — check `strings /usr/local/bin/btop | grep -c '^nvml'`
first (build problem), then `shown_boxes` in the config (config problem). These
look identical on screen.

**tty1 blank or scrambled** — `sudo systemctl restart btop-console`. The unit
sets `TTYReset`/`TTYVHangup`, so it reclaims the console cleanly.

**Service flapping** — `systemctl show btop-console -p NRestarts`. A rising
count usually means the config in `/var/lib/btopdisplay` is unreadable or
malformed; delete it and re-seed from step 2.
