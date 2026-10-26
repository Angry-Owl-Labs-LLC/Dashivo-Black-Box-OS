#!/bin/bash
# USB serial bridges for USB GPS receivers on Black Box OS (docs/blackbox-supported-devices.md, "USB GPS receivers").
# Part of build-in-container.sh, run as root in the builder container with the image's root filesystem mounted at $1,
# right after usb-wifi.sh.
#
# Arduino's kernel (7.0.0-g122c2c22d838) builds the USB serial core and the bridges most GPS receivers and OBD adapters
# use as modules: usbserial, ftdi_sio (FTDI FT232R / FT-X), cp210x (Silicon Labs), cdc_acm (u-blox's own USB, Arduino
# boards, ...). It does NOT build the two cheapest bridges:
#
#   pl2303   Prolific PL2303 (GlobalSat BU-353S4 and most GPS mice and serial cables of that kind)
#   ch341    WCH CH340 / CH341 (the small GPS modules on a CH340 board, Arduino clones)
#   qcserial Qualcomm "Gobi" modem serial ports (AT, NMEA, diagnostics) of USB cellular modems: Sierra MC7455 / EM7455
#            and other Gobi modules (option and usb_wwan, for Quectel / SIMCom / Huawei / ZTE, are in Arduino's kernel).
#            For usb-cellular.sh (docs/blackbox-supported-devices.md "USB cellular modems"): built here with the other
#            serial drivers, never twice; it links to the image's usb_wwan too.
#
# This builds just those two as external modules, exactly the way usb-wifi.sh builds the Wi-Fi drivers: from Arduino's own
# kernel source at the kernel's exact commit, against the headers package of the same kernel build, with trixie's gcc
# 14.2.0, so the vermagic and every structure match (the kernel has no CONFIG_MODVERSIONS and no module signing: the
# vermagic string is the whole check). They link to the image's own usbserial module. Both are Linux kernel drivers
# (GPL-2.0, unmodified, not our code); the licence texts and the source offer go to /usr/share/doc/dashivo-usb-serial.
#
# Installed to /lib/modules/<release>/updates/dashivo-usb-serial, then depmod: udev loads a driver by its USB id the
# moment a receiver is plugged in, like every other driver in the image.
#
# Inputs (/work/usb-wifi, fetched by build-image.sh): the headers .deb (the Wi-Fi build's) and the driver source tar.
# Env: KERNEL_RELEASE KERNEL_SRC_COMMIT.
set -euo pipefail
R=${1:?root filesystem}
: "${KERNEL_RELEASE:?}" "${KERNEL_SRC_COMMIT:?}"
KVER=$KERNEL_RELEASE
IN=/work/usb-wifi
T=/build/usb-serial
DEST=/lib/modules/$KVER/updates/dashivo-usb-serial
DOC=/usr/share/doc/dashivo-usb-serial
in_root() { chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C "$@"; }
die() { echo "usb-serial: $*" >&2; exit 1; }
MODULES="ch341 pl2303 qcserial"

[ -d "$R/lib/modules/$KVER/kernel" ] || die "the image has no kernel $KVER"
[ "$(ls "$R/lib/modules")" = "$KVER" ] || die "the image has more than one kernel: $(ls "$R/lib/modules" | tr '\n' ' ')"
VERMAGIC=$(in_root modinfo -F vermagic "/lib/modules/$KVER/kernel/drivers/usb/serial/usbserial.ko")
[ "$VERMAGIC" = "$KVER SMP preempt mod_unload aarch64" ] || die "unexpected vermagic of the image's usbserial: $VERMAGIC"

