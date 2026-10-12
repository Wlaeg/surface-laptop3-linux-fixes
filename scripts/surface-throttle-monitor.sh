#!/bin/bash
# Surface Laptop 3 —— 锁频事件取证监控
#
# 背景：该机存在"随机锁 200MHz"问题。已排除 PL4(0x601) 与过热
# （锁频时 PL4=117W 正常、温度仅 56°C）。现场发现 PROCHOT Log
# (MSR 0x19C/0x1B1 bit3) = 1，指向外部 PROCHOT 断言。
#
# 本脚本持续采样，一旦发现 CPU 被锁在低频，就把完整的 MSR +
# sysfs 快照写入日志，供事后分析。正常运行时不写日志。
#
# 用法：由 systemd 服务启动（需 root 读 MSR）

LOG=/var/log/surface-throttle.log
INTERVAL=2          # 采样间隔（秒）
CORE_LOW_MHZ=500    # 单核低于此值算"被压住"
MIN_LOW_CORES=6     # 低于阈值的核数达到此值才判定锁频（共 8 核）

# ── 锁频判据（2026-10-12 修正）──────────────────────────────
# 原先用「平均频率 < 600MHz」判定，会误报：CPU 空闲时个别核心
# 深度休眠到 400MHz，把平均值拉低，实际 CPU 完全正常。
#
# 真锁频的特征是「几乎全部核心都被钉在 200~400MHz」：
#   真实锁频采样: 201 200 200 200 201 200 200 200 → 8/8 低于阈值
#   空闲误报采样: 1572 3300 3096 2499 3429 400 400 3272 → 仅 2/8
#
# 故改为「低于 CORE_LOW_MHZ 的核数 ≥ MIN_LOW_CORES」才判定锁频。

# 读取单个 MSR（全核，取第一个）
rd() { rdmsr -a "$1" 2>/dev/null | head -1; }

# 统计低于阈值的核数
low_cores() {
    grep '^cpu MHz' /proc/cpuinfo | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1 \
        | awk -v th="$CORE_LOW_MHZ" '$1 < th' | wc -l | tr -d ' '
}

# 平均频率（仅供记录，不参与判定）
avg_mhz() {
    grep '^cpu MHz' /proc/cpuinfo | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1 \
        | awk '{s+=$1;n++} END{if(n)printf "%.0f", s/n; else print 0}'
}

# 采集完整快照
snapshot() {
    local reason="$1" avg="$2"
    {
        echo "════════════════════════════════════════════════════════"
        echo "[$(date '+%F %T')] 锁频事件: $reason (平均频率 ${avg}MHz)"
        echo "── MSR ──"
        for m in 0x601:PL4 0x19C:THERM_STATUS 0x1B1:PKG_THERM_STATUS \
                 0x198:PERF_STATUS 0x199:PERF_CTL 0x770:PM_ENABLE \
                 0x771:HWP_CAPABILITIES 0x772:HWP_REQ_PKG 0x774:HWP_REQUEST \
                 0x777:HWP_STATUS 0x1FC:POWER_CTL 0x1AA:MISC_ENABLE \
                 0x1AD:TURBO_RATIO_LIMIT 0x1B0:ENERGY_PERF_BIAS \
                 0x1A2:TEMP_TARGET 0xE2:CST_CONFIG 0xCE:PLATFORM_INFO; do
            a=${m%%:*}; n=${m##*:}
            printf "  %-20s %-6s = 0x%s\n" "$n" "$a" "$(rd "$a")"
        done

        echo "── PROCHOT 解析 ──"
        local t p
        t=$(rd 0x19C); p=$(rd 0x1B1)
        python3 - "$t" "$p" <<'PY' 2>/dev/null
import sys
for name, v in (("THERM_STATUS 0x19C", sys.argv[1]), ("PKG_THERM_STATUS 0x1B1", sys.argv[2])):
    if not v:
        continue
    x = int(v, 16)
    print(f"  {name} = 0x{x:08X}")
    print(f"    PROCHOT Event(bit2)={((x>>2)&1)} Log(bit3)={((x>>3)&1)} "
          f"CritTemp(bit4)={((x>>4)&1)} Thermal(bit0)={(x&1)}")
    print(f"    PowerLimit(bit10)={((x>>10)&1)} CurrentLimit(bit12)={((x>>12)&1)} "
          f"CrossDomain(bit14)={((x>>14)&1)}")
PY

        echo "── 频率 ──"
        grep '^cpu MHz' /proc/cpuinfo | tr '\n' ' '; echo

        echo "── 温度 ──"
        for z in /sys/class/thermal/thermal_zone*/; do
            printf "  %-14s %s°C\n" "$(cat $z/type 2>/dev/null)" "$(( $(cat $z/temp 2>/dev/null) / 1000 ))"
        done

        echo "── 电源 ──"
        echo "  AC在线=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)" \
             "电池=$(cat /sys/class/power_supply/BAT1/status 2>/dev/null)" \
             "电量=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null)%" \
             "电压=$(awk '{printf "%.3f", $1/1000000}' /sys/class/power_supply/BAT1/voltage_now 2>/dev/null)V"
        echo "  ppd=$(powerprofilesctl get 2>/dev/null)" \
             "platform=$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)"
        echo "  PL1=$(awk '{printf "%.2f", $1/1000000}' /sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null)W" \
             "PL4=$(awk '{printf "%.2f", $1/1000000}' /sys/class/powercap/intel-rapl:0/constraint_2_power_limit_uw 2>/dev/null)W"

        echo "── cooling device（非0即为被激活）──"
        for c in /sys/class/thermal/cooling_device*/; do
            local cur mx ty
            ty=$(cat $c/type 2>/dev/null); cur=$(cat $c/cur_state 2>/dev/null); mx=$(cat $c/max_state 2>/dev/null)
            [ "$cur" != "0" ] && echo "  ★ $ty = $cur/$mx"
        done
        echo "  负载: $(cut -d' ' -f1-3 /proc/loadavg)"
        echo "════════════════════════════════════════════════════════"
    } >> "$LOG" 2>&1
}

# 记录一次启动标记
{ echo; echo "[$(date '+%F %T')] 监控启动 (间隔 ${INTERVAL}s，判据: ≥${MIN_LOW_CORES}/8 核低于 ${CORE_LOW_MHZ}MHz)"; } >> "$LOG"

was_locked=0
while sleep "$INTERVAL"; do
    low=$(low_cores)
    avg=$(avg_mhz)
    if [ "${low:-0}" -ge "$MIN_LOW_CORES" ]; then
        if [ "$was_locked" -eq 0 ]; then
            snapshot "检测到锁频（${low}/8 核低于 ${CORE_LOW_MHZ}MHz）" "$avg"
            was_locked=1
        fi
    else
        if [ "$was_locked" -eq 1 ]; then
            { echo "[$(date '+%F %T')] 锁频解除 (平均频率 ${avg}MHz，${low}/8 核低频)"; } >> "$LOG"
            was_locked=0
        fi
    fi
done
