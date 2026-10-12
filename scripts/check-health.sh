#!/bin/bash
# Surface Laptop 3 (Ice Lake) Linux 修复方案 · 一键体检
#
# 用法:
#   sudo bash check-health.sh        # 直接跑（会提示密码）
#   或者不加 sudo，脚本遇到需要 root 的部分会提示
#
# 检查内容：BD PROCHOT、PL1 双域、systemd 服务、依赖环、
#          温度频率、电池、锁频监控日志统计。
# 只读操作，不修改任何系统设置。

# ── 颜色（非终端时自动关闭）─────────────────────────────
if [ -t 1 ]; then
    G=$'\033[32m'; R=$'\033[31m'; Y=$'\033[33m'; B=$'\033[36m'; N=$'\033[0m'
else
    G=; R=; Y=; B=; N=
fi

OK=0; BAD=0
pass() { echo "  ${G}✓${N} $*"; OK=$((OK+1)); }
fail() { echo "  ${R}✗${N} $*"; BAD=$((BAD+1)); }
warn() { echo "  ${Y}!${N} $*"; }
info() { echo "      $*"; }
head_() { echo; echo "${B}── $* ──${N}"; }

# 需要 root 才能读 MSR / sysfs 的部分
NEED_SUDO=""
if [ "$(id -u)" -ne 0 ]; then
    if sudo -n true 2>/dev/null; then
        SUDO="sudo -n"
    else
        SUDO="sudo"
        NEED_SUDO=1
    fi
else
    SUDO=""
fi

echo "════════ Surface Laptop 3 系统体检 ════════"
echo "  时间: $(date '+%F %T')"
echo "  主机: $(hostname)   内核: $(uname -r)"
echo "  运行时长: $(uptime -p 2>/dev/null | sed 's/^up //')"

if [ -n "$NEED_SUDO" ]; then
    echo
    echo "  ${Y}提示${N}: 读取 MSR 寄存器需要 root，即将提示输入密码。"
fi

# ── 1. BD PROCHOT（最核心）──────────────────────────────
head_ "1. BD PROCHOT（锁 200MHz 的根因开关）"
if command -v rdmsr >/dev/null 2>&1; then
    val=$($SUDO rdmsr -a 0x1FC 2>/dev/null | head -1)
    if [ -n "$val" ]; then
        last="${val: -1}"
        bit0=$(( 16#$val & 1 ))
        if [ "$bit0" -eq 0 ]; then
            pass "MSR 0x1FC = 0x$val （末位 $last 为偶数）→ BD PROCHOT 已禁用"
        else
            fail "MSR 0x1FC = 0x$val （末位 $last 为奇数）→ BD PROCHOT 已启用！"
            info "修复: sudo wrmsr -a 0x1FC 0x24005e"
            info "      sudo systemctl restart surface-bd-prochot.service"
        fi
        uniq_n=$($SUDO rdmsr -a 0x1FC 2>/dev/null | sort -u | wc -l)
        [ "$uniq_n" = "1" ] && info "8 核取值一致 ✓" \
                            || warn "各核取值不一致（$uniq_n 种），修复可能只部分生效"
    else
        fail "无法读取 MSR 0x1FC（msr 模块未加载？或需要 root）"
        info "尝试: sudo modprobe msr"
    fi
else
    fail "rdmsr 未安装（msr-tools）"
    info "安装: sudo pacman -S msr-tools"
fi

# ── 2. PL4（仅作参考，非根因）───────────────────────────
head_ "2. PL4 / MSR 0x601（参考项，实测与锁频无关）"
v=$($SUDO rdmsr -a 0x601 2>/dev/null | head -1)
if [ -n "$v" ]; then
    w=$(python3 -c "print(f'{int('$v',16)/8:.1f}')" 2>/dev/null)
    if [ "$v" = "3a8" ]; then
        pass "MSR 0x601 = 0x3a8（${w}W）正常"
    else
        warn "MSR 0x601 = 0x$v（${w}W），本机正常值为 0x3a8(117W)"
        info "注：实测此寄存器与锁频无关，一般无需处理"
    fi
else
    warn "无法读取（不影整体判定）"
fi

# ── 3. PL1 电源限制 ────────────────────────────────────
head_ "3. PL1 功率限制（防满载 100°C）"
MSR_PL=/sys/class/powercap/intel-rapl:0/constraint_0_power_limit_uw
MMIO_PL=/sys/class/powercap/intel-rapl-mmio:0/constraint_0_power_limit_uw
if [ -r "$MSR_PL" ] && [ -r "$MMIO_PL" ]; then
    a=$(awk '{printf "%.2f", $1/1000000}' "$MSR_PL")
    b=$(awk '{printf "%.2f", $1/1000000}' "$MMIO_PL")
    info "MSR 域:  ${a} W"
    info "MMIO 域: ${b} W"
    if [ "$a" = "$b" ]; then
        pass "两域一致（必须都设置，固件实际用 MMIO 域）"
    else
        fail "两域不一致！固件用的是 MMIO 域，请重跑 surface-pl1-limit.sh"
    fi
    # 合理性：不应超过 15W（TDP），也不应低于 5W
    over=$(python3 -c "print(1 if $a > 15.01 else 0)")
    under=$(python3 -c "print(1 if $a < 5 else 0)")
    [ "$over" = "1" ] && warn "PL1=${a}W 超过 TDP(15W)，满载会过热"
    [ "$under" = "1" ] && warn "PL1=${a}W 偏低，性能会受限"
    [ "$over" = "0" ] && [ "$under" = "0" ] && pass "数值在合理范围（TDP 15W 以内）"
else
    fail "无法读取 powercap（intel_rapl 模块未加载？）"
fi

# 当前预设
if command -v powerprofilesctl >/dev/null 2>&1; then
    p=$(powerprofilesctl get 2>/dev/null)
    case "$p" in
        performance) exp="15.00" ;;
        balanced)    exp="13.00" ;;
        power-saver) exp="8.00" ;;
        *)           exp="" ;;
    esac
    info "电源预设: $p${exp:+ （该档应为 ${exp}W）}"
    if [ -n "$exp" ] && [ -n "$a" ] && [ "$a" != "$exp" ]; then
        warn "PL1 与预设不匹配（预期 ${exp}W，实际 ${a}W）"
        info "3 分钟内定时器会自动纠正；也可立即: sudo systemctl restart surface-pl1-watch.service"
    fi
