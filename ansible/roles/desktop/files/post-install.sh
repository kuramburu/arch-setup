#!/usr/bin/env bash
set -euo pipefail

echo "=== 1. Bootstrapping Steam runtime ==="
if [ ! -d "$HOME/.local/share/Steam/ubuntu12_32" ]; then
    echo "Starting Steam in silent mode to fetch runtime components..."
    steam -silent &
    STEAM_PID=$!

    # Wait until Steam has generated its client directory
    until [ -d "$HOME/.local/share/Steam/ubuntu12_32" ]; do
        sleep 2
    done

    echo "Steam runtime initialized. Stopping background process..."
    kill "$STEAM_PID" 2>/dev/null || true
    wait "$STEAM_PID" 2>/dev/null || true
else
    echo "Steam runtime already initialized."
fi

echo "=== 2. Installing XLM (FFXIV) ==="
if ! command -v xlm &>/dev/null && [ ! -d "$HOME/.xlm" ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/Blooym/xlm/main/setup/install-native.sh)"
else
    echo "XLM is already installed."
fi

echo "=== Post-install tasks finished ==="
