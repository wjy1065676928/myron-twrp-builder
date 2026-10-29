#!/bin/bash
# 修正 recovery 的 prop.default 版本属性，让 KeyMint 认作「与设备同代、无需升级密钥」。
#
# 背景：
# 设备树 BoardConfig.mk 里写了
#   BOARD_RECOVERY_BUILD_PROP_VERSION_RELEASE := 99.87.36
#   BOARD_RECOVERY_BUILD_PROP_SECURITY_PATCH := 2099-12-31
# 但这两个变量只存在于 MissMyTime 自建的 build 里，TWRP-Test 的 build（AOSP 上游同样）
# 没有任何实现，因此设置被静默忽略，prop.default 落成：
#   ro.build.version.release=14        （PLATFORM_VERSION_LAST_STABLE）
#   ro.build.version.sdk=34            （ap2a release 的 SDK）
#   ro.build.version.security_patch=2024-09-05
# 而设备实际跑 Android 17。KeyMint 看到补丁级别远低于设备，会请求把已有 key blob
# 升级到新版本；recovery 拒绝持久化升级（会破坏回滚保护），于是 FBE 解密失败。
#
# 做法：在 core/Makefile 里 prop.default 的生成规则末尾追加 sed 后处理，
# 把 release 改成 99.87.36（无效版本号，防止 KeyMint 做版本比较），
# security_patch 改成 2099-12-31（远未来，确保不发生升级请求）。

set -euo pipefail
SRC="${1:?usage: patch_prop_versions.sh <src_root>}"
MK="$SRC/build/make/core/Makefile"

if [ ! -f "$MK" ]; then
  echo "::error::core/Makefile not found at $MK"
  exit 1
fi

if grep -q 'MYRON_PROP_PATCH' "$MK"; then
  echo "[ok] prop.default version patch already present"
  exit 0
fi

python3 - "$MK" <<'PYEOF'
import io, sys

path = sys.argv[1]
src = io.open(path, encoding="utf-8").read()

anchor = "\t$(call append-recovery-ui-properties,$(PRIVATE_RECOVERY_UI_PROPERTIES),$@)\n"
if anchor not in src:
    print("::error::prop.default generation rule not found")
    sys.exit(1)

rules = [
    (r"ro\.build\.version\.release=", "ro.build.version.release=99.87.36"),
    (r"ro\.build\.version\.release_or_codename=", "ro.build.version.release_or_codename=99.87.36"),
    (r"ro\.build\.version\.release_or_preview_display=", "ro.build.version.release_or_preview_display=99.87.36"),
    (r"ro\.build\.version\.security_patch=", "ro.build.version.security_patch=2099-12-31"),
]
# 分区级属性：ro.<part>.build.version.release / .security_patch
parts = ["system", "vendor", "odm", "product", "system_ext"]

sed_exprs = []
for pat, repl in rules:
    sed_exprs.append('s/^%s.*/%s/' % (pat, repl))
for part in parts:
    sed_exprs.append('s/^ro\\.%s\\.build\\.version\\.release=.*/ro.%s.build.version.release=99.87.36/' % (part, part))
    sed_exprs.append('s/^ro\\.%s\\.build\\.version\\.release_or_codename=.*/ro.%s.build.version.release_or_codename=99.87.36/' % (part, part))
for part in parts:
    sed_exprs.append('s/^ro\\.%s\\.build\\.security_patch=.*/ro.%s.build.security_patch=2099-12-31/' % (part, part))

# SDK 版本：设备树按 AOSP16 编，ap2a release 落到 34；第三方镜像为 36。
# KeyMint 会比对 sdk 与 key blob 的版本，偏低同样触发升级请求。
for part in ["build"] + parts:
    if part == "build":
        sed_exprs.append('s/^ro\\.build\\.version\\.sdk=.*/ro.build.version.sdk=36/')
        sed_exprs.append('s/^ro\\.build\\.version\\.sdk_full=.*/ro.build.version.sdk_full=36.0/')
    else:
        sed_exprs.append('s/^ro\\.%s\\.build\\.version\\.sdk=.*/ro.%s.build.version.sdk=36/' % (part, part))
        sed_exprs.append('s/^ro\\.%s\\.build\\.version\\.sdk_full=.*/ro.%s.build.version.sdk_full=36.0/' % (part, part))

sed_cmd = "\\\n\t  -e ".join(sed_exprs)
inject = "\t$(hide) sed -i -e %s $@ # MYRON_PROP_PATCH\n" % sed_cmd

src = src.replace(anchor, anchor + inject, 1)
io.open(path, "w", encoding="utf-8").write(src)
print("[fix] injected prop.default version override (%d rules)" % len(sed_exprs))
PYEOF

echo "--- 注入结果 ---"
grep -n 'MYRON_PROP_PATCH' "$MK" | head -3
sed -n "$(grep -n 'MYRON_PROP_PATCH' "$MK" | head -1 | cut -d: -f1),+2p" "$MK" | cut -c1-160
