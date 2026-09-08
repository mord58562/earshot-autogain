#!/bin/bash
# Build Earshot AutoGain, install it, and force macOS to register the plug-in.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Earshot AutoGain"
BUNDLE="$APP_NAME.app"
DEST="/Applications/$BUNDLE"

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Command Line Tools are not installed. Run: xcode-select --install"
    exit 1
fi

./build.sh

# A running copy holds the old extension registration open, so retire it first.
osascript -e "tell application \"$APP_NAME\" to quit" >/dev/null 2>&1 || true
if [ -d "$DEST" ]; then
    echo "Replacing existing install"
    rm -rf "$DEST"
fi

cp -R "$BUNDLE" "$DEST"

# macOS discovers Audio Unit extensions through pluginkit. It normally picks
# them up on first launch, but a rebuilt binary with an unchanged bundle ID is
# exactly the case where the cache goes stale, so nudge it explicitly and then
# flush the Audio Unit component cache.
echo "Registering the extension"
pluginkit -a "$DEST/Contents/PlugIns/AutoGainAU.appex" >/dev/null 2>&1 || true
killall -9 AudioComponentRegistrar >/dev/null 2>&1 || true

open "$DEST"

cat <<EOF

------------------------------------------------------------------
Installed to $DEST

The container app window will confirm whether macOS has picked the
component up. Once it reads "Registered", quit it - it does not need
to keep running for the plug-in to work.

In your host, look under Audio Unit Effects for:
  Earshot: AutoGain

Place it after any EQ or boost stage, so it sees the signal it is
meant to be protecting.

Hosts enumerate Audio Units at launch, so quit and reopen the host if
it was already running.
------------------------------------------------------------------
EOF
