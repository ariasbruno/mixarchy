#!/bin/bash -p
# install.sh — Automated, idempotent installer for Mixarchy (Omarchy plugin).
#
# Hardening:
#  * The interpreter is a fixed trusted path (/bin/bash, never `env` or PATH
#    resolution) invoked in privileged mode (-p), so Bash processes no
#    inherited BASH_ENV/ENV startup file and imports no exported functions
#    — from the very first process, before any script code runs.
#  * The script then re-executes itself through a sanitized environment
#    (`env -i`) with an explicit allow-list, so inherited PATH, LD_PRELOAD,
#    and other hostile variables are cleared and rebuilt before tools run.
#  * Required executables are resolved with executable-provenance checks:
#    every interpreter/tool is verified against lstat/resolved-path
#    expectations — a regular executable owned by root, without group/world
#    write bits, whose literal and resolved directory chains are root-owned
#    and non-group/world-writable — before use, and a required tool that
#    cannot be validated aborts the install. There is no unchecked fallback
#    and no home-directory fallback.
#  * The download is pinned to an immutable release tag and verified against a
#    pinned SHA-256 before install, and the temporary payload is only chmod'ed
#    + moved atomically after verification. Every acquisition path (local
#    build, Cargo fallback, staged copy) applies the same pinned digest check
#    before the bytes can reach the runtime.
#  * shell.json updates are written to a collision-resistant temp file
#    (exclusive creation, no-follow), fsynced, and atomically renamed.
set -euo pipefail

# --- Sanitized self re-exec bootstrap ---------------------------------------
# Re-run this script through a trusted fixed Bash with a cleared, reconstructed
# environment (HOME, XDG_RUNTIME_DIR, LANG, fixed PATH only). From this point on
# every tool is invoked by absolute path from fixed root-owned locations and no
# inherited startup file, exported function, or shadowed executable can run.
if [ -z "${OMARCHY_INSTALLER_SAFE_REEXEC:-}" ]; then
  if [ -x /bin/bash ]; then
    SAFE_BASH=/bin/bash
  else
    SAFE_BASH=/usr/bin/bash
  fi
  exec /usr/bin/env -i \
    OMARCHY_INSTALLER_SAFE_REEXEC=1 \
    HOME="$HOME" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
    LANG="${LANG:-C.UTF-8}" \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$SAFE_BASH" -p "$0" "$@"
fi

PLUGIN_ID="ariasbruno.mixarchy"
SRC_DIR="${BASH_SOURCE[0]%/*}"
[ "$SRC_DIR" = "${BASH_SOURCE[0]}" ] && SRC_DIR="."
PLUGIN_SRC="$(cd "$SRC_DIR" && pwd)"
TARGET_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

RELEASE_TAG="v1.1.1"
EXPECTED_SHA256="20ac824a623bcb237480375259a5551c0278f3ccd58795dd178b48b271f3a46b"
MAX_BYTES=10485760 # 10 MiB limit

# --- Trusted tool resolution (executable-provenance boundary) ----------------
# Every tool is verified with lstat/resolved-path checks: a regular executable
# owned by root (uid 0), with no group/world write bits, whose literal and
# resolved directory chains are root-owned and non-group/world-writable. Tools
# that cannot be validated abort the install; there is no user-writable
# fallback. `stat` and `readlink` are the verifier primitives and are resolved
# from fixed root-owned paths, then re-verified through the same checks.

STAT_BIN="/usr/bin/stat"
READLINK_BIN="/usr/bin/readlink"

if [ ! -x "$STAT_BIN" ] || [ ! -x "$READLINK_BIN" ]; then
  echo "  !! Error: coreutils verifiers ($STAT_BIN / $READLINK_BIN) not found. Aborting." >&2
  exit 1
fi

