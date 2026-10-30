#!/bin/bash
# 修复 init.recovery.usb.rc 的 mtp,adb 分支：解密后 TWRP 切 MTP 会踢掉 ADB。
#
# 问题：
#   1) `on property:sys.usb.config=mtp,adb` 只做“拆除”——UDC 置 none、
#      删掉 f1/f2/f3、ffs.mtp.ready 置 0，然后 start adbd 就结束了。
#   2) 真正负责“重建 + 重新绑定 UDC”的是第 122 行那条 handler，
#      但它要求 `sys.usb.ffs.mtp.ready=1`。
#   3) 全系统没有任何进程会把 ffs.mtp.ready 置 1（镜像里没有 mtp 守护进程，
#      只有把该 prop 置 0 的地方）。
#   结论：重建 handler 永不触发 -> UDC 永远 none -> ADB 断开且不会自愈。
#
# 修法：
#   A. 去掉第 122 行对 ffs.mtp.ready 的依赖，只要 config=mtp,adb 且
#      ffs.ready=1 就重建（MTP 端点若未就绪，symlink 失败最多让 MTP 不可用，
#      但 adb 端点仍会绑上，ADB 不会丢）。
#   B. 追加一个兜底 service：切到 mtp,adb 后 8 秒内 UDC 仍未绑定，则强制
#      回退到纯 adb 配置，保证刷机时 ADB 始终可用。
set -euo pipefail

RC="${1:?usage: patch_usb_rc.sh <init.recovery.usb.rc>}"

if grep -q 'MYRON_MTP_ADB_FIX' "$RC"; then
  echo "[ok] usb rc already patched"
  exit 0
fi

python3 - "$RC" <<'PYEOF'
import io, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

# ---- A. 松开重建条件 ----
old = ("on property:sys.usb.ffs.ready=1 && property:sys.usb.ffs.mtp.ready=1 "
       "&& property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1\n")
new = ("# MYRON_MTP_ADB_FIX: 原条件要求 ffs.mtp.ready=1，但系统无进程置该值，\n"
       "# 导致 UDC 被置 none 后永不重建、ADB 断开。这里去掉该前置条件。\n"
       "on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb "
       "&& property:sys.usb.configfs=1\n")
if old not in src:
    print("::error::mtp,adb rebuild handler not found")
    sys.exit(1)
src = src.replace(old, new, 1)

# ---- B. 兜底 service 定义 + 触发 ----
guard = """
# MYRON_MTP_ADB_FIX: mtp,adb 若重建失败（MTP 端点未就绪），8 秒后强制回退纯 adb，
# 保证 ADB 始终可用。oneshot，失败也不影响其他服务。
service myron-mtp-adb-guard /system/bin/sh /system/bin/myron-mtp-adb-guard.sh
    class late_start
    user root
    group root
    disabled
    oneshot
    seclabel u:r:recovery:s0

on property:sys.usb.config=mtp,adb
    start myron-mtp-adb-guard
"""
src = src.rstrip("\n") + "\n" + guard

io.open(path, "w", encoding="utf-8").write(src)
print("[fix] usb rc: 松开 mtp,adb 重建条件 + 追加兜底 service")
PYEOF

echo "--- 校验 ---"
grep -n 'MYRON_MTP_ADB_FIX' "$RC" | head -5
sed -n "$(grep -n 'on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb' "$RC" | head -1 | cut -d: -f1),+2p" "$RC"
