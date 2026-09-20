#!/usr/bin/env bash
# Builds the tait-cli .deb for one architecture.
#
#   packaging/build-deb.sh <version> [amd64|arm64|armhf] [outdir]
#
# Produces <outdir>/tait-cli_<version>_<arch>.deb. Default outdir is <repo>/artifacts.
#
# The publish flags here are deliberately identical to the six-arch loop in
# .github/workflows/publish.yml, so the binary inside the .deb is the same program as the
# release asset for that arch. If one list changes, change both.
#
# This is a plain CLI tool: no daemon, no user to create, no config to seed. So no systemd
# unit and no maintainer scripts at all - dpkg unpacking the files is the whole install.
#
# Layout note, observed rather than assumed. Published for linux-x64 on this repo at the time
# of writing, the flags below emit exactly one file:
#
#   $ ls -la publish/
#   -rwxr-xr-x 1 tf tf 39383516 tait-cli
#
# so /usr/bin/tait-cli is a plain file. IncludeNativeLibrariesForSelfExtract=true is what buys
# that: M0LTE.Tait.Ccdi pulls in System.IO.Ports, and dropping that flag leaves
# libSystem.IO.Ports.Native.so loose beside the executable (checked, same command without it).
# .NET resolves a loose shim relative to the real path of the running binary, so installing
# the bare executable to /usr/bin would drop it and opening a port would die with
# DllNotFoundException. If a future SDK or dependency starts leaving anything beside the
# executable again, this script needs the sibling pdn-soundmodem treatment: payload in
# /usr/lib/tait-cli/ with /usr/bin/tait-cli a relative symlink into it. The Verify step in
# publish.yml would not catch that, so check the publish listing when the flags or the SDK
# change.
set -euo pipefail

VERSION="${1:?usage: build-deb.sh <version> [arch] [outdir]}"
ARCH="${2:-amd64}"

# A Debian version must start with a digit. Note for later, if a prerelease scheme is ever
# wanted: 1.0.0~rc1 sorts BEFORE 1.0.0, whereas 1.0.0-rc1 sorts after it, so a tag like
# v1.0.0-rc1 would make apt treat the candidate as newer than the eventual release.
case "$VERSION" in
  [0-9]*) ;;
  *) echo "version '$VERSION' does not start with a digit, which Debian requires" >&2; exit 2 ;;
esac

case "$ARCH" in
  amd64) RID=linux-x64 ;;
  arm64) RID=linux-arm64 ;;
  armhf) RID=linux-arm ;;
  *) echo "unsupported arch $ARCH" >&2; exit 2 ;;
esac

# dpkg-deb ships in the Essential `dpkg` package, so this only trips on a non-Debian host.
command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found - this needs a Debian-family host" >&2; exit 3; }
# readelf reads the library-version floors out of the published binary (see the Depends
# section below). Refuse to build rather than fall back to an unversioned Depends: a package
# that understates what it needs installs onto machines it cannot run on.
command -v readelf >/dev/null || { echo "readelf not found - install binutils" >&2; exit 3; }

# Directories inherit the caller's umask, and a developer box set to 002 produces
# group-writable 0775 directories inside the package, which is not what a .deb should ship
# (lintian: non-standard-dir-perm). Pin it so the package is the same from any shell.
umask 022

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$HERE")"
OUTDIR="${3:-$ROOT/artifacts}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

DOCDIR=/usr/share/doc/tait-cli

dotnet publish "$ROOT/tait-cli.csproj" \
  --configuration Release \
  --runtime "$RID" \
  --self-contained true \
  -p:PublishSingleFile=true \
  -p:IncludeNativeLibrariesForSelfExtract=true \
  -p:EnableCompressionInSingleFile=true \
  -p:Version="$VERSION" \
  -p:DebugType=none \
  -p:GenerateDocumentationFile=false \
  --output "$STAGE/publish"

mkdir -p "$STAGE/root/usr/bin" \
         "$STAGE/root$DOCDIR" \
         "$STAGE/root/DEBIAN"

install -m 0755 "$STAGE/publish/tait-cli" "$STAGE/root/usr/bin/tait-cli"

