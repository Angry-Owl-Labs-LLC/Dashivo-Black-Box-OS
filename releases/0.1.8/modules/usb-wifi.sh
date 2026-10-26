#!/bin/bash
# USB Wi-Fi adapters for Black Box OS (docs/blackbox-supported-devices.md, "USB Wi-Fi adapters"). Part of
# build-in-container.sh, run as root in the builder container with the image's root filesystem mounted at $1.
#
# Arduino's kernel (7.0.0-g122c2c22d838) has almost no USB Wi-Fi drivers: of mt76 it builds only the PCIe MT7921E and
# its libraries, and no rtw88, rtw89 or rtl8xxxu at all. This builds the USB ones as external modules from Arduino's own
# source at the kernel's exact commit, against the headers package of the same kernel build, so vermagic and every
# structure match. The kernel has no CONFIG_MODVERSIONS and no module signing: the vermagic string is the whole check.
#
#   mt76 USB parts   mt76-usb, mt76x02-lib, mt76x02-usb, mt76x0-common, mt76x0u (MT7610U), mt76x2-common, mt76x2u
#                    (MT7612U), mt792x-usb, mt7921u (MT7921AU), mt7925-common, mt7925u (MT7925 USB, Wi-Fi 7). They use
#                    Arduino's own mt76, mt76-connac-lib, mt792x-lib and mt7921-common (same source, same config:
#                    nothing in them depends on the USB options). MT7922 has no USB part (mt7921u knows only 7961 ids).
#   mt7601u          MT7601U
#   rtw88 USB        rtw88_core, rtw88_usb, rtw88_8822b(u) (RTL8812BU/8822BU), rtw88_8821c(u) (RTL8811CU/8821CU),
#                    rtw88_88xxa, rtw88_8812a(u), rtw88_8821a(u) (RTL8812AU/8811AU/8821AU)
#   rtw89 USB        rtw89_core, rtw89_usb, rtw89_8851b(u) (RTL8851BU / RTL8831BU), rtw89_8852a(u) (RTL8852AU /
#                    RTL8832AU), rtw89_8852b_common, rtw89_8852b(u) (RTL8852BU / RTL8832BU), rtw89_8852c(u) (RTL8852CU /
#                    RTL8832CU): the Realtek "AX" sticks. No rtw89_pci: the chip modules never call it.
#   rtl8xxxu         RTL8188EU/FU/GU, RTL8192EU/FU, RTL8723BU, RTL8710BU (the 2.4 GHz "N150/N300" sticks)
#
# Installed to /lib/modules/<release>/updates/dashivo-wifi, then depmod: udev loads a driver by its USB id the moment
# an adapter is plugged in. The firmware files the modules ask for (their MODULE_FIRMWARE list, nothing else) come
# from Debian's firmware packages; their licence texts go to /usr/share/doc/dashivo-usb-wifi.
#
# Inputs (/work/usb-wifi, fetched and checked by build-image.sh): the headers .deb, the three firmware .debs, the
# driver source tar. Env: KERNEL_RELEASE KERNEL_SRC_COMMIT.
set -euo pipefail
R=${1:?root filesystem}
: "${KERNEL_RELEASE:?}" "${KERNEL_SRC_COMMIT:?}"
KVER=$KERNEL_RELEASE
IN=/work/usb-wifi
T=/build/usb-wifi
DEST=/lib/modules/$KVER/updates/dashivo-wifi
DOC=/usr/share/doc/dashivo-usb-wifi
in_root() { chroot "$R" /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin LC_ALL=C "$@"; }
die() { echo "usb-wifi: $*" >&2; exit 1; }

[ -d "$R/lib/modules/$KVER/kernel" ] || die "the image has no kernel $KVER"
[ "$(ls "$R/lib/modules")" = "$KVER" ] || die "the image has more than one kernel: $(ls "$R/lib/modules" | tr '\n' ' ')"
VERMAGIC=$(in_root modinfo -F vermagic "/lib/modules/$KVER/kernel/drivers/net/wireless/mediatek/mt76/mt76.ko")
[ "$VERMAGIC" = "$KVER SMP preempt mod_unload aarch64" ] || die "unexpected vermagic of the image's mt76: $VERMAGIC"

