#!/usr/bin/env bash
# Upload the newest release of every app in apps-ppa.txt to a Launchpad PPA.
#
# Environment:
#   PPA            target, e.g. jokergermany/ppa                       (required)
#   SIGN_KEY       fingerprint of the upload key                      (required unless DRY_RUN=1)
#   GPG_PASSFILE   file with the key passphrase                       (optional)
#   DEBFULLNAME, DEBEMAIL                                             (required unless DRY_RUN=1)
#   APPS_FILE      app list                                           (default: apps-ppa.txt)
#   STATE_FILE     uploaded releases                                  (default: state/published.txt)
#   SERIES         space-separated Ubuntu series                      (default: noble)
#   ONLY           only process repos containing this string          (optional)
#   DRY_RUN        1 = only report what would be uploaded             (default: 0)
#   GH_TOKEN       GitHub token for the API rate limit                (optional)
#
# apps-ppa.txt: one app per line, fields separated by "|":
#   owner/repo | license | asset regex | sums (required|optional)

set -uo pipefail

APPS_FILE="${APPS_FILE:-apps-ppa.txt}"
STATE_FILE="${STATE_FILE:-state/published.txt}"
SERIES="${SERIES:-noble}"
DRY_RUN="${DRY_RUN:-0}"
ONLY="${ONLY:-}"
: "${PPA:?set PPA, e.g. jokergermany/ppa}"
LP_OWNER="${PPA%%/*}"; LP_NAME="${PPA##*/}"
HERE="$(cd "$(dirname "$0")" && pwd)"
BASE="${RUNNER_TEMP:-/tmp}/ppa-sync"
mkdir -p "$(dirname "$STATE_FILE")"; touch "$STATE_FILE"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }
gh_api() {
  local a=(-fsSL -H "Accept: application/vnd.github+json")
  [ -n "${GH_TOKEN:-}" ] && a+=(-H "Authorization: Bearer $GH_TOKEN")
  curl "${a[@]}" "https://api.github.com/$1"
}
lp_has_version() {   # $1 = source package, $2 = version; any status (Launchpad never accepts a version twice)
  local n
  n="$(curl -fsSL "https://api.launchpad.net/devel/~$LP_OWNER/+archive/ubuntu/$LP_NAME?ws.op=getPublishedSources&source_name=$1&exact_match=true&version=$2" \
       | jq '.entries | length')" || return 2
  [ "${n:-0}" -gt 0 ]
}

failed=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%%#*}"; [ -z "$(trim "$line")" ] && continue
  IFS='|' read -r repo license regex sums <<<"$line"
  repo="$(trim "$repo")"; license="$(trim "$license")"; regex="$(trim "$regex")"; sums="$(trim "${sums:-required}")"
  [ -n "$ONLY" ] && [[ "$repo" != *"$ONLY"* ]] && continue
  echo "::group::$repo"

  rel="$(gh_api "repos/$repo/releases?per_page=20" | jq -c '[.[] | select(.draft==false and .prerelease==false)] | first // empty')"
  if [ -z "$rel" ]; then echo "ERROR: no release / API error for $repo"; failed+=("$repo"); echo "::endgroup::"; continue; fi
  tag="$(jq -r .tag_name <<<"$rel")"
  asset="$(jq -r --arg re "$regex" '[.assets[] | select(.name|test($re))][0] // empty | "\(.name) (\(.size/1048576|floor) MB)"' <<<"$rel")"
  hassums="$(jq -r '[.assets[].name] | index("SHA256SUMS.txt") != null' <<<"$rel")"
  echo "latest: $tag, asset: ${asset:-NONE}, SHA256SUMS.txt: $hassums"

  if grep -q "^$repo $tag " "$STATE_FILE"; then echo "already uploaded"; echo "::endgroup::"; continue; fi
  if [ "$DRY_RUN" = "1" ]; then echo "DRY RUN: would upload $repo $tag"; echo "::endgroup::"; continue; fi
  if [ -z "$asset" ]; then echo "ERROR: no asset matches '$regex'"; failed+=("$repo"); echo "::endgroup::"; continue; fi

  work="$BASE/$(tr / _ <<<"$repo")"; rm -rf "$work"
  ok=1; uploaded=()
  for s in $SERIES; do
    # orig/ stays in $work, so further series reuse the byte-identical orig tarball;
    # only the first series includes it in the upload.
    inc=1; [ ${#uploaded[@]} -gt 0 ] && inc=0
    if ! GH_REPO="$repo" ASSET_REGEX="$regex" LICENSE="$license" REQUIRE_SUMS="$([ "$sums" = optional ] && echo 0 || echo 1)" \
         SERIES="$s" INCLUDE_ORIG="$inc" WORKDIR="$work" "$HERE/make-ppa-source.sh"; then
      ok=0; break
    fi
    # shellcheck disable=SC1091
    . "$work/result.env"
    if lp_has_version "$PKG" "$SRCVER"; then
      echo "$PKG $SRCVER already in ppa:$PPA, skipping upload"
      uploaded+=("$s"); continue
    fi
    if ! debsign -p"$HERE/gpg-batch.sh" -k"$SIGN_KEY" "$CHANGES"; then ok=0; break; fi
    if ! dput "ppa:$PPA" "$CHANGES"; then ok=0; break; fi
    uploaded+=("$s")
  done

  if [ "$ok" = 1 ]; then
    echo "$repo $tag ${SRCVER%~*} $(date -u +%F)" >> "$STATE_FILE"
  else
    echo "ERROR: $repo $tag failed"; failed+=("$repo")
  fi
  rm -rf "$work"
  echo "::endgroup::"
done < "$APPS_FILE"

if [ ${#failed[@]} -gt 0 ]; then echo "FAILED: ${failed[*]}"; exit 1; fi
echo "all done"