install -m 0644 "$HERE/copyright" "$STAGE/root$DOCDIR/copyright"

# Debian changelog. A numeric SOURCE_DATE_EPOCH keeps rebuilds of a tag byte-identical;
# anything else (an ISO string from a CI event payload, say) falls back to now rather than
# failing the build on `date -R`.
#
# lintian says wrong-name-for-changelog-of-native-package about this file, and it is right on
# its own terms: the version carries no Debian revision (0.1.0, not 0.1.0-1), which is what
# lintian reads as a native package, and policy wants a native package's changelog at
# changelog.gz. Left as changelog.Debian.gz deliberately, because every package in the
# packet-net apt repo ships that name and the verify step in publish.yml greps for it; a
# station operator reading `dpkg -L tait-cli` should find the same layout in all of them. If
# that ever gets fixed, fix it in tait-codeplug and pdn-soundmodem at the same time.
case "${SOURCE_DATE_EPOCH:-}" in
  ''|*[!0-9]*) CHANGELOG_DATE="$(date -R)" ;;
  *)           CHANGELOG_DATE="$(date -R --date="@$SOURCE_DATE_EPOCH")" ;;
esac
cat > "$STAGE/changelog.Debian" <<EOF
tait-cli ($VERSION) unstable; urgency=medium

  * Release $VERSION. Notes:
    https://github.com/M0LTE/tait-cli/releases/tag/v$VERSION

 -- Tom Fanning M0LTE <tom@m0lte.uk>  $CHANGELOG_DATE
EOF
gzip -9n -c "$STAGE/changelog.Debian" > "$STAGE/root$DOCDIR/changelog.Debian.gz"
chmod 0644 "$STAGE/root$DOCDIR/changelog.Debian.gz"

INSTALLED_SIZE="$(du -k -s --exclude=DEBIAN "$STAGE/root" | cut -f1)"

# --- library version floors, read from the binary we just published -----------
# The executable is Microsoft's `singlefilehost` with our payload bundled into it, so its
# symbol-version floor is whatever .NET's runtime pack for this RID was built against, not
# anything this repo controls, and it moves without warning: .NET 10 raised linux-arm from
# glibc 2.16 to 2.34, which is above Debian 11's 2.31. While Depends: said a bare `libc6`,
# apt installed that armhf package onto bullseye quite happily and the binary then died in
# the dynamic loader with "version `GLIBC_2.33' not found". So derive the floor from the
# ELF rather than asserting one here, and let apt refuse the install with a clear reason.
#
# .gnu.version_r is the authoritative record of which symbol versions of which libraries
# the loader must satisfy. Read the highest of one family (GLIBC, GLIBCXX) out of it.
# "GLIBC_" cannot match inside "GLIBCXX_", so the two families do not overlap.
max_needed() {
  readelf --version-info "$1" \
    | awk '/Version needs section/,0' \
    | grep -oE "$2_[0-9][0-9.]*" \
    | sed "s/^$2_//" \
    | sort -uV \
    | tail -1
}

PUBLISHED_BIN="$STAGE/root/usr/bin/tait-cli"
# A glibc symbol version is the glibc release that introduced it, and libc6's package
# version is that same release, so this maps straight onto a Debian version constraint.
GLIBC_MIN="$(max_needed "$PUBLISHED_BIN" GLIBC)"
GLIBCXX_MIN="$(max_needed "$PUBLISHED_BIN" GLIBCXX)"
[ -n "$GLIBC_MIN" ] || { echo "could not read a GLIBC floor from $PUBLISHED_BIN" >&2; exit 4; }
[ -n "$GLIBCXX_MIN" ] || { echo "could not read a GLIBCXX floor from $PUBLISHED_BIN" >&2; exit 4; }