# Verify one directory: root-owned (uid 0) and with no group/world write bits.
is_trusted_dir() {
  local st kind owner mode
  st="$("$STAT_BIN" -c '%F|%u|%a' "$1" 2>/dev/null)" || return 1
  kind="${st%%|*}"
  owner="${st#*|}"; owner="${owner%%|*}"
  mode="${st##*|}"
  [ "$kind" = "directory" ] || return 1
  [ "$owner" = "0" ] || return 1
  [ -n "$mode" ] || return 1
  [ $(( 8#$mode & 022 )) -eq 0 ] || return 1
  return 0
}

# Verify a RESOLVED directory chain: every ancestor from $1 up to / must be a
# root-owned, non-group/world-writable directory. When passed a file path, its
# parent directory chain is verified instead.
is_trusted_chain() {
  local p="$1"
  [ -n "$p" ] || return 1
  p="$("$READLINK_BIN" -f "$p" 2>/dev/null)" || return 1
  if [ ! -d "$p" ]; then
    p="${p%/*}"
    [ -n "$p" ] || p="/"
  fi
  while :; do
    is_trusted_dir "$p" || return 1
    [ "$p" = "/" ] && break
    p="${p%/*}"
    [ -n "$p" ] || p="/"
  done
  return 0
}

# Verify the LITERAL directory chain of a candidate path: every ancestor as
# written must be a trusted directory, or a root-owned symlink whose target
# chain is itself trusted.
is_trusted_literal_chain() {
  local p="$1" owner
  [ -n "$p" ] || return 1
  p="${p%/*}"               # directory components only (no external dirname)
  [ -n "$p" ] || p="/"
  while :; do
    if [ -L "$p" ]; then
      owner="$("$STAT_BIN" -c '%u' "$p" 2>/dev/null)" || return 1
      [ "$owner" = "0" ] || return 1
      is_trusted_chain "$p" || return 1
    elif [ -d "$p" ]; then
      is_trusted_dir "$p" || return 1
    else
      return 1
    fi
    [ "$p" = "/" ] && break
    p="${p%/*}"
    [ -n "$p" ] || p="/"
  done
  return 0
}

# Verify one candidate executable: its resolved target must be a regular,
# root-owned, non-group/world-writable executable, and both the literal and
# resolved directory chains must be trusted.
is_trusted_executable() {
  local cand="$1" real st kind owner mode
  real="$("$READLINK_BIN" -f "$cand" 2>/dev/null)" || return 1
  [ -n "$real" ] || return 1
  st="$("$STAT_BIN" -c '%F|%u|%a' "$real" 2>/dev/null)" || return 1
  kind="${st%%|*}"
  owner="${st#*|}"; owner="${owner%%|*}"
  mode="${st##*|}"
  case "$kind" in
    regular*) ;;
    *) return 1 ;;
  esac
  [ "$owner" = "0" ] || return 1
  [ -n "$mode" ] || return 1
  [ $(( 8#$mode & 022 )) -eq 0 ] || return 1
  [ -x "$real" ] || return 1
  is_trusted_literal_chain "$cand" || return 1
  is_trusted_chain "$real" || return 1
  return 0
}

# Self-check the verifier primitives through the same provenance checks.
if ! is_trusted_executable "$STAT_BIN" || ! is_trusted_executable "$READLINK_BIN"; then
  echo "  !! Error: coreutils verifiers failed executable-provenance checks. Aborting." >&2
  exit 1
fi

# Resolve an executable from fixed trusted system locations only. Never
# consults the inherited PATH or user-writable directories. The final
# component may be a symlink, but only if it resolves to a trusted executable.
resolve_tool() {
  local name="$1" cand
  for cand in "/usr/bin/$name" "/bin/$name" "/usr/local/bin/$name"; do
    if { [ -e "$cand" ] || [ -L "$cand" ]; } && is_trusted_executable "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

# Resolve a required tool from trusted locations or fail. Prints the resolved
# path on success; on failure prints a diagnostic and returns non-zero. The
# caller MUST abort with `|| exit 1` so the fail-closed behavior never
# depends on `set -e` disposition for command substitutions, which is not
# portable across bash versions.
resolve_required() {
  local name="$1" resolved=""
  if ! resolved="$(resolve_tool "$name")"; then
    echo "  !! Error: required tool '$name' not found in trusted locations" >&2
    echo "     (/usr/bin, /bin, /usr/local/bin) or failed provenance checks. Aborting to keep the install fail-closed." >&2
    return 1
  fi
  printf '%s\n' "$resolved"
}

# The `|| exit 1` is deliberate: a failing command substitution inside an
# assignment does not reliably trigger `set -e` across bash versions, so the
# abort must be explicit. There is NO fixed-path fallback here: falling back to
# a tool that could not be validated would bypass the fail-closed hardening.
MKDIR_BIN="$(resolve_required mkdir)" || exit 1
CP_BIN="$(resolve_required cp)" || exit 1
RM_BIN="$(resolve_required rm)" || exit 1
MV_BIN="$(resolve_required mv)" || exit 1
CHMOD_BIN="$(resolve_required chmod)" || exit 1
MKTEMP_BIN="$(resolve_required mktemp)" || exit 1
DD_BIN="$(resolve_required dd)" || exit 1
CURL_BIN="$(resolve_tool curl || true)"
SHA256SUM_BIN="$(resolve_tool sha256sum || true)"
MPV_BIN="$(resolve_tool mpv || true)"
CARGO_BIN="$(resolve_tool cargo || true)" # no $HOME/.cargo/bin fallback: user-writable
JQ_BIN="$(resolve_tool jq || true)"
OMARCHY_BIN="$(resolve_tool omarchy || true)"

# Verify that a file's SHA-256 matches the pinned release digest.
verify_digest() {
  local file="$1" out actual
  [ -n "$SHA256SUM_BIN" ] || return 1
  out="$("$SHA256SUM_BIN" "$file" 2>/dev/null)" || return 1
  actual="${out%% *}"
  [ -n "$actual" ] && [ "$actual" = "$EXPECTED_SHA256" ]
}

# Atomically apply a jq transform to shell.json. The temp file is created in
# the destination directory with exclusive/no-follow semantics (mktemp), the
# transformed content is written and fsynced, and only then atomically renamed
# over the original. A symlinked shell.json is rejected as an unsafe
# destination type.
update_shell_json() {
  local jq_prog="$1" tmp_json orig_mode
  if [ -L "$SHELL_JSON" ]; then
    echo "  !! Error: $SHELL_JSON is a symlink; refusing to modify it." >&2
    return 1
  fi
  tmp_json="$("$MKTEMP_BIN" "$SHELL_JSON.tmp.XXXXXX")" || return 1
  orig_mode="$("$STAT_BIN" -c '%a' "$SHELL_JSON" 2>/dev/null || printf '644')"
  if ! "$JQ_BIN" "$jq_prog" "$SHELL_JSON" > "$tmp_json"; then
    "$RM_BIN" -f "$tmp_json"
    return 1
  fi
  if ! "$DD_BIN" if=/dev/null of="$tmp_json" conv=fsync,notrunc 2>/dev/null; then
    "$RM_BIN" -f "$tmp_json"
    return 1
  fi
  "$CHMOD_BIN" "$orig_mode" "$tmp_json"
  "$MV_BIN" -f "$tmp_json" "$SHELL_JSON" || { "$RM_BIN" -f "$tmp_json"; return 1; }
  return 0
}

uninstall() {
  echo "==> Uninstalling $PLUGIN_ID..."
  if [ -L "$TARGET_DIR" ] || [ -d "$TARGET_DIR" ]; then
    "$RM_BIN" -rf "$TARGET_DIR"
    echo "  - Removed plugin directory: $TARGET_DIR"
  fi

  if [ -f "$SHELL_JSON" ] && [ -n "$JQ_BIN" ]; then
    if "$JQ_BIN" -e '(.bar.layout.left[]?, .bar.layout.center[]?, .bar.layout.right[]?) | select(.id == "'"$PLUGIN_ID"'")' "$SHELL_JSON" >/dev/null 2>&1; then
      update_shell_json '
        .bar.layout.left |= map(select(.id != "'"$PLUGIN_ID"'")) |
        .bar.layout.center |= map(select(.id != "'"$PLUGIN_ID"'")) |
        .bar.layout.right |= map(select(.id != "'"$PLUGIN_ID"'"))
      ' || return 1
      echo "  - Removed $PLUGIN_ID from $SHELL_JSON"
    fi
  fi

  if [ -n "$OMARCHY_BIN" ]; then
    "$OMARCHY_BIN" restart shell 2>/dev/null || true
  fi
  echo "==> Uninstalled successfully."
  exit 0
}

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
  uninstall
fi

echo "==> Installing Mixarchy plugin ($PLUGIN_ID)..."

# 1. Dependency check: mpv
if [ -z "$MPV_BIN" ]; then
  echo "  ! mpv is required but not installed."
  echo "  ! Install it manually, e.g.: sudo pacman -S mpv"
  echo "  ! Then re-run ./install.sh"
  exit 1
else
  echo "  ✓ mpv detected"
fi

# Verify backend binary. Every acquisition path (in-place, local build, Cargo
# fallback) must satisfy the same pinned digest check before its bytes are
# staged into bin/; a mismatching local build is discarded and re-acquired.
BIN_VERIFIED=0
if [ -x "$PLUGIN_SRC/bin/mixarchy-ctl" ] && [ -n "$SHA256SUM_BIN" ] && verify_digest "$PLUGIN_SRC/bin/mixarchy-ctl"; then
  echo "  ✓ mixarchy-ctl binary verified ($RELEASE_TAG, sha256 match)"
  BIN_VERIFIED=1
else
  echo "  ! Stale or unpinned binary detected in bin/ — re-acquiring verified binary"
fi

if [ "$BIN_VERIFIED" -eq 1 ]; then
  : # Pinned binary already in place and verified
elif [ -x "$PLUGIN_SRC/target/release/mixarchy-ctl" ] && verify_digest "$PLUGIN_SRC/target/release/mixarchy-ctl"; then
  echo "  ✓ mixarchy-ctl local build detected and digest verified ($PLUGIN_SRC/target/release/mixarchy-ctl)"
  "$MKDIR_BIN" -p "$PLUGIN_SRC/bin"
  "$CP_BIN" "$PLUGIN_SRC/target/release/mixarchy-ctl" "$PLUGIN_SRC/bin/mixarchy-ctl"
  echo "  ✓ Staged local release binary into bin/"
else
  DOWNLOAD_OK=0
  if [ -n "$CURL_BIN" ] && [ -n "$SHA256SUM_BIN" ]; then
    echo "  -> Downloading precompiled mixarchy-ctl binary ($RELEASE_TAG)..."
    "$MKDIR_BIN" -p "$PLUGIN_SRC/bin"
    # Collision-resistant temp file with exclusive creation so a pre-existing
    # symlink at a predictable name cannot redirect the download write.
    TMP_BIN="$("$MKTEMP_BIN" "$PLUGIN_SRC/bin/mixarchy-ctl.tmp.XXXXXX")" || exit 1

    if "$CURL_BIN" -fsSL \
         --connect-timeout 10 \
         --max-time 120 \
         --max-filesize "$MAX_BYTES" \
         "https://github.com/ariasbruno/mixarchy/releases/download/${RELEASE_TAG}/mixarchy-ctl" \
         -o "$TMP_BIN"; then
      SHA256_OUT="$("$SHA256SUM_BIN" "$TMP_BIN")" || {
        echo "  ! Error: sha256sum failed to verify the downloaded binary; aborting." >&2
        "$RM_BIN" -f "$TMP_BIN"
        exit 1
      }
      ACTUAL_SHA256="${SHA256_OUT%% *}"
      if [ -n "$ACTUAL_SHA256" ] && [ "$EXPECTED_SHA256" = "$ACTUAL_SHA256" ]; then
        "$CHMOD_BIN" 755 "$TMP_BIN"
        "$MV_BIN" -f "$TMP_BIN" "$PLUGIN_SRC/bin/mixarchy-ctl"
        echo "  ✓ Pinned release binary ($RELEASE_TAG) verified and installed (sha256)"
        DOWNLOAD_OK=1
      else
        echo "  ! Error: Checksum mismatch. Expected $EXPECTED_SHA256, got $ACTUAL_SHA256"
        "$RM_BIN" -f "$TMP_BIN"
      fi
    else
      echo "  ! Release binary download failed or exceeded safety limits."
      "$RM_BIN" -f "$TMP_BIN"
    fi
  fi

  if [ "$DOWNLOAD_OK" -ne 1 ]; then
    if [ -n "$CARGO_BIN" ]; then
      echo "  -> Building mixarchy-ctl via Cargo (verified fallback)..."
      "$CARGO_BIN" build --release --locked --manifest-path "$PLUGIN_SRC/Cargo.toml"
      if ! verify_digest "$PLUGIN_SRC/target/release/mixarchy-ctl"; then
        echo "  ! Error: locally built binary does not match the pinned release checksum ($EXPECTED_SHA256)." >&2
        echo "    Refusing to install unreviewed bytes. Remove local target/ or install from the pinned release." >&2
        "$RM_BIN" -f "$PLUGIN_SRC/target/release/mixarchy-ctl"
        exit 1
      fi
      "$MKDIR_BIN" -p "$PLUGIN_SRC/bin"
      "$CP_BIN" "$PLUGIN_SRC/target/release/mixarchy-ctl" "$PLUGIN_SRC/bin/mixarchy-ctl"
      echo "  ✓ Compiled mixarchy-ctl binary ready and digest verified"
    else
      echo "  ! Error: Could not obtain a verified mixarchy-ctl binary (download failed and cargo is not installed)." >&2
      exit 1
    fi
  fi
fi

# 2. Install plugin into Omarchy user plugins directory
#    Copy (not symlink) so the plugin lives fully inside ~/.config/omarchy/plugins/<id>/,
#    matching the marketplace contract and surviving moves/deletes of this repo.
"$MKDIR_BIN" -p "$HOME/.config/omarchy/plugins"
# Remove a stale symlink from an older dev-installer if present, so it is
# replaced by a real directory copy.
if [ -L "$TARGET_DIR" ]; then
  "$RM_BIN" -f "$TARGET_DIR"
fi
"$MKDIR_BIN" -p "$TARGET_DIR"
if [ "$PLUGIN_SRC" = "$TARGET_DIR" ]; then
  # In-place (re)install: skip self-copy to avoid `cp: same file`; the
  # upgrade-integrity block above already re-acquired the pinned binary.
  echo "  → In-place install (PLUGIN_SRC == TARGET_DIR), skipping self-copy"
else
  "$CP_BIN" -f "$PLUGIN_SRC/manifest.json" "$TARGET_DIR/"
  "$CP_BIN" -f "$PLUGIN_SRC/Panel.qml" "$TARGET_DIR/"
  "$MKDIR_BIN" -p "$TARGET_DIR/bin"
  # Final pinned-digest gate: refuse to copy staged bytes that do not match the
  # reviewed release binary, regardless of how they were acquired.
  if ! verify_digest "$PLUGIN_SRC/bin/mixarchy-ctl"; then
    echo "  ! Error: staged bin/mixarchy-ctl failed final digest verification. Aborting." >&2
    exit 1
  fi
  "$CP_BIN" -f "$PLUGIN_SRC/bin/mixarchy-ctl" "$TARGET_DIR/bin/"
  "$CP_BIN" -f "$PLUGIN_SRC/README.md" "$PLUGIN_SRC/LICENSE" "$TARGET_DIR/" 2>/dev/null || true
  "$CHMOD_BIN" +x "$TARGET_DIR/bin/mixarchy-ctl"
fi
echo "  ✓ Installed plugin: $TARGET_DIR"

# 3. Register widget in shell.json idempotently
if [ -f "$SHELL_JSON" ] && [ -n "$JQ_BIN" ]; then
  if ! "$JQ_BIN" -e '(.bar.layout.left[]?, .bar.layout.center[]?, .bar.layout.right[]?) | select(.id == "'"$PLUGIN_ID"'")' "$SHELL_JSON" >/dev/null 2>&1; then
    echo "  -> Registering $PLUGIN_ID in $SHELL_JSON..."
    if ! update_shell_json '
      if (.bar.layout.right | map(.id) | contains(["omarchy.audio"])) then
        .bar.layout.right |= reduce .[] as $item ([]; if $item.id == "omarchy.audio" then . + [{"id": "'"$PLUGIN_ID"'"}, $item] else . + [$item] end)
      else
        .bar.layout.right += [{"id": "'"$PLUGIN_ID"'"}]
      end
    '; then
      echo "  ! Error: could not update $SHELL_JSON atomically. Aborting." >&2
      exit 1
    fi
    echo "  ✓ Added $PLUGIN_ID to bar layout (right section)"
  else
    echo "  ✓ Already registered in $SHELL_JSON"
  fi
fi

# 4. Restart the Omarchy shell so the new widget loads. Use `restart`, NOT
#    `refresh`: refresh resets ~/.config/omarchy/shell.json to Omarchy defaults
#    and would wipe the user's bar layout.
if [ -n "$OMARCHY_BIN" ]; then
  echo "  -> Restarting Omarchy shell..."
  "$OMARCHY_BIN" restart shell 2>/dev/null || true
fi

echo "==> Mixarchy installed successfully."