#!/bin/bash
# 给 bootable/recovery 打 C++ 补丁（复刻 MissMyTime 的 MTP 复合模式方案）。
#
# 目标：让 MTP 与 ADB 在 USB 上并存。
#
# 背景（设备日志实测的多条失败链）：
#   TWRP 的 EnableMtp() 里直接 `setprop sys.usb.config mtp,adb`，
#   这会命中 init.recovery.usb.rc 的 mtp,adb 分支，而该分支「只拆不建」：
#     摘 UDC → rm f1/f2/f3（无 -f，撞 File exists）→ 等一个恒为 0 的
#     sys.usb.ffs.mtp.ready → UDC 永远绑不回 → adbd 端点被 shutdown，
#     报 FUNCTIONFS_BIND timeout 死循环 → ADB 永久失联。
#
# 修法（对照 MissMyTime 的 mtp_composite.patch + 其 partitionmanager.cpp 实现）：
#   1. 把 MTP 切换到 ForkServer **之后**做——那时 MTP 子进程已打开
#      /dev/usb-ffs/mtp/ep0，端点才 ready。
#   2. 切换前先等 ffs.mtp.ready=1（最多 5s），未就绪则同步 configfs 的 ready
#      文件到 prop；仍未就绪就拒绝切换、保住纯 adb。
#   3. setprop 改用 twrp_mtp_adb —— init.recovery.usb.rc 没有该 handler，
#      init 收到后不执行任何 USB 操作。
#   4. 自己按序重建：解绑 UDC → rm -f 强制清理 → ln -s 两个端点 → 绑 UDC。
#   5. 绑完验证 UDC 状态，失败则等 2.5s 重试一次；两次都失败回退纯 adb。
set -euo pipefail

SRC="${1:?usage: apply_mtp_composite.sh <recovery source root>}"
PATCH_DIR="${2:?usage: apply_mtp_composite.sh <src> <patch dir>}"

PM="$SRC/partitionmanager.cpp"
[ -f "$PM" ] || { echo "::error::partitionmanager.cpp not found in $SRC"; exit 1; }

MARKER="MYRON_MTP_COMPOSITE"
if grep -q "$MARKER" "$PM"; then
  echo "[ok] partitionmanager.cpp already patched"
  exit 0
fi

PATCH_FILE="$PATCH_DIR/0003-myron-mtp-composite.patch"
[ -f "$PATCH_FILE" ] || { echo "::error::patch not found: $PATCH_FILE"; exit 1; }

cd "$SRC"
if patch -p1 --dry-run < "$PATCH_FILE" >/dev/null 2>&1; then
  patch -p1 < "$PATCH_FILE"
  echo "[fix] partitionmanager.cpp: MTP+ADB composite mode applied"
else
  echo "::error::patch does not apply cleanly; upstream source changed"
  patch -p1 --dry-run < "$PATCH_FILE" || true
  exit 1
fi

echo "--- verify ---"
grep -n "$MARKER" "$PM" | head -3
grep -c "twrp_mtp_adb" "$PM"
