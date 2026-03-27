#!/bin/bash
set -euo pipefail

# Build script for creating the Netbird QPKG
# Handles QDK setup so qbuild finds everything where it expects it

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
QPKG_DIR="${SCRIPT_DIR}/qpkg"
QDK_DIR="${QPKG_DIR}/QDK"

# Clone QDK into the location qbuild expects (inside the package root)
if [ ! -d "$QDK_DIR" ]; then
    echo "Cloning QDK..."
    git clone --depth 1 https://github.com/qnap-dev/QDK.git /tmp/qdk
    ln -sf /tmp/qdk/shared "$QDK_DIR"
fi

# Compile qpkg_encrypt if not already available
if ! command -v qpkg_encrypt &>/dev/null; then
    echo "Building qpkg_encrypt..."
    make -C /tmp/qdk/src
    sudo cp /tmp/qdk/src/bin/qpkg_encrypt /usr/local/bin/
fi

# Install system deps if missing
for cmd in rsync hexdump; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Installing missing dependency: $cmd"
        sudo apt-get install -y rsync bsdmainutils
        break
    fi
done

echo "Building QPKG..."
cd "$QPKG_DIR"
"${QDK_DIR}/bin/qbuild" --root .

echo "Build complete. Output:"
find "${QPKG_DIR}/build" -name "*.qpkg" -type f 2>/dev/null
