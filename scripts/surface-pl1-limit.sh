#!/bin/bash
# Surface Laptop 3 (i5-1035G7) —— 按电源预设联动 RAPL PL1
#
# ── 这里处理的是两个【互相独立】的问题，别混淆 ──────────────
#
#  问题 A：随机锁 200MHz（用户实际遇到的主要问题）
#    → 根因：固件把 MSR 0x601 (PL4) 写成坏值，与温度无关。
#      实测 PL4=117W 时 2200MHz，PL4=15W 时仅 475MHz。
#    → 由 surface-rapl-fix.sh + surface-rapl.service
#      + surface-rapl.timer 负责修复，【本脚本不涉及】。
#
#  问题 B：满载过热降频（本脚本处理）
#    → 根因：固件默认 PL1 = 25W，而该 CPU 的 TDP 只有 15W。
#      实测 25W 满载可达 100°C，长时高位运行会持续降频。
#    → 因此按电源预设分级限制 PL1。
#
#  注：早期分析曾把锁频归因于"固件 80°C 保守保护"，该结论
#      后来被推翻（锁频时温度仅 55~68°C 且还在下降，热保护
#      不可能是这种表现）。真正原因是上面的 PL4。
#
# ── 两个 RAPL 域都要设置 ──────────────────────────────────
#   本机同时存在 MSR 与 MMIO 两个 RAPL 域，固件实际使用 MMIO 域，
#   只改一个不生效，必须都改。
#
# 参考：https://github.com/linux-surface/linux-surface/issues/1917
# ───────────────────────────────────────────────────────────

# 预设 → PL1（微瓦）
#   performance  15W    TDP 上限，性能最好；温度较高（实测约 77~82°C）
#   balanced     13W    日常默认，性能与温度折中
#   power-saver   8W    长续航、机身更凉
#
# 想改数值直接改这里，然后：
#   sudo systemctl restart surface-pl1-watch.service
LIMIT_PERFORMANCE=15000000
LIMIT_BALANCED=13000000
LIMIT_POWERSAVER=8000000

RAILS="
/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
"

# ── 读取当前电源预设 ───────────────────────────────────────
# 优先读 ppd（用户实际操作的层），失败则回退到 ACPI platform_profile
get_profile() {
    local p
    p=$(busctl get-property net.hadess.PowerProfiles /net/hadess/PowerProfiles \
            net.hadess.PowerProfiles ActiveProfile 2>/dev/null \
        | sed -n 's/^s "\(.*\)"$/\1/p')
    if [ -z "$p" ]; then
        p=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)
    fi
    echo "$p"
}

profile=$(get_profile)

case "$profile" in
    performance|balanced-performance)
        LIMIT_UW=$LIMIT_PERFORMANCE ;;
    power-saver|low-power)
        LIMIT_UW=$LIMIT_POWERSAVER ;;
    balanced|"")
        LIMIT_UW=$LIMIT_BALANCED ;;
    *)
        # 未知取值：保守使用平衡档，避免放开到固件的 25W
        LIMIT_UW=$LIMIT_BALANCED ;;
esac

# ── 等待 powercap 设备就绪（开机时可能晚于本服务出现）──────
for _ in $(seq 1 30); do
    [ -w /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw ] && break
    sleep 1
done

# ── 应用 ───────────────────────────────────────────────────
changed=0
for rail in $RAILS; do
    if [ ! -w "$rail" ]; then
        echo "surface-pl1-limit: $rail 不可写，跳过" >&2
        continue
    fi
    current=$(cat "$rail" 2>/dev/null)
    if [ "$current" != "$LIMIT_UW" ]; then
        if echo "$LIMIT_UW" > "$rail" 2>/dev/null; then
            logger -t surface-pl1-limit \
                "预设 $profile: PL1 $((current/1000))mW -> $((LIMIT_UW/1000))mW ($rail)"
            changed=1
        else
            echo "surface-pl1-limit: 写入 $rail 失败" >&2
        fi
    fi
done

# 仅在发生变化时输出，避免 timer 每次轮询都刷日志
[ "$changed" -eq 1 ] && echo "PL1 已按预设 $profile 设为 $((LIMIT_UW/1000))mW"
exit 0
