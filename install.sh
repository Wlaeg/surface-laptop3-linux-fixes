#!/bin/bash
#
# Surface Laptop 3 (Ice Lake) Linux 修复方案 —— 安装脚本
#
# 用法:
#   sudo ./install.sh            # 交互式安装（会逐项确认）
#   sudo ./install.sh --yes      # 非交互，全部默认启用
#   sudo ./install.sh --dry-run  # 只检查环境，不做任何修改
#
# 本脚本会:
#   1. 检查环境（机型/CPU/lockdown/msr 模块）
#   2. 安装脚本到 /usr/local/bin
#   3. 安装 systemd 单元
#   4. 立即应用修复并显示结果
#
# 卸载请用 ./uninstall.sh

set -u

# ── 参数 ────────────────────────────────────────────────
ASSUME_YES=0
DRY_RUN=0
for a in "$@"; do
    case "$a" in
        --yes|-y)   ASSUME_YES=1 ;;
        --dry-run)  DRY_RUN=1 ;;
        --help|-h)  sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知参数: $a（可用: --yes --dry-run --help）" >&2; exit 2 ;;
    esac
done

# ── 颜色 ────────────────────────────────────────────────
if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
    G=; R=; Y=; B=; N=
fi
ok()   { echo "  ${G}✓${N} $*"; }
bad()  { echo "  ${R}✗${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
info() { echo "      $*"; }
step() { echo; echo "${B}▶ $*${N}"; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ── 必须 root ───────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行: sudo $0 $*" >&2
    exit 1
fi

echo "════════════════════════════════════════════════════════"
echo " Surface Laptop 3 (Ice Lake) Linux 修复方案 —— 安装"
echo "════════════════════════════════════════════════════════"
[ "$DRY_RUN" -eq 1 ] && echo " ${Y}【dry-run 模式】只检查环境，不会修改任何文件${N}"

FAIL=0

# ── 1. 环境检查 ─────────────────────────────────────────
step "1. 环境检查"

# 机型
model=""
if command -v dmidecode >/dev/null 2>&1; then
    model=$(dmidecode -s system-product-name 2>/dev/null || true)
fi
if [ -n "$model" ]; then
    case "$model" in
        *"Surface Laptop 3"*)
            ok "机型: $model" ;;
        *Surface*)
            warn "机型: $model"
            info "本方案针对 Surface Laptop 3 开发，其他 Surface 未经验证。"
            info "请确认症状一致（随机锁 200MHz、温度不高）再继续。"
            ;;
        *)
            bad "机型: $model（不是 Surface）"
            info "本方案依赖 Surface 特有的 EC 行为，其他机型请勿使用。"
            FAIL=$((FAIL+1)) ;;
    esac
else
    warn "无法读取机型（dmidecode 未安装或缺权限）"
fi

# CPU
cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs)
if [ -n "$cpu" ]; then
    info "CPU: $cpu"
    case "$cpu" in
        *"10"*G[1-9]*|*Ice*Lake*)
            ok "CPU 疑似 Ice Lake（本方案目标平台）" ;;
        *)
            warn "CPU 可能不是 Ice Lake 10 代，请自行确认" ;;
    esac
fi

# 内核
info "内核: $(uname -r)"

# msr 模块
if modprobe msr 2>/dev/null; then
    ok "msr 模块可加载"
else
    bad "msr 模块加载失败"
    info "部分精简内核未编译 CONFIG_X86_MSR，本方案无法使用。"
    FAIL=$((FAIL+1))
fi

# rdmsr/wrmsr
missing=""
for c in rdmsr wrmsr; do
    command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "$missing" ]; then
    bad "缺少工具:$missing（包名通常为 msr-tools）"
    info "  Arch/Manjaro : pacman -S msr-tools"
    info "  Debian/Ubuntu: apt install msr-tools"
    info "  Fedora       : dnf install msr-tools"
    FAIL=$((FAIL+1))
else
    ok "rdmsr / wrmsr 可用"
fi

# lockdown（决定能否写 MSR）
if [ -r /sys/kernel/security/lockdown ]; then
    lk=$(cat /sys/kernel/security/lockdown)
    if echo "$lk" | grep -q '\[none\]'; then
        ok "内核 lockdown: $lk（允许写 MSR）"
    else
        bad "内核 lockdown: $lk —— 会阻止 wrmsr"
        info "需关闭 Secure Boot，或 mokutil --disable-validation"
        FAIL=$((FAIL+1))
    fi
else
    info "无 lockdown 接口（通常没问题）"
fi

