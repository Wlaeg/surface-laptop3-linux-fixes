#!/bin/bash
#
# Surface Laptop 3 (Ice Lake) Linux 修复方案 —— 卸载脚本
#
# 用法:
#   sudo ./uninstall.sh              # 交互式
#   sudo ./uninstall.sh --yes        # 非交互
#   sudo ./uninstall.sh --keep-logs  # 保留 /var/log/surface-throttle.log
#
# 本脚本会:
#   1. 停用并禁用所有 surface-* 单元
#   2. 删除 /usr/local/bin 下的脚本
#   3. 删除 systemd 单元与 modules-load 配置
#   4. 恢复 BD PROCHOT 保护（写回 0x24005f）
#   5. 把 PL1 恢复为固件原值 25W（可选，默认恢复）
#
# 注意: 恢复 BD PROCHOT 后，"随机锁 200MHz"问题会重新出现。

set -u

ASSUME_YES=0
KEEP_LOGS=0
for a in "$@"; do
    case "$a" in
        --yes|-y)    ASSUME_YES=1 ;;
        --keep-logs) KEEP_LOGS=1 ;;
        --help|-h)   sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "未知参数: $a" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
    G=; R=; Y=; B=; N=;
fi
ok()   { echo "  ${G}✓${N} $*"; }
bad()  { echo "  ${R}✗${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
info() { echo "      $*"; }
step() { echo; echo "${B}▶ $*${N}"; }

if [ "$(id -u)" -ne 0 ]; then
    echo "请用 root 运行: sudo $0 $*" >&2
    exit 1
fi

UNITS="surface-bd-prochot.service
surface-bd-prochot-resume.service
surface-pl1-watch.service
surface-pl1-limit.service
surface-pl1-limit.timer
surface-throttle-monitor.service"

FILES="/usr/local/bin/disable-bd-prochot.sh
/usr/local/bin/surface-pl1-limit.sh
/usr/local/bin/surface-pl1-watch.py
/usr/local/bin/surface-throttle-monitor.sh
/etc/modules-load.d/msr.conf"

echo "════════════════════════════════════════════════════════"
echo " Surface Laptop 3 (Ice Lake) Linux 修复方案 —— 卸载"
echo "════════════════════════════════════════════════════════"
echo
echo "  将执行:"
echo "    - 停用/禁用并删除所有 surface-* 单元"
echo "    - 删除 /usr/local/bin 下的 4 个脚本与 msr.conf"
echo "    - 恢复 BD PROCHOT 保护 (wrmsr 0x1FC 0x24005f)"
echo "    - 恢复 PL1 为固件原值 25W"
echo
echo "  ${Y}警告${N}: 恢复 BD PROCHOT 后，CPU 随机锁 200MHz 的问题会回来。"
echo

if [ "$ASSUME_YES" -ne 1 ]; then
    printf "  确认卸载？[y/N] "
    read -r ans
    case "$ans" in [yY]*) ;; *) echo "  已取消。"; exit 0 ;; esac
fi

# ── 1. 停用单元 ─────────────────────────────────────────
step "1. 停用 systemd 单元"
for u in $UNITS; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1; then
        systemctl disable --now "$u" >/dev/null 2>&1 && ok "已停用 $u" || info "$u 未在运行"
    fi
done

# ── 2. 删除单元文件 ─────────────────────────────────────
step "2. 删除单元文件"
for u in $UNITS; do
    if [ -e "/etc/systemd/system/$u" ]; then
        rm -f "/etc/systemd/system/$u" && ok "已删除 $u"
    fi
done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
ok "systemd 已重新加载"

# ── 3. 删除脚本 ─────────────────────────────────────────
step "3. 删除脚本文件"
for f in $FILES; do
    if [ -e "$f" ]; then
        rm -f "$f" && ok "已删除 $f"
    fi
done

# ── 4. 恢复 BD PROCHOT ──────────────────────────────────
step "4. 恢复 BD PROCHOT 保护"
if command -v wrmsr >/dev/null 2>&1; then
    if wrmsr -a 0x1FC 0x24005f 2>/dev/null; then
        v=$(rdmsr -a 0x1FC 2>/dev/null | head -1)
        if [ -n "$v" ] && [ $(( 16#$v & 1 )) -eq 1 ]; then
            ok "BD PROCHOT 已恢复启用 (0x1FC = 0x$v)"
        else
            warn "写入完成但读回为 0x$v（期望末位为奇数）"
        fi
    else
        bad "wrmsr 失败 —— 请手动执行: sudo wrmsr -a 0x1FC 0x24005f"
    fi
else
    warn "wrmsr 不可用，跳过（BD PROCHOT 将在重启后由固件恢复默认）"
fi

# ── 5. 恢复 PL1 ─────────────────────────────────────────
step "5. 恢复 PL1 为固件原值 (25W)"
for r in /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw \
         /sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw; do
    if [ -w "$r" ]; then
        echo 25000000 > "$r" 2>/dev/null && ok "已恢复 $r" || warn "写入失败: $r"
    fi
done
info "注意: 25W 远超 TDP 15W，满载可能再次达到 100°C。"

# ── 6. 日志 ─────────────────────────────────────────────
step "6. 监控日志"
if [ "$KEEP_LOGS" -eq 1 ]; then
    info "按 --keep-logs 保留 /var/log/surface-throttle.log"
elif [ -e /var/log/surface-throttle.log ]; then
    rm -f /var/log/surface-throttle.log && ok "已删除 /var/log/surface-throttle.log"
fi

echo
echo "════════════════════════════════════════════════════════"
ok "卸载完成"
echo
echo "  建议重启一次，确认系统状态已回到原厂行为。"
echo "  如仍需该修复，可重新运行: sudo ./install.sh"
echo "════════════════════════════════════════════════════════"
