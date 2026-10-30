#!/system/bin/sh
# MTP + ADB 双端点 USB 重建（复刻 MissMyTime 的实现）
#
# 为什么需要这个脚本：
#   标准 init.recovery.usb.rc 的 `mtp,adb` 分支是「只拆不建」——
#   它把 UDC 置 none、删掉 f1/f2/f3，然后指望一个要求
#   sys.usb.ffs.mtp.ready=1 的 handler 来重建。但镜像里没有独立 mtp 守护进程，
#   该 prop 永远为 0，于是 UDC 永远绑不回去，ADB 彻底失联。
#   init 的 rm 又没有 -f，会撞 File exists；write UDC 会撞 Device or resource busy。
#
# 复刻方案（实测来源：MissMyTime 的 recovery 二进制内嵌命令）：
#   1. setprop sys.usb.config twrp_mtp_adb   ← init 不认识这个名字，完全不插手
#   2. echo none > UDC                       ← 自己解绑
#   3. rm -f f1/f2/f3（必须 -f）             ← 自己清理，不撞 File exists
#   4. 写 configuration / idVendor / idProduct
#   5. ln -s 两个端点（ffs.mtp → f1, ffs.adb → f2）
#   6. echo $controller > UDC                ← 自己绑回去
#
# 用法：myron-usb-mtp.sh mtp   启用 MTP + ADB
#       myron-usb-mtp.sh adb   回退纯 ADB
set -u

LOG=/tmp/myron-usb-mtp.log
G1=/config/usb_gadget/g1
CFG=$G1/configs/b.1

log() { echo "$(date '+%H:%M:%S') $*" >> "$LOG"; }

ctrl() {
    c="$(getprop sys.usb.controller)"
    [ -n "$c" ] || c=a600000.dwc3
    echo "$c"
}

# 统一拆除：解绑 + 强制清理 + 清 configuration
teardown() {
    echo none > $G1/UDC 2>/dev/null || true
    # 给内核时间完成 unbind，否则下一步 rm/write 会撞 busy
    i=0
    while [ "$i" -lt 20 ]; do
        [ "$(cat /sys/class/udc/"$(ctrl)"/state 2>/dev/null)" = "not attached" ] && break
        sleep 0.05
        i=$((i + 1))
    done
    rm -f $CFG/function0 $CFG/function1 $CFG/f1 $CFG/f2 $CFG/f3
    rm -f $CFG/strings/0x409/configuration 2>/dev/null || true
}

bind() { echo "$(ctrl)" > $G1/UDC; }

case "${1:-}" in
mtp)
    log "=== MTP+ADB: start ==="
    # ① 关键：设一个 init 没有 handler 的配置名，让 init 完全不插手
    setprop sys.usb.config twrp_mtp_adb

    teardown

    # ② 配置标识
    echo mtp_adb > $CFG/strings/0x409/configuration
    echo 0x2717 > $G1/idVendor
    echo 0xFF48 > $G1/idProduct

    # ③ 两个端点：MTP 在前，ADB 在后（与官方 mtp_adb 布局一致）
    ln -s $G1/functions/ffs.mtp $CFG/f1
    ln -s $G1/functions/ffs.adb $CFG/f2

    # ④ 绑回 UDC
    if bind; then
        setprop sys.usb.state mtp,adb
        setprop twrp.usb.mtp_configured 1
        log "=== MTP+ADB: bound ==="
    else
        log "=== MTP+ADB: bind FAILED, fallback to adb ==="
        exec "$0" adb
    fi
    ;;

adb)
    log "=== ADB-only: start ==="
    setprop sys.usb.config twrp_adb_only 2>/dev/null || true

    teardown

    echo adb > $CFG/strings/0x409/configuration
    echo 0x18D1 > $G1/idVendor
    echo 0x4E11 > $G1/idProduct

    ln -s $G1/functions/ffs.adb $CFG/f1

    if bind; then
        setprop sys.usb.state adb
        setprop twrp.usb.mtp_configured 0
        log "=== ADB-only: bound ==="
    else
        log "=== ADB-only: bind FAILED ==="
    fi
    ;;

*)
    echo "usage: $0 {mtp|adb}" >&2
    exit 1
    ;;
esac
