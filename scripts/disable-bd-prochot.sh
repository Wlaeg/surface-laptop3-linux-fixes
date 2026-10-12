#!/bin/bash
# Surface Laptop 3 (i5-1035G7) —— 永久禁用 BD PROCHOT，根治随机锁 200MHz
#
# ── 根因（已由现场取证确证）────────────────────────────────
#   MSR 0x1FC (MSR_POWER_CTL) 的 bit 0 是 BD PROCHOT 使能位：
#     bit0=1 → CPU 接受外部芯片（VRM / EC / 温度传感器）的降频信号
#     bit0=0 → 忽略这些外部信号
#
#   本机该位为 1（0x24005F，末位 f 为奇数）。当外部信号误触发时，
#   CPU 会被钉在最低频率（本机实测锁 200MHz），且【与温度无关】。
#
# ── 锁频现场证据（2026-10-12 13:25~13:27）────────────────
#     PL4 (MSR 0x601) = 0x3a8 = 117W   完全正常 → 排除 PL4 假说
#     封装温度        = 56°C           远低于阈值 → 排除过热
#     THERM_STATUS    PROCHOT Log = 1   ← 外部 PROCHOT 曾断言
#     MSR 0x1FC       = 0x24005F       BD PROCHOT 处于启用状态
#   锁频自行解除后频率恢复 2600MHz，PL4 全程未变。
#
# ── 为什么这台机器容易触发 ─────────────────────────────────
#   上游文档指出："dying battery（老化电池）或误报的传感器会把核心
#   无限期钉在低频"。本机电池健康度约 80.5%、已循环 490 次，属老化
#   电池，是典型触发源。电源适配器老化/供电余量不足也会误报。
#
# ── 参考 ───────────────────────────────────────────────────
#   https://github.com/fralapo/Disable-BD-PROCHOT-on-LINUX
#   （本脚本按其 manual install 章节实现，并加入写入校验）
#
# ── 注意 ───────────────────────────────────────────────────
#   禁用 BD PROCHOT 会移除一层硬件保护。若外部信号是【真实的】
#   过热/供电告警，CPU 将不再因此降频。
#   本机缓解：PL1 已按电源预设限制在 8~15W（见 surface-pl1-limit.sh），
#   且已有 surface-throttle-monitor 持续记录温度与锁频事件。
#   如需恢复保护：wrmsr -a 0x1FC 0x24005f，或运行
#   systemctl disable --now surface-bd-prochot.service
# ───────────────────────────────────────────────────────────

modprobe msr 2>/dev/null || true

shopt -s nullglob
cpus=(/dev/cpu/[0-9]*)
if [ ${#cpus[@]} -eq 0 ]; then
    logger -t surface-bd-prochot "未找到 /dev/cpu/*/msr，msr 模块是否可用？"
    exit 1
fi

fail=0
fixed=0
for cpu in "${cpus[@]}"; do
    cpu_id="${cpu##*/cpu/}"
    cpu_id="${cpu_id%%/*}"

    cur=$(rdmsr -p "$cpu_id" 0x1FC 2>/dev/null) || {
        logger -t surface-bd-prochot "cpu $cpu_id: rdmsr 失败"
        fail=1
        continue
    }

    # bit0 已为 0，无需处理
    (( 16#$cur & 1 )) || continue

    new=$(( 16#$cur & ~1 ))
    if ! wrmsr -p "$cpu_id" 0x1FC "$(printf '0x%x' "$new")" 2>/dev/null; then
        logger -t surface-bd-prochot "cpu $cpu_id: wrmsr 失败（内核 lockdown？）"
        fail=1
        continue
    fi

    # 写入校验：确认 bit0 确实被清除
    chk=$(rdmsr -p "$cpu_id" 0x1FC 2>/dev/null)
    if (( 16#$chk & 1 )); then
        logger -t surface-bd-prochot \
            "cpu $cpu_id: 写入未生效（0x$cur -> 0x$chk），固件/EC 正在改回"
        fail=1
    else
        fixed=$((fixed + 1))
    fi
done

[ "$fixed" -gt 0 ] && logger -t surface-bd-prochot "已在 $fixed 个核心禁用 BD PROCHOT"
exit $fail