# libstdc++ versions its symbols by C++ ABI, not by package version, so this needs a table.
# Anchors measured against the distributions themselves: Debian 10 ships GCC 8 and tops out
# at 3.4.25, Debian 11 / GCC 10 at 3.4.28, Debian 12 / GCC 12 at 3.4.30, Debian 13 / GCC 14
# at 3.4.33. Unmeasured points round up to the next anchor, because the failure modes are
# not symmetric: too high refuses an install that would have worked and says why, too low
# ships the loader crash this whole block exists to prevent. An unknown value is a new GCC
# ABI nobody has checked, so stop and make someone extend the table.
case "$GLIBCXX_MIN" in
  3.4|3.4.[0-9]|3.4.1[0-9]|3.4.2[01]) STDCXX_MIN=5 ;;
  3.4.22)     STDCXX_MIN=6 ;;
  3.4.23|3.4.24) STDCXX_MIN=7 ;;
  3.4.25)     STDCXX_MIN=8 ;;
  3.4.26)     STDCXX_MIN=9 ;;
  3.4.27|3.4.28) STDCXX_MIN=10 ;;
  3.4.29)     STDCXX_MIN=11 ;;
  3.4.30)     STDCXX_MIN=12 ;;
  3.4.31|3.4.32) STDCXX_MIN=13 ;;
  3.4.33)     STDCXX_MIN=14 ;;
  3.4.34)     STDCXX_MIN=15 ;;
  *) echo "unknown GLIBCXX_$GLIBCXX_MIN - extend the table in $0" >&2; exit 4 ;;
esac

# libgcc-s1 and zlib1g are deliberately left unversioned: the binary asks libgcc only for
# GCC_3.0 and GCC_3.5, and zlib carries no symbol versions at all, so there is nothing
# measured to constrain them with and every distribution in scope satisfies both.
echo "floors for $ARCH: libc6 >= $GLIBC_MIN, libstdc++6 >= $STDCXX_MIN (GLIBCXX_$GLIBCXX_MIN)"

# Depends: the native prerequisites a self-contained .NET app still needs from the system,
# checked rather than copied from the sibling packages. No libicu alternation here, which is
# the one difference from tait-codeplug: this project sets InvariantGlobalization=true, so the
# runtime never dlopens libicu and a bookworm container with only these four packages plus
# their own dependencies runs the binary fine. (Never write `libicu` as a dependency in any
# case: Debian stamps the soname into the package name and a bare `libicu` does not exist.)
# No ca-certificates either - this tool talks to a serial port and makes no network calls.
cat > "$STAGE/root/DEBIAN/control" <<EOF
Package: tait-cli
Version: $VERSION
Architecture: $ARCH
Maintainer: Tom Fanning M0LTE <tom@m0lte.uk>
Installed-Size: $INSTALLED_SIZE
Depends: libc6 (>= $GLIBC_MIN), libgcc-s1, libstdc++6 (>= $STDCXX_MIN), zlib1g
Section: hamradio
Priority: optional
Homepage: https://github.com/M0LTE/tait-cli
Description: Tait TM8100/TM8200 CCDI command-line tool
 A small shell for a Tait TM8100 or TM8200 mobile over its CCDI serial port:
 run it against a port for an interactive prompt, or give it one command and it
 prints the answer and exits. It reads the things the radio will tell you over
 CCDI - model, serial number, firmware, band, current channel, signal level in
 dBm and S-points, control-head display text and PA temperature - and can sit
 watching the signal level until you stop it.
 .
 This is a self-contained build: it bundles the .NET runtime, so the machine it
 runs on needs no .NET installed.
 .
 AGPL-3.0-or-later.
EOF

mkdir -p "$OUTDIR"
DEB="$OUTDIR/tait-cli_${VERSION}_${ARCH}.deb"
# -Zxz, not the host dpkg's default. A recent dpkg (and Ubuntu's, for years) builds
# control.tar.zst/data.tar.zst, and dpkg only learned to read zstd in 1.21.18: bullseye ships
# 1.20.14, which refuses the archive outright with "unknown compression for member
# control.tar.zst" before it gets as far as the dependencies. Raspberry Pi OS bullseye on
# armhf is exactly the sort of machine this package is for, so the package has to be readable
# there. xz is the portable choice and costs nothing here: the payload is a single-file bundle
# that is already compressed internally, so neither format gains much on it.
dpkg-deb -Zxz --build --root-owner-group "$STAGE/root" "$DEB"
echo "built $DEB"
