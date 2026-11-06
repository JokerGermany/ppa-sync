#!/usr/bin/env bash
# Repack an upstream amd64 .deb into a Debian SOURCE package that only contains the
# prebuilt files and installs them at build time. The result can be uploaded to a
# Launchpad PPA with dput.
#
# NOTE: this is a repack of prebuilt binaries, not a build from source.
#
# Environment:
#   DEBFULLNAME, DEBEMAIL  name/e-mail for changelog + Maintainer (must match the upload key's UID)
#   GH_REPO       upstream GitHub repo                      (default: storytold/lightcraft)
#   ASSET_REGEX   jq regex selecting the .deb asset         (default: -linux-x86_64\.deb$)
#   SUMS_NAME     checksum asset name                       (default: SHA256SUMS.txt)
#   REQUIRE_SUMS  1 = fail without checksum file, 0 = warn  (default: 1)
#   LICENSE       license line for debian/copyright         (default: MIT or Apache-2.0)
#   DEB           local .deb instead of download            (optional, skips checksum check)
#   SERIES        Ubuntu series                             (default: noble)
#   PPA_REV       revision suffix                           (default: ppa1)
#   INCLUDE_ORIG  1 = include orig tarball in upload        (default: 1)
#   WORKDIR       working directory                         (default: ./build)
#   API_BASE      GitHub API                                (default: https://api.github.com)
#   GH_TOKEN      optional, higher API rate limit
#
# The source package is built UNSIGNED; sign the .changes afterwards with debsign.
# On success, $WORKDIR/result.env contains PKG, SRCVER, CHANGES, TAG.

set -euo pipefail

GH_REPO="${GH_REPO:-storytold/lightcraft}"
ASSET_REGEX="${ASSET_REGEX:--linux-x86_64\\.deb\$}"
SUMS_NAME="${SUMS_NAME:-SHA256SUMS.txt}"
REQUIRE_SUMS="${REQUIRE_SUMS:-1}"
LICENSE="${LICENSE:-MIT or Apache-2.0}"
SERIES="${SERIES:-noble}"
PPA_REV="${PPA_REV:-ppa1}"
INCLUDE_ORIG="${INCLUDE_ORIG:-1}"
WORKDIR="${WORKDIR:-$PWD/build}"
API_BASE="${API_BASE:-https://api.github.com}"
: "${DEBFULLNAME:?set DEBFULLNAME}"
: "${DEBEMAIL:?set DEBEMAIL}"

die() { echo "ERROR: $*" >&2; exit 1; }
log() { echo "==> $*"; }
for t in curl jq dpkg-deb dpkg-buildpackage dh tar xz sha256sum awk fakeroot; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

mkdir -p "$WORKDIR/dl" "$WORKDIR/orig"
WORKDIR="$(cd "$WORKDIR" && pwd)"
rm -f "$WORKDIR/result.env"
TAG=""
SUMS_NOTE="no upstream checksum available"

# ---------------------------------------------------------------- fetch .deb
if [ -z "${DEB:-}" ]; then
  args=(-fsSL -H "Accept: application/vnd.github+json")
  if [ -n "${GH_TOKEN:-}" ]; then args+=(-H "Authorization: Bearer $GH_TOKEN"); fi
  rel="$(curl "${args[@]}" "$API_BASE/repos/$GH_REPO/releases?per_page=20" \
        | jq -c '[.[] | select(.draft==false and .prerelease==false)] | first // empty')" \
        || die "GitHub API request failed"
  [ -n "$rel" ] || die "no published release found"
  TAG="$(jq -r .tag_name <<<"$rel")"; log "$GH_REPO release $TAG"
  deb_url="$(jq -r --arg re "$ASSET_REGEX" '.assets[] | select(.name|test($re)) | .browser_download_url' <<<"$rel" | head -n1)"
  sum_url="$(jq -r --arg n "$SUMS_NAME" '.assets[] | select(.name==$n) | .browser_download_url' <<<"$rel" | head -n1)"
  [ -n "$deb_url" ] || die "no asset matching '$ASSET_REGEX' in $TAG"
  DEB="$WORKDIR/dl/$(basename "$deb_url")"
  [ -f "$DEB" ] || curl -fsSL -o "$DEB" "$deb_url"
  name="$(basename "$DEB")"
  if [ -n "$sum_url" ]; then
    curl -fsSL -o "$WORKDIR/dl/$SUMS_NAME" "$sum_url"
    exp="$(awk -v f="$name" '{n=$2; sub(/^\*/,"",n); if (n==f) print $1}' "$WORKDIR/dl/$SUMS_NAME")"
    act="$(sha256sum "$DEB" | awk '{print $1}')"
    if [ -z "$exp" ] || [ "$exp" != "$act" ]; then die "checksum mismatch for $name"; fi
    log "checksum OK"
    SUMS_NOTE="checksum verified against the release's $SUMS_NAME"
  elif [ "$REQUIRE_SUMS" = "1" ]; then
    die "$SUMS_NAME missing in release $TAG"
  else
    echo "WARNING: $SUMS_NAME missing in $TAG, uploading without upstream checksum" >&2
  fi
else
  [ -f "$DEB" ] || die "$DEB not found"
  log "using local file $DEB (no checksum check)"
fi

