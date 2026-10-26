#!/bin/bash
# USB cellular modems (4G / LTE / 5G) for Black Box OS (docs/blackbox-supported-devices.md, "USB cellular modems").
# Part of build-in-container.sh, run as root in the builder container with the image's root filesystem mounted at $1,
# after usb-wifi.sh and usb-serial.sh. Kept apart from both on purpose: none touches another's files.
#
# Arduino's kernel (7.0.0-g122c2c22d838) already builds usbnet, cdc_ether, cdc_ncm, option, usb_wwan, usbserial and wwan
# as modules (read from the kernel's own configuration: CONFIG_USB_NET_CDCETHER=m, CONFIG_USB_NET_CDC_NCM=m,
# CONFIG_USB_SERIAL_OPTION=m, CONFIG_USB_SERIAL_WWAN=m), but not these, which most modems need:
#
#   cdc-wdm          CONFIG_USB_WDM            the control port (/dev/cdc-wdmN) of QMI and MBIM modems and Huawei NCM sticks
#   rndis_host       CONFIG_USB_NET_RNDIS_HOST "router" sticks that show up as an RNDIS network card (ZTE MF79, many
#                                              unbranded LTE sticks; also Android USB tethering)
#   qmi_wwan         CONFIG_USB_NET_QMI_WWAN   Qualcomm-based modems in QMI mode (Quectel EC25 / EG25 / RM500Q, Sierra
#                                              MC7455 / EM7455, SIMCom SIM7600, Huawei ME909s, ...)
#   cdc_mbim         CONFIG_USB_NET_CDC_MBIM   modems in MBIM mode (Sierra EM7455 in MBIM, Quectel RM500Q in MBIM, Fibocom)
#   huawei_cdc_ncm   CONFIG_USB_NET_HUAWEI_CDC_NCM  Huawei E3372s / E3276 "stick" firmware (NCM data + an AT port)
#
# The modems' serial ports: option (Quectel, SIMCom, Huawei, ZTE) is in the kernel; qcserial (CONFIG_USB_SERIAL_QUALCOMM,
# Sierra MC7455 / EM7455 and other Gobi modules) is built by usb-serial.sh with the other serial drivers, never here;
# this script checks that it is there.
#
# They are built as external modules from Arduino's own source at the kernel's exact commit, against the headers
# package of that kernel build, exactly as usb-wifi.sh builds the Wi-Fi drivers (same checks: vermagic, every symbol
# resolved against the kernel and the image's own modules, udev finds each driver by a modem's USB id). Installed to
# /lib/modules/<release>/updates/dashivo-cellular; depmod. No firmware: modems carry their own.
#
# Not built: ppp (CONFIG_PPP is off; PPP-only serial modems are not supported, every modem in the table has a network
# interface), sierra / sierra_net (pre-2012 Sierra 3G cards), sr_mod (a stick's virtual CD-ROM: usb_modeswitch talks to
# it over libusb and needs no CD driver).
#
# The programs come from Debian trixie (build-in-container.sh installs them, pinned, before this runs): ModemManager,
# qmicli / mbimcli, usb_modeswitch with its device data, the APN database. This checks they are there at the pinned
# version and unmodified (dpkg --verify), and writes what is in the image and under which licence to
# /usr/share/doc/dashivo-usb-cellular.
#
# Inputs (/work/usb-wifi, fetched and checked by build-image.sh): the headers .deb (shared with usb-wifi.sh) and
# linux-qcom-<commit>-cellular.tar (the five source files and the kernel's licence texts).
# Env: KERNEL_RELEASE KERNEL_SRC_COMMIT CELLULAR_PKGS ("name=version sha256 ..."; empty: the package checks are skipped,
# for a test build of the drivers alone against a copy of the image's /lib/modules).
set -euo pipefail
R=${1:?root filesystem}
: "${KERNEL_RELEASE:?}" "${KERNEL_SRC_COMMIT:?}"
KVER=$KERNEL_RELEASE
IN=${CELLULAR_IN:-/work/usb-wifi}
T=/build/usb-cellular
DEST=/lib/modules/$KVER/updates/dashivo-cellular
DOC=/usr/share/doc/dashivo-usb-cellular
MODULES="cdc-wdm rndis_host qmi_wwan cdc_mbim huawei_cdc_ncm"
die() { echo "usb-cellular: $*" >&2; exit 1; }