# --- what Arduino's kernel already has, and what it hasn't ---------------------------------------------------------------
CFG=$R/boot/config-$KVER
for opt in USB_SERIAL USB_SERIAL_FTDI_SIO USB_SERIAL_CP210X USB_ACM USB_SERIAL_WWAN USB_SERIAL_OPTION; do
    [ "$(sed -n "s/^CONFIG_$opt=//p" "$CFG")" = m ] || die "CONFIG_$opt is no longer a module in the image's kernel: $(grep "CONFIG_$opt[= ]" "$CFG")"
done
for m in usbserial ftdi_sio cp210x cdc_acm usb_wwan option; do
    f=$(in_root modinfo -k "$KVER" -F filename "$m") || die "the image has no $m module"
    echo "kernel module present: $m ($f)"
done
for opt in USB_SERIAL_CH341 USB_SERIAL_PL2303 USB_SERIAL_QUALCOMM; do
    ! grep -q "^CONFIG_$opt=" "$CFG" || die "Arduino's kernel now builds CONFIG_$opt: this script is not needed any more"
done
for m in $MODULES; do
    ! in_root modinfo -k "$KVER" "$m" >/dev/null 2>&1 || die "the image already has a $m module"
done

apt-get install -y -qq --no-install-recommends gcc make libc6-dev binutils >/dev/null
rm -rf "$T"; mkdir -p "$T/hdr" "$T/src" "$T/build"

# --- headers: the kernel build's own package; its configuration must be the image's /boot/config ------------------------
dpkg-deb -x "$IN/linux-headers-${KVER}_${KVER}-1_arm64.deb" "$T/hdr"
HDR=$T/hdr/usr/src/linux-headers-$KVER
[ "$(cat "$HDR/include/config/kernel.release")" = "$KVER" ] || die "headers are for $(cat "$HDR/include/config/kernel.release")"
# The same single, harmless difference usb-wifi.sh allows (CONFIG_CMA_SIZE_MBYTES: read only inside the kernel itself).
HARMLESS='^CONFIG_CMA_SIZE_MBYTES='
cfg_diff=$(diff <(grep '^CONFIG_' "$HDR/include/config/auto.conf" | grep -Ev "$HARMLESS" | sort) \
    <(grep '^CONFIG_' "$CFG" | sed 's/^\([^=]*\)="\(.*\)"$/\1=\2/' | grep -Ev "$HARMLESS" | sort) || true)
[ -z "$cfg_diff" ] || die "the headers' configuration differs from the image's /boot/config-$KVER: $cfg_diff"
! grep -q '^CONFIG_MODVERSIONS=' "$HDR/include/config/auto.conf" || die "CONFIG_MODVERSIONS is on: symbol CRCs would have to match"
! grep -q '^CONFIG_MODULE_SIG=' "$HDR/include/config/auto.conf" || die "CONFIG_MODULE_SIG is on: modules would need Arduino's key"
want=$(sed -n 's/^CONFIG_CC_VERSION_TEXT=//p' "$HDR/include/config/auto.conf")
got=$(aarch64-linux-gnu-gcc --version | head -n 1)
echo "compiler: $got (kernel: $want)"
[ "${got##* }" = "${want##* }" ] || die "gcc ${got##* } differs from the kernel's ${want##* }"
grep -q 'usb_serial_register_drivers' "$HDR/Module.symvers" || die "the headers' Module.symvers has no usbserial symbols"

# --- driver source: Arduino's tree at the kernel's commit (the three files build-image.sh fetched) ---------------------
tar -xf "$IN/linux-qcom-$KERNEL_SRC_COMMIT-usbserial.tar" -C "$T/src"
for f in ch341.c pl2303.c pl2303.h qcserial.c usb-wwan.h; do
    install -m 0644 "$T/src/drivers/usb/serial/$f" "$T/build/$f"
    grep -q 'SPDX-License-Identifier: GPL-2.0' "$T/build/$f" || die "$f: not GPL-2.0 (SPDX line missing)"
done
printf 'obj-m += ch341.o pl2303.o qcserial.o\n' > "$T/build/Makefile"     # nothing of the kernel's own serial Makefile: just these
make -s -C "$HDR" ARCH=arm64 CC=aarch64-linux-gnu-gcc "-j$(nproc)" M="$T/build" modules
# modpost stops the build on an undefined symbol; the headers' Module.symvers is where usbserial's come from

rm -rf "${R:?}$DEST"; install -d -m 0755 "$R$DEST"
for m in $MODULES; do
    [ -f "$T/build/$m.ko" ] || die "$m.ko was not built"
    install -m 0644 "$T/build/$m.ko" "$R$DEST/$m.ko"
    aarch64-linux-gnu-strip --strip-debug "$R$DEST/$m.ko"
done
[ "$(find "$T/build" -name '*.ko' | wc -l)" -eq "$(echo $MODULES | wc -w)" ] || die "built more or fewer modules than $MODULES"
in_root depmod -a "$KVER"

# --- checks: vermagic, GPL, the chain, and udev's USB-id lookup ------------------------------------------------------------
for m in $MODULES; do
    v=$(in_root modinfo -F vermagic "$DEST/$m.ko")
    [ "$v" = "$VERMAGIC" ] || die "$m: vermagic '$v'"
    [ "$(in_root modinfo -F license "$DEST/$m.ko")" = "GPL v2" ] || die "$m: licence '$(in_root modinfo -F license "$DEST/$m.ko")'"
    deps=usbserial; [ "$m" = qcserial ] && deps=usb_wwan,usbserial     # qcserial: the modem serial core too
    [ "$(in_root modinfo -F depends "$DEST/$m.ko" | tr ',' '\n' | sort | paste -sd, -)" = "$deps" ] || die "$m: depends on '$(in_root modinfo -F depends "$DEST/$m.ko")'"
    echo "vermagic ok: $m ($v), $(in_root modinfo -F alias "$DEST/$m.ko" | wc -l) USB ids"
done
unresolved=$(in_root depmod -n -e -F "/boot/System.map-$KVER" "$KVER" 2>&1 >/dev/null | grep -i 'unknown symbol' | grep dashivo-usb-serial || true)
[ -z "$unresolved" ] || die "unresolved symbols: $unresolved"
for m in ch341 pl2303 qcserial; do
    in_root modprobe -S "$KVER" --show-depends "$m" | sed "s#^#  $m: #; s#/lib/modules/$KVER/##"
done
# A USB id per bridge, as the kernel reports it in MODALIAS (vendor, product, version, device class..., interface...).
# The first four are the ones this script adds; the rest are the image's own drivers (they must still answer).
while read -r name modalias want; do
    got=$(in_root modprobe -S "$KVER" -R "$modalias" 2>/dev/null | tr '\n' ' ')
    case " $got " in *" $want "*) echo "usb id ok: $name -> $want" ;; *) die "$name resolves to '$got', not $want" ;; esac