apt-get install -y -qq --no-install-recommends gcc make libc6-dev binutils >/dev/null
rm -rf "$T"; mkdir -p "$T/hdr" "$T/src" "$T/fw"

# --- headers: the kernel build's own package; its configuration must be the image's /boot/config -------------------
dpkg-deb -x "$IN/linux-headers-${KVER}_${KVER}-1_arm64.deb" "$T/hdr"
HDR=$T/hdr/usr/src/linux-headers-$KVER
[ "$(cat "$HDR/include/config/kernel.release")" = "$KVER" ] || die "headers are for $(cat "$HDR/include/config/kernel.release")"
# Arduino's headers package comes from an earlier run of the same build (May 8 2026; the kernel May 19): the same commit
# and configuration but for one value, CONFIG_CMA_SIZE_MBYTES (32 there, 256 in the kernel). It is read only by
# kernel/dma/contiguous.c, built into the kernel (the boot-time CMA reservation), never by a module or a header. Any
# other difference stops the build.
HARMLESS='^CONFIG_CMA_SIZE_MBYTES='
cfg_diff=$(diff <(grep '^CONFIG_' "$HDR/include/config/auto.conf" | grep -Ev "$HARMLESS" | sort) \
    <(grep '^CONFIG_' "$R/boot/config-$KVER" | sed 's/^\([^=]*\)="\(.*\)"$/\1=\2/' | grep -Ev "$HARMLESS" | sort) || true)
[ -z "$cfg_diff" ] || die "the headers' configuration differs from the image's /boot/config-$KVER: $cfg_diff"
! grep -q '^CONFIG_MODVERSIONS=' "$HDR/include/config/auto.conf" || die "CONFIG_MODVERSIONS is on: symbol CRCs would have to match"
! grep -q '^CONFIG_MODULE_SIG=' "$HDR/include/config/auto.conf" || die "CONFIG_MODULE_SIG is on: modules would need Arduino's key"
# The kernel was built with Debian's gcc 14.2.0-19 (a cross compiler); trixie's native one prints the same banner.
want=$(sed -n 's/^CONFIG_CC_VERSION_TEXT=//p' "$HDR/include/config/auto.conf")
got=$(aarch64-linux-gnu-gcc --version | head -n 1)
echo "compiler: $got (kernel: $want)"
[ "${got##* }" = "${want##* }" ] || die "gcc ${got##* } differs from the kernel's ${want##* }"

# --- driver source: Arduino's tree at the kernel's commit (the folders build-image.sh fetched) ------------------------
tar -xf "$IN/linux-qcom-$KERNEL_SRC_COMMIT-wifi.tar" -C "$T/src"
W=$T/src/drivers/net/wireless
KMAKE=(make -s -C "$HDR" ARCH=arm64 CC=aarch64-linux-gnu-gcc "-j$(nproc)")
# mt76: only the USB parts. The core modules Arduino already builds (mt76, mt76-connac-lib, mt792x-lib,
# mt7921-common) are switched off here: a second copy exporting the same symbols is an error in modpost, and the
# image's own ones are used at run time.
MT76_OFF=(CONFIG_MT76_CORE= CONFIG_MT76_CONNAC_LIB= CONFIG_MT792x_LIB= CONFIG_MT7921_COMMON= CONFIG_MT7921E=)
"${KMAKE[@]}" M="$W/mediatek/mt76" "${MT76_OFF[@]}" \
    CONFIG_MT76_USB=m CONFIG_MT76x02_LIB=m CONFIG_MT76x02_USB=m CONFIG_MT76x0_COMMON=m CONFIG_MT76x0U=m \
    CONFIG_MT76x2_COMMON=m CONFIG_MT76x2U=m CONFIG_MT792x_USB=m CONFIG_MT7925_COMMON=m CONFIG_MT7925U=m modules
