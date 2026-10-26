# Black Box OS 0.2.2

## Builds

| Build | Channel | Built | Packages | Package list |
|---|---|---|---:|---|
| `0.2.2+1` | Beta | 2026-10-25 | 959 | package list read from the published image |

## Source

- **Packages:** [`packages.tsv`](packages.tsv) (959 packages from 596 source packages) and
  [`sources.tsv`](sources.tsv) (every source file, its size, SHA-256, upstream URL and the archive that holds it).
- **Kernel:** [`kernel.txt`](kernel.txt): Arduino's `7.0.0-g122c2c22d838`, [`arduino/linux-qcom@122c2c22d838`](https://github.com/arduino/linux-qcom/tree/122c2c22d838ca826e7f4e7360df96fb4e8f7ad2), configuration in [`kernel-config-7.0.0-g122c2c22d838`](kernel-config-7.0.0-g122c2c22d838).
- **Drivers we build:** [`modules/`](modules/) (`usb-wifi.sh`, `usb-serial.sh`, `usb-cellular.sh`, [`BUILD-INPUTS`](modules/BUILD-INPUTS)).

### Archives

The source of every package of this version is in these GitHub release assets (an archive is attached to the release
of the first version that shipped its packages; later versions point back to it):

| Release | Archive | Size | SHA-256 |
|---|---|---:|---|
| [`bbos-0.1.0`](../../../../releases/tag/bbos-0.1.0) | `bbos-0.1.0-sources-part1.tar` | pending | `pending…` |
| [`bbos-0.1.0`](../../../../releases/tag/bbos-0.1.0) | `bbos-0.1.0-sources-part2.tar` | pending | `pending…` |
| [`bbos-0.1.0`](../../../../releases/tag/bbos-0.1.0) | `linux-qcom-122c2c22d838ca826e7f4e7360df96fb4e8f7ad2.tar.gz` | pending | `pending…` |
| [`bbos-0.1.1`](../../../../releases/tag/bbos-0.1.1) | `bbos-0.1.1-sources-part1.tar` | pending | `pending…` |
| [`bbos-0.1.8`](../../../../releases/tag/bbos-0.1.8) | `bbos-0.1.8-sources-part1.tar` | pending | `pending…` |

### Notes

Packages from Arduino's base image that are vendor rebuilds or have no published source:

- `alsa-ucm-conf` 1.2.14-1qcom0.1arduino3: Arduino's rebuild (in Arduino's base image): Debian's alsa-ucm-conf 1.2.14-1 source is provided; Arduino has not published its change (BSD-3-Clause)
- `android-platform-tools` 34.0.5-12arduino7: Arduino's rebuild (in Arduino's base image): Debian's android-platform-tools 34.0.5-12 source is provided; Arduino has not published its change (Apache-2.0 and permissive licences)
- `arduino-unoq-config` 0.1.0: Arduino's package in its base image; no public source found (to be requested from Arduino)
- `arduino-unoq-radio-firmware` 0.6.1: Arduino's package in its base image; no public source found (to be requested from Arduino)
- `hexagon-dsp-binaries` 0~20260110-0qcom1~bpo1: Qualcomm's DSP firmware (binary, redistributable licences) in Arduino's base image; no source published
- `pipewire` 1.4.2-1~qcom1: Qualcomm's rebuild (in Arduino's base image): provided as Debian's pipewire 1.4.2-1 source plus Qualcomm's published change, pipewire_1.4.2-1~qcom1.debdiff (github.com/qualcomm-linux/qcom-deb-images, overlay-debs/pipewire-no-aptx)
- `webkit2gtk` 2.48.3-1qcom1: Qualcomm's rebuild (in Arduino's base image): Debian's webkit2gtk 2.48.3-1 source is provided; Qualcomm has not published its change (to be requested from Arduino / Qualcomm)