# ---------------------------------------------------------------- metadata
field() { dpkg-deb -f "$DEB" "$1" 2>/dev/null || true; }
PKG="$(field Package)"; FULLVER="$(field Version)"; ARCH="$(field Architecture)"
if [ -z "$PKG" ] || [ -z "$FULLVER" ]; then die "cannot read Package/Version from .deb"; fi
[ "$ARCH" = "amd64" ] || die "expected Architecture amd64, got '$ARCH'"
UPSTREAM="${FULLVER%-*}"; UREV="${FULLVER##*-}"
if [ "$UPSTREAM" = "$FULLVER" ]; then UREV="1"; fi
SRCVER="${UPSTREAM}-${UREV}${PPA_REV}~${SERIES}1"
log "package $PKG, upstream $UPSTREAM, source version $SRCVER, series $SERIES"

# ---------------------------------------------------------------- payload + orig tarball
TREE="$WORKDIR/${PKG}-${UPSTREAM}"
ORIG="$WORKDIR/${PKG}_${UPSTREAM}.orig.tar.xz"
rm -rf "$TREE"; mkdir -p "$TREE"
dpkg-deb -x "$DEB" "$TREE"

if [ -f "$WORKDIR/orig/$(basename "$ORIG")" ]; then
  log "reusing cached orig tarball"
  cp -f "$WORKDIR/orig/$(basename "$ORIG")" "$ORIG"
else
  log "creating orig tarball (may take a few minutes)"
  epoch="$(find "$TREE" -type f -printf '%T@\n' | sort -n | tail -n1 | cut -d. -f1)"
  ( cd "$WORKDIR" && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@${epoch:-0}" \
      -cf - "${PKG}-${UPSTREAM}" | xz -T1 -6 > "$ORIG" )
  cp -f "$ORIG" "$WORKDIR/orig/"
fi

# ---------------------------------------------------------------- debian/
D="$TREE/debian"
rm -rf "$D"; mkdir -p "$D/source"
echo "3.0 (quilt)" > "$D/source/format"

DEPENDS="$(field Depends)"; RECOMMENDS="$(field Recommends)"; HOMEPAGE="$(field Homepage)"
SECTION="$(field Section)"; PRIORITY="$(field Priority)"
DESC="$(dpkg-deb -f "$DEB" Description)"
[ -n "$DESC" ] || DESC="$PKG (repackaged upstream release)"
{
  echo "Source: $PKG"
  echo "Section: ${SECTION:-misc}"
  echo "Priority: ${PRIORITY:-optional}"
  echo "Maintainer: $DEBFULLNAME <$DEBEMAIL>"
  echo "Build-Depends: debhelper-compat (= 13)"
  echo "Standards-Version: 4.6.2"
  echo "Rules-Requires-Root: no"
  if [ -n "$HOMEPAGE" ]; then echo "Homepage: $HOMEPAGE"; fi
  echo
  echo "Package: $PKG"
  echo "Architecture: amd64"
  echo "Depends: \${misc:Depends}${DEPENDS:+, $DEPENDS}"
  if [ -n "$RECOMMENDS" ]; then echo "Recommends: $RECOMMENDS"; fi
  echo "Description: $DESC"
} > "$D/control"

CT="$WORKDIR/ctrl"; rm -rf "$CT"; mkdir -p "$CT"; dpkg-deb -e "$DEB" "$CT"
for s in preinst postinst prerm postrm; do
  if [ -f "$CT/$s" ]; then install -m 0755 "$CT/$s" "$D/$PKG.$s"; fi
done

# Copies every top-level directory of the payload (usr/, opt/, etc/ ...), not only usr/.
cat > "$D/rules" <<RULES
#!/usr/bin/make -f
# Repack: the prebuilt files are already in the source tree and are only installed.
%:
	dh \$@

override_dh_auto_configure override_dh_auto_build override_dh_auto_test override_dh_auto_clean:

override_dh_auto_install:
	mkdir -p debian/$PKG
	find . -mindepth 1 -maxdepth 1 -type d ! -name debian ! -name .pc -exec cp -a {} debian/$PKG/ \;

# Leave files untouched (binaries are already built/stripped).
override_dh_strip override_dh_dwz override_dh_shlibdeps override_dh_compress:
RULES
chmod 0755 "$D/rules"

cat > "$D/copyright" <<COPY
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: $PKG
Source: https://github.com/$GH_REPO

Files: *
Copyright: the $PKG contributors
License: $LICENSE
 This package repackages the official upstream release (prebuilt binaries)
 from https://github.com/$GH_REPO without modification. See the upstream
 repository for the full license text and third-party notices.
COPY

cat > "$D/changelog" <<CHLOG
$PKG ($SRCVER) $SERIES; urgency=medium

  * Unofficial repackage of upstream release $UPSTREAM${TAG:+ ($TAG)}
    (binary payload of the official amd64 .deb; $SUMS_NOTE).

 -- $DEBFULLNAME <$DEBEMAIL>  $(date -R)
CHLOG

# ---------------------------------------------------------------- build source package
sa=-sd; [ "$INCLUDE_ORIG" = "1" ] && sa=-sa
( cd "$TREE" && dpkg-buildpackage -S "$sa" -d -us -uc )

CHANGES="$WORKDIR/${PKG}_${SRCVER}_source.changes"
[ -f "$CHANGES" ] || die "expected $CHANGES"
{
  echo "PKG=$PKG"; echo "SRCVER=$SRCVER"; echo "CHANGES=$CHANGES"; echo "TAG=$TAG"
} > "$WORKDIR/result.env"
log "done: $CHANGES"