done <<'EOF'
CH340 usb:v1A86p7523d0254dcFFdsc00dp00icFFisc01ip02in00 ch341
CH341A usb:v1A86p5523d0304dcFFdsc00dp00icFFisc01ip02in00 ch341
PL2303(BU-353S4) usb:v067Bp2303d0400dc00dsc00dp00ic00isc00ip00in00 pl2303
PL2303(BU-353) usb:v067BpAAA0d0300dc00dsc00dp00ic00isc00ip00in00 pl2303
Sierra-MC7455-AT usb:v1199p9071d0006dc00dsc00dp00icFFiscFFipFFin03 qcserial
Quectel-EC25-AT usb:v2C7Cp0125d0318dcEFdsc02dp01icFFisc00ip00in02 option
FTDI(FT232R) usb:v0403p6001d0600dc00dsc00dp00icFFiscFFipFFin00 ftdi_sio
FTDI(FT-X) usb:v0403p6015d1000dc00dsc00dp00icFFiscFFipFFin00 ftdi_sio
CP210x usb:v10C4pEA60d0100dc00dsc00dp00icFFiscFFipFFin00 cp210x
u-blox(CDC-ACM) usb:v1546p01A7d0100dc02dsc00dp00ic02isc02ip00in00 cdc_acm
u-blox(CDC-ACM,AT) usb:v1546p01A8d0100dc02dsc00dp00ic02isc02ip01in00 cdc_acm
EOF

# --- the GPL source offer ------------------------------------------------------------------------------------------------
install -d -m 0755 "$R$DOC"
for f in COPYING LICENSES/preferred/GPL-2.0; do
    install -m 0644 "$T/src/$f" "$R$DOC/$(basename "$f")"
done
{
    echo "USB serial drivers in Black Box OS: Linux kernel drivers (GPL-2.0), built unmodified as external modules."
    echo "Source: https://github.com/arduino/linux-qcom commit $KERNEL_SRC_COMMIT (Arduino's UNO Q kernel, the one this"
    echo "image runs), files drivers/usb/serial/ch341.c, pl2303.c, pl2303.h, qcserial.c and usb-wwan.h. Built against linux-headers-$KVER"
    echo "(apt-repo.arduino.cc) by blackbox/os/image/usb-serial.sh. They load on top of the kernel's own usbserial module."
    echo "Licence: GPL-2.0 (COPYING and GPL-2.0 in this folder). Installed in $DEST:"
    for m in $MODULES; do
        echo "$m.ko  $(sha256sum "$R$DEST/$m.ko" | awk '{print $1}')  $(stat -c %s "$R$DEST/$m.ko") bytes"
    done
    echo "Source files:"
    for f in ch341.c pl2303.c pl2303.h qcserial.c usb-wwan.h; do
        echo "drivers/usb/serial/$f  $(sha256sum "$T/src/drivers/usb/serial/$f" | awk '{print $1}')"
    done
} > "$R$DOC/SOURCE"
chmod -R u=rwX,go=rX "$R$DOC"

mods_kb=$(du -sk "$R$DEST" | awk '{print $1}')
echo "usb-serial: $(echo $MODULES | wc -w) modules ${mods_kb} KB, licences and source list $(du -sk "$R$DOC" | awk '{print $1}') KB"
rm -rf "$T"
