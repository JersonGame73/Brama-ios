#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$PROJECT_ROOT/MadeiraRuntime"

if [ -f "$RUNTIME_DIR/libmadeira.dylib" ] && [ -d "$RUNTIME_DIR/arm64ec-windows" ]; then
    echo "[Brama] MadeiraRuntime already staged at $RUNTIME_DIR"
    exit 0
fi

echo "[Brama] Downloading and staging Madeira 0.1.3 iOS Runtime (Wine ARM64EC + FEX-Emu + DXMT Metal)..."
TMP_IPA="/tmp/Madeira-0.1.3.ipa"
TMP_EXTRACT="/tmp/Madeira-ipa-extract"

if [ ! -f "$TMP_IPA" ]; then
    curl -L --fail -o "$TMP_IPA" "https://github.com/willfaust/Madeira/releases/download/v0.1.3/Madeira-0.1.3.ipa"
fi

rm -rf "$TMP_EXTRACT"
mkdir -p "$TMP_EXTRACT"
unzip -q -o "$TMP_IPA" -d "$TMP_EXTRACT"

APP_PAYLOAD="$TMP_EXTRACT/Payload/Madeira.app"
mkdir -p "$RUNTIME_DIR"

cp -f "$APP_PAYLOAD/Madeira.debug.dylib" "$RUNTIME_DIR/libmadeira.dylib"

# Patch _init_syscall_frame M8 page0 debugger trap (brk #0xf00d at 0x996820 -> mov x0, #0)
# so Xcode lldb does not pause before Wine installs its Mach exception port handler.
python3 - "$RUNTIME_DIR/libmadeira.dylib" << 'EOF'
import sys
path = sys.argv[1]
with open(path, "r+b") as f:
    f.seek(0x996820)
    orig = f.read(4)
    if orig == bytes.fromhex("a0013ed4"):
        f.seek(0x996820)
        f.write(bytes.fromhex("000080d2"))
        print("[Brama] Patched _init_syscall_frame brk #0xf00d -> mov x0, #0")
EOF

install_name_tool -id "@rpath/libmadeira.dylib" "$RUNTIME_DIR/libmadeira.dylib" || true

rsync -a "$APP_PAYLOAD/arm64ec-windows" "$RUNTIME_DIR/"
rsync -a "$APP_PAYLOAD/aarch64-windows" "$RUNTIME_DIR/"
rsync -a "$APP_PAYLOAD/d3d12" "$RUNTIME_DIR/"
rsync -a "$APP_PAYLOAD/nls" "$RUNTIME_DIR/"
cp -f "$APP_PAYLOAD/prefix-template.tar.gz" "$RUNTIME_DIR/"
cp -f "$APP_PAYLOAD/default.metallib" "$RUNTIME_DIR/"
cp -f "$APP_PAYLOAD/cacert.pem" "$RUNTIME_DIR/"
cp -f "$APP_PAYLOAD/madeira-jit.js" "$RUNTIME_DIR/"

xattr -cr "$RUNTIME_DIR"
codesign -f -s - "$RUNTIME_DIR/libmadeira.dylib"
codesign -f -s - "$RUNTIME_DIR/d3d12/libmetalirconverter.dylib"

rm -rf "$TMP_EXTRACT"
echo "[Brama] MadeiraRuntime staged successfully at $RUNTIME_DIR"
