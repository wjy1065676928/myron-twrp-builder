#!/bin/bash
# 修复 init.recovery.usb.rc 的 mtp,adb 分支：解密后开 MTP 会把 ADB 踢掉且不自愈。
#
# 根因（设备日志实测，非推测）：
#   `on property:sys.usb.config=mtp,adb` 只拆不建——UDC 置 none、rm f1/f2/f3，
#   然后指望一个要求 `ffs.mtp.ready=1` 的 handler 来重建。但镜像里没有独立
#   mtp 守护进程，该 prop 恒为 0，UDC 永远绑不回去。
#   即便 prop 就绪也不行：init 的 rm 无 -f（撞 `symlink() failed: File exists`），
#   write UDC 撞 `Device or resource busy`，adbd 报
#   `timed out while waiting for FUNCTIONFS_BIND` 死循环（errno 108）。
#
# 实测证据（/sdcard/logcat.txt）：
#   E recovery: Mtp got error event: Cannot send after transport endpoint shutdown
#   E MtpServer: request read returned -1, errno: 108
#   I adbd : UsbFfs: connection terminated: read 0 failed with error
#            Cannot send after transport endpoint shutdown
#   init  : symlink ... f1 failed: File exists
#   init  : write ... UDC failed: Device or resource busy
#
# 修法（复刻 MissMyTime 的方案）：
#   让 init 完全不插手 USB，交由脚本按正确时序重建。
#   脚本第一步 `setprop sys.usb.config twrp_mtp_adb`——一个 init 没有 handler
#   的配置名，init 收到后无匹配动作、什么都不做。然后脚本自己用 `rm -f`
#   强制清理、按序 ln -s 两个端点、最后自己绑 UDC。
set -euo pipefail

RC="${1:?usage: patch_usb_rc.sh <init.recovery.usb.rc>}"

if grep -q 'MYRON_USB_MTP_REBUILD' "$RC"; then
  echo "[ok] usb rc already patched"
  exit 0
fi

python3 - "$RC" <<'PYEOF'
import io, sys, re

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

# ---- 1. 把 mtp,adb 的“拆除”分支替换为 start 我们自己的服务 ----
m = re.search(
    r"on property:sys\.usb\.config=mtp,adb && property:sys\.usb\.configfs=1\n"
    r"((?:    .*\n)+)",
    src,
)
if not m:
    print("::error::mtp,adb teardown block not found")
    sys.exit(1)

new_block = (
    "# MYRON_USB_MTP_REBUILD: 原分支只拆不建，会让 UDC 永远绑不回、ADB 失联。\n"
    "# 改由 myron-usb-mtp.sh 按正确时序重建（复刻 MissMyTime 的方案）。\n"
    "on property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1\n"
    "    start myron-usb-mtp-rebuild\n"
)
src = src[:m.start()] + new_block + src[m.end():]

# ---- 2. 删掉依赖 ffs.mtp.ready 的旧重建 handler（已无意义，且会与脚本抢时序）----
m2 = re.search(
    r"on property:sys\.usb\.ffs\.ready=1 && (?:property:sys\.usb\.ffs\.mtp\.ready=1 && )?"
    r"property:sys\.usb\.config=mtp,adb && property:sys\.usb\.configfs=1\n"
    r"((?:    .*\n)+)",
    src,
)
if m2:
    src = src[:m2.start()] + (
        "# MYRON_USB_MTP_REBUILD: 原重建 handler 已移除——它依赖恒为 0 的\n"
        "# ffs.mtp.ready，且会与 myron-usb-mtp-rebuild 抢时序。\n"
    ) + src[m2.end():]
    print("[fix] removed ffs.mtp.ready rebuild handler")
else:
    print("[warn] rebuild handler not found (already absent?)")

# ---- 3. 追加 service 定义 ----
svc = """
# MYRON_USB_MTP_REBUILD: mtp,adb 的 USB 重建交给脚本，时序完全由脚本控制。
# oneshot，跑完即退；不依赖 ffs.mtp.ready（镜像里没有独立 mtp 守护进程）。
service myron-usb-mtp-rebuild /system/bin/sh /system/bin/myron-usb-mtp.sh
    class late_start
    user root
    group root
    disabled
    oneshot
    seclabel u:r:recovery:s0
"""
src = src.rstrip("\n") + "\n" + svc

io.open(path, "w", encoding="utf-8").write(src)
print("[fix] usb rc: mtp,adb 分支交由 myron-usb-mtp-rebuild 处理")
PYEOF

echo "--- 校验 ---"
grep -n 'MYRON_USB_MTP_REBUILD' "$RC" | head -6
echo "--- 新的 mtp,adb 分支 ---"
grep -n -A2 'on property:sys.usb.config=mtp,adb' "$RC" | head -6