apt-get install -y -qq --no-install-recommends gcc make libc6-dev binutils kmod >/dev/null
[ -d "$R/lib/modules/$KVER/kernel" ] || die "the image has no kernel $KVER"
# the kernel's own modules ours link to (exported symbols) must be in the image
for m in drivers/net/usb/usbnet drivers/net/usb/cdc_ether drivers/net/usb/cdc_ncm drivers/usb/serial/usbserial \
         drivers/usb/serial/usb_wwan drivers/usb/serial/option; do
    [ -f "$R/lib/modules/$KVER/kernel/$m.ko" ] || die "the image's kernel lacks $m.ko"
done
[ -f "$R/lib/modules/$KVER/updates/dashivo-usb-serial/qcserial.ko" ] || die "usb-serial.sh didn't build qcserial (run it first)"
for m in $MODULES; do
    if find "$R/lib/modules/$KVER/kernel" -name "$m.ko" | grep -q .; then die "the image's kernel now builds $m itself: drop it here"; fi
done
VERMAGIC=$(modinfo -F vermagic "$R/lib/modules/$KVER/kernel/drivers/net/usb/usbnet.ko")
[ "$VERMAGIC" = "$KVER SMP preempt mod_unload aarch64" ] || die "unexpected vermagic of the image's usbnet: $VERMAGIC"

rm -rf "$T"; mkdir -p "$T/hdr" "$T/src" "$T/mod"

# --- headers: the kernel build's own package; the same checks as usb-wifi.sh ---------------------------------------
dpkg-deb -x "$IN/linux-headers-${KVER}_${KVER}-1_arm64.deb" "$T/hdr"
HDR=$T/hdr/usr/src/linux-headers-$KVER
[ "$(cat "$HDR/include/config/kernel.release")" = "$KVER" ] || die "headers are for $(cat "$HDR/include/config/kernel.release")"
HARMLESS='^CONFIG_CMA_SIZE_MBYTES='     # see usb-wifi.sh: read only by kernel/dma/contiguous.c, built into the kernel
cfg_diff=$(diff <(grep '^CONFIG_' "$HDR/include/config/auto.conf" | grep -Ev "$HARMLESS" | sort) \
    <(grep '^CONFIG_' "$R/boot/config-$KVER" | sed 's/^\([^=]*\)="\(.*\)"$/\1=\2/' | grep -Ev "$HARMLESS" | sort) || true)
[ -z "$cfg_diff" ] || die "the headers' configuration differs from the image's /boot/config-$KVER: $cfg_diff"
! grep -q '^CONFIG_MODVERSIONS=' "$HDR/include/config/auto.conf" || die "CONFIG_MODVERSIONS is on: symbol CRCs would have to match"
! grep -q '^CONFIG_MODULE_SIG=' "$HDR/include/config/auto.conf" || die "CONFIG_MODULE_SIG is on: modules would need Arduino's key"
for c in USB_USBNET USB_NET_CDCETHER USB_NET_CDC_NCM USB_SERIAL USB_SERIAL_WWAN; do
    grep -q "^CONFIG_$c=m" "$HDR/include/config/auto.conf" || die "CONFIG_$c is not a module any more"
done
for c in USB_WDM USB_NET_RNDIS_HOST USB_NET_QMI_WWAN USB_NET_CDC_MBIM USB_NET_HUAWEI_CDC_NCM; do
    ! grep -q "^CONFIG_$c=" "$HDR/include/config/auto.conf" || die "CONFIG_$c is set in the kernel now: drop it here"
done
want=$(sed -n 's/^CONFIG_CC_VERSION_TEXT=//p' "$HDR/include/config/auto.conf")
got=$(aarch64-linux-gnu-gcc --version | head -n 1)
echo "compiler: $got (kernel: $want)"
[ "${got##* }" = "${want##* }" ] || die "gcc ${got##* } differs from the kernel's ${want##* }"

# --- the five drivers, unmodified, from Arduino's tree at the kernel's commit, built in one folder -------------------
tar -xf "$IN/linux-qcom-$KERNEL_SRC_COMMIT-cellular.tar" -C "$T/src"
S=$T/src
cp "$S/drivers/usb/class/cdc-wdm.c" "$S/drivers/net/usb/rndis_host.c" "$S/drivers/net/usb/qmi_wwan.c" \
   "$S/drivers/net/usb/cdc_mbim.c" "$S/drivers/net/usb/huawei_cdc_ncm.c" "$T/mod/"
# Our own Kbuild names exactly these objects (an in-tree folder's Makefile would also rebuild what the kernel already has)
echo "obj-m := $(for m in $MODULES; do printf '%s.o ' "$m"; done)" > "$T/mod/Kbuild"
make -s -C "$HDR" ARCH=arm64 CC=aarch64-linux-gnu-gcc "-j$(nproc)" M="$T/mod" modules
rm -rf "${R:?}$DEST"; install -d -m 0755 "$R$DEST"
for m in $MODULES; do
    [ -f "$T/mod/$m.ko" ] || die "$m.ko was not built"
    install -m 0644 "$T/mod/$m.ko" "$R$DEST/$m.ko"
    aarch64-linux-gnu-strip --strip-debug "$R$DEST/$m.ko"
