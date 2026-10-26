# Black Box OS releases

One folder per published version. Each has:

- `README.md`: the builds, where each source archive is, anything to know
- `packages.tsv`: every installed package, its version, source package, licences, source URL and checksum
- `sources.tsv`: every source file, its size, SHA-256, upstream URL and the archive that holds it
- `kernel.txt` and `kernel-config-7.0.0-g122c2c22d838`: the kernel's exact source and configuration
- `modules/` (0.1.7 and later): the build scripts of the drivers we add, and their pinned inputs
- `SHA256SUMS`: the checksums of the source archives attached to the GitHub release `bbos-<version>`

| Version | Builds | Packages | Source packages | Archives in `bbos-<version>` |
|---|---|---:|---:|---|
| [0.2.2](0.2.2/) | `0.2.2+1` | 959 | 596 | none new: all in earlier releases |
| [0.2.1](0.2.1/) | `0.2.1+1`, `0.2.1+2` | 959 | 596 | none new: all in earlier releases |
| [0.2.0](0.2.0/) | `0.2.0+2`, `0.2.0+3` | 958 | 596 | none new: all in earlier releases |
| [0.1.8](0.1.8/) | `0.1.8` | 958 | 596 | 1 (16 MB) |
| [0.1.7](0.1.7/) | `0.1.7` | 949 | 589 | none new: all in earlier releases |
| [0.1.6](0.1.6/) | `0.1.6` | 949 | 589 | none new: all in earlier releases |
| [0.1.4](0.1.4/) | `0.1.4` | 949 | 589 | none new: all in earlier releases |
| [0.1.3](0.1.3/) | `0.1.3` | 949 | 589 | none new: all in earlier releases |
| [0.1.2](0.1.2/) | `0.1.2` | 949 | 589 | none new: all in earlier releases |
| [0.1.1](0.1.1/) | `0.1.1` | 949 | 589 | 1 (2 MB) |
| [0.1.0](0.1.0/) | `0.1.0` | 945 | 585 | 3 (3.43 GB) |