"${KMAKE[@]}" M="$W/mediatek/mt76/mt7921" "${MT76_OFF[@]}" CONFIG_MT7921U=m \
    KBUILD_EXTRA_SYMBOLS="$W/mediatek/mt76/Module.symvers" modules
"${KMAKE[@]}" M="$W/mediatek/mt7601u" CONFIG_MT7601U=m modules
"${KMAKE[@]}" M="$W/realtek/rtw88" CONFIG_RTW88_CORE=m CONFIG_RTW88_USB=m \
    CONFIG_RTW88_8822B=m CONFIG_RTW88_8822BU=m CONFIG_RTW88_8821C=m CONFIG_RTW88_8821CU=m \
    CONFIG_RTW88_88XXA=m CONFIG_RTW88_8812A=m CONFIG_RTW88_8812AU=m CONFIG_RTW88_8821A=m CONFIG_RTW88_8821AU=m modules
# rtw89: the USB chips only (the kernel at this commit has USB parts for 8851B, 8852A, 8852B and 8852C; 8852BT and
# 8922A are PCIe only). Debug messages and debugfs stay off, as in Arduino's other Realtek drivers.
"${KMAKE[@]}" M="$W/realtek/rtw89" CONFIG_RTW89_CORE=m CONFIG_RTW89_USB=m \
    CONFIG_RTW89_8851B=m CONFIG_RTW89_8851BU=m CONFIG_RTW89_8852A=m CONFIG_RTW89_8852AU=m \
    CONFIG_RTW89_8852B_COMMON=m CONFIG_RTW89_8852B=m CONFIG_RTW89_8852BU=m CONFIG_RTW89_8852C=m CONFIG_RTW89_8852CU=m modules
"${KMAKE[@]}" M="$W/realtek/rtl8xxxu" CONFIG_RTL8XXXU=m modules

MODULES="mt76-usb mt76x02-lib mt76x02-usb mt76x0-common mt76x0u mt76x2-common mt76x2u mt792x-usb mt7921u
mt7925-common mt7925u mt7601u
rtw88_core rtw88_usb rtw88_8822b rtw88_8822bu rtw88_8821c rtw88_8821cu rtw88_88xxa rtw88_8812a rtw88_8812au
rtw88_8821a rtw88_8821au
rtw89_core rtw89_usb rtw89_8851b rtw89_8851bu rtw89_8852a rtw89_8852au rtw89_8852b_common rtw89_8852b rtw89_8852bu
rtw89_8852c rtw89_8852cu
rtl8xxxu"
rm -rf "${R:?}$DEST"; install -d -m 0755 "$R$DEST"
for m in $MODULES; do
    ko=$(find "$W" -name "$m.ko" -print -quit)
    [ -n "$ko" ] || die "$m.ko was not built"
    install -m 0644 "$ko" "$R$DEST/$m.ko"
    aarch64-linux-gnu-strip --strip-debug "$R$DEST/$m.ko"
done
built=$(find "$W" -name '*.ko' | wc -l)
[ "$built" -eq "$(echo $MODULES | wc -w)" ] || die "built $built modules, expected $(echo $MODULES | wc -w)"
in_root depmod -a "$KVER"

# --- checks: vermagic, every symbol resolved, each module's chain, and udev's USB-id lookup --------------------------
for m in $MODULES; do
    v=$(in_root modinfo -F vermagic "$DEST/$m.ko")
    [ "$v" = "$VERMAGIC" ] || die "$m: vermagic '$v'"
    echo "vermagic ok: $m ($v)"
done
unresolved=$(in_root depmod -n -e -F "/boot/System.map-$KVER" "$KVER" 2>&1 >/dev/null | grep -i 'unknown symbol' | grep dashivo-wifi || true)
[ -z "$unresolved" ] || die "unresolved symbols: $unresolved"
for m in mt7921u mt7925u mt76x2u mt76x0u mt7601u rtw88_8822bu rtw88_8821cu rtw88_8812au rtw88_8821au \
    rtw89_8851bu rtw89_8852au rtw89_8852bu rtw89_8852cu rtl8xxxu; do
    in_root modprobe -S "$KVER" --show-depends "$m" | sed "s#^#  $m: #; s#/lib/modules/$KVER/##"
