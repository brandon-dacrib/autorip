#!/usr/bin/env bash

set -Eeuo pipefail

# ----------------------------------------
# Auto Rip and Encode (efficient path)
# - Detects title
# - Rips long titles directly to MKV using MakeMKV (no full backup)
# - Encodes the largest title with HandBrakeCLI
# - Optional transfer and notification
# ----------------------------------------

# Configurable via environment variables
TMPDIR_DEFAULT="/mnt/backup/tmp"
WORKDIR_BASE="${TMPDIR:-$TMPDIR_DEFAULT}"
DEST_DIR="${DEST_DIR:-$WORKDIR_BASE}"
REMOTE_DEST="${REMOTE_DEST:-}"                    # e.g. mythbackend:/var/lib/mythtv/videos
SSH_KEY="${SSH_KEY:-$HOME/.ssh/utility}"
TITLE_MINLENGTH="${TITLE_MINLENGTH:-1800}"        # seconds; filter out extras
HB_QUALITY="${HB_QUALITY:-20}"                    # HandBrake constant quality (lower = higher quality)
HB_SUBS_ARGS="${HB_SUBS_ARGS:---subtitle 1}"      # e.g. --all-subtitles or --subtitle 1
SKIP_ENCODE="${SKIP_ENCODE:-0}"                   # 1 to keep MakeMKV MKV as final
NOTIFY_URL="${NOTIFY_URL:-}"                      # e.g. http://cloverleaf/say

LOG_PREFIX="[autorip]"

log() {
  echo "$LOG_PREFIX $*"
}

die() {
  echo "$LOG_PREFIX ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found"
}

cleanup_dir=""
cleanup() {
  if [[ -n "$cleanup_dir" && -d "$cleanup_dir" ]]; then
    rm -rf "$cleanup_dir" || true
  fi
}
trap cleanup EXIT

# Dependencies
require_cmd makemkvcon
require_cmd HandBrakeCLI
require_cmd awk
require_cmd sed
require_cmd grep

# Resolve disc title (try filesystem label first, then MakeMKV info)
get_disc_label() {
  local label=""
  if command -v blkid >/dev/null 2>&1; then
    label=$(blkid -o value -s LABEL /dev/sr0 2>/dev/null || true)
  fi
  if [[ -z "$label" || "$label" == "LOGICAL_VOLUME_ID" ]]; then
    label=$(makemkvcon info -r disc:0 2>/dev/null | grep -m1 'CINFO:2' | awk -F',' '{gsub(/\"/, "", $6); print $6}' || true)
  fi
  if [[ -z "$label" || "$label" == "LOGICAL_VOLUME_ID" ]]; then
    # Fallback to the original heuristic
    label=$(makemkvcon info -r disc:0 2>/dev/null | grep -m1 BD | awk -F, '{gsub(/\"/, "", $6); print $6}' || true)
  fi
  if [[ -z "$label" ]]; then
    label="disc-$(date +%Y%m%d-%H%M%S)"
  fi
  echo "$label"
}

sanitize() {
  # Keep alnum, dot, dash and underscore; replace others with dash; collapse dashes
  sed -E 's/[^A-Za-z0-9._-]+/-/g' | sed -E 's/-+/-/g' | sed -E 's/^-|-$//g'
}

TITLE_RAW=$(get_disc_label)
TITLE_SAFE=$(echo "$TITLE_RAW" | sanitize)

log "Detected title: '$TITLE_RAW' -> '$TITLE_SAFE'"

mkdir -p "$WORKDIR_BASE" "$DEST_DIR"

FINAL_PATH="$DEST_DIR/${TITLE_SAFE}.mkv"

# Skip if file already exists and is larger than 200MB
if [[ -f "$FINAL_PATH" ]]; then
  existing_size=$(stat -c%s "$FINAL_PATH" 2>/dev/null || echo 0)
  if (( existing_size > 200 * 1024 * 1024 )); then
    log "Final file exists (size=$existing_size). Skipping."
    exit 0
  fi
fi

# Working directory for this rip
cleanup_dir=$(mktemp -d "$WORKDIR_BASE/${TITLE_SAFE}.XXXXXX")
log "Working directory: $cleanup_dir"

# Rip long titles directly to MKV (no full backup). Use low priority IO/CPU
log "Ripping long titles (>= ${TITLE_MINLENGTH}s) with MakeMKV..."
nice -n 10 ionice -c2 -n7 \
  makemkvcon -r --decrypt --minlength="${TITLE_MINLENGTH}" --cache=2048 \
  mkv disc:0 all "$cleanup_dir" | sed -u 's/^/[makemkv] /'

shopt -s nullglob
mapfile -t ripped_titles < <(ls -1t "$cleanup_dir"/*.mkv 2>/dev/null || true)
shopt -u nullglob

[[ ${#ripped_titles[@]} -gt 0 ]] || die "No MKV titles ripped by MakeMKV."

# Pick the largest MKV as the main feature
largest_file=""
largest_size=0
for f in "${ripped_titles[@]}"; do
  sz=$(stat -c%s "$f")
  if (( sz > largest_size )); then
    largest_size=$sz
    largest_file="$f"
  fi
done

log "Selected main title: $(basename "$largest_file") ($largest_size bytes)"

if [[ "$SKIP_ENCODE" == "1" ]]; then
  log "Skipping encode. Moving main title to destination."
  mv -f "$largest_file" "$FINAL_PATH"
else
  log "Encoding with HandBrakeCLI (CQ=${HB_QUALITY})..."
  nice -n 10 ionice -c2 -n7 \
    HandBrakeCLI -i "$largest_file" -o "$FINAL_PATH" -m -q "$HB_QUALITY" $HB_SUBS_ARGS | sed -u 's/^/[handbrake] /'
fi

log "Output: $FINAL_PATH"

# Optional remote transfer
if [[ -n "$REMOTE_DEST" ]]; then
  require_cmd scp
  log "Transferring to $REMOTE_DEST ..."
  scp -i "$SSH_KEY" -q "$FINAL_PATH" "$REMOTE_DEST" || die "scp failed"
fi

# Optional notification
if [[ -n "$NOTIFY_URL" ]]; then
  if command -v curl >/dev/null 2>&1; then
    curl -sS "${NOTIFY_URL}/${TITLE_SAFE} has been copied and is now available for viewing" >/dev/null || true
  fi
fi

log "Done."