fi

# ── 4. systemd 服务 ────────────────────────────────────
head_ "4. 优化服务状态"
declare -A WANT=(
    [surface-bd-prochot.service]=enabled
    [surface-bd-prochot-resume.service]=enabled
    [surface-pl1-watch.service]=enabled
    [surface-pl1-limit.service]=enabled
    [surface-pl1-limit.timer]=enabled
    [surface-throttle-monitor.service]=enabled
)
for u in surface-bd-prochot.service surface-bd-prochot-resume.service \
         surface-pl1-watch.service surface-pl1-limit.service \
         surface-pl1-limit.timer surface-throttle-monitor.service; do
    en=$(systemctl is-enabled "$u" 2>/dev/null)
    ac=$(systemctl is-active "$u" 2>/dev/null)
    if [ "$en" = "enabled" ]; then
        if [ "$ac" = "active" ] || [ "$ac" = "inactive" ]; then
            pass "$u  $en / $ac"
        else
            fail "$u  $en / $ac"
        fi
    else
        fail "$u  未启用（当前: $en）"
        info "启用: sudo systemctl enable --now $u"
    fi
done
info "注: oneshot 服务显示 inactive 是正常的（跑完即退出）"

# ── 5. 依赖环自检 ──────────────────────────────────────
head_ "5. systemd 依赖环（曾导致服务重启后静默失效）"

# 【原则】判断依据是「服务当前配置是否有环」，不是翻历史日志。
# 历史日志里会永久保留修复前的旧记录，据此报警会造成误报（踩过坑）。
# 环的成因：本服务的 After= 引用了某个「自身 After=multi-user.target」的服务。
# 已知的成环源是 power-profiles-daemon（它 After=multi-user.target）。

check_cycle() {
    local unit="$1"
    local after
    after=$(systemctl show "$unit" -p After --value 2>/dev/null)
    local hit=""
    for dep in power-profiles-daemon.service display-manager.service; do
        case " $after " in
            *" $dep "*) hit="$dep" ;;
        esac
    done
    if [ -n "$hit" ]; then
        return 1
    fi
    return 0
}

cyc_bad=0
for u in surface-bd-prochot.service surface-bd-prochot-resume.service \
         surface-pl1-watch.service surface-pl1-limit.service \
         surface-pl1-limit.timer surface-throttle-monitor.service; do
    if ! check_cycle "$u"; then
        fail "$u 的 After= 含成环风险项"
        systemctl show "$u" -p After --value 2>/dev/null \
            | tr ' ' '\n' | grep -E 'power-profiles-daemon|display-manager' \
            | sed 's/^/        引用: /'
        info "修法: 删除该单元 After=/Wants= 里对 power-profiles-daemon 的引用，"
        info "      脚本自身会重试连接 D-Bus，无需声明依赖。"
        cyc_bad=$((cyc_bad + 1))
    fi