done
# A USB id per chip family, as the kernel reports it in MODALIAS (vendor, product, then the interface class).
while read -r chip vidpid want; do
    a="usb:v${vidpid%%:*}p${vidpid##*:}d0100dc00dsc00dp00icFFiscFFipFFin00"
    got=$(in_root modprobe -S "$KVER" -R "$a" 2>/dev/null | tr '\n' ' ')
    case " $got " in *" $want "*) echo "usb id ok: $chip $vidpid -> $want" ;; *) die "$chip $vidpid resolves to '$got', not $want" ;; esac
done <<'EOF'
MT7921AU 0E8D:7961 mt7921u
MT7925U 0E8D:7925 mt7925u
MT7925U-NetgearA9000 0846:9072 mt7925u
MT7612U 0E8D:7612 mt76x2u
MT7610U 148F:7610 mt76x0u
MT7601U 148F:7601 mt7601u
RTL8822BU 0BDA:B812 rtw88_8822bu
RTL8821CU 0BDA:C811 rtw88_8821cu
RTL8812AU 0BDA:8812 rtw88_8812au
RTL8811AU 0BDA:A811 rtw88_8821au
RTL8851BU 0BDA:B851 rtw89_8851bu
RTL8831BU 0BDA:B831 rtw89_8851bu
RTL8832AU 0BDA:8832 rtw89_8852au
RTL8852AU 0BDA:885A rtw89_8852au
RTL8832BU 0BDA:B832 rtw89_8852bu
RTL8852BU 0BDA:B852 rtw89_8852bu
RTL8832CU 0BDA:C832 rtw89_8852cu
RTL8852CU 0BDA:C85A rtw89_8852cu
RTL8188FTV 0BDA:F179 rtl8xxxu
RTL8192EU 0BDA:818B rtl8xxxu
EOF

# --- firmware: exactly the files the modules name, from Debian's packages, with their licences ----------------------
FW_PKGS=""
for deb in "$IN"/firmware-*_all.deb; do
    p=$(dpkg-deb -f "$deb" Package); v=$(dpkg-deb -f "$deb" Version)
    mkdir -p "$T/fw/$p"; dpkg-deb -x "$deb" "$T/fw/$p"
    FW_PKGS="$FW_PKGS $p=$v"
done
FW_ROOT=/usr/lib/firmware; [ -L "$R/lib" ] || FW_ROOT=/lib/firmware
WANTED=$(for m in $MODULES; do in_root modinfo -F firmware "$DEST/$m.ko"; done | sort -u)
install -d -m 0755 "$R$DOC"
python3 - "$R" "$FW_ROOT" "$T/fw" "$R$DOC" "$FW_PKGS" $WANTED <<'PY'
"""Copy each wanted firmware file (and what its symlinks point to) from the extracted packages into the image; write
the licence of each file (Debian's machine-readable copyright, DEP-5) and a manifest."""
import fnmatch, hashlib, os, re, shutil, sys
root, fw_root, src, doc, pkgs, wanted = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5].split(), sys.argv[6:]
versions = dict(p.split("=", 1) for p in pkgs)
trees = {p: os.path.join(src, p, "usr/lib/firmware") for p in versions}
dest = root + fw_root
# Every chip in docs/blackbox-supported-devices.md needs these; a module may also name files that were never published
# (rtl8xxxu's rtlwifi/rtl8723bu_bt.bin): those are reported, not fatal.
REQUIRED = {"mediatek/WIFI_MT7961_patch_mcu_1_2_hdr.bin", "mediatek/WIFI_RAM_CODE_MT7961_1.bin", "mt7662.bin",
            "mt7662_rom_patch.bin", "mediatek/mt7610u.bin", "mt7601u.bin", "rtw88/rtw8822b_fw.bin",
            "rtw88/rtw8821c_fw.bin", "rtw88/rtw8812a_fw.bin", "rtw88/rtw8821a_fw.bin", "rtlwifi/rtl8188fufw.bin",
            "rtlwifi/rtl8192eu_nic.bin", "rtlwifi/rtl8188eufw.bin", "rtlwifi/rtl8723bu_nic.bin",
            "rtlwifi/rtl8192fufw.bin", "rtlwifi/rtl8710bufw_UMC.bin", "rtlwifi/rtl8710bufw_SMIC.bin",
            "mediatek/mt7925/WIFI_MT7925_PATCH_MCU_1_1_hdr.bin", "mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin",
            "rtw89/rtw8851b_fw.bin", "rtw89/rtw8852a_fw.bin", "rtw89/rtw8852b_fw-1.bin", "rtw89/rtw8852c_fw-2.bin"}
