#!/bin/bash
# Runs inside an archlinux container with the repository mounted at /src.
# Usage: build-in-arch.sh <subtarget> <executable> <variant: znver3|generic> <host-uid:gid>
#   znver3  -> -march=znver3 build, packaged as a CachyOS/Arch .pkg.tar.zst
#   generic -> baseline x86-64 build, packaged as an AppImage
set -euo pipefail

SUBTARGET=$1 EXE=$2 VARIANT=$3 OWNER=$4
cd /src
git config --global --add safe.directory /src

pacman -Syu --noconfirm --needed base-devel git python sdl2 sdl2_ttf fontconfig \
  alsa-lib libpulse libxinerama libxi zstd file wget desktop-file-utils patchelf >/dev/null

ARCHOPTS='-U_FORTIFY_SOURCE'
if [ "$VARIANT" = znver3 ]; then
  ARCHOPTS="-march=znver3 -mtune=znver3 $ARCHOPTS"
fi

mkdir -p dist
set +e
make -j"$(nproc)" SUBTARGET="$SUBTARGET" TOOLS=1 NOWERROR=1 USE_QTDEBUG=0 ARCHOPTS="$ARCHOPTS" 2>&1 | tee build.log
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" -ne 0 ]; then
  # Surface the first real errors as workflow annotations (job logs may not be downloadable)
  echo "make failed with exit code $rc, first errors:"
  grep -nE "error:|Error [0-9]+|\*\*\* |undefined reference|No such file|fatal" build.log | head -8 | while IFS= read -r l; do
    echo "::error::$(printf '%s' "$l" | cut -c1-400)"
  done
  tail -n 15 build.log | while IFS= read -r l; do echo "::warning::$(printf '%s' "$l" | cut -c1-300)"; done
  tail -n 400 build.log > "dist/build-failure-tail.log"; chown -R "$OWNER" dist build.log
  exit "$rc"
fi
./"$EXE" -version

VER=$(./"$EXE" -version | awk '{print $1}' | tr -c 'A-Za-z0-9._\n' '_')
DATE=$(date -u +%Y%m%d)
SHORT=${GITHUB_SHA:0:8}
strip "$EXE" chdman romcmp unidasm

# Shared install tree: /usr/lib/<exe> holds the binaries and data files.
stage_tree() {
  local root=$1 lib=$1/usr/lib/$EXE
  mkdir -p "$lib" "$root/usr/bin"
  cp "$EXE" chdman romcmp unidasm "$lib/"
  cp -r hash ini plugins language keymaps ctrlr artwork bgfx hlsl samples uismall.bdf COPYING "$lib/" 2>/dev/null || true
  for t in chdman romcmp unidasm; do ln -sf "../lib/$EXE/$t" "$root/usr/bin/$t-$EXE"; done
}

OPTS='-inipath "$HOME/.mame;$D/ini" -hashpath "$D/hash" -pluginspath "$D/plugins" -languagepath "$D/language" -artpath "$HOME/.mame/artwork;$D/artwork" -ctrlrpath "$D/ctrlr" -bgfx_path "$D/bgfx" -samplepath "$HOME/.mame/samples;$D/samples"'

mkdir -p dist
if [ "$VARIANT" = znver3 ]; then
  # ---------- CachyOS / Arch package ----------
  ROOT=$PWD/pkgwork/stage
  rm -rf pkgwork && mkdir -p "$ROOT"
  stage_tree "$ROOT"
  cat > "$ROOT/usr/bin/$EXE" <<WRAP
#!/bin/sh
D=/usr/lib/$EXE
exec "\$D/$EXE" $OPTS "\$@"
WRAP
  chmod 755 "$ROOT/usr/bin/$EXE"
  PROVIDES=$EXE; [ "$EXE" = mame ] && PROVIDES=mame
  DESC="MAME full"; [ "$SUBTARGET" = arcade ] && DESC="MAME arcade-only"
  cat > pkgwork/PKGBUILD <<PKG
pkgname=$EXE-znver3
pkgver=$VER.$DATE
pkgrel=1
pkgdesc="$DESC build optimized for AMD Zen 3 (-march=znver3), commit $SHORT"
arch=(x86_64)
url=https://github.com/Paolo86cripple/mame
license=(GPL-2.0-or-later BSD-3-Clause)
depends=(sdl2 sdl2_ttf fontconfig alsa-lib libpulse libxinerama libxi)
provides=($PROVIDES)
conflicts=($PROVIDES)
options=(!strip !debug !lto)
package() { cp -a "\$startdir/stage/." "\$pkgdir/"; }
PKG
  useradd -m builder 2>/dev/null || true
  chown -R builder pkgwork
  (cd pkgwork && su builder -c 'makepkg -f --nodeps --nocheck --skipinteg')
  cp pkgwork/*.pkg.tar.zst dist/
else
  # ---------- AppImage ----------
  rm -rf AppDir && mkdir -p AppDir
  stage_tree AppDir
  cat > AppDir/AppRun <<RUN
#!/bin/sh
HERE="\$(dirname "\$(readlink -f "\$0")")"
D="\$HERE/usr/lib/$EXE"
exec "\$D/$EXE" $OPTS "\$@"
RUN
  chmod 755 AppDir/AppRun
  cp docs/source/images/MAMElogo.svg "AppDir/$EXE.svg"
  cat > "AppDir/$EXE.desktop" <<DESK
[Desktop Entry]
Type=Application
Name=$EXE
Comment=Multiple Arcade Machine Emulator
Exec=AppRun
Icon=$EXE
Categories=Game;Emulator;
Terminal=false
DESK
  # SOURCE_DATE_EPOCH breaks appimagetool; extract-and-run avoids needing FUSE in the container
  unset SOURCE_DATE_EPOCH
  export APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64
  wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
  wget -q https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x ./*.AppImage
  # bundle shared libraries (SDL2 etc.) of every binary in the AppDir
  ./linuxdeploy-x86_64.AppImage --appdir AppDir \
    -e AppDir/usr/lib/$EXE/$EXE -e AppDir/usr/lib/$EXE/chdman \
    -d "AppDir/$EXE.desktop" -i "AppDir/$EXE.svg" || true
  ./appimagetool-x86_64.AppImage --no-appstream AppDir "dist/$EXE-$VER.$DATE-$SHORT-x86_64.AppImage"
fi

( cd dist && sha256sum * > "SHA256SUMS-$EXE-$VARIANT.txt" )
chown -R "$OWNER" dist
ls -lh dist