done
[ "$(find "$T/mod" -name '*.ko' | wc -l)" -eq "$(echo $MODULES | wc -w)" ] || die "built other modules than $MODULES"
depmod -b "$R" -a "$KVER"

# --- checks: vermagic, symbols, dependency chains, and udev's lookup of a modem's USB id -----------------------------
for m in $MODULES; do
    v=$(modinfo -F vermagic "$R$DEST/$m.ko")
    [ "$v" = "$VERMAGIC" ] || die "$m: vermagic '$v'"
    echo "vermagic ok: $m ($v)"
done
unresolved=$(depmod -b "$R" -n -e -F "$R/boot/System.map-$KVER" "$KVER" 2>&1 >/dev/null | grep -i 'unknown symbol' | grep dashivo-cellular || true)
[ -z "$unresolved" ] || die "unresolved symbols: $unresolved"
for m in qmi_wwan cdc_mbim huawei_cdc_ncm rndis_host; do
    modprobe -d "$R" -S "$KVER" --show-depends "$m" | sed "s#^#  $m: #; s#$R##; s#/lib/modules/$KVER/##"
done
# A USB id (and interface) per modem family, as the kernel reports it in MODALIAS: vendor, product, device class,
# interface class / subclass / protocol and number. Each must resolve to its driver (and only drivers the image has).
while read -r what alias want; do
    got=$(modprobe -d "$R" -S "$KVER" -R "$alias" 2>/dev/null | tr '\n' ' ')
    case " $got " in *" $want "*) echo "usb id ok: $what -> $want" ;; *) die "$what ($alias) resolves to '$got', not $want" ;; esac
done <<'EOF'
Quectel-EC25-QMI usb:v2C7Cp0125d0318dcEFdsc02dp01icFFiscFFipFFin04 qmi_wwan
Quectel-EC25-AT usb:v2C7Cp0125d0318dcEFdsc02dp01icFFisc00ip00in02 option
Quectel-EG25-QMI usb:v2C7Cp0195d0318dcEFdsc02dp01icFFiscFFipFFin04 qmi_wwan
Quectel-RM500Q-QMI usb:v2C7Cp0800d0414dcEFdsc02dp01icFFiscFFipFFin04 qmi_wwan
Sierra-MC7455-QMI usb:v1199p9071d0006dc00dsc00dp00icFFiscFFipFFin08 qmi_wwan
Sierra-MC7455-AT usb:v1199p9071d0006dc00dsc00dp00icFFiscFFipFFin03 qcserial
Sierra-EM7455-MBIM usb:v1199p9079d0006dcEFdsc02dp01ic02isc0Eip00in0C cdc_mbim
SIMCom-SIM7600-QMI usb:v1E0Ep9001d0318dcEFdsc02dp01icFFiscFFipFFin05 qmi_wwan
SIMCom-SIM7600-AT usb:v1E0Ep9001d0318dcEFdsc02dp01icFFisc00ip00in02 option
Huawei-E3372s-NCM usb:v12D1p1506d0102dc00dsc00dp00icFFisc02ip16in01 huawei_cdc_ncm
Huawei-E3372s-AT usb:v12D1p1506d0102dc00dsc00dp00icFFisc02ip12in00 option
Huawei-E3372h-HiLink-ECM usb:v12D1p14DCd0102dc00dsc00dp00ic02isc06ip00in00 cdc_ether
ZTE-MF79-RNDIS usb:v19D2p1405d0100dcEFdsc02dp01icE0isc01ip03in00 rndis_host
Generic-RNDIS usb:v05C6pF00Ed0100dcEFdsc02dp01icE0isc01ip03in00 rndis_host
Generic-NCM usb:v1782p4D10d0100dc00dsc00dp00ic02isc0Dip00in00 cdc_ncm
EOF

