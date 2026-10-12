# Manual Installation / 手动安装

[English](#english) | [中文](#中文)

---

## English

If you prefer not to run `install.sh`, follow these steps.

### Prerequisites

```bash
# Debian / Ubuntu
sudo apt install msr-tools python3-dbus python3-gi

# Arch / Manjaro
sudo pacman -S msr-tools python-dbus python-gobject

# Fedora
sudo dnf install msr-tools python3-dbus python3-gobject
```

Verify MSR access works (Secure Boot must be off, lockdown must be `[none]`):

```bash
cat /sys/kernel/security/lockdown     # want: [none] integrity confidentiality
sudo modprobe msr
sudo rdmsr -a 0x1FC                    # should print 8 values
```

### Step 1 — Apply the fixes immediately

```bash
# 1a. Disable BD PROCHOT (fixes the 200 MHz lock)
sudo wrmsr -a 0x1FC 0x24005e

# 1b. Limit PL1 to 12.5 W (fixes overheating; adjust to taste)
echo 12500000 | sudo tee /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
echo 12500000 | sudo tee /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
```

> Note both RAPL domains — the firmware uses the **MMIO** one.

### Step 2 — Install scripts

```bash
sudo install -m 755 scripts/disable-bd-prochot.sh       /usr/local/bin/
sudo install -m 755 scripts/surface-pl1-limit.sh        /usr/local/bin/
sudo install -m 755 scripts/surface-pl1-watch.py        /usr/local/bin/
sudo install -m 755 scripts/surface-throttle-monitor.sh /usr/local/bin/
sudo install -m 644 systemd/msr.conf                    /etc/modules-load.d/
```

### Step 3 — Install systemd units

```bash
for u in surface-bd-prochot.service \
         surface-bd-prochot-resume.service \
         surface-pl1-watch.service \
         surface-pl1-limit.service \
         surface-pl1-limit.timer \
         surface-throttle-monitor.service; do
    sudo install -m 644 "systemd/$u" /etc/systemd/system/
done
sudo systemctl daemon-reload
```

### Step 4 — Enable

```bash
sudo systemctl enable --now surface-bd-prochot.service
sudo systemctl enable --now surface-bd-prochot-resume.service
sudo systemctl enable --now surface-pl1-watch.service
sudo systemctl enable --now surface-pl1-limit.service
sudo systemctl enable --now surface-pl1-limit.timer
sudo systemctl enable --now surface-throttle-monitor.service
```

### Step 5 — Verify

```bash
sudo rdmsr -a 0x1FC                       # last digit must be even
systemctl is-active surface-bd-prochot.service surface-pl1-watch.service \
                    surface-throttle-monitor.service
sudo ./scripts/check-health.sh
```

Then **reboot** and re-run `check-health.sh` — reboot is the only real test that the
units start automatically.

### Customising PL1

Edit the three variables at the top of `/usr/local/bin/surface-pl1-limit.sh`
(values are in **microwatts**):

```bash
LIMIT_PERFORMANCE=15000000   # 15 W
LIMIT_BALANCED=13000000      # 13 W
LIMIT_POWERSAVER=8000000     #  8 W
```

Then:

```bash
sudo systemctl restart surface-pl1-watch.service
```

---

## 中文

如果你不想运行 `install.sh`，可按下述步骤手动安装。

### 前置依赖

```bash
# Debian / Ubuntu
sudo apt install msr-tools python3-dbus python3-gi

# Arch / Manjaro
sudo pacman -S msr-tools python-dbus python-gobject

# Fedora
sudo dnf install msr-tools python3-dbus python3-gobject
```

先确认 MSR 可写（需关闭 Secure Boot，lockdown 必须为 `[none]`）：

```bash
cat /sys/kernel/security/lockdown     # 期望: [none] integrity confidentiality
sudo modprobe msr
sudo rdmsr -a 0x1FC                    # 应输出 8 个值
```

### 第 1 步 — 立即应用修复

```bash
# 1a. 禁用 BD PROCHOT（解决锁 200MHz）
sudo wrmsr -a 0x1FC 0x24005e

# 1b. 限制 PL1 为 12.5W（解决过热，可按需调整）
echo 12500000 | sudo tee /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
echo 12500000 | sudo tee /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
```

> 注意要写**两个域** —— 固件实际使用的是 **MMIO** 域。

### 第 2 步 — 安装脚本

```bash
sudo install -m 755 scripts/disable-bd-prochot.sh       /usr/local/bin/
sudo install -m 755 scripts/surface-pl1-limit.sh        /usr/local/bin/
sudo install -m 755 scripts/surface-pl1-watch.py        /usr/local/bin/
sudo install -m 755 scripts/surface-throttle-monitor.sh /usr/local/bin/
sudo install -m 644 systemd/msr.conf                    /etc/modules-load.d/
```

### 第 3 步 — 安装 systemd 单元

```bash
for u in surface-bd-prochot.service \
         surface-bd-prochot-resume.service \
         surface-pl1-watch.service \
         surface-pl1-limit.service \
         surface-pl1-limit.timer \
         surface-throttle-monitor.service; do
    sudo install -m 644 "systemd/$u" /etc/systemd/system/
done
sudo systemctl daemon-reload
```

### 第 4 步 — 启用

```bash
sudo systemctl enable --now surface-bd-prochot.service
sudo systemctl enable --now surface-bd-prochot-resume.service
sudo systemctl enable --now surface-pl1-watch.service
sudo systemctl enable --now surface-pl1-limit.service
sudo systemctl enable --now surface-pl1-limit.timer
sudo systemctl enable --now surface-throttle-monitor.service
```

### 第 5 步 — 验证

```bash
sudo rdmsr -a 0x1FC                       # 末位必须是偶数
systemctl is-active surface-bd-prochot.service surface-pl1-watch.service \
                    surface-throttle-monitor.service
sudo ./scripts/check-health.sh
```

然后**重启**，再跑一次 `check-health.sh` —— 重启是验证服务能否开机自启的唯一可靠方法。

### 调整 PL1 瓦数

编辑 `/usr/local/bin/surface-pl1-limit.sh` 顶部的三个变量（单位**微瓦**）：

```bash
LIMIT_PERFORMANCE=15000000   # 15 W
LIMIT_BALANCED=13000000      # 13 W
LIMIT_POWERSAVER=8000000     #  8 W
```

然后：

```bash
sudo systemctl restart surface-pl1-watch.service
```