# 实测写 MSR
if [ "$FAIL" -eq 0 ]; then
    cur=$(rdmsr -a 0x1FC 2>/dev/null | head -1)
    if [ -n "$cur" ]; then
        ok "MSR 0x1FC 可读: 0x$cur"
        if [ $(( 16#$cur & 1 )) -eq 1 ]; then
            warn "BD PROCHOT 当前为【启用】状态 —— 这正是问题根源"
            info "安装后将自动禁用。"
        else
            ok "BD PROCHOT 已为禁用状态"
        fi
    else
        bad "MSR 0x1FC 读取失败"
        FAIL=$((FAIL+1))
    fi
fi

# 依赖：python3 + dbus（PL1 实时联动需要）
if [ -e "$SCRIPT_DIR/scripts/surface-pl1-watch.py" ]; then
    if command -v python3 >/dev/null 2>&1 \
       && python3 -c 'import dbus, gi' 2>/dev/null; then
        ok "python3 + dbus + gi 可用（PL1 实时联动）"
    else
        warn "python3 的 dbus/gi 模块不可用"
        info "PL1 实时联动会失效，但 timer 兜底仍能工作。"
        info "  Debian/Ubuntu: apt install python3-dbus python3-gi"
        info "  Arch/Manjaro : pacman -S python-dbus python-gobject"
    fi
fi

# ppd
if command -v powerprofilesctl >/dev/null 2>&1; then
    ok "power-profiles-daemon 可用（当前: $(powerprofilesctl get 2>/dev/null)）"
else
    warn "未检测到 power-profiles-daemon"
    info "PL1 将回退到 ACPI platform_profile 判断。"
fi

if [ "$FAIL" -gt 0 ]; then
    echo
    bad "环境检查未通过（$FAIL 项），已中止安装。"
    echo "     解决上述问题后重试，或用 --dry-run 复查。"
    exit 1
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo
    ok "dry-run 完成：环境检查通过，可以正式安装。"
    exit 0
fi

# ── 2. 确认 ─────────────────────────────────────────────
step "2. 将要执行的操作"
cat <<'EOF'
  安装以下文件:
    /usr/local/bin/disable-bd-prochot.sh
    /usr/local/bin/surface-pl1-limit.sh
    /usr/local/bin/surface-pl1-watch.py
    /usr/local/bin/surface-throttle-monitor.sh
    /etc/modules-load.d/msr.conf

  安装并【启用】以下 systemd 单元:
    surface-bd-prochot.service          (开机禁用 BD PROCHOT)
    surface-bd-prochot-resume.service   (唤醒后再次禁用)
    surface-pl1-watch.service           (PL1 实时联动电源模式)
    surface-pl1-limit.service + .timer  (开机 + 每 3 分钟兜底)
    surface-throttle-monitor.service    (锁频取证监控)

  并立即:
    - 清除 MSR 0x1FC bit0 (禁用 BD PROCHOT)
    - 按当前电源模式设置 PL1
EOF
echo
if [ "$ASSUME_YES" -ne 1 ]; then
    printf "  继续？[y/N] "
    read -r ans
    case "$ans" in
        [yY]*) ;;
        *) echo "  已取消。"; exit 0 ;;
    esac
fi

# ── 3. 安装文件 ─────────────────────────────────────────
step "3. 安装文件"
install -m 755 "$SCRIPT_DIR/scripts/disable-bd-prochot.sh"       /usr/local/bin/ || { bad "复制失败"; exit 1; }
install -m 755 "$SCRIPT_DIR/scripts/surface-pl1-limit.sh"        /usr/local/bin/ || exit 1
install -m 755 "$SCRIPT_DIR/scripts/surface-pl1-watch.py"        /usr/local/bin/ || exit 1
install -m 755 "$SCRIPT_DIR/scripts/surface-throttle-monitor.sh" /usr/local/bin/ || exit 1
install -m 644 "$SCRIPT_DIR/systemd/msr.conf"                    /etc/modules-load.d/ || exit 1
ok "脚本已安装到 /usr/local/bin"

for u in surface-bd-prochot.service surface-bd-prochot-resume.service \
         surface-pl1-watch.service surface-pl1-limit.service \
         surface-pl1-limit.timer surface-throttle-monitor.service; do
    install -m 644 "$SCRIPT_DIR/systemd/$u" /etc/systemd/system/ || exit 1
done
ok "systemd 单元已安装"

systemctl daemon-reload
ok "systemd 已重新加载"

# ── 4. 启用服务 ─────────────────────────────────────────
step "4. 启用服务"
for u in surface-bd-prochot.service surface-bd-prochot-resume.service \
         surface-pl1-watch.service surface-pl1-limit.service \
         surface-pl1-limit.timer surface-throttle-monitor.service; do
    if systemctl enable --now "$u" >/dev/null 2>&1; then
        ok "$u"
    else
        # oneshot 的 resume 单元在此刻 enable 可能报"无触发条件"，仍视为成功
        if systemctl is-enabled "$u" >/dev/null 2>&1; then
            ok "$u（已启用）"
        else
            bad "$u 启用失败"
        fi
    fi
done

# ── 5. 立即应用并验证 ───────────────────────────────────
step "5. 应用修复并验证"
sleep 1

v=$(rdmsr -a 0x1FC 2>/dev/null | head -1)
if [ -n "$v" ] && [ $(( 16#$v & 1 )) -eq 0 ]; then
    ok "BD PROCHOT 已禁用 (0x1FC = 0x$v)"
else
    bad "BD PROCHOT 仍为启用 (0x$v)"
    info "手动执行: sudo wrmsr -a 0x1FC 0x24005e"
fi

a=$(awk '{printf "%.2f", $1/1000000}' /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null)
b=$(awk '{printf "%.2f", $1/1000000}' /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw 2>/dev/null)
if [ -n "$a" ] && [ "$a" = "$b" ]; then
    ok "PL1 两域一致: ${a}W"
else
    warn "PL1 两域不一致（MSR=${a:-?}W MMIO=${b:-?}W）"
    info "手动执行: sudo /usr/local/bin/surface-pl1-limit.sh"
fi

# ── 完成 ────────────────────────────────────────────────
echo
echo "════════════════════════════════════════════════════════"
ok "安装完成"
echo
echo "  立即验证:  sudo rdmsr -a 0x1FC        （末位应为偶数 e）"
echo "  完整体检:  sudo ./scripts/check-health.sh"
echo "  卸载:      sudo ./uninstall.sh"
echo
echo "  ${Y}注意${N}: 已禁用 BD PROCHOT，这移除了一层硬件降频保护。"
echo "        本方案用 PL1 限制 + 取证监控作为缓解。"
echo "        日志: /var/log/surface-throttle.log"
echo "  建议重启一次，确认所有服务开机自启正常。"
echo "════════════════════════════════════════════════════════"
