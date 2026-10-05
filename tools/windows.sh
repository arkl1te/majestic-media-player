#!/usr/bin/env bash
# Windows build and install, run from Git Bash (what `make` does elsewhere).
#   tools/windows.sh build       fetch deps + libmpv, compile majestic-media-player.exe
#   tools/windows.sh debug       same, unoptimized with stack traces and a console
#   tools/windows.sh run         build, then start it
#   tools/windows.sh install     build, then install for the current user
#   tools/windows.sh uninstall   remove the install, its shortcut and file associations
# Requires: nim >= 2.2, git, and Visual Studio (or its Build Tools) with the
# C++ workload; Nim finds it by itself. libmpv comes prebuilt from the pinned
# release below, unpacked with 7-Zip.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=majestic-media-player.exe
LIBMPV_URL=https://github.com/shinchiro/mpv-winbuild-cmake/releases/download/20261005/mpv-dev-x86_64-20261005-git-c152964208.7z
LIBMPV_DIR=vendor/libmpv
APP_DIR="${LOCALAPPDATA:?}/Programs/Majestic Media Player"
SHORTCUT="${APPDATA:?}/Microsoft/Windows/Start Menu/Programs/Majestic Media Player.lnk"

find_7z() {
  local c
  for c in 7z 7za "$PROGRAMFILES/7-Zip/7z.exe" "$(dirname "$(command -v nim)")/7zG.exe"; do
    if command -v "$c" >/dev/null 2>&1 || [[ -x $c ]]; then echo "$c"; return; fi
  done
  echo "7-Zip not found: install it (https://7-zip.org) to unpack libmpv" >&2
  exit 1
}

fetch_libmpv() {
  # The URL is the version: a different one means fetch again.
  if [[ -f $LIBMPV_DIR/libmpv-2.dll && $(cat "$LIBMPV_DIR/.url" 2>/dev/null) == "$LIBMPV_URL" ]]; then
    return
  fi
  echo "Fetching libmpv..."
  rm -rf "$LIBMPV_DIR"
  mkdir -p "$LIBMPV_DIR"
  curl -fL --progress-bar -o "$LIBMPV_DIR/mpv-dev.7z" "$LIBMPV_URL"
  local sz
  sz=$(find_7z)
  (cd "$LIBMPV_DIR" && "$sz" x -y mpv-dev.7z >/dev/null)
  rm "$LIBMPV_DIR/mpv-dev.7z"
  [[ -f $LIBMPV_DIR/libmpv-2.dll ]] || { echo "libmpv-2.dll missing from the archive" >&2; exit 1; }
  echo "$LIBMPV_URL" > "$LIBMPV_DIR/.url"
}

resources() {
  # The icon Explorer shows for the .exe. rc.exe ships with the Windows SDK;
  # without it the program still builds, just with the generic icon.
  local rc
  rc=$(ls -d "${PROGRAMFILES_X86:-/c/Program Files (x86)}"/Windows\ Kits/10/bin/10.*/x64/rc.exe 2>/dev/null | sort -V | tail -1)
  if [[ -z $rc ]]; then
    echo "rc.exe (Windows SDK) not found: building without the icon" >&2
    return
  fi
  "$rc" -nologo -fo vendor/majestic.res "$(cygpath -w assets/windows/majestic-media-player.rc)" >/dev/null
  echo "--passL:$(cygpath -w vendor/majestic.res)"
}

build() {
  fetch_libmpv
  local res=()
  mapfile -t res < <(resources)
  # --app:gui: no console window. MSVC via Nim's vccexe, which locates Visual
  # Studio itself.
  ./tools/build.sh nim c --cc:vcc "${res[@]}" "$@" -o:"$BIN" src/majestic.nim
  cp "$LIBMPV_DIR/libmpv-2.dll" .
}

install_app() {
  build -d:release --app:gui
  mkdir -p "$APP_DIR"
  cp "$BIN" libmpv-2.dll "$APP_DIR/"
  local exe
  exe=$(cygpath -w "$APP_DIR/$BIN")
  powershell -NoProfile -Command "
    \$s = (New-Object -ComObject WScript.Shell).CreateShortcut('$(cygpath -w "$SHORTCUT")')
    \$s.TargetPath = '$exe'
    \$s.WorkingDirectory = '$(cygpath -w "$APP_DIR")'
    \$s.Description = 'Majestic Media Player'
    \$s.Save()"
  echo "Installed $(cygpath -w "$APP_DIR")\\$BIN — find it in the Start menu as 'Majestic Media Player'."
  echo "Make it the default player in Options > Formats, or right-click a video > Open with."
}

uninstall_app() {
  rm -rf "$APP_DIR"
  rm -f "$SHORTCUT"
  # What Options > Formats registered (see src/assoc_win32.nim).
  local k
  for k in 'HKCU\Software\Classes\MajesticMediaPlayer.Media' \
           "HKCU\\Software\\Classes\\Applications\\$BIN" \
           'HKCU\Software\MajesticMediaPlayer'; do
    reg delete "$k" /f >/dev/null 2>&1 || true
  done
  reg delete 'HKCU\Software\RegisteredApplications' /v 'Majestic Media Player' /f >/dev/null 2>&1 || true
  powershell -NoProfile -Command "
    Get-ChildItem 'HKCU:\Software\Classes' -ErrorAction SilentlyContinue |
      Where-Object { \$_.PSChildName -like '.*' } | ForEach-Object {
        if (\$_.GetValue('') -eq 'MajesticMediaPlayer.Media') { Remove-ItemProperty \$_.PSPath -Name '(default)' -ErrorAction SilentlyContinue }
        Remove-ItemProperty (Join-Path \$_.PSPath 'OpenWithProgids') -Name 'MajesticMediaPlayer.Media' -ErrorAction SilentlyContinue
      }"
  echo "Uninstalled."
}

case "${1:-build}" in
  build)     build -d:release --app:gui ;;
  debug)     build -d:debug --debugger:native --stackTrace:on --lineTrace:on ;;
  run)       build -d:release --app:gui; ./"$BIN" "${@:2}" ;;
  install)   install_app ;;
  uninstall) uninstall_app ;;
  *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
