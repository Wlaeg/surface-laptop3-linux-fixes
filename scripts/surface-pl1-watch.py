#!/usr/bin/env python3
"""
监听 power-profiles-daemon 的预设切换，实时调整 RAPL PL1。

为什么需要它：systemd timer 每 3 分钟才轮询一次，用户切到
"性能"或"省电"后要等最多 3 分钟才生效。本守护进程监听
D-Bus 属性变化，切换即刻应用。

它只做一件事：预设一变就调用 surface-pl1-limit.sh（该脚本负责
决定具体瓦数并写两个 RAPL 域）。真正的功率逻辑集中在 shell 脚本里，
保持单一事实来源，便于用户查看和修改。

无 D-Bus 时（例如早期启动阶段）自动重连，不会退出。
"""

import subprocess
import sys
import time

import dbus
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BUS = "net.hadess.PowerProfiles"
PATH = "/net/hadess/PowerProfiles"
IFACE = "net.hadess.PowerProfiles"
APPLY = "/usr/local/bin/surface-pl1-limit.sh"


def apply_limit(*_args):
    """预设变化时应用对应的 PL1 限制。"""
    try:
        subprocess.run(
            [APPLY],
            check=False,
            timeout=30,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception as exc:  # noqa: BLE001 - 守护进程不应因单次失败退出
        print(f"apply failed: {exc}", file=sys.stderr, flush=True)
    return True


def main():
    DBusGMainLoop(set_as_default=True)

    # 启动时先按当前预设应用一次，避免开机到 ppd 就绪前的空窗
    apply_limit()

    while True:
        try:
            bus = dbus.SystemBus()
            bus.add_signal_receiver(
                apply_limit,
                dbus_interface="org.freedesktop.DBus.Properties",
                signal_name="PropertiesChanged",
                arg0=IFACE,
                path=PATH,
            )
            print("listening for profile changes", flush=True)
            GLib.MainLoop().run()
        except Exception as exc:  # noqa: BLE001
            print(f"dbus unavailable ({exc}), retrying in 5s", file=sys.stderr, flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