done

if [ "$cyc_bad" -eq 0 ]; then
    pass "6 个单元均无依赖环配置"
fi

# 历史日志仅供参考（可能含修复前的旧记录）
hist=$(journalctl -b --no-pager 2>/dev/null \
        | grep 'Found ordering cycle' | grep 'surface-' \
        | grep -v 'dsh-subprocess\|systemd-run\|runner\.js' | wc -l | tr -d ' ')
hist=${hist:-0}
if [ "$hist" -gt 0 ] && [ "$cyc_bad" -eq 0 ]; then
    info "（本次启动日志有 $hist 条历史环记录，属修复前遗留，可忽略）"
fi

# 注意: grep -c 无匹配时输出 0 但退出码非零，故改用 awk 统计，保证纯数字
failed=$(systemctl --failed --no-pager 2>/dev/null | awk '/●/ && /\.service/ {c++} END{print c+0}')
failed=${failed:-0}
if [ "$failed" -eq 0 ]; then
    pass "无失败单元"
else
    warn "$failed 个失败单元（执行 systemctl --failed 查看）"
fi

# ── 6. 温度与频率 ──────────────────────────────────────
head_ "6. 实时温度与频率"
if [ -r /sys/class/thermal/thermal_zone13/temp ]; then
    t=$(( $(cat /sys/class/thermal/thermal_zone13/temp) / 1000 ))
    if [ "$t" -ge 95 ]; then
        fail "CPU 封装 ${t}°C（过高）"
    elif [ "$t" -ge 85 ]; then
        warn "CPU 封装 ${t}°C（偏高）"
    else
        pass "CPU 封装 ${t}°C"
    fi
fi
# 找最热的温区
hottest=$(for z in /sys/class/thermal/thermal_zone*/; do
    ty=$(cat "$z/type" 2>/dev/null); tv=$(cat "$z/temp" 2>/dev/null)
    [ -n "$tv" ] && echo "$((tv/1000)) $ty"
done | sort -rn | head -1)
[ -n "$hottest" ] && info "最热温区: ${hottest}"

freqs=$(grep '^cpu MHz' /proc/cpuinfo | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1)
avgf=$(echo "$freqs" | awk '{s+=$1;n++} END{printf "%.0f", s/n}')
minf=$(echo "$freqs" | sort -n | head -1)
lowc=$(echo "$freqs" | awk '$1<500' | wc -l | tr -d ' ')
ncpu=$(echo "$freqs" | wc -l | tr -d ' ')
info "各核频率: $(echo $freqs | tr '\n' ' ')"

# 【判据】(2026-10-12 修正)
# 不能用「平均频率低」判断锁频：CPU 空闲时个别核心会深度休眠到 400MHz，
# 把平均值拉低，但实际 CPU 完全正常（其余核 2~3GHz）。曾因此误报。
# 真锁频的特征是【几乎全部核心都被钉在 200~400MHz】。
if [ "${lowc:-0}" -ge 6 ]; then
    fail "锁频中！${lowc}/${ncpu} 个核低于 500MHz（全部被压住）"
    info "立即恢复: sudo wrmsr -a 0x1FC 0x24005e"
    info "查看现场: sudo tail -60 /var/log/surface-throttle.log"
elif [ "$avgf" -lt 600 ]; then
    warn "平均 ${avgf}MHz 偏低，但仅 ${lowc}/${ncpu} 核低频（多为空闲降频，非锁频）"
else
    pass "平均 ${avgf}MHz（最低核 ${minf}MHz，低于 500MHz 的核 ${lowc}/${ncpu}）"
fi

# ── 7. 电池与供电 ──────────────────────────────────────
head_ "7. 电池与供电"
if [ -r /sys/class/power_supply/BAT1/energy_full ]; then
    ef=$(cat /sys/class/power_supply/BAT1/energy_full)
    efd=$(cat /sys/class/power_supply/BAT1/energy_full_design)
    cc=$(cat /sys/class/power_supply/BAT1/cycle_count 2>/dev/null)
    hlth=$(python3 -c "print(f'{100*$ef/$efd:.1f}')" 2>/dev/null)
    info "健康度 ${hlth}%  循环 ${cc} 次"
    over=$(python3 -c "print(1 if $hlth < 80 else 0)")
    [ "$over" = "1" ] && warn "健康度已低于 80%，续航会明显缩水" \
                      || pass "电池健康度 ${hlth}%（≥80%）"
fi
ac=$(cat /sys/class/power_supply/ADP1/online 2>/dev/null)
st=$(cat /sys/class/power_supply/BAT1/status 2>/dev/null)
cap=$(cat /sys/class/power_supply/BAT1/capacity 2>/dev/null)
info "供电: AC=$([ "$ac" = "1" ] && echo 已插电 || echo 电池)  电池 $cap% $st"

