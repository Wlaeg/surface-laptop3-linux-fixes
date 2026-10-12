# Surface Laptop 3 (Ice Lake) Linux Fixes

**English** | [中文文档](README.zh.md)

Fixes two well-known problems with the Microsoft Surface Laptop 3 (Intel Ice Lake)
running Linux:

1. **CPU randomly locked at 200 MHz** — system becomes nearly unusable
2. **Temperatures hitting 100 °C under load** — constant throttling

These are **two independent problems** requiring separate fixes. This repo provides
scripts and systemd units that were developed and verified on real hardware.

---

## The 200 MHz lock — root cause

`MSR 0x1FC` (`MSR_POWER_CTL`) **bit 0** is the **BD PROCHOT** enable bit:

- `bit0 = 1` → CPU **obeys** throttle signals from external chips (VRM / EC / thermal sensors)
- `bit0 = 0` → CPU **ignores** those signals

The machine ships with `bit0 = 1`. The Embedded Controller (EC) asserts PROCHOT
**roughly every 200 ms, continuously** — so the CPU pins itself to its lowest frequency.

**This has nothing to do with temperature.** Evidence captured during a real lock-up:

| Metric | Value during lock-up | Meaning |
|---|---|---|
| Package temperature | **56–77 °C** | Far below the 100 °C limit ⇒ **not thermal** |
| `MSR 0x601` (PL4) | `0x3a8` = **117 W** | Normal ⇒ **PL4 is not the cause** |
| `MSR 0x19C` bit2 | **1** | The EC is **actively asserting** PROCHOT |
| `MSR 0x19C` bit4 | **0** | Critical temperature not reached |
| All-core frequency | **200 MHz** | Pinned |

Measured assertion rate (using the sticky bit3 of `0x19C`, cleared by writing 1):

```
Time until bit3 re-asserts, 10 rounds:
  202 ms  194 ms  198 ms  257 ms  179 ms  223 ms  209 ms  214 ms  156 ms  227 ms
Windows with an assertion in 20 × 1 s samples: 20/20 = 100 %
```

⇒ **The EC asserts PROCHOT every ~200 ms, indefinitely.** It is a *continuously
present* spurious signal, not an intermittent glitch. The lock-up only *appears*
random because the CPU throttles when the signal coincides with an internal
high-frequency request.

### Fix

```bash
sudo modprobe msr
sudo wrmsr -a 0x1FC 0x24005e     # last hex digit becomes even (e) on success
```

The EC does **not** revert it (verified stable over repeated sampling), so a single
write is enough.

**Daily check — this one command is all you need:**

```bash
sudo rdmsr -a 0x1FC
```

- last digit **even** (`e`) → disabled → healthy
- last digit **odd** (`f`) → protection is back → re-run the fix

---

## Overheating under load — root cause

The firmware sets **PL1 (long-term power limit) to 25 W**, while the CPU's **TDP is 15 W**.

| PL1 | Load temperature | Result |
|---|---|---|
| **25 W** (firmware default) | **100 °C** | Hits thermal wall, sustained throttling |
| 15 W | 77–82 °C | Still high |
| **12.5 W** | **70–74 °C** | 3 min full load, zero lock-ups ✓ |

### Fix: tier PL1 by power profile

| ppd profile (GNOME power mode) | PL1 |
|---|---|
| Performance | 15 W |
| Balanced | 13 W |
| Power Saver | 8 W |

> **⚠️ Critical gotcha — you must write BOTH RAPL domains.** The firmware actually
> uses the MMIO domain; writing only the MSR domain has **no effect**:
> ```
> /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw       (MSR)
> /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw  (MMIO — firmware uses this)
> ```

> **Note:** ppd's three profiles originally only switched `platform_profile` and never
> touched power limits, so all three modes performed identically. This project adds
> that linkage.

---

## Installation

```bash
git clone https://github.com/<your-user>/surface-laptop3-linux-fixes.git
cd surface-laptop3-linux-fixes
sudo ./install.sh --dry-run    # check environment first, changes nothing
sudo ./install.sh              # interactive install
```

`install.sh` will:

1. Verify the environment (model, CPU, lockdown state, `msr` module, tooling)
2. Install scripts to `/usr/local/bin/`
3. Install systemd units and **ask before** enabling them
4. Apply the fix immediately and report the result

**Read `install.sh` before running it** — it modifies systemd configuration.

Manual installation: see [`docs/INSTALL.md`](docs/INSTALL.md).

---

## Verification

```bash
sudo ./scripts/check-health.sh
```

Checks BD PROCHOT, both PL1 domains, service state, systemd ordering cycles,
temperature/frequency, battery, and lock-up history.

**Read-only — it changes nothing.**

---

## What gets installed

| Path | Purpose |
|---|---|
| `/usr/local/bin/disable-bd-prochot.sh` | Clears `0x1FC` bit0, with write verification |
| `/usr/local/bin/surface-pl1-limit.sh` | Sets PL1 per ppd profile |
| `/usr/local/bin/surface-pl1-watch.py` | Listens on ppd's D-Bus, applies PL1 **instantly** on profile change |
| `/usr/local/bin/surface-throttle-monitor.sh` | Forensic lock-up monitor |
| `/etc/modules-load.d/msr.conf` | Loads the `msr` module at boot |

