#!/system/bin/sh
# mtp,adb 兜底：TWRP 解密后切 MTP 时，若 USB gadget 未能在 8 秒内重新绑定，
# 强制回退到纯 adb 配置，保证刷机时 ADB 始终可用。
# 由 init.recovery.usb.rc 里的 myron-mtp-adb-guard service 触发（oneshot）。

UDC=/config/usb_gadget/g1/UDC
GUARD=/tmp/myron-mtp-adb-guard.log
CTRL="$(getprop sys.usb.controller)"
[ -n "$CTRL" ] || CTRL=a600000.dwc3

log_line() {
    echo "$(date '+%H:%M:%S') $*" >> "$GUARD"
}

udc_state() {
    cat "/sys/class/udc/$CTRL/state" 2>/dev/null || echo unknown
}

# 最多等 8 秒，看 UDC 是否被重新绑定
i=0
while [ "$i" -lt 80 ]; do
    udc="$(cat "$UDC" 2>/dev/null)"
    state="$(udc_state)"
    if [ -n "$udc" ] && [ "$udc" != none ] && [ "$state" = configured ]; then
        log_line "mtp,adb ok (state=$state)"
        exit 0
    fi
    # MTP 端点就绪但 prop 还没置位时，帮着置一下
    if [ "$(cat /config/usb_gadget/g1/functions/ffs.mtp/ready 2>/dev/null)" = "1" ] &&
       [ "$(getprop sys.usb.ffs.mtp.ready)" != "1" ]; then
        setprop sys.usb.ffs.mtp.ready 1
        log_line "set ffs.mtp.ready=1"
    fi
    sleep 0.1
    i=$((i + 1))
done

# 兜底：回退纯 adb
log_line "mtp,adb failed (udc=$(cat "$UDC" 2>/dev/null) state=$(udc_state)), fallback to adb"
setprop sys.usb.ffs.mtp.ready 0
setprop sys.usb.config adb
sleep 1
log_line "after fallback: config=$(getprop sys.usb.config) state=$(udc_state)"
exit 0
