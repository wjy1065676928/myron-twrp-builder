#!/bin/bash
# 在设备树 device.mk 里补充 vintf manifest fragment 的 copy 规则。
#
# 背景：servicemanager 在 recovery 模式下使用 VintfObjectRecovery，
# 只读 /system/etc/vintf/manifest.xml 并自动合并 /system/etc/vintf/manifest/*.xml。
# 设备树的 prebuilt/system/etc/vintf/manifest.xml 里没有 KeyMint / Weaver / Gatekeeper
# 声明，导致 vendor.keymint 注册失败（IKeyMintDevice/default not found in VINTF manifest）
# 并退出，keystore2 随之 panic 崩溃循环，odm.weaver_nxp 无法保持运行，
# 最终 metadata 解密失败。
#
# 做法：新增 fragment 文件并加一条 copy 规则到 recovery/root 下。

set -euo pipefail
DEVICE_MK="${1:?usage: patch_device_mk.sh <device.mk>}"

if grep -q 'android.hardware.security.keymint-qti.xml' "$DEVICE_MK"; then
  echo "[ok] manifest fragment copy rule already present"
  exit 0
fi

ANCHOR='    $(DEVICE_PATH)/prebuilt/system/etc/vintf/manifest.xml:recovery/root/system/etc/vintf/manifest.xml \'
if ! grep -qF "$ANCHOR" "$DEVICE_MK"; then
  echo "::error::anchor line not found in device.mk"
  exit 1
fi

python3 - "$DEVICE_MK" <<'PYEOF'
import io, sys
path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

anchor = "    $(DEVICE_PATH)/prebuilt/system/etc/vintf/manifest.xml:recovery/root/system/etc/vintf/manifest.xml \\\n"
add = (
    "    $(DEVICE_PATH)/prebuilt/system/etc/vintf/manifest/android.hardware.security.keymint-qti.xml:"
    "recovery/root/system/etc/vintf/manifest/android.hardware.security.keymint-qti.xml \\\n"
)
if anchor not in src:
    print("::error::anchor not found")
    sys.exit(1)
src = src.replace(anchor, anchor + add, 1)
io.open(path, "w", encoding="utf-8").write(src)
print("[fix] added vintf manifest fragment copy rule")
PYEOF

echo "--- 结果 ---"
grep -n -A2 'keymint-qti.xml' "$DEVICE_MK" | head -5