# --- the programs from Debian, at the pinned versions, unmodified ------------------------------------------------------
install -d -m 0755 "$R$DOC"
if [ -n "${CELLULAR_PKGS:-}" ]; then
    in_root() { chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C "$@"; }
    {
        echo "USB cellular programs in Black Box OS: Debian trixie packages, unmodified, run as separate programs (our"
        echo "code only talks to them over D-Bus and nmcli). Version, the SHA-256 of the .deb in Debian's signed index,"
        echo "and the licences their copyright file names (full texts: /usr/share/doc/<package>/copyright)."
        echo
    } > "$R$DOC/PACKAGES"
    set -- $CELLULAR_PKGS
    while [ $# -ge 2 ]; do
        pv=$1 sum=$2; shift 2
        p=${pv%%=*} v=${pv#*=}
        have=$(in_root dpkg-query -W -f='${Version}' "$p" 2>/dev/null || true)
        [ "$have" = "$v" ] || die "$p is ${have:-not installed}, pinned $v (build-image.sh CELLULAR_PKGS)"
        # the programs, libraries and udev rules must be the package's own (a changed conffile or doc is no matter)
        bad=$(in_root dpkg --verify "$p" 2>&1 | grep -E ' /usr/(s?bin|lib)/' || true)
        [ -z "$bad" ] || die "$p's files differ from the package: $bad"
        lic=$(sed -n 's/^License: *//p' "$R/usr/share/doc/$p/copyright" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//; s/,/, /g')
        printf '%s %s  sha256 %s  %s\n' "$p" "$v" "$sum" "${lic:-see copyright}" >> "$R$DOC/PACKAGES"
        echo "package ok: $p $v"
    done
    # usb_modeswitch (already used by usb-wifi.sh for Realtek's driver-disk sticks, found the same way) knows the
    # modem sticks in the table by their CD-ROM ids, and Debian's udev rule calls it for them (Huawei's by one generic
    # rule: vendor 12d1, a mass-storage interface 0, not an Android phone). Nothing of usb-modeswitch is changed here.
    [ -x "$R/usr/sbin/usb_modeswitch" ] || die "the image has no usb_modeswitch: modem sticks in CD-ROM mode would stay disks"
    for rd in "$R/usr/lib/udev/rules.d" "$R/lib/udev/rules.d"; do
        [ -f "$rd/40-usb_modeswitch.rules" ] && break
        rd=
    done
    [ -n "$rd" ] || die "usb-modeswitch-data's udev rule is missing"
    # listed once (tar | grep -q under pipefail fails on the SIGPIPE when grep stops early: the first image build, Oct 18)
    pack=$(tar -tzf "$R/usr/share/usb_modeswitch/configPack.tar.gz")
    for id in 12d1:1f01 19d2:1225 19d2:0166 05c6:f000 1e0e:f000; do
        v=${id%%:*} p=${id##*:}
        printf '%s\n' "$pack" | grep -q "^$id" || die "usb_modeswitch has no entry for $id"
        grep -Eqi "idVendor\}==\"$v\", ATTRS?\{(idProduct\}==\"$p\"|manufacturer\}!=\"Android\")" \
            "$rd/40-usb_modeswitch.rules" || die "no usb_modeswitch udev rule for $id"
        echo "usb_modeswitch ok: $id"
    done
    [ -s "$R/usr/share/mobile-broadband-provider-info/serviceproviders.xml" ] || die "the APN database is missing"
fi

# --- the GPL source of what we built, and a manifest ------------------------------------------------------------------
install -d -m 0755 "$R$DOC/kernel"
install -m 0644 "$S/COPYING" "$R$DOC/kernel/COPYING"
install -m 0644 "$S/LICENSES/preferred/GPL-2.0" "$R$DOC/kernel/GPL-2.0"
{
    echo "USB cellular drivers in Black Box OS: Linux kernel drivers, built unmodified as external modules."
    echo "Source: https://github.com/arduino/linux-qcom commit $KERNEL_SRC_COMMIT (Arduino's UNO Q kernel, the one this"
    echo "image runs): drivers/usb/class/cdc-wdm.c, drivers/net/usb/{rndis_host,qmi_wwan,cdc_mbim,huawei_cdc_ncm}.c."
    echo "Built against linux-headers-$KVER (apt-repo.arduino.cc) by blackbox/os/image/usb-cellular.sh (the modems'"
    echo "qcserial: /usr/share/doc/dashivo-usb-serial). Licence: GPL-2.0 (rndis_host: GPL-2.0-or-later); texts here."
    echo "Installed in $DEST:"
    for m in $MODULES; do
        echo "$m.ko  $(sha256sum "$R$DEST/$m.ko" | awk '{print $1}')  $(stat -c %s "$R$DEST/$m.ko") bytes"
    done
} > "$R$DOC/kernel/SOURCE"
chmod -R u=rwX,go=rX "$R$DOC"

mods_kb=$(du -sk "$R$DEST" | awk '{print $1}')
doc_kb=$(du -sk "$R$DOC" | awk '{print $1}')
echo "usb-cellular: $(echo $MODULES | wc -w) modules ${mods_kb} KB, licences ${doc_kb} KB"
rm -rf "$T"
