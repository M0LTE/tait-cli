# Changelog

What changed in each release. The section for a version is lifted into that version's GitHub release notes by `.github/workflows/publish.yml`, so this file is the source of truth for what a release says it did.

Newest first. Add a section before tagging.

## 0.1.1 - 2026-09-20

A packaging fix. The tool itself is unchanged.

- **The `armhf` package no longer installs onto machines it cannot run on.** .NET 10 needs glibc 2.34 on 32-bit ARM, which Debian 11 and 32-bit Raspberry Pi OS bullseye do not have, but the package declared a bare `libc6` with no version, so apt installed it happily and the binary then died in the dynamic loader with ``version `GLIBC_2.33' not found``. The package now declares the floor it actually needs, so apt explains the problem before installing rather than leaving you with a command that will not start. On a 32-bit bullseye Pi the ways forward are the 64-bit image with the `arm64` package, or an upgrade to bookworm. `amd64` and `arm64` are unaffected and install as before on anything with glibc 2.27 or newer.
- The dependency floors are now read out of the compiled binary when the package is built, rather than written by hand, so they cannot silently fall out of date the next time a .NET runtime pack moves them.

## 0.1.0 - 2026-09-17

First release. The tool itself is unchanged; what is new is that there is now a way to get it onto a radio's host machine without a .NET SDK and a `git clone`.

- **`apt install tait-cli` works**, on Debian, Ubuntu and Raspberry Pi OS, for `amd64`, `arm64` and `armhf`. Three lines to add the [packet-net apt repository](https://github.com/packet-net/apt) and it installs like any other package, and `apt upgrade` keeps it current along with everything else on the machine; the README has the lines. The package is the same self-contained single-file binary as the release asset for that architecture, built by the same publish with the same flags, so nothing needs .NET installed.
- **Ready-to-run binaries for six platforms** attached to the release: Linux x64, arm64 and armv7 (32-bit Raspberry Pi OS), Windows x64, and macOS on Intel and Apple Silicon. Download one, make it executable, run it. `SHA256SUMS` covers every asset.
- **The three `.deb` files are release assets too**, for installing one by hand on a machine that is not going to carry an extra apt source.
- Every push and pull request now gets a build, so a change that does not compile is caught before anyone tries to release it.

What the tool does, as of this first release: it opens a Tait TM8100 or TM8200 mobile's CCDI serial port and either gives you an interactive prompt or runs the one command you named and exits. It reads model, serial number, firmware and band (`info`, `version`), the current channel and band split (`channel`, `freq`), signal level in dBm and S-points (`rssi`, and `watch` to keep reading it), the text on the control head (`display`) and the PA temperature (`temp`). The baud rate defaults to 28800 and `--baud` sets it to whatever the radio's data port is programmed for; after an attempt at the wrong rate the radio's command buffer holds junk and rejects the next good command, which the tool retries once and tells you about.
