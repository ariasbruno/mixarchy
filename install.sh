#!/usr/bin/env bash
# install.sh — Automated, idempotent installer for Mixarchy (Omarchy plugin).
set -euo pipefail

PLUGIN_ID="ariasbruno.mixarchy"
PLUGIN_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"

uninstall() {
  echo "==> Uninstalling $PLUGIN_ID..."
  if [ -L "$TARGET_DIR" ] || [ -d "$TARGET_DIR" ]; then
    rm -rf "$TARGET_DIR"
    echo "  - Removed plugin directory: $TARGET_DIR"
  fi

  if [ -f "$SHELL_JSON" ] && command -v jq >/dev/null 2>&1; then
    if jq -e '.bar.layout.right[] | select(.id == "'"$PLUGIN_ID"'")' "$SHELL_JSON" >/dev/null 2>&1; then
      jq '.bar.layout.right |= map(select(.id != "'"$PLUGIN_ID"'"))' "$SHELL_JSON" > "$SHELL_JSON.tmp"
      mv "$SHELL_JSON.tmp" "$SHELL_JSON"
      echo "  - Removed $PLUGIN_ID from $SHELL_JSON"
    fi
  fi

  if command -v omarchy >/dev/null 2>&1; then
    omarchy restart shell 2>/dev/null || true
  fi
  echo "==> Uninstalled successfully."
  exit 0
}

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "-u" ]; then
  uninstall
fi

echo "==> Installing Mixarchy plugin ($PLUGIN_ID)..."

# 1. Dependency check: mpv
if ! command -v mpv >/dev/null 2>&1; then
  echo "  ! mpv is required but not installed."
  echo "  ! Install it manually, e.g.: sudo pacman -S mpv"
  echo "  ! Then re-run ./install.sh"
  exit 1
else
  echo "  ✓ mpv detected"
fi

# Verify backend binary
if [ -x "$PLUGIN_SRC/bin/mixarchy-ctl" ]; then
  echo "  ✓ mixarchy-ctl binary ready ($PLUGIN_SRC/bin/mixarchy-ctl)"
elif [ -x "$PLUGIN_SRC/target/release/mixarchy-ctl" ]; then
  echo "  ✓ mixarchy-ctl binary ready ($PLUGIN_SRC/target/release/mixarchy-ctl)"
  mkdir -p "$PLUGIN_SRC/bin"
  cp "$PLUGIN_SRC/target/release/mixarchy-ctl" "$PLUGIN_SRC/bin/mixarchy-ctl"
  echo "  ✓ Staged release binary into bin/"
  DOWNLOAD_OK=0
  if command -v curl >/dev/null 2>&1; then
    echo "  -> Downloading precompiled mixarchy-ctl binary (v1.0.0)..."
    RELEASE_TAG="v1.0.0"
    EXPECTED_SHA256="d0c66ca6859d4c1777d05c1b508e88bc69a40322f9d0696d7e7e0c525eebec25"
    MAX_BYTES=10485760 # 10 MiB limit
    TMP_BIN="$PLUGIN_SRC/bin/mixarchy-ctl.tmp.$$"

    mkdir -p "$PLUGIN_SRC/bin"
    rm -f "$TMP_BIN"

    if curl -fsSL \
         --connect-timeout 10 \
         --max-time 120 \
         --max-filesize "$MAX_BYTES" \
         "https://github.com/ariasbruno/mixarchy/releases/download/${RELEASE_TAG}/mixarchy-ctl" \
         -o "$TMP_BIN" && \
       command -v sha256sum >/dev/null 2>&1; then
      ACTUAL_SHA256=$(sha256sum "$TMP_BIN" | awk '{print $1}')
      if [ -n "$ACTUAL_SHA256" ] && [ "$EXPECTED_SHA256" = "$ACTUAL_SHA256" ]; then
        chmod 755 "$TMP_BIN"
        mv -f "$TMP_BIN" "$PLUGIN_SRC/bin/mixarchy-ctl"
        echo "  ✓ Pinned release binary ($RELEASE_TAG) verified and installed (sha256)"
        DOWNLOAD_OK=1
      else
        echo "  ! Error: Checksum mismatch. Expected $EXPECTED_SHA256, got $ACTUAL_SHA256"
        rm -f "$TMP_BIN"
      fi
    else
      echo "  ! Release binary download failed or exceeded safety limits."
      rm -f "$TMP_BIN"
    fi
  fi

  if [ "$DOWNLOAD_OK" -ne 1 ]; then
    if command -v cargo >/dev/null 2>&1; then
      echo "  -> Building mixarchy-ctl binary via Cargo (Rust fallback)..."
      cargo build --release --locked --manifest-path "$PLUGIN_SRC/Cargo.toml"
      mkdir -p "$PLUGIN_SRC/bin"
      cp "$PLUGIN_SRC/target/release/mixarchy-ctl" "$PLUGIN_SRC/bin/mixarchy-ctl"
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
mkdir -p "$HOME/.config/omarchy/plugins"
# Remove a stale symlink from an older dev-installer if present, so it is
# replaced by a real directory copy.
if [ -L "$TARGET_DIR" ]; then
  rm -f "$TARGET_DIR"
fi
mkdir -p "$TARGET_DIR"
cp -f "$PLUGIN_SRC/manifest.json" "$TARGET_DIR/"
cp -f "$PLUGIN_SRC/Panel.qml" "$TARGET_DIR/"
mkdir -p "$TARGET_DIR/bin"
cp -f "$PLUGIN_SRC/bin/mixarchy-ctl" "$TARGET_DIR/bin/"
cp -f "$PLUGIN_SRC/README.md" "$PLUGIN_SRC/LICENSE" "$TARGET_DIR/" 2>/dev/null || true
chmod +x "$TARGET_DIR/bin/mixarchy-ctl"
echo "  ✓ Installed plugin: $TARGET_DIR"

# 3. Register widget in shell.json idempotently
if [ -f "$SHELL_JSON" ] && command -v jq >/dev/null 2>&1; then
  if ! jq -e '.bar.layout.right[] | select(.id == "'"$PLUGIN_ID"'")' "$SHELL_JSON" >/dev/null 2>&1; then
    echo "  -> Registering $PLUGIN_ID in $SHELL_JSON..."
    jq '
      if (.bar.layout.right | map(.id) | contains(["omarchy.audio"])) then
        .bar.layout.right |= reduce .[] as $item ([]; if $item.id == "omarchy.audio" then . + [{"id": "'"$PLUGIN_ID"'"}, $item] else . + [$item] end)
      else
        .bar.layout.right += [{"id": "'"$PLUGIN_ID"'"}]
      end
    ' "$SHELL_JSON" > "$SHELL_JSON.tmp"
    mv "$SHELL_JSON.tmp" "$SHELL_JSON"
    echo "  ✓ Added $PLUGIN_ID to bar layout (right section)"
  else
    echo "  ✓ Already registered in $SHELL_JSON"
  fi
fi

# 4. Restart the Omarchy shell so the new widget loads. Use `restart`, NOT
#    `refresh`: refresh resets ~/.config/omarchy/shell.json to Omarchy defaults
#    and would wipe the user's bar layout.
if command -v omarchy >/dev/null 2>&1; then
  echo "  -> Restarting Omarchy shell..."
  omarchy restart shell 2>/dev/null || true
fi

echo "==> Mixarchy installed successfully."
