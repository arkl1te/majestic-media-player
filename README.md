# Majestic Media Player

A dark-themed video player built on [libmpv](https://mpv.io) with a
[Silky](https://github.com/treeform/silky) immediate-mode UI, written in Nim.

## Build (CachyOS / Arch)

```sh
sudo pacman -S --needed nim git base-devel mpv libx11 libxrandr kdialog
make            # fetches pinned deps into ./vendor, then compiles
make install    # per-user: ~/.local/bin, app launcher entry, "Open With" for media
```

After `make install`, start it from the application launcher like any other
player, or right-click a video in Dolphin → Open With → Majestic Media Player.
Files can also be passed on the command line (`majestic-media-player a.mkv`),
but that's optional — without them it opens empty and you use File ▸ Open.
`make uninstall` removes it again.

`kdialog` provides the native file dialogs (`zenity` works as a fallback).
Dependencies are pinned in `deps.lock` and cloned by `tools/fetch_deps.sh`, so
builds don't depend on whatever is in `~/.nimble`.

## Notes

- Windy (Silky's windowing layer) is X11-only on Linux, so the player runs
  through XWayland on a Wayland session. Window dragging, always-on-top and
  aspect-locked resizing use EWMH/ICCCM hints, which KWin honours.
- Menus are override-redirect X11 popup windows (no frame, taskbar entry or
  focus, like a toolkit's menus), so they can extend past the main window.
  They are drawn with the main window's GL context and the same Silky atlas.
- vsync is disabled on purpose: with NVIDIA under XWayland, a vsync'd
  `glXSwapBuffers` can block for seconds when the window is hidden. Video frames
  are paced from mpv's frame timing instead; the compositor prevents tearing.
- Settings and recent files live in `~/.config/majestic-media-player/config.json`.
- The UI font is IBM Plex Sans (SIL Open Font License), embedded in the binary.

## Source layout

| File | Purpose |
|---|---|
| `src/majestic.nim` | App state, menus, layout, panels, main loop |
| `src/player.nim` | mpv playback instance, thumbnail-preview instance, folder helpers |
| `src/videogl.nim` | mpv → texture rendering and the transformed video quad |
| `src/menutree.nim` | Menu bar / popup / context-menu system |
| `src/ui.nim` | Widget helpers on top of Silky's drawing primitives |
| `src/xwin.nim` | X11 helpers (drag, on-top, aspect hints, monitors, menu popup windows) |
| `src/config.nim`, `src/dialogs.nim`, `src/theme.nim`, `src/icons.nim` | Settings, file dialogs, palette, vector icons |

## Debugging

- `MMP_DEBUG=1` prints mpv's log to stderr.
- `MMP_SCRIPT` drives the UI for automated checks, e.g.
  `MMP_SCRIPT="1:open ~/v.mkv;3:menu 1;3.5:shot /tmp/view.png;4:quit"`.
  Commands: `open`, `menu <bar> [sub...]`, `ctx x y`, `close`, `mouse x y|off`,
  `overlay <name>`, `action Menu/Sub/Item`, `fs 0|1`, `seek t`, `pause`,
  `size w h`, `set prop value`, `dump props...`, `shot file.png`, `quit`.
  `shot` also writes each open menu popup as `file-menuN.png`.