missing_req = sorted(REQUIRED - set(wanted))
if missing_req:
    sys.exit(f"usb-wifi: no module asks for {missing_req} any more: update REQUIRED")
# rtw89 names only its newest firmware format, rtw89/<chip>_fw-<N>.bin, and when that file isn't there it tries N-1 ...
# down to the plain <chip>_fw.bin (fw.c, rtw89_early_fw_feature_recognize). A newest format the packages don't have is
# replaced by the newest one they do (RTL8852C: the kernel knows format 2, firmware-nonfree 20250410 has format 1).
RTW89_FORMAT = re.compile(r"^(rtw89/.+_fw)-([0-9]+)\.bin$")
# Files in a folder Debian's DEP-5 has no stanza for, with the licence linux-firmware's own WHENCE gives them (tag
# 20250410, "Driver: mt7925 - MediaTek MT7925 Wireless MACs ... Licence: Redistributable. See LICENCE.mediatek").
WHENCE = {"mediatek/mt7925/*": ("binary-redist-MediaTek", "MediaTek Inc.")}
def find(name):
    for p, t in sorted(trees.items()):
        if os.path.lexists(os.path.join(t, name)):
            return p, t
    return None, None
done, rows, absent, older = set(), [], [], []
def copy(name):
    if name in done:
        return
    done.add(name)
    p, t = find(name)
    fmt = RTW89_FORMAT.match(name)
    if p is None and fmt:
        for n in range(int(fmt.group(2)) - 1, -1, -1):
            alt = f"{fmt.group(1)}-{n}.bin" if n else f"{fmt.group(1)}.bin"
            if find(alt)[0]:
                older.append((name, alt))
                copy(alt)
                return
    if p is None:
        if name in REQUIRED:
            sys.exit(f"usb-wifi: firmware {name} is in none of {sorted(trees)}")
        absent.append(name)
        return
    s, d = os.path.join(t, name), os.path.join(dest, name)
    os.makedirs(os.path.dirname(d), exist_ok=True)
    if os.path.lexists(d):
        os.remove(d)
    if os.path.islink(s):
        link = os.readlink(s)
        os.symlink(link, d)
        target = os.path.normpath(os.path.join(os.path.dirname(name), link))
        rows.append((name, p, "-> " + target, ""))
        copy(target)
    else:
        shutil.copyfile(s, d); os.chmod(d, 0o644)
        rows.append((name, p, hashlib.sha256(open(s, "rb").read()).hexdigest(), os.path.getsize(s)))
for name in wanted:
    copy(name)
# DEP-5: the last Files stanza that matches a path applies; '*' also matches '/'.
cp = open(os.path.join(src, sorted(versions)[0], "usr/share/doc", sorted(versions)[0], "copyright")).read()
paras = [p for p in re.split(r"\n\s*\n", cp) if p.strip()]
def fields(par):
    out, key = {}, None
    for line in par.splitlines():
        if line[:1] in " \t" and key:
            out[key] += "\n" + line
        elif ":" in line:
            key, _, val = line.partition(":"); out[key] = val.strip()
    return out