# ── 8. 锁频监控统计 ────────────────────────────────────
head_ "8. 锁频监控统计（区分修复前后）"
LOG=/var/log/surface-throttle.log
if $SUDO test -r "$LOG" 2>/dev/null; then
    # 只统计【当前这次启动之后】的【真锁频】事件。
    #
    # 两个要点（都踩过坑）：
    #  1) 日志里留有修复安装前的历史记录，不能当成本次问题；
    #  2) 判据要用「核数占比」而非「平均频率」——旧版监控用平均频率，
    #     把 CPU 空闲时个别核心休眠（400MHz）误记成了锁频事件。
    #     新格式的事件行带「N/8 核低于 500MHz」，可据此识别真伪。
    boot_ts=$(date -d "$(uptime -s)" '+%s' 2>/dev/null || echo 0)
    info "日志: $LOG"
    info "本次启动: $(uptime -s)"

    since_boot=0        # 本次启动后的真锁频数
    total_real=0        # 历史真锁频总数
    total_false=0       # 旧判据误报数
    while IFS= read -r line; do
        ts=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}' | head -1)
        [ -z "$ts" ] && continue

        # 新格式：行内含「N/8 核低于」，据此精确判定
        c=$(echo "$line" | grep -oE '[0-9]+/8 核低于' | grep -oE '^[0-9]+')
        if [ -n "$c" ]; then
            [ "$c" -ge 6 ] || { total_false=$((total_false + 1)); continue; }
        else
            # 旧格式行没有核数信息，只能用平均频率粗判。
            # 实测区分度很好：真锁频时 8 核全被钉住 → 平均仅 200MHz；
            # 而空闲误报只有个别核休眠 → 平均 550MHz 以上。
            # 故用 450MHz 作分界（而不是 600MHz，那会把 550/594 的误报算进来）。
            f=$(echo "$line" | grep -oE '[0-9]+MHz' | head -1 | tr -d 'MHz')
            [ -z "$f" ] && continue
            [ "$f" -ge 450 ] && { total_false=$((total_false + 1)); continue; }
        fi

        total_real=$((total_real + 1))
        t=$(date -d "$ts" '+%s' 2>/dev/null || echo 0)
        [ "$t" -ge "$boot_ts" ] && since_boot=$((since_boot + 1))
    done < <($SUDO grep '锁频事件' "$LOG" 2>/dev/null)

    info "历史真锁频记录: ${total_real} 条$([ "$total_false" -gt 0 ] && echo "（另有 ${total_false} 条旧判据误报，已忽略）")"
    if [ "$total_real" -gt 0 ]; then
        # 只列出真锁频的行（平均 <450MHz，与上面的过滤口径一致）
        $SUDO grep '锁频事件' "$LOG" 2>/dev/null \
            | grep -E '平均频率 ([0-3][0-9]{2}|4[0-4][0-9])MHz' \
            | grep -oE '\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8}\].*' \
            | tail -4 | sed 's/^/        /'
        info "↑ 若时间早于本次修复安装，属历史记录，无需处理"
    fi

    if [ "$since_boot" -gt 0 ]; then
        warn "本次启动（$(uptime -s)）以来记录到 ${since_boot} 次真锁频"
        info "注意: 若你刚做过诱发实验，这些是预期结果，不是故障。"
        info "      判断是否真出问题，请看第 1 节(0x1FC) 与第 6 节(当前频率)。"
        info "      查看现场: sudo tail -80 $LOG"
    else
        pass "本次启动以来未记录到真锁频"
    fi

    last=$($SUDO grep -E '锁频事件|锁频解除' "$LOG" 2>/dev/null | tail -1)
    [ -n "$last" ] && info "最近一条: $last"
else
    warn "无法读取监控日志（服务可能尚未产生事件）"
fi

# ── 汇总 ───────────────────────────────────────────────
echo
echo "════════ 体检结论 ════════"
echo "  通过 ${G}${OK}${N} 项，异常 ${R}${BAD}${N} 项"
echo
if [ "$BAD" -eq 0 ]; then
    echo "  ${G}系统优化全部生效，未发现异常。${N}"
else
    echo "  ${R}发现 ${BAD} 项异常，请按上面的提示处理。${N}"
    echo "  如需进一步排查，请把以上输出附到本仓库的 Issue 中。"
fi
echo
echo "  参考文档: 本仓库的 docs/TROUBLESHOOTING.md"
echo "═══════════════════════════════════════════"

exit 0