| systemd unit | Trigger |
|---|---|
| `surface-bd-prochot.service` | Boot |
| `surface-bd-prochot-resume.service` | suspend / hibernate / hybrid-sleep / suspend-then-hibernate |
| `surface-pl1-watch.service` | Boot, resident |
| `surface-pl1-limit.service` + `.timer` | Boot + every 3 min as a safety net |
| `surface-throttle-monitor.service` | Boot, resident |

---

## Dead ends we went through

Documented so others don't repeat them.

### ❌ "It's thermal protection"

Initially blamed on conservative firmware throttling at 80 °C. **Wrong** — measured
56–68 °C *while falling* during lock-ups; thermal protection cannot behave that way.

### ❌ "PL4 (`MSR 0x601`) got corrupted"

Inferred from [linux-surface#706](https://github.com/linux-surface/linux-surface/issues/706);
a fix service was even written. **Disproven by on-site forensics** — PL4 read
`0x3a8` (117 W) throughout, unchanged during lock-ups.

> The `wrmsr 0x601` fix *does* work on some Surface models (e.g. SP7), but on the
> **SL3 Ice Lake it is not the cause of this problem**.

### ❌ "The aging battery causes it"

A battery-vs-AC comparison **disproved** this: assertion rate is 100 % on battery too,
yet lock-ups were *less* likely. Trigger conditions correlate with power source, but
it is not simply "a worn battery".

### ⚠️ systemd ordering cycle silently kills the service

If `surface-pl1-watch.service` declares `After=` + `Wants=power-profiles-daemon.service`
while ppd itself has `After=multi-user.target`, a cycle forms:

```
multi-user.target → power-profiles-daemon → surface-pl1-watch → multi-user.target
```

systemd **drops the unit** to break the cycle, so it **never starts after reboot** —
with only a single `Found ordering cycle ... Job deleted` line in the journal.

**Fix:** client-style units must not declare a dependency on ppd; let the script retry
its D-Bus connection instead.

### ⚠️ Never judge a lock-up by average frequency

The monitor originally used `average < 600 MHz` and produced **false positives**: when
idle, individual cores deep-sleep to 400 MHz, dragging the average down while other
cores run at 2–3 GHz.

The correct criterion is **"cores below 500 MHz ≥ 6 of 8"**:

```
real lock-up:  201 200 200 200 201 200 200 200      → 8/8 below ✓
idle false:    1572 3300 3096 2499 3429 400 400 3272 → only 2/8 ✗
```

### ⚠️ Do not run full-load stress tests

An 8-thread stress test during development caused a **hard reset back to the BIOS
screen**. To validate the fix, use the 18-second method below instead.

---

## Reproducible quick repro (to verify the fix)

To confirm the blocking is actually necessary — or that it still holds — takes 18 s:

```bash
# 1. Temporarily re-enable BD PROCHOT (bit0 = 1)
sudo wrmsr -a 0x1FC 0x24005f

# 2. Watch for ~20 s. If all cores drop to 200 MHz, the EC is still
#    asserting and blocking it is indeed necessary.
grep MHz /proc/cpuinfo

# 3. ★ ALWAYS restore ★
sudo wrmsr -a 0x1FC 0x24005e
```

**Risk:** the CPU will briefly be pinned at 200 MHz (it self-recovers in ~1 minute, or
restore immediately). **Do not power off or do important work while locked.**

---

## Uninstalling / rollback

```bash
sudo ./uninstall.sh
```

Or manually:

```bash
sudo wrmsr -a 0x1FC 0x24005f     # restore BD PROCHOT protection
sudo systemctl disable --now surface-bd-prochot.service surface-bd-prochot-resume.service
sudo systemctl disable --now surface-pl1-watch.service surface-pl1-limit.timer
sudo systemctl disable --now surface-throttle-monitor.service
```

---

## Requirements & risks

| Item | Detail |
|---|---|
| Hardware | **Surface Laptop 3**, Intel Ice Lake (i5-1035G7 / i7-1065G7) |
| OS | Linux — verified on **Manjaro + linux-surface kernel 6.19.8** |
| Privileges | root (MSR writes) |
| Secure Boot | **must be off**; kernel lockdown must be `[none]` |

Check lockdown:

```bash
cat /sys/kernel/security/lockdown    # want: [none] integrity confidentiality
```

> ⚠️ **Disabling BD PROCHOT removes a hardware throttle layer.** If the external
> signal were genuine (real overheating or a power fault), the CPU would no longer
> throttle in response. This project mitigates that with the PL1 limits and the
> forensic monitor — but you should understand the tradeoff.
>
> ⚠️ These fixes were derived from measurements on **one specific machine**.
> Different BIOS revisions or batches may behave differently. Run
> `check-health.sh` first and confirm your symptoms match.
>
> ⚠️ **No warranty.** MIT licensed, use at your own risk.

---

## Related projects

- [linux-surface](https://github.com/linux-surface/linux-surface) — Linux support for Surface devices
- [linux-surface#706](https://github.com/linux-surface/linux-surface/issues/706) — related throttling discussion
- [linux-surface#1917](https://github.com/linux-surface/linux-surface/issues/1917) — SL3 PL1 issue
- [Disable-BD-PROCHOT-on-LINUX](https://github.com/fralapo/Disable-BD-PROCHOT-on-LINUX) — the BD PROCHOT approach this project builds on

---

## License

MIT — see [LICENSE](LICENSE).