stanzas = [fields(p) for p in paras]
texts = {f["License"].split("\n")[0].strip(): f["License"] for f in stanzas if "License" in f and "Files" not in f}
used, lic_rows, whence = {}, [], []
for name, p, sha, size in rows:
    if sha.startswith("->"):
        continue
    hit = None
    for f in stanzas:
        if "Files" in f and any(fnmatch.fnmatchcase(name, g) for g in f["Files"].split()):
            hit = f
    for glob, (lic, holder) in WHENCE.items():
        if not hit and fnmatch.fnmatchcase(name, glob):
            hit = {"License": lic, "Copyright": holder}
            whence.append(name)
    if not hit:
        sys.exit(f"usb-wifi: no licence stanza for {name}")
    lic = hit["License"].split("\n")[0].strip()
    if lic not in texts:
        sys.exit(f"usb-wifi: licence {lic} of {name} has no text")
    for holder in hit.get("Copyright", "").split("\n"):   # one holder per line in DEP-5
        if holder.strip():
            used.setdefault(lic, set()).add(" ".join(holder.split()))
    lic_rows.append((name, lic))
# The licence files under linux-firmware's own names (Debian reformats them for line length only).
NAMES = {"binary-redist-MediaTek": "LICENCE.mediatek", "binary-redist-Ralink": "LICENCE.ralink_a_mediatek_company_firmware",
         "binary-redist-Realtek-restrictive": "LICENCE.rtlwifi_firmware.txt"}
for lic, holders in sorted(used.items()):
    body = "\n".join(l[1:] if l.startswith(" ") else l for l in texts[lic].split("\n")[1:])
    body = "\n".join("" if l == "." else l for l in body.split("\n"))
    with open(os.path.join(doc, NAMES.get(lic, lic)), "w") as fh:
        fh.write("".join(f"Copyright: {h}\n" for h in sorted(holders)) + "\n" + body.strip() + "\n")
with open(os.path.join(doc, "FIRMWARE"), "w") as fh:
    fh.write("USB Wi-Fi firmware in Black Box OS, copied unmodified from Debian's packages "
             + ", ".join(f"{p} {v}" for p, v in sorted(versions.items())) + " (non-free-firmware).\n"
             + f"Installed under {fw_root}. Licence per file (Debian's DEP-5 copyright); the texts are next to this file.\n\n")
    lic_of = dict(lic_rows)
    for name, p, sha, size in rows:
        fh.write(f"{name}  {p}  {sha}" + (f"  {size} bytes  {NAMES.get(lic_of[name], lic_of[name])}" if size != "" else "") + "\n")
total = sum(int(s) for *_, s in rows if s != "")
with open(os.path.join(doc, "FIRMWARE"), "a") as fh:
    if whence:
        fh.write("\nLicence from linux-firmware's WHENCE (Debian's copyright file has no stanza for them): "
                 + ", ".join(whence) + "\n")
    if older:
        fh.write("\nNamed by a module, an older format installed instead (the driver tries older formats): "
                 + ", ".join(f"{a} -> {b}" for a, b in older) + "\n")
if older:
    print("firmware: an older format for " + ", ".join(f"{a} (installed {b})" for a, b in older))
if absent:
    print("firmware named by a module but in no Debian package (never published upstream): " + ", ".join(absent))
    with open(os.path.join(doc, "FIRMWARE"), "a") as fh:
        fh.write("\nNamed by a module, not published (not installed): " + ", ".join(absent) + "\n")
print(f"firmware: {sum(1 for r in rows if r[3] != '')} files + {sum(1 for r in rows if r[3] == '')} links, {total} bytes; licences: {', '.join(NAMES.get(l, l) for l in sorted(used))}")
PY
for f in $WANTED; do
    [ -e "$R$FW_ROOT/$f" ] || grep -q "not installed.*$f" "$R$DOC/FIRMWARE" || grep -q "instead.*$f -> " "$R$DOC/FIRMWARE" ||
        die "firmware $f missing after install"
done

