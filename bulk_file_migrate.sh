#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./bulk_file_migrate.sh
#     Runs with defaults from this file/environment:
#     - DRY_DELETE=1 (do not delete source folders)
#     - VERIFY_WITH_CHECKSUM=1 (slowest/safest verify mode)
#     - MAX_FOLDERS=1 (process one top-level folder per run)
#
#   MAX_FOLDERS=5 bash bulk_file_migrate.sh
#     Process only 5 top-level folders in this run (still no delete by default).
#
#   MAX_FOLDERS=5 DRY_DELETE=0 bash bulk_file_migrate.sh
#     Process 5 folders and delete each source folder only after verify passes.
#
#   VERIFY_WITH_CHECKSUM=0 DRY_DELETE=0 bash bulk_file_migrate.sh
#     Faster verify (size/mtime based), with delete enabled after verify.
#
# Optional log location override:
#   LOG_DIR=/path/to/logs bash bulk_file_migrate.sh
#
# === CONFIG ===
# Set both to real absolute paths before running.
# Example format: /mnt/<pool>/<path-to-folder>
SRC="/mnt/<pool>/<path-to-folder>"      # folder containing many subfolders
DST="/mnt/<pool>/<path-to-folder-new>"  # destination dataset/path

# Keep logs in a writable location by default.
LOG_DIR="${LOG_DIR:-$PWD/logs}"
LOG="$LOG_DIR/rsync_migrate_$(date +%F_%H%M%S).log"

# Safer default: set to 0 only when ready to delete verified source folders.
DRY_DELETE="${DRY_DELETE:-1}"

# Strong verify (checksum) is safest but slower on very large trees.
VERIFY_WITH_CHECKSUM="${VERIFY_WITH_CHECKSUM:-1}"

# Process at most this many top-level source folders per run.
# 0 means "no limit".
MAX_FOLDERS="${MAX_FOLDERS:-1}"

RSYNC_COPY_OPTS=(
  -aHAXx
  --numeric-ids
  --human-readable
  --partial
  --info=progress2,stats
)

RSYNC_VERIFY_OPTS=(
  -aHAXxn
  --numeric-ids
  --delete
  --itemize-changes
)

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_path_prefix() {
  local prefix="$1"
  local path="$2"
  case "$path" in
    "$prefix"/*) return 0 ;;
    *) return 1 ;;
  esac
}

safe_delete_dir() {
  local dir="$1"
  [ -d "$dir" ] || die "Delete target is not a directory: $dir"
  [ "$dir" != "/" ] || die "Refusing to delete root directory"
  is_path_prefix "$SRC_REAL" "$dir" || die "Delete target escaped source root: $dir"
  rm -rf --one-file-system -- "$dir"
}

require_cmd rsync
require_cmd realpath
require_cmd dirname
require_cmd grep

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG") 2>&1

echo "== Starting migration =="
echo "Started: $(date -Is)"
echo "Host: $(hostname)"
echo "Raw SRC: $SRC"
echo "Raw DST: $DST"
echo "LOG: $LOG"
echo

case "$SRC$DST" in
  *"<pool>"*|*"<path-to-folder>"*)
    die "SRC/DST are still placeholders. Set real paths in CONFIG first."
    ;;
esac

[ -d "$SRC" ] || die "SRC not found: $SRC"
mkdir -p "$DST"
[ -d "$DST" ] || die "DST not found/creatable: $DST"

SRC_REAL="$(realpath "$SRC")"
DST_REAL="$(realpath "$DST")"

echo "Resolved SRC: $SRC_REAL"
echo "Resolved DST: $DST_REAL"
echo

[ "$SRC_REAL" != "$DST_REAL" ] || die "SRC and DST resolve to the same path"
is_path_prefix "$SRC_REAL" "$DST_REAL" && die "DST is inside SRC; refusing"
is_path_prefix "$DST_REAL" "$SRC_REAL" && die "SRC is inside DST; refusing"

# Lock to prevent concurrent runs against the same source path.
LOCK_FILE="$(dirname "$SRC_REAL")/.bulk_file_migrate.lock"
if [ -e "$LOCK_FILE" ]; then
  die "Lock file exists: $LOCK_FILE"
fi
trap 'rm -f "$LOCK_FILE"' EXIT
printf '%s\n' "$$" >"$LOCK_FILE"

if [ "$VERIFY_WITH_CHECKSUM" -eq 1 ]; then
  RSYNC_VERIFY_OPTS+=(--checksum)
fi

echo "$MAX_FOLDERS" | grep -Eq '^[0-9]+$' || die "MAX_FOLDERS must be a non-negative integer"

echo "DRY_DELETE=$DRY_DELETE"
echo "VERIFY_WITH_CHECKSUM=$VERIFY_WITH_CHECKSUM"
echo "MAX_FOLDERS=$MAX_FOLDERS"
echo

processed=0
copied_ok=0
verify_failed=0
copy_failed=0
delete_skipped=0
deleted=0

shopt -s nullglob
for src_dir in "$SRC_REAL"/*; do
  [ -d "$src_dir" ] || continue

  if [ "$MAX_FOLDERS" -gt 0 ] && [ "$processed" -ge "$MAX_FOLDERS" ]; then
    echo "Reached MAX_FOLDERS=$MAX_FOLDERS, stopping early."
    break
  fi

  processed=$((processed + 1))
  name="$(basename "$src_dir")"
  dst_dir="$DST_REAL/$name"

  echo "---- [$name] ----"
  echo "[1/3] Copying: $src_dir -> $dst_dir"
  if ! rsync "${RSYNC_COPY_OPTS[@]}" -- "$src_dir/" "$dst_dir/"; then
    copy_failed=$((copy_failed + 1))
    echo "Copy failed for: $name (skipping)"
    echo
    continue
  fi

  copied_ok=$((copied_ok + 1))

  echo "[2/3] Verifying: $name"
  if ! verify_out="$(rsync "${RSYNC_VERIFY_OPTS[@]}" -- "$src_dir/" "$dst_dir/")"; then
    verify_failed=$((verify_failed + 1))
    echo "Verify command failed for: $name (skipping delete)"
    echo
    continue
  fi

  if [ -n "$verify_out" ]; then
    verify_failed=$((verify_failed + 1))
    echo "VERIFY FAILED for: $name"
    echo "Differences:"
    echo "$verify_out"
    echo "Skipping delete for $name"
    echo
    continue
  fi

  echo "Verify OK: $name"
  echo "[3/3] Deleting source: $src_dir"
  if [ "$DRY_DELETE" -eq 1 ]; then
    delete_skipped=$((delete_skipped + 1))
    echo "DRY_DELETE=1, would delete: $src_dir"
  else
    safe_delete_dir "$src_dir"
    deleted=$((deleted + 1))
    echo "Deleted: $src_dir"
  fi

  echo
done

echo "== Migration complete =="
echo "Ended: $(date -Is)"
echo "Processed folders: $processed"
echo "Copy success: $copied_ok"
echo "Copy failures: $copy_failed"
echo "Verify failures: $verify_failed"
echo "Deleted: $deleted"
echo "Delete skipped (dry-run): $delete_skipped"
