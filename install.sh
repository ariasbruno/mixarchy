#!/usr/bin/env bash
# install.sh — Automated, idempotent installer for Mixarchy (Omarchy plugin).
#
# Hardening: required executables are resolved from fixed root-owned system
# locations (never the inherited PATH), the download is pinned to an immutable
# release tag and verified against a pinned SHA-256 before install, and the
# temporary payload is only chmod'ed + moved atomically after verification.
set -euo pipefail

PLUGIN_ID="ariasbruno.mixarchy"
PLUGIN_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

RELEASE_TAG="v1.1.1"
EXPECTED_SHA256="20ac824a623bcb237480375259a5551c0278f3ccd58795dd178b48b271f3a46b"
MAX_BYTES=10485760 # 10 MiB limit

# Resolve an executable from fixed trusted locations only. Never consults the
# inherited PATH.
resolve_tool() {
  local name="$1" cand
  for cand in "/usr/bin/$name" "/bin/$name" "/usr/local/bin/$name"; do
    if [ -f "$cand" ] && [ -x "$cand" ]; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

TEST_BIN="$(resolve_tool test || echo /usr/bin/test)"
MKDIR_BIN="$(resolve_tool mkdir || echo /usr/bin/mkdir)"
CP_BIN="$(resolve_tool cp || echo /usr/bin/cp)"
RM_BIN="$(resolve_tool rm || echo /usr/bin/rm)"
MV_BIN="$(resolve_tool mv || echo /usr/bin/mv)"
CHMOD_BIN="$(resolve_tool chmod || echo /usr/bin/chmod)"
CURL_BIN="$(resolve_tool curl || true)"
SHA256SUM_BIN="$(resolve_tool sha256sum || true)"
MPV_BIN="$(resolve_tool mpv || true)"
CARGO_BIN="$(resolve_tool cargo || true)"
JQ_BIN="$(resolve_tool jq || true)"
OMARCHY_BIN="$(resolve_tool omarchy || true)"

uninstall() {
  echo "==> Uninstalling $PLUGIN_ID..."
  if [ -L "$TARGET_DIR" ] || [ -d "$TARGET_DIR" ]; then
    "$RM_BIN" -rf "$TARGET_DIR"
    echo "  - Removed plugin directory: $TARGET_DIR"
  fi

  if [ -f "$SHELL_JSON" ] && [ -n "$JQ_BIN" ]; then
    if "$JQ_BIN" -e '.bar.layout.right[] | select(.id == "'"$PLUGIN_ID"'")' "$SHELL_JSON" >/dev/null 2>&1; then
      "$JQ_BIN" '.bar.layout.right |= map(select(.id != "'"$PLUGIN_ID"'"))' "$SHELL_JSON" > "$SHELL_JSON.tmp"
      "$MV_BIN" "$SHELL_JSON.tmp" "$SHELL_JSON"
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

# Verify backend binary
BIN_VERIFIED=0
if [ -x "$PLUGIN_SRC/bin/mixarchy-ctl" ] && [ -n "$SHA256SUM_BIN" ]; then
  SHA256_CURRENT="$("$SHA256SUM_BIN" "$PLUGIN_SRC/bin/mixarchy-ctl" 2>/dev/null || true)"
  if [ "${SHA256_CURRENT%% *}" = "$EXPECTED_SHA256" ]; then
    echo "  ✓ mixarchy-ctl binary verified ($RELEASE_TAG, sha256 match)"
    BIN_VERIFIED=1
  else
    echo "  ! Stale or unpinned binary detected in bin/ — re-acquiring verified binary"
  fi
fi

if [ "$BIN_VERIFIED" -eq 1 ]; then
  : # Pinned binary already in place and verified
elif [ -x "$PLUGIN_SRC/target/release/mixarchy-ctl" ]; then
  echo "  ✓ mixarchy-ctl local build detected ($PLUGIN_SRC/target/release/mixarchy-ctl)"
  "$MKDIR_BIN" -p "$PLUGIN_SRC/bin"
  "$CP_BIN" "$PLUGIN_SRC/target/release/mixarchy-ctl" "$PLUGIN_SRC/bin/mixarchy-ctl"
  echo "  ✓ Staged local release binary into bin/"
else
  DOWNLOAD_OK=0
  if [ -n "$CURL_BIN" ] && [ -n "$SHA256SUM_BIN" ]; then
    echo "  -> Downloading precompiled mixarchy-ctl binary ($RELEASE_TAG)..."
    TMP_BIN="$PLUGIN_SRC/bin/mixarchy-ctl.tmp.$$"

    "$MKDIR_BIN" -p "$PLUGIN_SRC/bin"
    "$RM_BIN" -f "$TMP_BIN"

    if "$CURL_BIN" -fsSL \
         --connect-timeout 10 \
         --max-time 120 \
         --max-filesize "$MAX_BYTES" \
         "https://github.com/ariasbruno/mixarchy/releases/download/${RELEASE_TAG}/mixarchy-ctl" \
         -o "$TMP_BIN"; then
      SHA256_OUT="$("$SHA256SUM_BIN" "$TMP_BIN")"
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
      echo "  -> Building mixarchy-ctl binary via Cargo (Rust fallback)..."
      "$CARGO_BIN" build --release --locked --manifest-path "$PLUGIN_SRC/Cargo.toml"
      "$MKDIR_BIN" -p "$PLUGIN_SRC/bin"
      "$CP_BIN" "$PLUGIN_SRC/target/release/mixarchy-ctl" "$PLUGIN_SRC/bin/mixarchy-ctl"
      echo "  ✓ Compiled mixarchy-ctl binary ready"
    else
      echo "  ! Error: Could not obtain mixarchy-ctl binary (download failed and cargo is not installed)."
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
  "$CP_BIN" -f "$PLUGIN_SRC/bin/mixarchy-ctl" "$TARGET_DIR/bin/"
  "$CP_BIN" -f "$PLUGIN_SRC/README.md" "$PLUGIN_SRC/LICENSE" "$TARGET_DIR/" 2>/dev/null || true
  "$CHMOD_BIN" +x "$TARGET_DIR/bin/mixarchy-ctl"
fi
echo "  ✓ Installed plugin: $TARGET_DIR"

# 3. Register widget in shell.json idempotently
if [ -f "$SHELL_JSON" ] && [ -n "$JQ_BIN" ]; then
  if ! "$JQ_BIN" -e '.bar.layout.right[] | select(.id == "'"$PLUGIN_ID"'")' "$SHELL_JSON" >/dev/null 2>&1; then
    echo "  -> Registering $PLUGIN_ID in $SHELL_JSON..."
    "$JQ_BIN" '
      if (.bar.layout.right | map(.id) | contains(["omarchy.audio"])) then
        .bar.layout.right |= reduce .[] as $item ([]; if $item.id == "omarchy.audio" then . + [{"id": "'"$PLUGIN_ID"'"}, $item] else . + [$item] end)
      else
        .bar.layout.right += [{"id": "'"$PLUGIN_ID"'"}]
      end
    ' "$SHELL_JSON" > "$SHELL_JSON.tmp"
    "$MV_BIN" "$SHELL_JSON.tmp" "$SHELL_JSON"
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