# --- Realtek's driver-disk mode -------------------------------------------------------------------------------------
# Many Realtek AX / AC sticks first show up as a CD drive with their Windows driver (0bda:1a2b, 0bda:a192). The kernel
# ignores that drive (usb-storage US_FL_IGNORE_DEVICE); Arduino's image has usb-modeswitch, whose data switches
# 0bda:1a2b (StandardEject, a SCSI eject) and the stick comes back as its Wi-Fi id. Its data (20191128) predates
# 0bda:a192: the same switch is added for it here. Nothing else of usb-modeswitch is changed.
[ -x "$R/usr/sbin/usb_modeswitch" ] || die "the image has no usb_modeswitch: Realtek sticks in driver-disk mode would stay disks"
for d in "$R/usr/lib/udev/rules.d" "$R/lib/udev/rules.d"; do
    [ -f "$d/40-usb_modeswitch.rules" ] && grep -q 'ATTR{idVendor}=="0bda", ATTR{idProduct}=="1a2b"' "$d/40-usb_modeswitch.rules" && break
    d=
done
[ -n "$d" ] || die "usb-modeswitch-data no longer switches 0bda:1a2b"
install -d -m 0755 "$R/etc/usb_modeswitch.d"
printf '# Realtek Wi-Fi stick in driver-disk mode (Black Box OS, image/usb-wifi.sh)\nStandardEject=1\n' > "$R/etc/usb_modeswitch.d/0bda:a192"
cat > "$R/etc/udev/rules.d/40-dashivo-wifi-modeswitch.rules" <<'EOF'
# A Realtek Wi-Fi stick in its Windows-driver disk mode that usb-modeswitch-data 20191128 doesn't know (it switches
# 0bda:1a2b itself): the same switch, a SCSI eject (/etc/usb_modeswitch.d/0bda:a192). Black Box OS, image/usb-wifi.sh.
ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="0bda", ATTR{idProduct}=="a192", RUN+="usb_modeswitch '/%k'"
EOF
chmod 0644 "$R/etc/usb_modeswitch.d/0bda:a192" "$R/etc/udev/rules.d/40-dashivo-wifi-modeswitch.rules"
echo "driver-disk mode: 0bda:1a2b by usb-modeswitch-data (${d#"$R"}), 0bda:a192 added"

# --- the GPL source of what we built, and a manifest ------------------------------------------------------------------
install -d -m 0755 "$R$DOC/kernel"
for f in COPYING LICENSES/preferred/GPL-2.0 LICENSES/preferred/BSD-3-Clause LICENSES/preferred/BSD-3-Clause-Clear; do
    install -m 0644 "$T/src/$f" "$R$DOC/kernel/$(basename "$f")"
done
{
    echo "USB Wi-Fi drivers in Black Box OS: Linux kernel drivers, built unmodified as external modules."
    echo "Source: https://github.com/arduino/linux-qcom commit $KERNEL_SRC_COMMIT (Arduino's UNO Q kernel, the one this"
    echo "image runs), folders drivers/net/wireless/mediatek/mt76, mediatek/mt7601u, realtek/rtw88, realtek/rtw89,"
    echo "realtek/rtl8xxxu. Built against linux-headers-$KVER (apt-repo.arduino.cc) by blackbox/os/image/usb-wifi.sh"
    echo "with only the CONFIG_ options it names switched on. Licences: BSD-3-Clause-Clear (mt76; mt76x0 mostly GPL-2.0),"
    echo "GPL-2.0 (mt7601u, rtl8xxxu), GPL-2.0 OR BSD-3-Clause (rtw88, rtw89); texts in this folder. Installed in $DEST:"
    for m in $MODULES; do
        echo "$m.ko  $(sha256sum "$R$DEST/$m.ko" | awk '{print $1}')  $(stat -c %s "$R$DEST/$m.ko") bytes"
    done
} > "$R$DOC/kernel/SOURCE"
chmod -R u=rwX,go=rX "$R$DOC"

mods_kb=$(du -sk "$R$DEST" | awk '{print $1}')
fw_kb=$(awk '$4 == $4 + 0 && $5 == "bytes" {s += $4} END {printf "%d", s / 1024}' "$R$DOC/FIRMWARE")
doc_kb=$(du -sk "$R$DOC" | awk '{print $1}')
echo "usb-wifi: $(echo $MODULES | wc -w) modules ${mods_kb} KB, firmware ${fw_kb} KB, licences ${doc_kb} KB"
rm -rf "$T"
