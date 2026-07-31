#!/bin/bash
# GeoLite2 mmdb database updater
#
# Downloads MaxMind GeoLite2 databases from the P3TERX/GeoLite.mmdb mirror
# (no MaxMind account or license key required, rebuilt daily).
#
# Consumed by trippy: ~/.config/trippy/trippy.toml -> geoip-mmdb-file

set -euo pipefail

REPO="P3TERX/GeoLite.mmdb"
DEST_DIR="${GEOLITE_DIR:-$HOME/.local/share/trippy}"
STAMP_FILE=".geolite-release"

DATABASES=(City ASN Country)
FORCE=0
TMP_FILES=()

usage() {
    echo "Usage: $0 [--city] [--asn] [--country] [--force] [--dir <path>]"
    echo ""
    echo "Downloads GeoLite2 mmdb databases from the ${REPO} mirror."
    echo "With no database flags all three (City, ASN, Country) are updated."
    echo ""
    echo "Options:"
    echo "  --city, --asn, --country   Update only the named database(s)"
    echo "  --force                    Re-download even if already up to date"
    echo "  --dir <path>               Destination directory"
    echo "                             (default: \$HOME/.local/share/trippy)"
    echo ""
    echo "Examples:"
    echo "  $0                         # update all three"
    echo "  $0 --city                  # only the database trippy needs"
    echo "  $0 --force --dir /usr/share/GeoIP"
    exit "${1:-1}"
}

cleanup() {
    if [ ${#TMP_FILES[@]} -gt 0 ]; then
        rm -f -- "${TMP_FILES[@]}"
    fi
}
trap cleanup EXIT

# A valid mmdb ends with a metadata section carrying the MaxMind marker and the
# database type. Checking both rejects HTML error pages and truncated downloads.
verify_mmdb() {
    local file="$1" expected_type="$2" tail_bytes

    [ -s "$file" ] || return 1
    # tr strips NUL bytes, which command substitution cannot hold; letting tr
    # drain the pipe also avoids SIGPIPE tripping `set -o pipefail`.
    tail_bytes=$(tail -c 20000 -- "$file" | tr -d '\0')
    grep -aq "MaxMind.com" <<<"$tail_bytes" || return 1
    grep -aq "$expected_type" <<<"$tail_bytes" || return 1
}

selected=()
while [ $# -gt 0 ]; do
    case "$1" in
        --city)     selected+=(City); shift ;;
        --asn)      selected+=(ASN); shift ;;
        --country)  selected+=(Country); shift ;;
        --force)    FORCE=1; shift ;;
        --dir)      DEST_DIR="${2:-}"; [ -n "$DEST_DIR" ] || usage; shift 2 ;;
        -h|--help)  usage 0 ;;
        *)          echo "Error: unknown argument: $1" >&2; usage ;;
    esac
done
[ ${#selected[@]} -gt 0 ] && DATABASES=("${selected[@]}")

for cmd in curl jq; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Error: required command not found: $cmd" >&2
        exit 1
    fi
done

mkdir -p -- "$DEST_DIR"

echo "Checking latest release of ${REPO}..."
release=$(curl -fsSL --retry 3 --retry-delay 2 \
    "https://api.github.com/repos/${REPO}/releases/latest") || {
    echo "Error: could not reach the GitHub API. Existing databases left untouched." >&2
    exit 1
}

tag=$(jq -r '.tag_name // empty' <<<"$release")
if [ -z "$tag" ]; then
    echo "Error: could not determine the latest release tag." >&2
    exit 1
fi

stamp_path="${DEST_DIR}/${STAMP_FILE}"
local_tag=""
[ -f "$stamp_path" ] && local_tag=$(<"$stamp_path")

# Skip only when the tag matches AND every requested file is actually present,
# so adding a database on a later run still downloads it.
if [ "$FORCE" -eq 0 ] && [ "$local_tag" = "$tag" ]; then
    all_present=1
    for db in "${DATABASES[@]}"; do
        [ -s "${DEST_DIR}/GeoLite2-${db}.mmdb" ] || all_present=0
    done
    if [ "$all_present" -eq 1 ]; then
        echo "Already up to date (release ${tag}). Use --force to re-download."
        exit 0
    fi
fi

[ -n "$local_tag" ] && echo "Local release:  ${local_tag}"
echo "Latest release: ${tag}"
echo ""

failed=0
for db in "${DATABASES[@]}"; do
    name="GeoLite2-${db}.mmdb"
    target="${DEST_DIR}/${name}"
    tmp="${target}.tmp.$$"
    TMP_FILES+=("$tmp")

    echo "Downloading ${name}..."
    if ! curl -fL --retry 3 --retry-delay 2 --progress-bar \
        -o "$tmp" \
        "https://github.com/${REPO}/releases/download/${tag}/${name}"; then
        echo "Error: download failed for ${name}, keeping the existing file." >&2
        rm -f -- "$tmp"
        failed=1
        continue
    fi

    if ! verify_mmdb "$tmp" "GeoLite2-${db}"; then
        echo "Error: ${name} is not a valid mmdb file, keeping the existing one." >&2
        rm -f -- "$tmp"
        failed=1
        continue
    fi

    # Same filesystem as the target, so this replaces the database atomically.
    mv -f -- "$tmp" "$target"
    chmod 644 -- "$target"
    echo "  -> ${target} ($(du -h -- "$target" | cut -f1))"
done

echo ""
if [ "$failed" -ne 0 ]; then
    echo "Finished with errors: some databases were not updated." >&2
    exit 1
fi

echo "$tag" > "$stamp_path"
echo "All databases updated to release ${tag}."
