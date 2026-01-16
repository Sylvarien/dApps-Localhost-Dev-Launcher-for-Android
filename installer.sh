#!/data/data/com.termux/files/usr/bin/env bash
# DApps Localhost Launcher — OFFICIAL INSTALLER
# Target  : Termux
# Mode    : Clean install / overwrite lama
# Version : Installer v1.0
set -e

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BIN="$PREFIX/bin"
TARGET="$BIN/dapps"

echo "== DApps Launcher Installer =="
echo

# 1. Pastikan folder bin ada
mkdir -p "$BIN"

# 2. Kill dapps lama kalau masih hidup
pkill -f dapps 2>/dev/null || true

# 3. Backup binary lama (kalau ada)
if [ -f "$TARGET" ]; then
  echo "• Backup dapps lama -> dapps.bak"
  mv "$TARGET" "$TARGET.bak"
fi

# 4. Download launcher terbaru (FULL REWRITE)
TMP="$(mktemp -t dapps.XXXXXX)"
curl -fsSL \
https://raw.githubusercontent.com/Sylvarien/dApps-Localhost-Dev-Launcher-for-Android/main/launcher_website.sh \
-o "$TMP"

# 5. Pastikan shebang Termux
sed -i '1c #!/data/data/com.termux/files/usr/bin/env bash' "$TMP"

# 6. Pasang binary
chmod +x "$TMP"
mv "$TMP" "$TARGET"
chmod +x "$TARGET"

# 7. Reset shell cache
hash -r

# 8. Verifikasi
if command -v dapps >/dev/null 2>&1; then
  echo
  echo "✓ INSTALL SUKSES"
  echo "✓ Lokasi : $TARGET"
  echo
  echo "Jalankan:"
  echo "  dapps"
else
  echo
  echo "✗ INSTALL GAGAL"
  echo "Cek permission $BIN"
  exit 1
fi
