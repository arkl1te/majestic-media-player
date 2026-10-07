## Majestic Media Player — an mpv-based video player with a Silky UI.

import std/[os, strutils, strformat, times, math, osproc, unicode, sequtils, algorithm,
  random, tables, streams]
import silky, vmath, bumpy, chroma, pixie, opengl
import mpv, videogl, xwin, config, dialogs, theme, ui, menutree, player, icons, debugscript,
  options, instance, playlists, peers, cmdlines, runlog, mediainfo, inhibit, spherical, keymap
from std/uri import encodeUrl, decodeUrl, parseUri

const
  AppName = "Majestic Media Player"
  AppVersion = staticRead("../VERSION").strip  # single source of truth: /VERSION
  FontData = staticRead("../assets/fonts/IBMPlexSans-Regular.ttf")
  MinWindow = ivec2(480, 270)
  OptionsSize = ivec2(780, 512)
  RenameSize = ivec2(400, 116)
  CommandsSize = ivec2(880, 520)
  PlaylistRowH = 26'f32
  PlaylistHeaderH = 24'f32  ## column headers
  PlaylistGripW = 5'f32     ## draggable left edge of the playlist
  RunLogHeaderH = 28'f32
  RunLogRowH = 18'f32
  RunLogGripH = 5'f32       ## draggable bottom edge of the run log
  RunLogBarW = 10'f32       ## its scroll bar
  RunLogWheelRows = 4       ## lines scrolled per mouse wheel step
  SphereFov = 75'f32        ## 360° video: vertical field of view a file opens with
  SphereFovStep = 5'f32     ## degrees per Ctrl+Wheel notch
  SphereTextureMax = 8192   ## cap on the equirectangular texture's longer side

type
  Overlay = enum
    ovNone, ovOptions, ovProperties, ovShortcuts, ovAbout, ovRename, ovCommands, ovPick

  ContextMenu = enum
    cmVideo, cmTime, cmStatus, cmSeekBar, cmPlaylist, cmPlaylistColumns, cmRepeat  ## where the right-click menu was opened

  PlaylistSort = enum
    psName, psDuration, psDimensions, psSize

  PlaylistColumn = object
    label: string
    w: float32
    sort: PlaylistSort

  PointerShape = enum
    ptArrow, ptHidden, ptResize, ptResizeV

  VideoTransform = object
    pan: Vec2
    rotation: float32
    zoom: float32 = 1
    scaleX: float32 = 1
    scaleY: float32 = 1

  SubLayout = object
    alignX: int = 1           ## 0 left, 1 center, 2 right
    alignY: int = 2           ## 0 top, 1 middle, 2 bottom
    offset: Vec2              ## screen pixels, +x right, +y down
    scale: float32 = 1

  App = ref object
    window: Window
    sk: Silky
    ui: Ui
    menus: MenuSystem
    quad: QuadRenderer
    player: Player
    preview: Preview
    cfg: Config
    playlist: seq[string]
    plIndex: int
    plSelected: int
    plScroll: float32
    plReveal: bool            ## scroll the selected entry into view
    prober: Prober            ## created on the first sort that needs it
    mediaInfo: Table[string, MediaInfo]  ## probe results, for columns and sorting
    fileSizes: Table[string, int64]      ## -1 for streams and unreadable files
    plResizeFrom: (float32, float32)     ## pointer x and width when the drag began
    xf: VideoTransform
    subs: SubLayout
    subsKey: string           ## mpv subtitle placement last pushed
    osdFit: tuple[key: string, target, x, y: (int, int), subMarginX: int, props: string]
    afterPlayback: AfterPlayback
    overlay: Overlay
    optionsDlg: OptionsDialog
    optWin: Window            ## Options dialog window, created on first use
    optSk: Silky              ## its own Silky: one tracks one window's input
    optUi: Ui
    atlasImg: Image
    atlas: SilkyAtlas
    cfgBefore: Config         ## config when Options opened, restored on Cancel
    settingsKey: string       ## player-facing settings last pushed to mpv
    positions: Positions      ## remembered playback positions
    subScales: SubScales      ## remembered subtitle sizes, per file
    bookmarks: Bookmarks      ## per-file bookmarks, shown on the seek bar
    bmPath, bmKey: string     ## the current file and its mediaKey, once known
    bmPending: string         ## the file whose mediaKey is being worked out
    renWin: Window            ## Rename Bookmark dialog, created on first use
    renSk: Silky
    renUi: Ui
    renPath: string           ## the bookmark being renamed: its file and time
    renTime: float
    renText: string
    renPlaceholder: string    ## its default label, shown when renText is empty
    cmdDlg: CmdDialog         ## Commands window, its window created on first use
    cmdWin: Window
    cmdSk: Silky
    cmdUi: Ui
    commands: seq[CommandLine]  ## the Run menu's command lines
    runLog: seq[RunEntry]     ## command lines run, oldest first, with their output
    rlScroll: float32
    rlFollow: bool            ## keep the run log scrolled to its newest line
    rlResizeFrom: (float32, float32)     ## pointer y and height when the drag began
    rlThumbFrom: (float32, float32)      ## pointer y and scroll when the thumb drag began
    pickDlg: PickDialog       ## Run window: bookmarks and values for a run
    extRun: CommandLine       ## the command line whose external files are asked for
    extQueue: seq[string]     ## its external-file cards still to ask about
    extPicks: Table[string, string]  ## the files chosen so far, by card name
    pickWin: Window
    pickSk: Silky
    pickUi: Ui
    resumedAt: float          ## start time of the file being loaded, else 0
    instance: InstanceServer  ## receives files from later launches
    peers: PeerNet            ## other players, for Synchronize
    syncMaster: int           ## pid of our group's master, 0 when not synchronized
    syncMembers: seq[int]     ## the group, master included
    syncQuiet: bool           ## acting on a peer's command (or on our own EOF):
                              ## don't repeat it to the group
    props: seq[InfoSection]   ## File > Properties report
    propScroll: float32
    propPageH: float32        ## height of its scrolling body, for Page Up / Down
    propThumbFrom: (float32, float32)    ## pointer y and scroll when the thumb drag began
    dialog: Dialog
    children: seq[Process]
    fullscreen: bool
    ctxMenu: ContextMenu
    # mouse interaction with the video frame
    videoPress: bool
    videoPressPos: Vec2
    rotDrag: bool             ## Alt+Middle drag is turning the frame
    rotPivot: Vec2            ## window pixels the frame turns around
    rotStart: VideoTransform  ## transform when the drag began
    rotRef: float32           ## cursor angle around the pivot the turn counts from
    rotRefSet: bool
    rotPressPos: Vec2         ## window pixels where the press began
    panDrag: bool             ## Shift+Middle drag is panning the zoomed frame
    panFrom: Vec2             ## window pixels where the pan drag began
    panStart: Vec2            ## pan when the drag began
    # 360° video camera, degrees
    lookYaw, lookPitch: float32
    lookFov: float32 = SphereFov
    lookDragging: bool        ## a left drag is turning the camera
    lookLast: Vec2            ## pointer position the drag last turned from
    osdMsg: string            ## OSD message drawn by us over a 360° view
    osdUntil: float
    rotMoved: bool            ## past the click threshold; a click resets rotation
    lastMouse: Vec2
    lastMouseMove: float
    pointerShape: PointerShape
    # seek bar
    seekDragging: bool
    seekDragT: float
    seekRect: Rect            ## seek bar as last drawn
    ctxSeekT: float           ## seek bar time the context menu was opened at
    ctxBookmark: int          ## bookmark under the pointer then, else -1
    ctxOnMarker: bool         ## a chapter or bookmark was under the pointer then
    ctxMarkerT: float         ## and its time
    # A-B loop; marks last only for the current file
    loopA, loopB: float
    hasLoopA, hasLoopB: bool
    abLoop: bool
    lastDragSeekAt: float
    previewQuad: Rect
    showPreview: bool
    # window management
    onTopApplied: bool
    screenInhibit: Inhibitor  # keeps the display on while video plays
    title: string
    hintsKey: string
    fitPending: bool
    # render scheduling
    frameFlag, previewFlag: bool
    framePending: bool        ## mpv has a frame queued for frameDue
    frameDue: int64           ## mpv_get_time_ns when it should be shown
    renderNow: bool           ## render the queued frame this iteration
    dirtyUntil: float
    focusLostAt: float        ## when the window lost focus, else 0
    menuOpenedAt: float       ## when the menus opened, else 0
    fakeMods: string          ## debug scripting: "ctrl", "alt+shift", ...
    inputPending: bool        ## button/key/scroll this iteration; Windy clears
                              ## those per pollEvents, so draw before the next
    videoRect: Rect
    script: Script
    shotPath: string
    dropped: seq[string]      ## paths/URLs from a drag and drop, one per file
    dropAt: Vec2              ## pointer position when the drop arrived
    plListRect: Rect          ## playlist rows area as last drawn (empty if hidden)

proc setlocale(category: cint, locale: cstring): cstring {.importc, header: "<locale.h>".}
var LC_NUMERIC {.importc, header: "<locale.h>".}: cint

proc now(): float = epochTime()

# --- small helpers ----------------------------------------------------------

proc ctrl(w: Window): bool = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
proc shift(w: Window): bool = w.buttonDown[KeyLeftShift] or w.buttonDown[KeyRightShift]
proc alt(w: Window): bool = w.buttonDown[KeyLeftAlt] or w.buttonDown[KeyRightAlt]

proc osd(a: App, msg: string) =
  # mpv draws the OSD into the picture, which a 360° view would warp onto
  # the sphere (out of sight): show the message over the frame instead.
  if a.player.isSpherical:
    if a.cfg.showOsd:
      a.osdMsg = msg
      a.osdUntil = now() + 1.5
      a.dirtyUntil = max(a.dirtyUntil, a.osdUntil + 0.1)
  else:
    a.player.osd(msg)

proc fileTitle(path: string): string = path.extractFilename

proc bottomHeight(a: App): float32 =
  (if a.cfg.showSeekBar: SeekBarHeight else: 0) +
  (if a.cfg.showControls: ControlsHeight else: 0) +
  (if a.cfg.showStatus: StatusHeight else: 0)

proc playlistWidth(a: App): float32 =
  max(PlaylistMinWidth, round(a.cfg.playlistWidth).float32)

proc runLogHeight(a: App): float32 =
  max(RunLogMinHeight, round(a.cfg.runLogHeight).float32)

proc px(a: App, v: IVec2): IVec2 =
  ## UI units to window pixels (Options > Player > UI scaling).
  let s = a.sk.uiScale
  ivec2(int32(round(v.x.float32 * s)), int32(round(v.y.float32 * s)))

proc px(a: App, r: Rect): Rect =
  let s = a.sk.uiScale
  rect(r.x * s, r.y * s, r.w * s, r.h * s)

proc minWindow(a: App): IVec2 = a.px(MinWindow)

proc chromeSize(a: App): IVec2 =
  ## Window space not used by the video frame (windowed mode), in pixels.
  a.px(ivec2(int32(if a.cfg.showPlaylist: a.playlistWidth else: 0),
        int32(MenuBarHeight + a.bottomHeight + (if a.cfg.showRunLog: a.runLogHeight else: 0))))

proc naturalSize(a: App): Vec2 =
  var w = a.player.videoW.float32
  let h = a.player.videoH.float32
  let parts = a.cfg.aspectOverride.split(':')
  if parts.len == 2 and h > 0:
    try: w = h * parseFloat(parts[0]) / parseFloat(parts[1])
    except ValueError: discard
  vec2(w, h)

proc videoAspect(a: App): float =
  let n = a.naturalSize
  if n.y > 0: n.x / n.y else: 0

# --- atlas & UI scaling ----------------------------------------------------

proc glyphSet(): seq[string] =
  result = AsciiGlyphs
  for cp in 0xA0 .. 0x17F: result.add $Rune(cp)
  for s in ["…", "–", "—", "•", "‘", "’", "“", "”", "→", "←", "×", "°", "·", "▸"]:
    result.add s

proc buildAtlas(scale: float32): (Image, SilkyAtlas) =
  ## Fonts and icons rasterized at scale (Silky draws them at their UI size).
  let fontPath = getTempDir() / "majestic-media-player-font.ttf"
  if not fileExists(fontPath) or getFileSize(fontPath) != FontData.len:
    writeFile(fontPath, FontData)
  let b = newAtlasBuilder(2048, 2)
  let glyphs = glyphSet()
  proc px(size: int): int = int(round(size.float32 * scale))
  b.addFont(fontPath, FontMain, 15 * scale, glyphs)
  b.addFont(fontPath, FontSmall, 13 * scale, glyphs)
  b.addFont(fontPath, FontTitle, 20 * scale, glyphs)
  b.addIcons(scale)
  discard b.addImage("crown96", renderIcon(crownPath, 24, px(96)))
  discard b.addImage("music96", renderIcon(musicPath, 24, px(96)))
  discard b.addImage("knob16", renderIcon("M12 4a8 8 0 1 0 0.001 0z", 24, px(16)))
  (b.atlasImage, b.atlas)

# --- window management ------------------------------------------------------

proc updateTitle(a: App) =
  let path = a.player.path
  var name = if a.cfg.titleFullPath: path else: path.fileTitle
  if a.cfg.titleUseMediaTitle and a.player.loaded:
    # mpv falls back to the file name when the file has no title tag.
    let mt = a.player.h.getStr("media-title")
    if mt.len > 0 and mt != path.fileTitle and mt != path: name = mt
  let t = if path.len > 0: name & " - " & AppName else: AppName
  if t != a.title:
    a.title = t
    a.window.title = t

proc updateAspectHints(a: App) =
  let enforce = not a.fullscreen and a.cfg.preserveAspect and
    a.cfg.frameMode == fmTouchInside and a.player.hasVideo and not a.player.stopped
  let aspect = if enforce: a.videoAspect else: 0.0
  let chrome = a.chromeSize
  let key = &"{aspect:.4f}/{chrome.x}/{chrome.y}"
  if key != a.hintsKey:
    a.hintsKey = key
    a.window.setAspectHints(aspect, chrome, a.minWindow)

proc fitWindowToVideo(a: App) =
  ## Sizes the window so the video shows at its natural size, capped to 85%
  ## of the monitor.
  if a.fullscreen or a.window.maximized or not a.player.hasVideo: return
  let nat = a.naturalSize
  let chrome = a.chromeSize.vec2
  let mon = a.window.monitorSize.vec2
  let maxV = mon * 0.85 - chrome
  let s = min(1'f32, min(maxV.x / nat.x, maxV.y / nat.y))
  let v = vec2(round(nat.x * s), round(nat.y * s))
  var size = ivec2(int32(v.x + chrome.x), int32(v.y + chrome.y))
  size.x = max(size.x, a.minWindow.x)
  size.y = max(size.y, a.minWindow.y)
  a.window.size = size

proc resizeKeepingVideo(a: App, delta: IVec2) =
  ## Grows/shrinks the window by delta when chrome is toggled, so the video
  ## frame keeps its size. delta is in UI units.
  if a.fullscreen or a.window.maximized: return
  a.window.size = a.window.size + a.px(delta)

proc setFullscreen(a: App, on: bool) =
  if on == a.fullscreen: return
  a.menus.close()
  a.fullscreen = on
  a.window.fullscreen = on
  a.hintsKey = ""
  if on:
    a.window.setAspectHints(0, ivec2(0, 0), a.minWindow)

proc applyOnTop(a: App) =
  let want = case a.cfg.onTop
    of otDefault: false
    of otAlways: true
    of otWhilePlaying: a.player.playing
    of otWhilePlayingVideo: a.player.playing and a.player.hasRealVideo
  if want != a.onTopApplied:
    a.onTopApplied = want
    a.window.setAlwaysOnTop(want)

proc applyKeepAwake(a: App) =
  a.screenInhibit.set(a.cfg.keepDisplayOn and a.player.playing and a.player.hasRealVideo)

# --- synchronize ------------------------------------------------------------
# Synchronized players repeat each other's playback controls: whoever acts
# sends the action to every other member, each playing its own file. Times go
# out as absolute positions, clamped to each file's duration. The master (the
# player that started the group) owns the membership and keeps its playlist;
# the others' playlists are emptied and locked while synchronized.

proc synced(a: App): bool = a.syncMaster != 0

proc isSyncMaster(a: App): bool = a.synced and a.syncMaster == a.peers.pid

proc playlistLocked(a: App): bool = a.synced and not a.isSyncMaster

proc editLocked(a: App): bool =
  ## True (with a note on screen) when the playlist may not be edited here.
  if a.playlistLocked and not a.syncQuiet:
    a.osd("Playlist is locked: synchronized with another player")
    return true

template quietly(a: App, body: untyped) =
  let wasQuiet = a.syncQuiet
  a.syncQuiet = true
  try: body
  finally: a.syncQuiet = wasQuiet

proc syncSend(a: App, fields: varargs[string]) =
  ## Repeats a playback action on the other synchronized players.
  if a.syncQuiet or not a.synced: return
  for m in a.syncMembers:
    if m != a.peers.pid: a.peers.send(m, fields)

proc clampTime(a: App, t: float): float =
  ## A group member's time on this player's (perhaps shorter) file.
  if a.player.duration > 0: clamp(t, 0, a.player.duration) else: max(t, 0)

# --- playback actions -------------------------------------------------------

proc applyLoop(a: App) =
  a.player.h.setProp("loop-file",
    if a.cfg.repeatForever and a.cfg.repeatMode == rmFile: "inf" else: "no")

proc loopReady(a: App): bool =
  a.hasLoopA and a.hasLoopB and a.loopB > a.loopA

proc applyAbLoop(a: App) =
  let on = a.abLoop and a.loopReady
  for (prop, t) in [("ab-loop-a", a.loopA), ("ab-loop-b", a.loopB)]:
    if on: a.player.h.setProp(prop, t) else: a.player.h.setProp(prop, "no")

proc clearLoopMarks(a: App) =
  a.hasLoopA = false
  a.hasLoopB = false
  a.abLoop = false
  a.applyAbLoop()

proc setLoopMark(a: App, isB: bool, t: float) =
  ## Sets mark A or B; marks placed out of order swap roles. Completing the
  ## pair starts the loop.
  let had = a.loopReady
  if isB: (a.loopB, a.hasLoopB) = (t, true)
  else: (a.loopA, a.hasLoopA) = (t, true)
  if a.hasLoopA and a.hasLoopB and a.loopA > a.loopB: swap(a.loopA, a.loopB)
  if a.loopReady and not had: a.abLoop = true
  a.applyAbLoop()
  a.osd((if isB: "Loop B: " else: "Loop A: ") & fmtTime(t, a.cfg.showMillis))

proc unsetLoopMark(a: App, isB: bool) =
  ## Removes mark A or B, which also ends the loop.
  if isB: a.hasLoopB = false else: a.hasLoopA = false
  a.abLoop = false
  a.applyAbLoop()
  a.osd(if isB: "Loop B unset" else: "Loop A unset")

proc savePosition(a: App) =
  ## Remembers where the current file was left off; finished (or barely
  ## started) files are forgotten.
  let p = a.player
  if not a.cfg.rememberTime or not p.loaded or p.path.len == 0 or p.duration <= 0: return
  if p.timePos > 5 and p.timePos < p.duration - 5 and not p.eofReached:
    a.positions.remember(p.path, p.timePos)
  else:
    a.positions.del(p.path)
  a.positions.save()

proc playIndex(a: App, i: int, start = -1.0) =
  ## Plays entry i from `start`, or from where it was left off when negative.
  if i < 0 or i >= a.playlist.len: return
  a.savePosition()
  a.plIndex = i
  a.plSelected = i
  let path = a.playlist[i]
  if not a.cfg.rememberTransform: a.xf = VideoTransform()
  a.resumedAt =
    if start >= 0: start
    elif a.cfg.rememberTime: a.positions.getOrDefault(path, 0.0)
    else: 0.0
  a.clearLoopMarks()
  a.subs.scale = a.subScales.getOrDefault(path, 1'f32)
  a.player.load(path, a.resumedAt)
  a.applyLoop()
  a.cfg.addRecent(path)
  a.cfg.lastDir = path.parentDir
  a.updateTitle()

proc expandPaths(paths: seq[string]): seq[string] =
  ## Files and URLs as given; directories become their media files.
  for p in paths:
    if dirExists(p): result.add mediaFilesIn(p, isMediaFile)
    elif fileExists(p) or p.contains("://"): result.add p

proc openPaths(a: App, paths: seq[string]) =
  if a.editLocked: return
  let files = expandPaths(paths)
  if files.len == 0:
    a.osd("Nothing playable found")
    return
  a.playlist = files
  a.plScroll = 0
  a.playIndex(0)

proc closeFile(a: App) =
  if a.editLocked: return
  a.savePosition()
  a.clearLoopMarks()
  a.player.close()
  a.preview.forget()
  a.playlist.setLen 0
  a.plIndex = -1
  a.plSelected = -1
  a.updateTitle()

proc onWayland(): bool =
  getEnv("WAYLAND_DISPLAY").len > 0 and findExe("wl-copy").len > 0 and
    findExe("wl-paste").len > 0

proc fileUri(path: string): string =
  result = "file://"
  for part in path.absolutePath.split('/'):
    if part.len > 0: result.add "/" & encodeUrl(part, usePlus = false)

proc copyToClipboard(a: App) =
  ## The opened file goes on the clipboard as a file (text/uri-list), so a
  ## file manager pastes the file itself; streams go as their URL.
  let path = a.player.path
  if not a.player.loaded or path.len == 0: return
  when defined(windows):
    if not path.contains("://"):
      a.window.setClipboardFile(path.absolutePath)
      a.osd("Copied " & path.extractFilename)
      return
  if path.contains("://") or not onWayland():
    setClipboardString(path)
  else:
    try:
      let p = startProcess("wl-copy", args = @["--type", "text/uri-list"],
        options = {poUsePath})
      p.inputStream.write(path.fileUri & "\r\n")
      p.inputStream.close()
      discard p.waitForExit(2000)
      p.close()
    except OSError:
      setClipboardString(path)
  a.osd("Copied " & path.extractFilename)

proc clipboardPaths(a: App): seq[string] =
  ## Files and URLs on the clipboard: a file manager's text/uri-list (on
  ## Windows, Explorer's file list), or plain text holding paths or URLs, one
  ## per line.
  when defined(windows):
    result = a.window.clipboardFiles()
    if result.len > 0: return
  var text = ""
  if onWayland():
    # Listing types never asks the owner for data, so this cannot stall on
    # our own X selection; only a uri-list (never ours) is then fetched.
    let (types, code) = execCmdEx("wl-paste --list-types")
    if code == 0 and "text/uri-list" in types.splitLines:
      let (uris, code2) = execCmdEx("wl-paste --no-newline --type text/uri-list")
      if code2 == 0: text = uris
  if text.len == 0: text = getClipboardString()
  for line in text.splitLines:
    let e = strutils.strip(line, chars = Whitespace + {'"', '\''})
    if e.len == 0 or e.startsWith("#"): continue
    if e.toLowerAscii.startsWith("file://"):
      result.add decodeUrl(e.parseUri.path, false)
    elif e.contains("://"): result.add e
    else: result.add e.expandTilde

proc openFromClipboard(a: App) =
  if a.editLocked: return
  let paths = a.clipboardPaths()
  if paths.len == 0:
    a.osd("Clipboard has no file to open")
    return
  a.openPaths(paths)

proc reopenLast(a: App): bool =
  ## With nothing loaded, Play starts the selected playlist entry, or else
  ## reopens the most recently opened file.
  if a.player.loaded: return false
  if a.playlist.len > 0:
    a.playIndex(max(a.plSelected, 0))
    return true
  if a.playlistLocked: return false
  for r in a.cfg.recentFiles:
    if fileExists(r) or r.contains("://"):
      a.openPaths(@[r])
      return true

proc play(a: App) =
  if a.reopenLast(): return
  let restart = a.player.eofReached  # Play at the end starts over
  a.player.play()
  if restart: a.syncSend("seek", "0", "true")
  a.syncSend("play")

proc pause(a: App) =
  a.player.pause()
  a.syncSend("pause", $a.player.timePos)

proc stop(a: App) =
  a.player.stop()
  a.syncSend("stop")

proc togglePlay(a: App) =
  let p = a.player
  if not p.loaded: return
  if p.stopped or p.eofReached or p.paused: a.play() else: a.pause()

proc playPause(a: App) =
  if not a.reopenLast(): a.togglePlay()

proc seekTo(a: App, t: float, exact = true) =
  a.player.stopped = false
  a.player.seek(a.clampTime(t), exact)
  a.syncSend("seek", $t, $exact)

proc folderNeighbor(a: App, dir: int): string =
  if a.player.path.len == 0 or not fileExists(a.player.path): return
  let files = mediaFilesIn(a.player.path.parentDir, isMediaFile)
  let i = files.find(a.player.path.absolutePath)
  let j = (if i < 0: files.find(a.player.path) else: i) + dir
  if j >= 0 and j < files.len: files[j] else: ""

proc navigateLocal(a: App, dir: int) =
  ## Previous/next: walks the playlist, or the folder when it is the sole item.
  if a.playlist.len > 1:
    var j = a.plIndex + dir
    if j < 0 or j >= a.playlist.len:
      if a.cfg.repeatForever and a.cfg.repeatMode == rmPlaylist:
        j = (j + a.playlist.len) mod a.playlist.len
      else: return
    a.playIndex(j)
  else:
    let f = a.folderNeighbor(dir)
    if f.len > 0:
      a.playlist = @[f]
      a.playIndex(0)
    else:
      a.osd(if dir > 0: "Last file in folder" else: "First file in folder")

proc navigate(a: App, dir: int) =
  # Each player has its own file; the folder step would rewrite a locked playlist.
  if not a.editLocked: a.navigateLocal(dir)

# --- playlist editing -------------------------------------------------------

proc addToPlaylist(a: App, paths: seq[string], at = -1) =
  ## Inserts at `at` (appends when out of range) without touching playback;
  ## starts playing them when nothing is open.
  if a.editLocked: return
  let files = expandPaths(paths)
  if files.len == 0:
    a.osd("Nothing playable found")
    return
  let first = if at < 0 or at > a.playlist.len: a.playlist.len else: at
  a.playlist.insert(files, first)
  if a.plIndex >= first: a.plIndex += files.len
  if a.plSelected >= first: a.plSelected += files.len
  if not a.player.loaded: a.playIndex(first)
  else: a.osd(if files.len == 1: "Added to playlist" else: &"Added {files.len} files to playlist")

proc removeSelected(a: App) =
  if a.editLocked: return
  if a.plSelected < 0 or a.plSelected >= a.playlist.len: return
  a.playlist.delete(a.plSelected)
  if a.plIndex == a.plSelected: a.plIndex = -1
  elif a.plIndex > a.plSelected: dec a.plIndex
  a.plSelected = min(a.plSelected, a.playlist.len - 1)

proc reorderPlaylist(a: App, order: seq[int]) =
  ## order[new position] = old index; the playing and selected entries follow.
  if a.editLocked: return
  let old = a.playlist
  var cur, sel = -1
  for i, j in order:
    a.playlist[i] = old[j]
    if j == a.plIndex: cur = i
    if j == a.plSelected: sel = i
  a.plIndex = cur
  a.plSelected = sel
  a.plReveal = true

proc moveSelected(a: App, to: int) =
  let i = a.plSelected
  if i < 0 or i >= a.playlist.len: return
  var order = toSeq(0 ..< a.playlist.len)
  order.delete(i)
  order.insert(i, clamp(to, 0, order.len))
  a.reorderPlaylist(order)

proc probeInfo(a: App, path: string): MediaInfo =
  ## Duration and video size, probed once per file (streams are not probed).
  if path in a.mediaInfo: return a.mediaInfo[path]
  if not path.contains("://"):
    if a.prober == nil: a.prober = newProber()
    result = a.prober.probe(path)
  a.mediaInfo[path] = result

proc fileSize(a: App, path: string): int64 =
  ## Size in bytes, read once per file; -1 for streams and unreadable files.
  if path in a.fileSizes: return a.fileSizes[path]
  result = -1
  if not path.contains("://"):
    try: result = getFileSize(path)
    except OSError: discard
  a.fileSizes[path] = result

proc probeNext(a: App, visible: Slice[int]) =
  ## Starts the background probe of the next file the playlist columns need,
  ## visible rows first; releases the prober's file once all are known.
  if a.prober != nil and a.prober.pending.len > 0: return
  var next = ""
  for i in visible:
    let p = a.playlist[i]
    if not p.contains("://") and p notin a.mediaInfo: next = p; break
  if next.len == 0:
    for p in a.playlist:
      if not p.contains("://") and p notin a.mediaInfo: next = p; break
  if next.len == 0:
    a.prober.finish()
    return
  if a.prober == nil: a.prober = newProber()
  if a.prober != nil: a.prober.start(next)

proc pollProbe(a: App) =
  ## Collects a finished background probe and redraws to show it.
  if a.prober == nil or a.prober.pending.len == 0: return
  let path = a.prober.pending
  if a.prober.poll():
    a.mediaInfo[path] = a.prober.info
    a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)

proc sortPlaylist(a: App, by: PlaylistSort) =
  ## Sorts ascending, or descending when already in ascending order.
  if a.editLocked: return
  let n = a.playlist.len
  if n < 2: return
  var keys = newSeq[(float, float)](n)
  for i, p in a.playlist:
    case by
    of psName: discard
    of psDuration: keys[i] = (a.probeInfo(p).duration, 0.0)
    of psDimensions:
      let m = a.probeInfo(p)
      keys[i] = (float(m.width * m.height), m.width.float)
    of psSize:
      keys[i] = (a.fileSize(p).float, 0.0)
  if by in {psDuration, psDimensions}: a.prober.finish()
  let names = a.playlist.mapIt(it.extractFilename)
  let byKey = proc (i, j: int): int =
    if by == psName: naturalCmp(names[i], names[j]) else: cmp(keys[i], keys[j])
  let ascending = (0 ..< n - 1).toSeq.allIt(byKey(it, it + 1) <= 0)
  var order = toSeq(0 ..< n)
  order.sort(byKey, if ascending: Descending else: Ascending)
  a.reorderPlaylist(order)

proc clearPlaylist(a: App) =
  ## Empties the playlist; the open file keeps playing.
  if a.editLocked: return
  a.playlist.setLen 0
  a.plIndex = -1
  a.plSelected = -1
  a.plScroll = 0

proc randomizePlaylist(a: App) =
  var order = toSeq(0 ..< a.playlist.len)
  order.shuffle()
  a.reorderPlaylist(order)

proc spawn(a: App, cmd: string, args: varargs[string]) =
  if findExe(cmd).len == 0:
    stderr.writeLine "not found: ", cmd
    return
  # poDaemon: no console window flashes up on Windows.
  const opts = when defined(windows): {poUsePath, poParentStreams, poDaemon}
               else: {poUsePath, poParentStreams}
  try:
    a.children.add startProcess(cmd, args = @args, options = opts)
  except OSError as e:
    stderr.writeLine "cannot run ", cmd, ": ", e.msg

proc showInFolder(a: App, path: string) =
  ## Opens the file manager on path's folder with the file selected.
  if path.contains("://"): return
  let path = path.absolutePath
  when defined(windows):
    a.spawn("explorer.exe", "/select," & path)
  else:
    # FileManager1 (Dolphin, Nautilus, ...) selects the file; else just open the folder.
    if findExe("dbus-send").len > 0 and execCmdEx("dbus-send --session --print-reply " &
        "--dest=org.freedesktop.FileManager1 /org/freedesktop/FileManager1 " &
        "org.freedesktop.FileManager1.ShowItems array:string:" & quoteShell(path.fileUri) &
        " string:").exitCode == 0:
      return
    a.spawn("xdg-open", path.parentDir)

when defined(windows):
  proc runPowerAction(a: App) =
    case a.afterPlayback
    of apMonitorOff: a.window.monitorOff()
    of apSleep, apHibernate:
      if not suspend(a.afterPlayback == apHibernate):
        a.osd("Windows refused to " &
          (if a.afterPlayback == apSleep: "sleep" else: "hibernate"))
    of apShutdown: a.spawn("shutdown", "/s", "/t", "0")
    of apLogOff: a.spawn("shutdown", "/l")
    of apLock: lockSession()
    else: discard
else:
  proc runPowerAction(a: App) =
    case a.afterPlayback
    of apMonitorOff:
      if findExe("kscreen-doctor").len > 0: a.spawn("kscreen-doctor", "--dpms", "off")
      else: a.spawn("xset", "dpms", "force", "off")
    of apSleep: a.spawn("systemctl", "suspend")
    of apHibernate: a.spawn("systemctl", "hibernate")
    of apShutdown: a.spawn("systemctl", "poweroff")
    of apLogOff:
      if findExe("qdbus6").len > 0:
        a.spawn("qdbus6", "org.kde.Shutdown", "/Shutdown", "org.kde.Shutdown.logout")
      else:
        a.spawn("loginctl", "terminate-session", getEnv("XDG_SESSION_ID"))
    of apLock: a.spawn("loginctl", "lock-session")
    else: discard

proc runAfterPlayback(a: App) =
  case a.afterPlayback
  of apNothing: discard
  of apNextInFolder:
    let f = a.folderNeighbor(1)
    if f.len > 0:
      a.playlist = @[f]
      a.playIndex(0)
  of apExit: a.window.closeRequested = true
  else: a.runPowerAction()

proc afterEof(a: App) =
  if a.cfg.repeatForever and a.cfg.repeatMode == rmPlaylist and a.playlist.len > 0:
    a.playIndex((a.plIndex + 1) mod a.playlist.len)
  elif a.plIndex + 1 < a.playlist.len:
    a.playIndex(a.plIndex + 1)
  else:
    a.runAfterPlayback()

proc handleEof(a: App) =
  let p = a.player
  if not (p.loaded and p.eofReached and not p.eofHandled and not p.stopped): return
  p.eofHandled = true
  # A synchronized player's file may be shorter than the master's: it waits at
  # the end (clamped) until the group seeks back.
  if not a.playlistLocked: a.afterEof()

proc volumeStep(a: App, up: bool) =
  ## Soft cap 100, hard cap 200: the volume step (default 5) below the soft
  ## cap, +2 above it, and the volume step down.
  let v = a.player.volume
  let st = a.cfg.volumeStep
  let nv =
    if up: (if v < 100: min(v + st, 100) else: min(v + 2, 200))
    else: max(v - st, 0)
  a.player.setVolume(nv)
  a.osd(&"Volume: {nv:g}%")

proc setMute(a: App, on: bool) =
  a.player.h.setProp("mute", on)
  a.osd(if on: "Mute" else: "Unmute")

proc changeRate(a: App, dir: float) =
  if not a.player.loaded: return
  let s = clamp(a.player.speed + dir * a.cfg.rateStep, 0.25, 4.0)
  a.player.h.setProp("speed", s)
  a.syncSend("speed", $s)
  a.osd(&"Speed: {s:.2f}x")

proc cycleTrack(a: App, kind: string, up: bool) =
  if a.player.loaded:
    a.player.h.commandStr("osd-msg cycle " & kind & (if up: " up" else: " down"))

proc setTrack(a: App, prop: string, id: int) =
  a.player.h.setProp(prop, if id <= 0: "no" else: $id)

proc frameStep(a: App, forward: bool) =
  if not a.player.loaded: return
  a.player.stopped = false
  a.player.h.commandAsync(if forward: "frame-step" else: "frame-back-step")
  a.syncSend("frame", $forward)

proc seekRelative(a: App, d: float) =
  if a.player.loaded:
    a.player.stopped = false
    a.player.h.commandAsync("seek", $d, "relative")
    a.syncSend("seek", $(a.player.timePos + d), "false")

proc entryOf(a: App, path: string): string =
  ## The bookmarks key filed under path: an entry last seen there, or one
  ## written by an older version (keyed by path), else "".
  if path in a.bookmarks: return path
  for k, e in a.bookmarks:
    if e.path == path: return k

proc keyKnown(a: App, path, key: string) =
  ## Files the bookmarks found under path (older versions, or the contents
  ## changed) under key, and a moved file's bookmarks under its new path.
  (a.bmPath, a.bmKey) = (path, key)
  if key in a.bookmarks and a.bookmarks[key].path == path: return
  if key notin a.bookmarks and a.entryOf(path).len == 0: return
  a.bookmarks = loadBookmarks()
  if key notin a.bookmarks:
    let old = a.entryOf(path)
    if old.len == 0: return
    a.bookmarks[key] = a.bookmarks[old]
    a.bookmarks.del(old)
  a.bookmarks[key].path = path
  a.bookmarks.save()
  a.dirtyUntil = max(a.dirtyUntil, now() + 0.05)

proc pollMediaKey(a: App) =
  ## Starts working out the current file's key when it changes, and files
  ## its bookmarks under it once done.
  let path = if a.player.loaded: a.player.path else: ""
  if path.len > 0 and path != a.bmPath and path != a.bmPending:
    a.bmPending = path
    requestMediaKey(path)
  while true:
    let r = takeMediaKey()
    if not r.ok: break
    if r.path == a.bmPending:
      a.bmPending = ""
      a.keyKnown(r.path, r.key)

proc bookmarkKey(a: App, path: string): string =
  ## The key of path's bookmarks. Before the background mediaKey is done, the
  ## entry filed under the path (when there is one) stands in.
  if path == a.bmPath: a.bmKey
  else: a.entryOf(path)

proc fileBookmarks(a: App): seq[Bookmark] =
  if a.player.loaded: a.bookmarks.getOrDefault(a.bookmarkKey(a.player.path)).marks
  else: @[]

proc chapterStep(a: App, d: int) =
  let p = a.player
  if not p.loaded: return
  var cur = -1
  for i, c in p.chapters:
    if c.time <= p.timePos + 0.01: cur = i
  # With bookmarks as chapters, a bookmark nearer than the chapter mpv would
  # land on wins. mpv never goes back past the current chapter's start.
  if a.cfg.bookmarksAsChapters:
    let marks = a.fileBookmarks
    var bi = -1
    if d > 0:
      let limit = if cur + 1 < p.chapters.len: p.chapters[cur + 1].time else: Inf
      for i, b in marks:
        if b.time > p.timePos + 0.05 and b.time < limit: bi = i; break
    else:
      let limit = if cur >= 0: p.chapters[cur].time else: -Inf
      for i in countdown(marks.high, 0):
        if marks[i].time < p.timePos - 0.5 and marks[i].time > limit: bi = i; break
    if bi >= 0:
      a.seekTo(marks[bi].time)
      a.osd(marks[bi].label(bi))
      return
  if p.chapters.len > 0:
    p.h.commandStr("osd-msg add chapter " & $d)
    # The others' files have chapters of their own: send where this one lands.
    let j = cur + d
    if j >= 0 and j < p.chapters.len: a.syncSend("seek", $p.chapters[j].time, "true")

proc nearestBookmark(a: App, t: float): int =
  ## Index of the current file's bookmark closest to time t, else -1.
  result = -1
  var best = Inf
  for i, b in a.fileBookmarks:
    if abs(b.time - t) < best:
      best = abs(b.time - t)
      result = i

proc editBookmarks(a: App, path: string, edit: proc (marks: var seq[Bookmark])) =
  ## Applies `edit` to a file's bookmarks on the file's latest contents, so
  ## other players' bookmarks aren't overwritten.
  # Editing doesn't wait for the background key.
  if path != a.bmPath: a.keyKnown(path, mediaKey(path))
  let key = a.bmKey
  a.bookmarks = loadBookmarks()
  var e = a.bookmarks.getOrDefault(key)
  edit(e.marks)
  e.path = path
  if e.marks.len > 0: a.bookmarks[key] = e
  else: a.bookmarks.del(key)
  a.bookmarks.save()

proc addBookmark(a: App, t: float) =
  let p = a.player
  if not p.loaded or p.path.len == 0: return
  if a.fileBookmarks.anyIt(abs(it.time - t) < 0.05): return
  a.editBookmarks(p.path, proc (marks: var seq[Bookmark]) =
    var i = 0
    while i < marks.len and marks[i].time < t: inc i
    marks.insert(Bookmark(time: t), i))
  a.osd("Bookmark added at " & fmtTime(t, a.cfg.showMillis))

proc removeBookmark(a: App, t: float) =
  ## Removes the current file's bookmark at time t.
  a.editBookmarks(a.player.path, proc (marks: var seq[Bookmark]) =
    for i, b in marks:
      if b.time == t:
        marks.delete(i)
        break)
  a.osd("Bookmark removed at " & fmtTime(t, a.cfg.showMillis))

proc renameBookmark(a: App, path: string, t: float, name: string) =
  a.editBookmarks(path, proc (marks: var seq[Bookmark]) =
    for b in marks.mitems:
      if b.time == t: b.name = name)

proc xfChanged(a: App, msg: string) =
  a.osd(msg)

# --- synchronize: group and peer messages -----------------------------------

proc syncState(a: App): seq[string] =
  ## Where the master's playback is, for players joining the group.
  let p = a.player
  @["state", $p.loaded, $p.timePos, $p.paused, $p.stopped, $p.speed]

proc setGroup(a: App, members: seq[int]) =
  ## Master (or a player about to become one): the new membership. Newcomers
  ## get where playback is; a group of one dissolves.
  let me = a.peers.pid
  let old = a.syncMembers
  let keep = if members.len > 1: members else: @[]
  for m in old:
    if m != me and m notin keep: a.peers.send(m, "group", "")
  a.syncMembers = keep
  a.syncMaster = if keep.len > 0: me else: 0
  if keep.len == 0: return
  let list = keep.mapIt($it).join(",")
  for m in keep:
    if m == me: continue
    a.peers.send(m, "group", list)
    if m notin old: a.peers.send(m, a.syncState)

proc handleSyncRequest(a: App, op: string, pid: int) =
  ## Master: a membership change asked for here or by a member.
  let me = a.peers.pid
  var members = if a.synced: a.syncMembers else: @[me]
  case op
  of "all":
    for p in a.peers.peers:
      if p.pid notin members: members.add p.pid
  of "none": members.setLen 0
  of "add":
    if pid notin members and a.peers.find(pid) != nil: members.add pid
  of "remove": members.keepItIf(it != pid)
  a.setGroup(members)

proc syncRequest(a: App, op: string, pid = 0) =
  ## Membership changes go through the master; a player that isn't
  ## synchronized starts a group of its own.
  if a.peers == nil: return
  if a.synced and not a.isSyncMaster:
    a.peers.send(a.syncMaster, "request", op, $pid)
  else:
    a.handleSyncRequest(op, pid)

proc leaveGroup(a: App) =
  ## Before joining another group.
  if a.isSyncMaster: a.setGroup(@[])
  elif a.synced: a.peers.send(a.syncMaster, "request", "remove", $a.peers.pid)
  a.syncMaster = 0
  a.syncMembers.setLen 0

proc joined(a: App) =
  ## Just joined a group: the playlist empties (and stays locked); the open
  ## file keeps playing.
  a.playlist.setLen 0
  a.plIndex = -1
  a.plSelected = -1
  a.plScroll = 0

proc remotePlay(a: App) =
  ## Unlike Play here, doesn't restart a file that ended: one shorter than the
  ## master's stays at its end until the group seeks back.
  let p = a.player
  if not p.loaded: return
  p.stopped = false
  p.h.setProp("pause", false)

proc applyState(a: App, loaded: bool, t: float, paused, stopped: bool, speed: float) =
  ## Joins the master's playback: same time (clamped), pause state and rate.
  let p = a.player
  if not loaded or not p.loaded: return
  p.h.setProp("speed", speed)
  if stopped:
    a.stop()
  else:
    a.seekTo(t)
    if paused: a.pause() else: a.remotePlay()

proc handlePeerMessage(a: App, m: Message) =
  let f = m.fields
  let me = a.peers.pid
  template arg(i: int): string = (if i < f.len: f[i] else: "")
  template num(i: int): float =
    (try: parseFloat(arg(i)) except ValueError: 0.0)
  template flag(i: int): bool = arg(i) == "true"
  case f[0]
  of "group":
    let members = arg(1).split(',').filterIt(it.len > 0).mapIt(
      (try: parseInt(it) except ValueError: 0))
    if me in members:
      let isNew = a.syncMaster != m.sender
      if a.synced and isNew: a.leaveGroup()
      a.syncMaster = m.sender
      a.syncMembers = members
      if isNew: a.joined()
    elif a.syncMaster == m.sender:  # left the group, or it was dissolved
      a.syncMaster = 0
      a.syncMembers.setLen 0
    return
  of "request":
    if a.isSyncMaster and m.sender in a.syncMembers:
      a.handleSyncRequest(arg(1), int(num(2)))
    return
  else: discard
  # Everything else only from our own group.
  if not a.synced or m.sender notin a.syncMembers: return
  a.quietly:
    case f[0]
    of "state":
      if m.sender == a.syncMaster: a.applyState(flag(1), num(2), flag(3), flag(4), num(5))
    of "open":  # files launched on a member go into the master's playlist
      if a.isSyncMaster:
        a.syncQuiet = false
        a.openPaths(f[1 .. ^1])
    of "play": a.remotePlay()
    of "pause":
      a.pause()
      a.seekTo(num(1))
    of "stop": a.stop()
    of "seek": a.seekTo(num(1), flag(2))
    of "frame": a.frameStep(flag(1))
    of "speed":
      if a.player.loaded: a.player.h.setProp("speed", num(1))
    else: discard

proc pollPeers(a: App): bool =
  ## Handles peer messages and lost peers; true when anything arrived.
  if a.peers == nil: return
  for m in a.peers.poll():
    result = true
    a.handlePeerMessage(m)
  for pid in a.peers.takeGone():
    result = true
    if pid == a.syncMaster:
      a.syncMaster = 0
      a.syncMembers.setLen 0
      a.osd("Synchronization ended: the master player closed")
    elif a.isSyncMaster and pid in a.syncMembers:
      a.setGroup(a.syncMembers.filterIt(it != pid))
  a.peers.announce(a.player.path.extractFilename, a.syncMaster)

# --- dialogs ----------------------------------------------------------------

proc startDir(a: App): string =
  let custom = a.cfg.openDir.expandPath  # Options > Player > Paths
  if custom.len > 0 and dirExists(custom): custom
  elif a.player.path.len > 0 and fileExists(a.player.path): a.player.path.parentDir
  elif a.cfg.lastDir.len > 0 and dirExists(a.cfg.lastDir): a.cfg.lastDir
  else: getHomeDir()

proc ask(a: App, kind: DialogKind, purpose, title: string, start = "",
         exts: seq[string] = @[], filterName = "",
         extraFilters: seq[(string, seq[string])] = @[]) =
  if a.dialog != nil: return
  a.menus.close()
  a.dialog = startDialog(kind, purpose, title,
    if start.len > 0: start else: a.startDir, exts, filterName, extraFilters)

proc openFileDialog(a: App) =
  a.ask(dkOpenFiles, "open", "Open File", exts = @MediaExtensions,
    filterName = "Media files")

proc screenshot(a: App) =
  if not a.player.loaded: return
  let base = a.player.path.splitFile.name
  let stamp = fmtTime(a.player.timePos).replace(":", ".")
  let dir = a.cfg.screenshotFolder
  if a.cfg.screenshotNoAsk:
    var p = dir / &"{base}_{stamp}.png"
    var n = 2
    while fileExists(p):
      p = dir / &"{base}_{stamp}_{n}.png"
      inc n
    try: createDir(dir)
    except OSError: discard
    if a.player.h.command("screenshot-to-file", p, "video") >= 0:
      a.osd("Screenshot saved: " & p.extractFilename)
    else:
      a.osd("Screenshot failed")
    return
  a.ask(dkSaveFile, "screenshot", "Save Screenshot",
    dir / &"{base}_{stamp}.png", @["png", "jpg", "webp"], "Images")

const PlaylistFilters = @[("M3U playlist", @["m3u", "m3u8"]), ("PLS playlist", @["pls"])]

proc loadPlaylistDialog(a: App) =
  a.ask(dkOpenFile, "plload", "Load Playlist", exts = @PlaylistExtensions,
    filterName = "Playlists", extraFilters = PlaylistFilters)

proc savePlaylistDialog(a: App) =
  a.ask(dkSaveFile, "plsave", "Save Playlist", a.startDir / "Playlist.m3u",
    extraFilters = PlaylistFilters)

const ChapterFilters = @[("Matroska simple chapters", @["txt"])]

proc exportBookmarksDialog(a: App) =
  if a.fileBookmarks.len == 0: return
  let name = a.player.path.extractFilename.splitFile.name
  a.ask(dkSaveFile, "bmexport", "Export Bookmarks",
    a.startDir / name & ".chapters.txt", extraFilters = ChapterFilters)

proc importBookmarksDialog(a: App) =
  if not a.player.loaded: return
  a.ask(dkOpenFile, "bmimport", "Import Bookmarks", exts = @["txt"],
    filterName = "Matroska simple chapters")

proc exportBookmarks(a: App, path: string) =
  var p = path
  if p.splitFile.ext.len == 0: p.add ".txt"
  try:
    writeFile(p, a.fileBookmarks.toSimpleChapters)
    a.osd("Bookmarks exported: " & p.extractFilename)
  except IOError, OSError:
    a.osd("Cannot write " & p.extractFilename)

proc importBookmarks(a: App, path: string) =
  ## Adds the file's chapters to the current file's bookmarks; ones at a
  ## bookmark's time already only fill in its name when it has none.
  if not a.player.loaded or a.player.path.len == 0: return
  var marks: seq[Bookmark]
  try: marks = readFile(path).parseSimpleChapters
  except IOError, OSError, ValueError:
    a.osd("No bookmarks found in " & path.extractFilename)
    return
  var added = 0
  a.editBookmarks(a.player.path, proc (cur: var seq[Bookmark]) =
    for m in marks:
      var j = -1
      for i, b in cur:
        if abs(b.time - m.time) < 0.05: j = i; break
      if j >= 0:
        if cur[j].name.len == 0: cur[j].name = m.name
        continue
      var i = 0
      while i < cur.len and cur[i].time < m.time: inc i
      cur.insert(m, i)
      inc added)
  a.osd(if added == 1: "1 bookmark imported" else: $added & " bookmarks imported")

proc loadPlaylist(a: App, path: string) =
  ## Replaces the playlist with the file's entries and plays the first.
  if a.editLocked: return
  var entries: seq[string]
  try: entries = readPlaylist(path)
  except IOError, OSError:
    a.osd("Cannot read playlist: " & path.extractFilename)
    return
  let files = expandPaths(entries)
  if files.len == 0:
    a.osd("Nothing playable found")
    return
  a.playlist = files
  a.plScroll = 0
  a.playIndex(0)

proc savePlaylist(a: App, path: string) =
  ## M3U, or PLS for a .pls name; .m3u is added when there is no extension.
  var p = path
  if p.splitFile.ext.len == 0: p.add ".m3u"
  var entries: seq[PlaylistEntry]
  for f in a.playlist:
    # durations only as already probed: probing every file here would stall
    let d = if f in a.mediaInfo and a.mediaInfo[f].duration > 0: a.mediaInfo[f].duration
            else: -1.0
    let title = if f.contains("://"): f else: f.splitFile.name
    entries.add PlaylistEntry(path: (if f.contains("://"): f else: f.absolutePath),
                              title: title, duration: d)
  try:
    writePlaylist(p, entries)
    a.osd("Playlist saved: " & p.extractFilename)
  except IOError, OSError:
    a.osd("Cannot save playlist: " & p.extractFilename)

proc askExternal(a: App)  # Run menu, below

proc handleDialogResult(a: App, purpose: string, paths: seq[string]) =
  if paths.len == 0: return
  case purpose
  of "open": a.openPaths(paths)
  of "opendir": a.openPaths(paths[0 .. 0])
  of "pladd": a.addToPlaylist(paths)
  of "plload": a.loadPlaylist(paths[0])
  of "plsave": a.savePlaylist(paths[0])
  of "bmexport": a.exportBookmarks(paths[0])
  of "bmimport": a.importBookmarks(paths[0])
  of "extfile":
    if a.extQueue.len > 0:
      a.extPicks[a.extQueue[0]] = paths[0].absolutePath
      a.extQueue.delete(0)
      a.askExternal()
  of "optshotdir", "optopendir":  # Options > Player > Paths, Browse...
    if a.overlay == ovOptions:
      if purpose == "optshotdir": a.cfg.screenshotDir = paths[0]
      else: a.cfg.openDir = paths[0]
  of "subtitle":
    if a.player.loaded: a.player.h.command("sub-add", paths[0], "select")
  of "audio":
    if a.player.loaded: a.player.h.command("audio-add", paths[0], "select")
  of "screenshot":
    var p = paths[0]
    if p.splitFile.ext.len == 0: p.add ".png"
    if a.player.h.command("screenshot-to-file", p, "video") >= 0:
      a.osd("Screenshot saved: " & p.extractFilename)
    else:
      a.osd("Screenshot failed")

proc pollDialog(a: App) =
  if a.dialog == nil: return
  var done: bool
  let res = a.dialog.poll(done)
  if done:
    let purpose = a.dialog.purpose
    a.dialog = nil
    a.handleDialogResult(purpose, res)

# --- properties -------------------------------------------------------------

proc gatherProperties(a: App) =
  ## MediaInfo-style report, plus how this player is decoding the file.
  let h = a.player.h
  a.props = gatherMediaInfo(h, a.player.path)
  a.propScroll = 0
  var p = InfoSection(title: "Playback")
  template add(k, v: string) =
    if v.len > 0: p.rows.add (k, v)
  if a.player.hasVideo:
    add "Video decoder", h.getStr("video-codec")
    add "Hardware decoding", h.getStr("hwdec-current")
    add "Decoded pixel format", h.getStr("video-params/pixelformat")
    add "Display size", &"{a.player.videoW} x {a.player.videoH}"
    add "Video output", h.getStr("current-vo")
  add "Audio decoder", h.getStr("audio-codec")
  add "Audio output", h.getStr("current-ao")
  add "Audio device", h.getStr("audio-device")
  if p.rows.len > 0: a.props.add p

# --- settings -----------------------------------------------------------------

proc langList(s: string): string =
  ## "eng, jpn" or "eng jpn" -> "eng,jpn" (mpv's list syntax).
  s.multiReplace((";", ","), (" ", ",")).split(',').filterIt(it.len > 0).join(",")

proc subPathList(s: string): string =
  ## "Subs; ~/subs" -> "Subs:/home/me/subs" (mpv's path-list syntax).
  s.split(';').mapIt(it.strip.expandTilde).filterIt(it.len > 0).join(":")

proc applyOsd(a: App) =
  ## Level 3 adds the time / duration status line to the OSD.
  a.player.h.setProp("osd-level",
    if not a.cfg.showOsd: "0" elif a.cfg.osdTimestamp: "3" else: "1")
  # Empty osd-msg3 is mpv's built-in elapsed-time line.
  let f = if a.cfg.showMillis: "/full" else: ""
  a.player.h.setProp("osd-msg3", if not a.cfg.showRemaining: "" else:
    "${osd-sym-cc} -${time-remaining" & f & "} / ${duration" & f & "} (${percent-pos}%)")

proc syncSettings(a: App) =
  ## Pushes the player-facing options to mpv (and the title) when they change.
  let c = a.cfg
  let key = &"{c.showOsd}|{c.osdTimestamp}|{c.showMillis}|{c.showRemaining}|{c.subLangs}|{c.audioLangs}|{c.subDelay}|" &
    &"{c.subPaths}|{c.titleFullPath}|{c.titleUseMediaTitle}"
  if key == a.settingsKey: return
  a.settingsKey = key
  a.applyOsd()
  let h = a.player.h
  h.setProp("slang", langList(c.subLangs))
  h.setProp("alang", langList(c.audioLangs))
  h.setProp("sub-delay", c.subDelay / 1000)
  h.setProp("osd-fractions", if c.showMillis: "yes" else: "no")
  h.setProp("sub-file-paths", subPathList(c.subPaths))
  a.updateTitle()

proc closeOptions(a: App, ok: bool) =
  if ok: a.cfg.save()
  else: a.cfg = a.cfgBefore  # undo the live edits
  a.optUi.focusId = ""
  a.overlay = ovNone
  a.syncSettings()
  if a.optWin.visible:
    a.optWin.visible = false
    a.window.activate()

proc newDialogWindow(a: App, title: string, size: IVec2): (Window, Silky, Ui) =
  ## A hidden dialog window over the main one, with its own Silky and Ui.
  let w = newWindow(title, size, style = Decorated, visible = false,
    vsync = false)
  # Windy made the new window's own context current; it is drawn with the
  # main one instead (same visual), sharing the atlas texture and shaders.
  makeContextCurrent(a.window)
  w.icon = appIcon()
  w.setDialogFor(a.window)
  let sk = newSilky(w, a.atlasImg, a.atlas)
  sk.uiScale = a.sk.uiScale
  sk.atlasScale = a.sk.atlasScale
  let ui = newUi(sk, w)
  let touch = proc () = a.dirtyUntil = now() + 1.2
  let input = proc () =
    touch()
    a.inputPending = true
  w.onMouseMove = touch
  w.onFocusChange = touch
  w.onResize = touch
  w.onScroll = input
  w.onButtonPress = proc (b: Button) = input()
  w.onButtonRelease = proc (b: Button) = input()
  w.onRune = proc (r: Rune) =
    input()
    ui.typedPending.add $r
  (w, sk, ui)

proc ensureOptionsWindow(a: App) =
  if a.optWin != nil: return
  (a.optWin, a.optSk, a.optUi) = a.newDialogWindow("Options", OptionsSize)

proc showDialog(a: App, w: Window, size: IVec2) =
  ## Centres a dialog's frame on the main window's frame (both have the
  ## same decorations), kept on the main window's monitor. size is in UI units.
  let size = a.px(size)
  var pos = a.window.framePos + (a.window.size - size) div 2
  let m = monitorAt(a.window.pos + a.window.size div 2)
  pos.x = clamp(pos.x, m.pos.x, max(m.pos.x, m.pos.x + m.size.x - size.x))
  pos.y = clamp(pos.y, m.pos.y, max(m.pos.y, m.pos.y + m.size.y - size.y))
  w.placeDialog(pos, size)
  w.visible = true
  w.activate()

proc uiScale(a: App): float32 = float32(clamp(a.cfg.uiScale, 50, 300) / 100)

proc applyUiScale(a: App) =
  ## Rebuilds the atlas when Options > Player > UI scaling changed; windows
  ## sized in UI units follow (the main window keeps its size).
  let s = a.uiScale
  if s == a.sk.uiScale: return
  let (img, atlas) = buildAtlas(s)
  (a.atlasImg, a.atlas) = (img, atlas)
  for sk in [a.sk, a.optSk, a.renSk, a.cmdSk, a.pickSk]:
    if sk == nil: continue
    (sk.image, sk.atlas, sk.builder) = (img, atlas, AtlasBuilder(nil))
    sk.uiScale = s
    sk.atlasScale = s
    sk.uploadAtlas()
  for (w, size) in [(a.optWin, OptionsSize), (a.renWin, RenameSize), (a.cmdWin, CommandsSize)]:
    if w != nil and w.visible: a.showDialog(w, size)
  if a.pickWin != nil and a.pickWin.visible:
    let (sw, sh) = a.pickDlg.size
    a.showDialog(a.pickWin, ivec2(sw, sh))
  a.dirtyUntil = now() + 0.5

proc showRename(a: App, i: int) =
  ## Opens the Rename Bookmark dialog for the current file's bookmark i.
  let marks = a.fileBookmarks
  if i < 0 or i >= marks.len: return
  a.menus.close()
  a.renPath = a.player.path
  a.renTime = marks[i].time
  a.renText = marks[i].name
  a.renPlaceholder = marks[i].label(i)
  if a.renWin == nil:
    (a.renWin, a.renSk, a.renUi) = a.newDialogWindow("Rename Bookmark", RenameSize)
  # Type right away, the caret after the current name.
  a.renUi.focusId = "ren-name"
  a.renUi.focusFresh = true
  a.showDialog(a.renWin, RenameSize)
  a.overlay = ovRename

proc closeRename(a: App) =
  a.renUi.focusId = ""
  a.overlay = ovNone
  if a.renWin.visible:
    a.renWin.visible = false
    a.window.activate()

proc latestCommandLine(a: App): CommandLine =
  ## The command line created last (edits keep their place), else a new one.
  if a.commands.len > 0: a.commands[^1] else: CommandLine()

proc showCommands(a: App) =
  ## Opens the Commands window on the command line created last.
  a.menus.close()
  a.commands = loadCommandLines()
  a.cmdDlg.saved = a.commands
  a.cmdDlg.load(a.latestCommandLine)
  if a.cmdWin == nil:
    (a.cmdWin, a.cmdSk, a.cmdUi) = a.newDialogWindow("Commands", CommandsSize)
  a.cmdUi.focusId = "cl-title"
  a.cmdUi.focusFresh = true
  a.cmdUi.navVisible = false
  a.showDialog(a.cmdWin, CommandsSize)
  a.overlay = ovCommands

proc closeCommands(a: App) =
  a.cmdUi.focusId = ""
  a.overlay = ovNone
  if a.cmdWin.visible:
    a.cmdWin.visible = false
    a.window.activate()

proc editCommandLines(a: App, edit: proc (cmds: var seq[CommandLine])) =
  ## Like editBookmarks: applied to the file's latest contents.
  a.commands = loadCommandLines()
  edit(a.commands)
  a.commands.save()

proc setPlaylistShown(a: App, shown: bool) =
  ## Shows or hides the playlist, growing or shrinking the window by its width.
  if a.cfg.showPlaylist == shown: return
  a.cfg.showPlaylist = shown
  let w = int32(a.playlistWidth)
  a.resizeKeepingVideo(ivec2(if shown: w else: -w, 0))

proc setRunLogShown(a: App, shown: bool) =
  ## Shows or hides the run log, growing or shrinking the window by its height.
  if a.cfg.showRunLog == shown: return
  a.cfg.showRunLog = shown
  if shown: a.rlFollow = true
  let h = int32(a.runLogHeight)
  a.resizeKeepingVideo(ivec2(0, if shown: h else: -h))

proc execute(a: App, c: CommandLine, picks = initTable[string, string]()) =
  ## Runs c with bash in the media file's folder, its cards resolved against
  ## the current file and picks (what the Run window gave each card). Output
  ## goes to the run log (and our stdout).
  let path = if a.player.loaded: a.player.path else: ""
  let (script, err) = c.parts.compose(path, picks)
  let dir =
    if path.len > 0 and not path.contains("://"): path.parentDir else: getHomeDir()
  let e = newRunEntry(c.title, dir)
  a.runLog.add e
  a.runLog.trim()
  a.rlFollow = true
  a.setRunLogShown(true)
  if err.len > 0:
    e.error = err
    a.osd(c.title & ": " & err)
    stderr.writeLine "run ", c.title, ": ", err
    return
  try:
    e.start(script)
    a.osd("Running " & c.title)
  except OSError as ex:
    e.error = "cannot run bash: " & ex.msg
    a.osd(c.title & ": cannot run bash")
    stderr.writeLine "run ", c.title, ": ", ex.msg

proc askExternal(a: App) =
  ## Asks for the next external file of a.extRun, then goes on with the run
  ## once all are chosen. Cancelling a dialog cancels the run.
  if a.extQueue.len > 0:
    a.ask(dkOpenFile, "extfile", a.extRun.title & ": " & a.extQueue[0])
    return
  let c = a.extRun
  let cards = c.parts.runCards
  if cards.len == 0:
    a.execute(c, a.extPicks)
    return
  let marks = a.fileBookmarks
  let bookmarks = cards.anyIt(it.kind == ckReference)
  let err =
    if bookmarks and not a.player.loaded: "No media file is open"
    elif bookmarks and marks.len == 0: "The media file has no bookmarks"
    else: ""
  if err.len > 0:
    a.osd(c.title & ": " & err)
    return
  a.menus.close()
  a.pickDlg.start(c, marks, c.lastValues)
  let (sw, sh) = a.pickDlg.size
  if a.pickWin == nil:
    (a.pickWin, a.pickSk, a.pickUi) = a.newDialogWindow("Run", ivec2(sw, sh))
  a.pickWin.title = c.title
  a.pickUi.focusId = ""
  a.pickUi.navId = "pk-0"
  a.pickUi.navVisible = false
  a.showDialog(a.pickWin, ivec2(sw, sh))
  a.overlay = ovPick

proc runCommandLine(a: App, c: CommandLine) =
  ## Runs c, first asking for its external files, bookmarks and values when
  ## it has any.
  a.extRun = c
  a.extQueue = c.parts.externalCards
  a.extPicks = initTable[string, string]()
  a.askExternal()

proc closePick(a: App) =
  a.overlay = ovNone
  if a.pickWin.visible:
    a.pickWin.visible = false
    a.window.activate()

proc pollJobs(a: App) =
  for e in a.runLog:
    if not e.running or not e.poll(): continue
    if a.cfg.showRunLog: a.dirtyUntil = max(a.dirtyUntil, now() + 0.1)
    if not e.running:
      a.osd(if e.stopped: e.title & " stopped"
        elif e.code == 0: e.title & " finished"
        else: &"{e.title} failed (exit code {e.code})")

proc showOverlay(a: App, o: Overlay) =
  a.menus.close()
  if o == ovProperties:
    if not a.player.loaded: return
    a.gatherProperties()
  if o == ovOptions and a.overlay != ovOptions:
    a.cfgBefore = a.cfg
    a.ensureOptionsWindow()
    a.optionsDlg.opened(a.optUi)
    a.showDialog(a.optWin, OptionsSize)
  a.overlay = o

# --- menu tree --------------------------------------------------------------

proc bindAct[T](f: proc (x: T), x: T): proc () =
  ## Binds a value to an action. Closures made directly in a loop would share
  ## the loop's variables; building them here gives each item its own copy.
  result = proc () = f(x)

proc relabeled(n: MenuNode, label: string): MenuNode =
  ## Same item under another name, sharing its action and children.
  result = MenuNode()
  result[] = n[]
  result.label = label

proc buildMenu(a: App): tuple[bar, context: MenuNode] =
  let root = newMenuRoot()
  let p = a.player
  let loaded = p.loaded
  let cfg = addr a.cfg
  let k = proc (act: KeyAction): string = a.cfg.keyText(act)

  # File
  let locked = a.playlistLocked  # synchronized: the master's playlist rules
  let file = root.sub("File")
  file.item("Open File...", k(kaOpenFile), enabled = not locked, action = proc () = a.openFileDialog())
  let recent = file.sub("Open Recent", enabled = a.cfg.recentFiles.len > 0 and not locked)
  let openOne = proc (path: string) = a.openPaths(@[path])
  let removeOne = proc (path: string) =
    let i = a.cfg.recentFiles.find(path)
    if i >= 0: a.cfg.recentFiles.delete(i)
    if a.cfg.recentFiles.len == 0: a.menus.close()
  for r in a.cfg.recentFiles:
    recent.item(r.extractFilename, action = bindAct(openOne, r),
      remove = bindAct(removeOne, r))
  if a.cfg.recentFiles.len > 0:
    recent.sep()
    recent.item("Clear List", action = proc () = a.cfg.recentFiles.setLen 0)
  file.item("Open Directory...", enabled = not locked, action = proc () =
    a.ask(dkOpenDir, "opendir", "Open Directory"))
  file.item("Open From Clipboard", k(kaOpenClipboard), enabled = not locked,
    action = proc () = a.openFromClipboard())
  file.item("Copy to Clipboard", k(kaCopyClipboard), enabled = loaded,
    action = proc () = a.copyToClipboard())
  file.item("Close", k(kaClose), enabled = loaded and not locked, action = proc () = a.closeFile())
  file.sep()
  file.item("Save Screenshot...", k(kaScreenshot), enabled = loaded and p.hasVideo,
    action = proc () = a.screenshot())
  file.sep()
  let loadTrack = file.sub("Load Track From File", enabled = loaded)
  loadTrack.item("Subtitle File...", k(kaLoadSubtitle), action = proc () =
    a.ask(dkOpenFile, "subtitle", "Load Subtitle", exts = @SubtitleExtensions,
      filterName = "Subtitles"))
  loadTrack.item("Audio File...", k(kaLoadAudio), action = proc () =
    a.ask(dkOpenFile, "audio", "Load Audio Track", exts = @MediaExtensions,
      filterName = "Audio files"))
  file.sep()
  file.item("Properties", k(kaProperties), enabled = loaded, action = proc () = a.showOverlay(ovProperties))
  file.sep()
  file.item("Exit", k(kaExit), action = proc () = a.window.closeRequested = true)
  let exitItem = file.children[^1]

  # View
  let view = root.sub("View")
  view.check("Seek Bar", k(kaSeekBar), cfg.showSeekBar, action = proc () =
    a.cfg.showSeekBar = not a.cfg.showSeekBar
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showSeekBar: SeekBarHeight else: -SeekBarHeight))))
  view.check("Controls", k(kaControls), cfg.showControls, action = proc () =
    a.cfg.showControls = not a.cfg.showControls
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showControls: ControlsHeight else: -ControlsHeight))))
  view.check("Status", k(kaStatus), cfg.showStatus, action = proc () =
    a.cfg.showStatus = not a.cfg.showStatus
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showStatus: StatusHeight else: -StatusHeight))))
  view.check("Playlist", k(kaPlaylist), cfg.showPlaylist, action = proc () =
    a.setPlaylistShown(not a.cfg.showPlaylist))
  view.check("Run Log", k(kaRunLog), cfg.showRunLog, action = proc () =
    a.setRunLogShown(not a.cfg.showRunLog))
  view.sep()
  view.check("Show OSD", k(kaShowOsd), cfg.showOsd, action = proc () =
    a.cfg.showOsd = not a.cfg.showOsd
    a.syncSettings())
  view.check("Full Screen", k(kaFullScreen), a.fullscreen, action = proc () =
    a.setFullscreen(not a.fullscreen))
  let fullScreen = view.children[^1]

  let grab = view.sub("Pan, Rotate && Scale".replace("&&", "&"))
  grab.item("Center", k(kaCenter), action = proc () =
    a.xf.pan = vec2(0, 0); a.xfChanged("Pan: center"))
  for (label, key, d) in [("Move Up", kaMoveUp, vec2(0, -1)), ("Move Down", kaMoveDown, vec2(0, 1)),
                          ("Move Left", kaMoveLeft, vec2(-1, 0)), ("Move Right", kaMoveRight, vec2(1, 0))]:
    grab.item(label, k(key), action = bindAct(proc (dir: Vec2) =
      a.xf.pan += dir * a.cfg.panStep.float32
      a.xfChanged(&"Pan: {int(a.xf.pan.x)}, {int(a.xf.pan.y)}"), d))
  grab.sep()
  grab.item("0 Degrees", k(kaRotate0), action = proc () =
    a.xf.rotation = 0; a.xfChanged("Rotation: 0°"))
  grab.item("Rotate Clockwise", k(kaRotateCw), action = proc () =
    a.xf.rotation = floorMod(a.xf.rotation + a.cfg.rotateStep.float32, 360)
    a.xfChanged(&"Rotation: {a.xf.rotation:g}°"))
  grab.item("Rotate Counter-clockwise", k(kaRotateCcw), action = proc () =
    a.xf.rotation = floorMod(a.xf.rotation - a.cfg.rotateStep.float32, 360)
    a.xfChanged(&"Rotation: {a.xf.rotation:g}°"))
  grab.sep()
  grab.item("Restore Size", k(kaRestoreSize), action = proc () =
    a.xf.zoom = 1; a.xf.scaleX = 1; a.xf.scaleY = 1; a.xfChanged("Size: 100%"))
  let step = a.cfg.sizeStep.float32 / 100
  for (label, key, which, d) in [
      ("Increase Size", kaSizeUp, 0, 1'f32), ("Decrease Size", kaSizeDown, 0, -1'f32),
      ("Increase Width", kaWidthUp, 1, 1'f32), ("Decrease Width", kaWidthDown, 1, -1'f32),
      ("Increase Height", kaHeightUp, 2, 1'f32), ("Decrease Height", kaHeightDown, 2, -1'f32)]:
    grab.item(label, k(key), action = bindAct(proc (wd: (int, float32)) =
      let (w, dd) = wd
      case w
      of 0:
        a.xf.zoom = max(0.05, a.xf.zoom + dd * step)
        a.xfChanged(&"Size: {int(round(a.xf.zoom * 100))}%")
      of 1:
        a.xf.scaleX = max(0.05, a.xf.scaleX + dd * step)
        a.xfChanged(&"Width: {int(round(a.xf.scaleX * 100))}%")
      else:
        a.xf.scaleY = max(0.05, a.xf.scaleY + dd * step)
        a.xfChanged(&"Height: {int(round(a.xf.scaleY * 100))}%"), (which, d)))
  grab.sep()
  grab.item("Reset", k(kaPanReset), action = proc () =
    a.xf = VideoTransform(); a.xfChanged("Reset"))

  let frame = view.sub("Video Frame")
  for (label, mode) in [("Half Size", fmHalf), ("Normal Size", fmFull), ("Double Size", fmDouble),
                        ("Stretch To Window", fmStretch), ("Touch Window From Inside", fmTouchInside)]:
    frame.radio(label, "", cfg.frameMode == mode, action = bindAct(proc (m: FrameMode) =
      a.cfg.frameMode = m; a.hintsKey = "", mode))
  frame.sep()
  let ar = frame.sub("Aspect Ratio")
  for (label, value) in [("Original", ""), ("4:3", "4:3"), ("5:4", "5:4"),
                         ("16:9", "16:9"), ("16:10", "16:10")]:
    ar.radio(label, "", cfg.aspectOverride == value, action = bindAct(proc (v: string) =
      a.cfg.aspectOverride = v
      a.hintsKey = ""
      a.fitPending = true, value))
  frame.check("Preserve Aspect Ratio", "", cfg.preserveAspect, action = proc () =
    a.cfg.preserveAspect = not a.cfg.preserveAspect; a.hintsKey = "")
  view.sep()
  let ontop = view.sub("On Top")
  for (label, mode) in [("Default", otDefault), ("Always", otAlways),
                        ("While Playing", otWhilePlaying),
                        ("While Playing Video", otWhilePlayingVideo)]:
    ontop.radio(label, "", cfg.onTop == mode,
      action = bindAct(proc (m: OnTopMode) = a.cfg.onTop = m, mode))
  view.item("Options...", k(kaOptions), action = proc () = a.showOverlay(ovOptions))
  let options = view.children[^1]

  # Play
  let play = root.sub("Play")
  play.item(if p.playing: "Pause" else: "Play", k(kaPlayPause),
    enabled = loaded or a.cfg.recentFiles.len > 0,
    action = proc () = a.playPause())
  play.item("Stop", k(kaStop), enabled = loaded, action = proc () = a.stop())
  let (playPause, stop) = (play.children[0], play.children[1])
  play.item("Frame Forward", k(kaFrameForward), enabled = loaded, action = proc () = a.frameStep(true))
  play.item("Frame Back", k(kaFrameBack), enabled = loaded, action = proc () = a.frameStep(false))
  play.item(&"Faster Playback (+{a.cfg.rateStep:g}x)", k(kaFaster), enabled = loaded,
    action = proc () = a.changeRate(1))
  play.item(&"Slower Playback (-{a.cfg.rateStep:g}x)", k(kaSlower), enabled = loaded,
    action = proc () = a.changeRate(-1))
  let rep = play.sub("Repeat")
  rep.check("Forever", k(kaRepeatForever), cfg.repeatForever, action = proc () =
    a.cfg.repeatForever = not a.cfg.repeatForever; a.applyLoop())
  rep.sep()
  rep.radio("File", "", cfg.repeatMode == rmFile, action = proc () =
    a.cfg.repeatMode = rmFile; a.applyLoop())
  rep.radio("Playlist", "", cfg.repeatMode == rmPlaylist, action = proc () =
    a.cfg.repeatMode = rmPlaylist; a.applyLoop())
  rep.sep()
  rep.check("Loop A-B", "", a.abLoop and a.loopReady, enabled = loaded and a.loopReady,
    action = proc () =
      a.abLoop = not a.abLoop; a.applyAbLoop())
  play.sep()
  var trackMenus: seq[MenuNode]
  let selectTrack = proc (pt: (string, int)) = a.setTrack(pt[0], pt[1])
  for (title, kind, prop) in [("Audio Track", "audio", "aid"),
                              ("Subtitle Track", "sub", "sid"),
                              ("Video Track", "video", "vid")]:
    let m = play.sub(title, enabled = loaded)
    trackMenus.add m
    m.radio("None", "", p.selectedTrack(kind) == 0, action = bindAct(selectTrack, (prop, 0)))
    for t in p.tracks:
      if t.kind == kind:
        m.radio(t.trackLabel, "", t.selected, action = bindAct(selectTrack, (prop, t.id)))
  play.sep()
  let vol = play.sub("Volume")
  vol.item("Up", k(kaVolumeUp), action = proc () = a.volumeStep(true))
  vol.item("Down", k(kaVolumeDown), action = proc () = a.volumeStep(false))
  vol.check("Mute", k(kaMute), p.muted, action = proc () = a.setMute(not a.player.muted))
  vol.item("Max", action = proc () =
    a.player.setVolume(100); a.osd("Volume: 100%"))
  let after = play.sub("After Playback")
  for (label, mode) in [("Do Nothing", apNothing), ("Play Next File In The Folder", apNextInFolder),
                        ("Turn Off The Monitor", apMonitorOff), ("Exit", apExit),
                        ("Sleep", apSleep), ("Hibernate", apHibernate),
                        ("Shutdown", apShutdown), ("Log Off", apLogOff), ("Lock", apLock)]:
    after.radio(label, "", a.afterPlayback == mode,
      action = bindAct(proc (m: AfterPlayback) = a.afterPlayback = m, mode))

  # Navigate
  let nav = root.sub("Navigate")
  let bm = nav.sub("Bookmarks", enabled = loaded)
  bm.item("Add Bookmark", k(kaAddBookmark), enabled = loaded, action = proc () = a.addBookmark(a.player.timePos))
  bm.item("Remove Bookmark", enabled = a.fileBookmarks.len > 0, action = proc () =
    let i = a.nearestBookmark(a.player.timePos)
    if i >= 0: a.removeBookmark(a.fileBookmarks[i].time))
  bm.sep()
  bm.item("Import Bookmarks...", enabled = loaded, action = proc () = a.importBookmarksDialog())
  bm.item("Export Bookmarks...", enabled = a.fileBookmarks.len > 0,
    action = proc () = a.exportBookmarksDialog())
  let marks = a.fileBookmarks
  if marks.len > 0:
    bm.sep()
    for i, b in marks:
      bm.item(fmtTime(b.time) & "  " & b.label(i), action = bindAct(proc (t: float) = a.seekTo(t), b.time))
  nav.sep()
  nav.item(&"Jump Forward {a.cfg.seekStep:g}s", k(kaJumpForward), enabled = loaded,
    action = proc () = a.seekRelative(a.cfg.seekStep))
  nav.item(&"Jump Back {a.cfg.seekStep:g}s", k(kaJumpBack), enabled = loaded,
    action = proc () = a.seekRelative(-a.cfg.seekStep))
  nav.item("Go To Beginning", k(kaGoBeginning), enabled = loaded, action = proc () = a.seekTo(0))
  nav.sep()
  let hasCh = p.chapters.len > 0
  let canStep = hasCh or (a.cfg.bookmarksAsChapters and a.fileBookmarks.len > 0)
  let chm = nav.sub("Chapters", enabled = hasCh)
  for i, c in p.chapters:
    let label = fmtTime(c.time) & "  " & (if c.title.len > 0: c.title else: &"Chapter {i + 1}")
    chm.item(label, action = bindAct(proc (t: float) = a.seekTo(t), c.time))
  nav.item("Next Chapter", k(kaNextChapter), enabled = canStep, action = proc () = a.chapterStep(1))
  nav.item("Previous Chapter", k(kaPrevChapter), enabled = canStep, action = proc () = a.chapterStep(-1))
  nav.sep()
  nav.item("Next File", k(kaNextFile), enabled = loaded and not locked, action = proc () = a.navigate(1))
  nav.item("Previous File", k(kaPrevFile), enabled = loaded and not locked, action = proc () = a.navigate(-1))

  # Synchronize: the other players found, checked when in our group.
  let syn = root.sub("Synchronize")
  let others = if a.peers == nil: newSeq[Peer]() else: a.peers.peers
  syn.item("Connect All", enabled = others.anyIt(it.pid notin a.syncMembers),
    action = proc () = a.syncRequest("all"))
  syn.item("Disconnect All", enabled = a.synced, action = proc () = a.syncRequest("none"))
  syn.sep()
  if others.len == 0:
    syn.item("No other players running", enabled = false)
  let toggle = proc (pid: int) =
    if pid notin a.syncMembers: a.syncRequest("add", pid)
    # Unchecking the master leaves its group.
    elif pid == a.syncMaster: a.syncRequest("remove", a.peers.pid)
    else: a.syncRequest("remove", pid)
  for peer in others.sortedByIt(it.pid):
    var label = (if peer.title.len > 0: peer.title else: "No file") & &"  (PID {peer.pid})"
    if peer.pid == a.syncMaster: label.add "  · master"
    elif peer.master != 0 and peer.pid notin a.syncMembers: label.add "  · synchronized elsewhere"
    syn.check(label, checked = peer.pid in a.syncMembers, action = bindAct(toggle, peer.pid))

  # Run: the Commands window and the command lines it saved.
  let run = root.sub("Run")
  run.item("Commands...", action = proc () = a.showCommands())
  run.sep()
  if a.commands.len == 0:
    run.item("No command lines", enabled = false)
  let runOne = proc (c: CommandLine) = a.runCommandLine(c)
  for c in a.commands:
    run.item(c.title, action = bindAct(runOne, c))

  # Help
  let help = root.sub("Help")
  help.item("Keyboard Shortcuts", k(kaShortcuts), action = proc () = a.showOverlay(ovShortcuts))
  help.item("About " & AppName, action = proc () = a.showOverlay(ovAbout))

  # Right-click menu, built from the bar's nodes.
  let ctx = newMenuRoot()
  if p.isSpherical:
    ctx.check("Ctrl+Drag to Look",
      checked = a.cfg.sphereDragMovesWindow, action = proc () =
        a.cfg.sphereDragMovesWindow = not a.cfg.sphereDragMovesWindow
        a.cfg.save())
    ctx.sep()
  ctx.children.add file
  ctx.sep()
  ctx.children.add [playPause.relabeled("Play/Pause"), stop, rep]
  ctx.sep()
  ctx.children.add [fullScreen, frame, grab]
  ctx.sep()
  ctx.children.add nav
  ctx.sep()
  ctx.children.add [trackMenus[0].relabeled("Audio"), trackMenus[1].relabeled("Subtitles"),
                    trackMenus[2].relabeled("Video")]
  ctx.sep()
  ctx.children.add after
  ctx.sep()
  ctx.children.add view
  ctx.sep()
  ctx.children.add options
  ctx.sep()
  ctx.children.add exitItem

  case a.ctxMenu
  of cmVideo: (root, ctx)
  of cmRepeat:
    let rc = newMenuRoot()
    rc.children = rep.children
    (root, rc)
  of cmTime:
    let timeCtx = newMenuRoot()
    timeCtx.check("Enable milliseconds", checked = a.cfg.showMillis, action = proc () =
      a.cfg.showMillis = not a.cfg.showMillis
      a.cfg.save())
    timeCtx.check("Show remaining time", checked = a.cfg.showRemaining, action = proc () =
      a.cfg.showRemaining = not a.cfg.showRemaining
      a.cfg.save())
    (root, timeCtx)
  of cmStatus:
    let st = newMenuRoot()
    st.check("Show all shortcuts", checked = a.cfg.showAllShortcuts, action = proc () =
      a.cfg.showAllShortcuts = not a.cfg.showAllShortcuts
      a.cfg.save())
    (root, st)
  of cmSeekBar:
    # Adds at the time clicked; edits or removes the bookmark clicked on.
    let sb = newMenuRoot()
    let i = a.ctxBookmark
    let on = i >= 0 and i < a.fileBookmarks.len
    let (t, bt) = (a.ctxSeekT, if on: a.fileBookmarks[i].time else: 0.0)
    sb.item("Add Bookmark", enabled = loaded and not on, action = proc () = a.addBookmark(t))
    sb.item("Edit Bookmark...", enabled = on, action = proc () = a.showRename(i))
    sb.item("Remove Bookmark", enabled = on, action = proc () = a.removeBookmark(bt))
    if a.ctxOnMarker:
      let mt = a.ctxMarkerT
      sb.sep()
      for (isB, has, lt, name) in [(false, a.hasLoopA, a.loopA, "Loop A"),
                                   (true, a.hasLoopB, a.loopB, "Loop B")]:
        if has and abs(lt - mt) < 0.001:
          sb.check(name, checked = true, action = bindAct(proc (b: bool) = a.unsetLoopMark(b), isB))
        else:
          sb.check(name, checked = false, action = bindAct(proc (b: bool) = a.setLoopMark(b, mt), isB))
      sb.item("Clear Loop", enabled = a.hasLoopA or a.hasLoopB, action = proc () =
        a.clearLoopMarks(); a.osd("Loop cleared"))
    sb.sep()
    sb.check("Bookmarks as chapters", checked = a.cfg.bookmarksAsChapters, action = proc () =
      a.cfg.bookmarksAsChapters = not a.cfg.bookmarksAsChapters
      a.cfg.save())
    (root, sb)
  of cmPlaylist:
    let pl = newMenuRoot()
    let n = a.playlist.len
    let sel = a.plSelected
    let hasSel = sel >= 0 and sel < n
    let edit = not locked
    if hasSel:
      let path = a.playlist[sel]
      pl.item("Open Containing Directory", enabled = not path.contains("://"),
        action = proc () = a.showInFolder(path))
      pl.sep()
    else:
      pl.item("Add Media File...", enabled = edit, action = proc () =
        a.ask(dkOpenFiles, "pladd", "Add Media File", exts = @MediaExtensions,
          filterName = "Media files"))
    pl.item("Remove Media File", k(kaRemoveFromPlaylist), enabled = hasSel and edit, action = proc () =
      a.removeSelected())
    pl.sep()
    let sortBy = proc (by: PlaylistSort) = a.sortPlaylist(by)
    for (label, by) in [("Sort by A-Z", psName), ("Sort by Duration", psDuration),
                        ("Sort by Dimensions", psDimensions), ("Sort by Size", psSize)]:
      pl.item(label, enabled = n > 1 and edit, action = bindAct(sortBy, by))
    pl.sep()
    let moveTo = proc (i: int) = a.moveSelected(i)
    pl.item("Move to Top", enabled = hasSel and sel > 0 and edit, action = bindAct(moveTo, 0))
    pl.item("Move Up", enabled = hasSel and sel > 0 and edit, action = bindAct(moveTo, sel - 1))
    pl.item("Move Down", enabled = hasSel and sel < n - 1 and edit, action = bindAct(moveTo, sel + 1))
    pl.item("Move to Bottom", enabled = hasSel and sel < n - 1 and edit, action = bindAct(moveTo, n - 1))
    pl.sep()
    pl.item("Randomize", enabled = n > 1 and edit, action = proc () = a.randomizePlaylist())
    pl.sep()
    pl.item("Save Playlist...", enabled = n > 0, action = proc () = a.savePlaylistDialog())
    pl.item("Load Playlist...", enabled = edit, action = proc () = a.loadPlaylistDialog())
    pl.sep()
    pl.item("Clear", enabled = n > 0 and edit, action = proc () = a.clearPlaylist())
    (root, pl)
  of cmPlaylistColumns:
    let cols = newMenuRoot()
    cols.check("Size", checked = a.cfg.playlistShowSize, action = proc () =
      a.cfg.playlistShowSize = not a.cfg.playlistShowSize)
    cols.check("Dimensions", checked = a.cfg.playlistShowDimensions, action = proc () =
      a.cfg.playlistShowDimensions = not a.cfg.playlistShowDimensions)
    (root, cols)

# --- keyboard ---------------------------------------------------------------

proc runMenuPath(a: App, path: seq[string]) =
  ## Runs the action of the menu item at path, e.g. @["View", "Seek Bar"].
  var node = a.buildMenu().bar
  for name in path:
    var found: MenuNode
    for ch in node.children:
      if ch.label == name: found = ch
    if found == nil:
      if existsEnv("MMP_SCRIPT"):
        stderr.writeLine "menu path not found: ", name, " in ", $node.children.mapIt(it.label)
      return
    node = found
  if node.action != nil and node.enabled: node.action()

# --- subtitle placement ------------------------------------------------------

const
  SubMoveStep = 2'f32        ## Shift+arrows, screen pixels
  SubScaleStep = 0.1'f32     ## Shift+Numpad +/-
  SubMarginX = 19            ## mpv's sub-margin-x / sub-margin-y defaults
  SubMarginY = 34
  OsdMargin = 16'f32         ## mpv's osd-margin-x / osd-margin-y defaults
  OsdOutline = 1.65'f32      ## osd-outline-size
  OsdBarW = 75'f32           ## osd-bar-w / -h (percent), -align-x / -y
  OsdBarH = 3.125'f32
  OsdBarAlign = (x: 0'f32, y: 0.5'f32)
  OsdBarOutline = 0.5'f32    ## osd-bar-outline-size
  OsdBarMarkerMin = 1.6'f32  ## osd-bar-marker-min-size

proc alignSubs(a: App, x, y: int) =
  ## Re-aligning drops the nudge: it was relative to the old anchor.
  a.subs.alignX = x
  a.subs.alignY = y
  a.subs.offset = vec2(0, 0)
  const names = [["Top Left", "Top", "Top Right"], ["Left", "Middle", "Right"],
                 ["Bottom Left", "Bottom", "Bottom Right"]]
  a.osd("Subtitles: " & names[y][x])

proc moveSubs(a: App, d: Vec2) =
  a.subs.offset += d
  a.osd(&"Subtitle offset: {int(a.subs.offset.x)}, {int(a.subs.offset.y)}")

proc scaleSubs(a: App, dir: float32) =
  a.subs.scale = clamp(round((a.subs.scale + dir * SubScaleStep) * 10) / 10, 0.2'f32, 5'f32)
  let path = a.player.path
  if a.player.loaded and path.len > 0:
    # Reloaded first so sizes other players remembered meanwhile survive.
    a.subScales = loadSubScales()
    if a.subs.scale == 1: a.subScales.del(path)
    else: a.subScales.remember(path, a.subs.scale)
    a.subScales.save()
  a.osd(&"Subtitle size: {int(round(a.subs.scale * 100))}%")

proc subPadding(a: App): tuple[l, r, t, b: float32] =
  ## mpv can't shift centered subtitles, but text subtitles are laid out on
  ## the whole render target while video-margin-ratio keeps the video out of
  ## its margins: padding one side of the target moves them by half of it.
  let o = a.subs.offset
  if a.subs.alignX == 1:
    result.l = max(0, -2 * o.x)
    result.r = max(0, 2 * o.x)
  if a.subs.alignY == 1:
    result.t = max(0, -2 * o.y)
    result.b = max(0, 2 * o.y)

proc marginFill(a: App, target: (int, int), mx, my: (int, int)): (float32, float32) =
  ## video-scale-x/y that stretch mpv's aspect-fitted video over the whole
  ## box left inside the margins: mpv only honors the margins with
  ## keepaspect, and keepaspect would otherwise undo the frame's own aspect
  ## (Stretch, Increase Width...). Mirrors aspect_calc_panscan, plus half a
  ## pixel so mpv's truncation lands on the box edge.
  let (dw, dh) = (a.player.videoW.float32, a.player.videoH.float32)
  if dw <= 0 or dh <= 0: return (1'f32, 1'f32)
  let boxW = target[0] - mx[0] - mx[1]
  let boxH = target[1] - my[0] - my[1]
  var fw = boxW
  var fh = int(boxW.float32 / dw * dh)
  if fh > boxH or fh < a.player.videoH:
    let tw = int(boxH.float32 / dh * dw)
    if tw <= boxW:
      fh = boxH
      fw = tw
  ((boxW.float32 + 0.5) / max(1, fw).float32, (boxH.float32 + 0.5) / max(1, fh).float32)

const OsdPlayResY = 288.0  ## mpv's canvas height for the OSD and text subtitles

proc lrint(x: float): float =
  ## C's lrint under the default rounding mode: halves go to the even side.
  let f = floor(x)
  if x - f > 0.5 or (x - f == 0.5 and (int64(f) and 1) != 0): f + 1 else: f

proc subMarginPx(marginX, w, h, cw, ch: int): float =
  ## Pixels between a left/right-anchored text subtitle and the target's edge
  ## for --sub-margin-x=marginX, in a w x h target holding a cw x ch video:
  ## mpv truncates the margin to 288-high units, rescales it to its
  ## video-aspect PlayResX (sd_ass configure_ass) and libass maps those
  ## units over the video fitted into the target (fit_width).
  let resX = float(int(OsdPlayResY * (float(cw) / float(ch))))
  let units = lrint(float(int(float(marginX) * OsdPlayResY / 720)) * resX / 384)
  let fit = if cw * h >= ch * w: float(w) else: float(cw) * float(h) / float(ch)
  units * fit / resX

proc unitsOpt(units: int): int =
  ## Smallest margin option mpv truncates to `units` 288-high units.
  int(ceil(float(units) * 720 / OsdPlayResY + 0.1))

proc osdLayout(alignX, marginX: int, target: (int, int), mx, my: (int, int)):
    tuple[target, x, y: (int, int), subMarginX: int, props: string] =
  ## The OSD is laid out on the whole (padded) target: counter-scale and
  ## re-place it so it keeps the look and spot it has on the unpadded video.
  ## Its canvas is 288 units high (PlayResX = 288 * aspect, truncated) and
  ## mpv truncates its margins to whole units, ~2 pixels or more, so a padded
  ## target gets extra pixels on both sides of each axis, chosen so whole
  ## units land on the spot. They leave centered subtitles in place; anchored
  ## ones get their sub-margin-x redone to stay put. Returns the grown target
  ## and margins, the subtitles' margin option and the OSD property settings.
  let (cw, ch) = (target[0] - mx[0] - mx[1], target[1] - my[0] - my[1])
  result = (target, mx, my, marginX, "")
  if cw <= 0 or ch <= 0: return
  let (vw, vh) = (float(cw), float(ch))
  proc playResX(w, h: float): float = float(int(OsdPlayResY * (w / h)))
  const marginUnits = int(OsdMargin * OsdPlayResY / 720)  # mpv's own text margin
  # Where the text sits on the unpadded video, in target pixels.
  let textX = float(marginUnits) * vw / playResX(vw, vh)
  let textY = float(marginUnits) * vh / OsdPlayResY
  # Where the anchored subtitles sit, from the video's left edge.
  proc subX(m, w, h, left: int): float =
    let px = subMarginPx(m, w, h, cw, ch)
    (if alignX == 0: px else: float(w) - px) - float(left)
  let subRef = subX(marginX, target[0], target[1], mx[0])
  let padded = mx[0] + mx[1] + my[0] + my[1] > 0
  # Each extra pixel moves the spot by one but also grows the units the
  # margin is made of, so the farther the margin, the more pixels it takes
  # to sweep a whole unit; anchored subtitles' units add their own period.
  let (w0, h0) = (float(target[0]), float(target[1]))
  let (ux0, uy0) = (w0 / playResX(w0, h0), h0 / OsdPlayResY)
  let slowX = max(0.08, 1 - 2 * (textX + float(mx[0])) / ux0 / playResX(w0, h0))
  let slowY = max(0.08, 1 - 2 * (textY + float(my[0])) / uy0 / OsdPlayResY)
  let spanX = if not padded: 0 else: min(400, max(64, max(int(24 * uy0), int(32 / slowX))))
  let spanY = if not padded or my[0] + my[1] == 0: 0 else: min(400, max(32, int(32 / slowY)))
  var best = (score: Inf, ex: 0, ey: 0, ml: marginUnits, mv: marginUnits, sm: marginX)
  for ey in 0 .. spanY:
    for ex in 0 .. spanX:
      let left = mx[0] + ex
      let (w, h) = (target[0] + 2 * ex, target[1] + 2 * ey)
      let (ux, uy) = (float(w) / playResX(float(w), float(h)), float(h) / OsdPlayResY)  # pixels per unit
      let (x, y) = (textX + float(left), textY + float(my[0] + ey))
      let (ml, mv) = (int(round(x / ux)), int(round(y / uy)))
      var err = max(abs(float(ml) * ux - x), abs(float(mv) * uy - y))
      var sm = marginX
      if alignX != 1 and ex > 0:
        # Redo the subtitles' margin for the moved edge: try the unit counts
        # around the one that would put them back.
        let need = (if alignX == 0: subRef + float(left) else: float(w - left) - subRef)
        var subErr = Inf
        let perUnit = subMarginPx(unitsOpt(8), w, h, cw, ch) / 8  # pixels per 288-high unit, roughly
        let k = int(need / perUnit)
        for kk in max(0, k - 2) .. k + 2:
          let m = unitsOpt(kk)
          let e = abs(subX(m, w, h, left) - subRef)
          if e < subErr: (subErr, sm) = (e, m)
        err = max(err, 2 * subErr)  # the subtitles are what's being watched
      let score = err + 0.001 * float(ex + ey)  # equal fits: less padding
      if score < best.score: best = (score, ex, ey, ml, mv, sm)
  let (ex, ey) = (best.ex, best.ey)
  result.target = (target[0] + 2 * ex, target[1] + 2 * ey)
  result.x = (mx[0] + ex, mx[1] + ex)
  result.y = (my[0] + ey, my[1] + ey)
  result.subMarginX = best.sm
  let (w, h) = (float(result.target[0]), float(result.target[1]))
  let (resX0, resX) = (playResX(vw, vh), playResX(w, h))
  let f = vh / h  # undoes the taller canvas's bigger units
  let barOutline = OsdBarOutline * f
  let barW = OsdBarW * vw / w
  let barH = max(0.1, OsdBarH * f)
  proc align(a, frame0, unit0, offset, frame, unit: float, obj, border: float): float =
    ## osd-bar-align that puts the bar where `a` puts it on the unpadded
    ## video (mirrors mpv's get_align; frames in units, units in pixels).
    let (obj0, border0) = (obj * unit / unit0, border * unit / unit0)
    let pos0 = border0 + (frame0 - 2 * border0 - obj0) / 2 * (1 + a)
    let pos = (pos0 * unit0 + offset) / unit
    let free = (frame - 2 * border - obj) / 2
    if free <= 0: a else: clamp((pos - border - free) / free, -1.0, 1.0)
  let barX = align(OsdBarAlign.x, resX0, vw / resX0, float(result.x[0]), resX, w / resX,
                   resX * barW / 100, barOutline)
  let barY = align(OsdBarAlign.y, OsdPlayResY, vh / OsdPlayResY, float(result.y[0]), OsdPlayResY,
                   h / OsdPlayResY, OsdPlayResY * barH / 100, barOutline)
  let (scale, outline, markerMin) = (f, OsdOutline * f, OsdBarMarkerMin * f)
  result.props = &"osd-scale={scale:.6f}|osd-margin-x={unitsOpt(best.ml)}|" &
    &"osd-margin-y={unitsOpt(best.mv)}|osd-outline-size={outline:.6f}|" &
    &"osd-bar-w={barW:.6f}|osd-bar-h={barH:.6f}|osd-bar-align-x={barX:.6f}|" &
    &"osd-bar-align-y={barY:.6f}|osd-bar-outline-size={barOutline:.6f}|" &
    &"osd-bar-marker-min-size={markerMin:.6f}"

proc applySubLayout(a: App, video: Vec2, pad: tuple[l, r, t, b: float32],
                    target: (int, int)): tuple[x, y: (int, int), target: (int, int)] =
  ## Pushes the placement for a video drawn `video` pixels big into a
  ## `target` pixels big render target, returning the margins (target
  ## pixels) mpv keeps the video out of and the target size, which the OSD
  ## placement may grow by a few pixels. The anchored
  ## cases use mpv's own margins, in scaled pixels: 720 of them span the
  ## height, and text subtitles' 384x288 canvas makes 960 span the width.
  let s = a.subs
  let full = video + vec2(pad.l + pad.r, pad.t + pad.b)
  let (kx, ky) = (full.x / 960, full.y / 720)
  let marginX0 =
    case s.alignX
    of 0: max(0, int(round(SubMarginX + s.offset.x / kx)))
    of 2: max(0, int(round(SubMarginX - s.offset.x / kx)))
    else: SubMarginX
  let marginY = if s.alignY == 0: max(0, int(round(SubMarginY + s.offset.y / ky))) else: SubMarginY
  let pos = if s.alignY == 2: clamp(100 + s.offset.y / video.y * 100, 0'f32, 150'f32) else: 100'f32
  # Whole target pixels per margin; the ratios carry an extra half pixel so
  # mpv's truncation (calc_margin) lands on exactly these.
  let mx0 = (int(round(pad.l / full.x * target[0].float32)), int(round(pad.r / full.x * target[0].float32)))
  let my0 = (int(round(pad.t / full.y * target[1].float32)), int(round(pad.b / full.y * target[1].float32)))
  let fitKey = &"{s.alignX}|{s.alignY}|{marginX0}|{target}|{mx0}|{my0}"
  if a.osdFit.key != fitKey:
    let (t, x, y, m, props) = osdLayout(s.alignX, marginX0, target, mx0, my0)
    a.osdFit = (fitKey, t, x, y, m, props)
  let (target, mx, my, osd) = (a.osdFit.target, a.osdFit.x, a.osdFit.y, a.osdFit.props)
  let marginX = a.osdFit.subMarginX
  # Subtitles scale with the target height; keep padding from growing them.
  let scale = s.scale * float32(target[1] - my[0] - my[1]) / target[1].float32
  proc ratio(m, size: int): float32 = (if m > 0: (m.float32 + 0.5) / size.float32 else: 0)
  let ratios = (l: ratio(mx[0], target[0]), r: ratio(mx[1], target[0]),
                t: ratio(my[0], target[1]), b: ratio(my[1], target[1]))
  let padded = mx[0] + mx[1] + my[0] + my[1] > 0
  result = (mx, my, target)
  let (fillX, fillY) = if padded: a.marginFill(target, mx, my) else: (1'f32, 1'f32)
  let key = &"{s.alignX}|{s.alignY}|{marginX}|{marginY}|{pos:.3f}|{scale:.4f}|" &
    &"{ratios.l:.5f}|{ratios.r:.5f}|{ratios.t:.5f}|{ratios.b:.5f}|{fillX:.6f}|{fillY:.6f}|{osd}"
  if key == a.subsKey: return
  a.subsKey = key
  let h = a.player.h
  h.setProp("sub-align-x", ["left", "center", "right"][s.alignX])
  h.setProp("sub-align-y", ["top", "center", "bottom"][s.alignY])
  h.setProp("sub-margin-x", $marginX)
  h.setProp("sub-margin-y", $marginY)
  h.setProp("sub-pos", pos)
  h.setProp("sub-scale", scale)
  h.setProp("video-margin-ratio-left", ratios.l)
  h.setProp("video-margin-ratio-right", ratios.r)
  h.setProp("video-margin-ratio-top", ratios.t)
  h.setProp("video-margin-ratio-bottom", ratios.b)
  # Unpadded, keepaspect stays off: the target already has the frame's aspect.
  h.setProp("keepaspect", padded)
  h.setProp("video-scale-x", fillX)
  h.setProp("video-scale-y", fillY)
  for kv in osd.split('|'):
    if kv.len > 0:
      let p = kv.split('=')
      h.setProp(p[0], p[1])

const PanMenuLabels: array[kaCenter .. kaPanReset, string] = [
  "Center", "Move Up", "Move Down", "Move Left", "Move Right", "0 Degrees",
  "Rotate Clockwise", "Rotate Counter-clockwise", "Restore Size", "Increase Size",
  "Decrease Size", "Increase Width", "Decrease Width", "Increase Height",
  "Decrease Height", "Reset"]

proc runAction(a: App, act: KeyAction) =
  ## Carries out a rebindable command (Options > Player > Keys). View toggles
  ## and Pan/Rotate/Scale go through the menu actions so the window-resizing
  ## side effects live in one place.
  case act
  of kaOpenFile: a.openFileDialog()
  of kaLoadSubtitle:
    if a.player.loaded:
      a.ask(dkOpenFile, "subtitle", "Load Subtitle", exts = @SubtitleExtensions,
        filterName = "Subtitles")
  of kaLoadAudio:
    if a.player.loaded:
      a.ask(dkOpenFile, "audio", "Load Audio Track", exts = @MediaExtensions,
        filterName = "Audio files")
  of kaOpenClipboard: a.openFromClipboard()
  of kaCopyClipboard: a.copyToClipboard()
  of kaClose: a.closeFile()
  of kaScreenshot: a.screenshot()
  of kaProperties: a.showOverlay(ovProperties)
  of kaExit: a.window.closeRequested = true
  of kaPlayPause: a.playPause()
  of kaStop: a.runMenuPath(@["Play", "Stop"])
  of kaFrameForward: a.frameStep(true)
  of kaFrameBack: a.frameStep(false)
  of kaFaster: a.changeRate(1)
  of kaSlower: a.changeRate(-1)
  of kaRepeatForever: a.runMenuPath(@["Play", "Repeat", "Forever"])
  of kaVolumeUp: a.volumeStep(true)
  of kaVolumeDown: a.volumeStep(false)
  of kaMute: a.setMute(not a.player.muted)
  of kaNextAudio: a.cycleTrack("aid", true)
  of kaPrevAudio: a.cycleTrack("aid", false)
  of kaNextSub: a.cycleTrack("sid", true)
  of kaPrevSub: a.cycleTrack("sid", false)
  of kaJumpForward: a.seekRelative(a.cfg.seekStep)
  of kaJumpBack: a.seekRelative(-a.cfg.seekStep)
  of kaGoBeginning: a.seekTo(0)
  of kaSeek10 .. kaSeek90:
    if a.player.loaded:
      let k = act.ord - kaSeek10.ord + 1
      a.player.stopped = false
      a.player.h.commandAsync("seek", $(k * 10), "absolute-percent")
      a.syncSend("seek", $(a.player.duration * k.float / 10), "true")
  of kaNextChapter: a.chapterStep(1)
  of kaPrevChapter: a.chapterStep(-1)
  of kaNextFile: a.navigate(1)
  of kaPrevFile: a.navigate(-1)
  of kaAddBookmark: a.addBookmark(a.player.timePos)
  of kaRemoveFromPlaylist:
    if a.cfg.showPlaylist: a.removeSelected()
  of kaSubTopLeft .. kaSubBottomRight:
    # The numpad as a 3x3 grid.
    let i = act.ord - kaSubTopLeft.ord
    a.alignSubs(i mod 3, i div 3)
  of kaSubUp: a.moveSubs(vec2(0, -SubMoveStep))
  of kaSubDown: a.moveSubs(vec2(0, SubMoveStep))
  of kaSubMoveLeft: a.moveSubs(vec2(-SubMoveStep, 0))
  of kaSubMoveRight: a.moveSubs(vec2(SubMoveStep, 0))
  of kaSubBigger: a.scaleSubs(1)
  of kaSubSmaller: a.scaleSubs(-1)
  of kaSeekBar: a.runMenuPath(@["View", "Seek Bar"])
  of kaControls: a.runMenuPath(@["View", "Controls"])
  of kaStatus: a.runMenuPath(@["View", "Status"])
  of kaPlaylist: a.runMenuPath(@["View", "Playlist"])
  of kaRunLog: a.runMenuPath(@["View", "Run Log"])
  of kaShowOsd: a.runMenuPath(@["View", "Show OSD"])
  of kaFullScreen: a.setFullscreen(not a.fullscreen)
  of kaOptions: a.showOverlay(ovOptions)
  of kaShortcuts: a.showOverlay(ovShortcuts)
  of kaCenter .. kaPanReset:
    a.runMenuPath(@["View", "Pan, Rotate & Scale", PanMenuLabels[act]])

proc handleKeys(a: App) =
  let w = a.window
  let pressed = w.buttonPressed

  if pressed[KeyEscape]:
    # A text field being edited takes Escape itself.
    if a.overlay == ovOptions: a.closeOptions(false)
    elif a.overlay == ovRename: a.closeRename()
    elif a.overlay in {ovCommands, ovPick}: discard  # their windows handle Escape
    elif a.overlay != ovNone: a.overlay = ovNone
    elif a.menus.isOpen: a.menus.close()
    elif a.fullscreen: a.setFullscreen(false)
    return
  if a.overlay == ovProperties:
    # The report scrolls from the keyboard too; propertiesOverlay clamps.
    const RowH = 21'f32
    let page = max(RowH, a.propPageH - RowH * 2)
    if pressed[KeyDown]: a.propScroll += RowH
    elif pressed[KeyUp]: a.propScroll -= RowH
    elif pressed[KeyPageDown] or pressed[KeySpace]: a.propScroll += page
    elif pressed[KeyPageUp]: a.propScroll -= page
    elif pressed[KeyHome]: a.propScroll = 0
    elif pressed[KeyEnd]: a.propScroll = float32.high
  if a.overlay != ovNone: return

  let (ok, act) = a.cfg.pressedAction(w)
  if ok: a.runAction(act)

# --- video geometry ---------------------------------------------------------

proc videoGeometry(a: App, area: Rect): tuple[center, size: Vec2] =
  let nat = a.naturalSize
  var base =
    case a.cfg.frameMode
    of fmHalf: nat * 0.5
    of fmFull: nat
    of fmDouble: nat * 2
    of fmStretch: area.wh
    of fmTouchInside:
      if a.cfg.preserveAspect and nat.x > 0 and nat.y > 0:
        nat * min(area.w / nat.x, area.h / nat.y)
      else: area.wh
  base *= a.xf.zoom
  base.x *= a.xf.scaleX
  base.y *= a.xf.scaleY
  (area.xy + area.wh / 2 + a.xf.pan, base)

proc zoomAt(a: App, area: Rect, at: Vec2, notches: float32) =
  ## Ctrl+Wheel: zooms by the Resize step per notch (up = in), keeping the
  ## point under the cursor in place. `area` and `at` are window pixels.
  ## Zooming out stops once the (rotated) frame touches the window from
  ## inside, and the pan shrinks so the frame ends up centered there.
  let step = 1 + a.cfg.sizeStep.float32 / 100
  var z = clamp(a.xf.zoom * pow(step, -notches), 0.05, 50)
  let c = area.xy + area.wh / 2
  if notches > 0:
    let size = a.videoGeometry(area).size
    let rad = a.xf.rotation * PI.float32 / 180
    let bw = abs(size.x * cos(rad)) + abs(size.y * sin(rad))
    let bh = abs(size.x * sin(rad)) + abs(size.y * cos(rad))
    if bw < 1 or bh < 1: return
    # Zoom at which the frame touches the window; a frame already smaller
    # (Half size, Decrease Size) just stays as it is.
    let touch = a.xf.zoom * min(area.w / bw, area.h / bh)
    let floorZ = min(a.xf.zoom, touch)
    if z <= floorZ:
      z = floorZ
      if a.xf.zoom == z and a.xf.pan == vec2(0, 0): return
    # Pull the pan toward the center in step with the zoom so the frame
    # lands centered exactly when it reaches the touching size.
    let t = if a.xf.zoom > floorZ: (z - floorZ) / (a.xf.zoom - floorZ) else: 0'f32
    let k = z / a.xf.zoom
    a.xf.pan = (at + (c + a.xf.pan - at) * k - c) * t
  else:
    let k = z / a.xf.zoom
    a.xf.pan = at + (c + a.xf.pan - at) * k - c
  a.xf.zoom = z
  a.xfChanged(&"Zoom: {int(round(z * 100))}%")

proc frameBounds(a: App, area: Rect): Vec2 =
  ## Size of the (rotated) frame's bounding box, window pixels.
  let size = a.videoGeometry(area).size
  let rad = a.xf.rotation * PI.float32 / 180
  vec2(abs(size.x * cos(rad)) + abs(size.y * sin(rad)),
    abs(size.x * sin(rad)) + abs(size.y * cos(rad)))

proc panLimit(a: App, area: Rect): Vec2 =
  ## How far the pan may go from the center on each axis so the frame's
  ## edges don't cross into the window: a frame larger than the window
  ## keeps covering it, a smaller one stays inside it.
  let b = a.frameBounds(area)
  vec2(abs(b.x - area.w) / 2, abs(b.y - area.h) / 2)

proc canPan(a: App, area: Rect): bool =
  ## Zoomed in far enough that part of the frame lies outside the window.
  let b = a.frameBounds(area)
  a.xf.zoom > 1 and (b.x > area.w + 0.5 or b.y > area.h + 0.5)

proc panDragTo(a: App, area: Rect, at: Vec2) =
  ## Shift+Middle drag: the frame follows the pointer, stopping where its
  ## edges meet the window's. A pan already past that (Numpad moves) doesn't
  ## jump back, it just can't go further out. `area` and `at` are window pixels.
  let lim = a.panLimit(area)
  let want = a.panStart + at - a.panFrom
  let p = vec2(
    clamp(want.x, min(-lim.x, a.panStart.x), max(lim.x, a.panStart.x)),
    clamp(want.y, min(-lim.y, a.panStart.y), max(lim.y, a.panStart.y)))
  if p != a.xf.pan:
    a.xf.pan = p
    a.xfChanged(&"Pan: {int(p.x)}, {int(p.y)}")

proc resetLook(a: App) =
  a.lookYaw = 0; a.lookPitch = 0; a.lookFov = SphereFov

proc lookDrag(a: App, at: Vec2) =
  ## Left drag on a 360° view: the picture follows the pointer, as if
  ## grabbed. `at` is in UI units, like the frame area.
  let k = a.lookFov / max(1'f32, a.videoRect.h)
  let d = at - a.lookLast
  a.lookLast = at
  a.lookYaw = floorMod(a.lookYaw - d.x * k, 360)
  a.lookPitch = clamp(a.lookPitch + d.y * k, -90, 90)

proc changeFov(a: App, notches: float32) =
  ## Ctrl+Wheel on a 360° view: up narrows the view (zooms in).
  a.lookFov = clamp(a.lookFov + notches * SphereFovStep, 20, 120)
  a.osd(&"Field of view: {int(round(a.lookFov))}°")

proc beginRotate(a: App, area: Rect, at: Vec2, atCursor: bool) =
  ## Alt+Middle press: the frame turns around its center, or around the
  ## cursor (Ctrl). `area` and `at` are window pixels.
  a.rotDrag = true
  a.rotStart = a.xf
  a.rotRefSet = false
  a.rotPressPos = at
  a.rotMoved = false
  a.rotPivot = if atCursor: at else: area.xy + area.wh / 2 + a.xf.pan

proc rotateDrag(a: App, area: Rect, at: Vec2, snap: bool) =
  ## Alt+Middle drag: turns the frame by the angle the cursor sweeps around
  ## the pivot; Shift snaps the rotation to multiples of the Rotate step.
  if not a.rotMoved:
    if (at - a.rotPressPos).length <= 4: return
    a.rotMoved = true
  let v = at - a.rotPivot
  if v.length < 8: return  # too close to the pivot for a steady angle
  let ang = arctan2(v.y, v.x) * 180 / PI.float32
  if not a.rotRefSet:
    a.rotRef = ang; a.rotRefSet = true
    return
  var r = floorMod(a.rotStart.rotation + ang - a.rotRef, 360)
  if snap:
    let step = max(1'f32, a.cfg.rotateStep.float32)
    r = floorMod(round(r / step) * step, 360)
  else: r = round(r * 10) / 10
  let d = (r - a.rotStart.rotation) * PI.float32 / 180
  let c = area.xy + area.wh / 2
  let o = c + a.rotStart.pan - a.rotPivot
  a.xf.pan = a.rotPivot + vec2(o.x * cos(d) - o.y * sin(d), o.x * sin(d) + o.y * cos(d)) - c
  if r != a.xf.rotation:
    a.xf.rotation = r
    a.xfChanged(&"Rotation: {r:g}°")

proc pollVideoFrame(a: App) =
  ## Picks up newly queued mpv frames and decides whether one is due.
  if a.frameFlag:
    a.frameFlag = false
    let flags = mpv_render_context_update(a.player.render)
    if (flags and MpvRenderUpdateFrame) != 0:
      a.framePending = true
      a.frameDue = a.player.render.nextFrameTarget()
  a.renderNow = a.framePending and
    (a.frameDue == 0 or mpv_get_time_ns(a.player.h) >= a.frameDue - 1_500_000)

proc drawSphere(a: App, area: Rect, fb: IVec2, flags: uint64) =
  ## 360° video: mpv renders the whole equirectangular picture at its own
  ## size, then the camera's view of it fills the frame area.
  let p = a.player
  let cap = min(1'f32, SphereTextureMax / max(p.videoW, p.videoH).float32)
  let size = (max(1, int(round(p.videoW.float32 * cap))), max(1, int(round(p.videoH.float32 * cap))))
  let (_, _, (tw, th)) = a.applySubLayout(vec2(size[0].float32, size[1].float32),
    (l: 0'f32, r: 0'f32, t: 0'f32, b: 0'f32), size)
  let resized = tw != p.target.w or th != p.target.h
  p.target.ensureSize(tw, th)
  let fresh = resized or (flags and MpvRenderUpdateFrame) != 0
  if fresh: p.render.render(p.target)
  let s = p.sphere
  var v = SphereView(yaw: a.lookYaw, pitch: a.lookPitch, fov: a.lookFov,
    poseYaw: s.yaw, posePitch: s.pitch, poseRoll: s.roll,
    bounds: [s.left, s.right, s.top, s.bottom], eye: [0'f32, 0, 1, 1])
  # Stereo pictures hold both eyes: show the first.
  case s.stereo
  of slTopBottom: v.eye = [0'f32, 0, 1, 0.5]
  of slSideBySide: v.eye = [0'f32, 0, 0.5, 1]
  of slMono: discard
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  a.quad.drawSphere(p.target.tex, area, fb.vec2, v, fresh)
  glDisable(GL_SCISSOR_TEST)

proc drawVideo(a: App, area: Rect, fb: IVec2) =
  ## GL pass beneath the UI: black frame area and the transformed video.
  let flags = if a.renderNow: MpvRenderUpdateFrame else: 0'u64
  if a.renderNow:
    a.renderNow = false
    a.framePending = false
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  glClearColor(0, 0, 0, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  glDisable(GL_SCISSOR_TEST)
  if not a.player.hasVideo or a.player.stopped:
    # Still consume frames so mpv keeps its pipeline moving.
    if (flags and MpvRenderUpdateFrame) != 0:
      a.player.target.ensureSize(16, 16)
      a.player.render.render(a.player.target)
    return
  if a.player.isSpherical:
    a.drawSphere(area, fb, flags)
    return
  let (center, size) = a.videoGeometry(area)
  if size.x < 1 or size.y < 1: return
  # The target is padded around the video to move centered subtitles.
  let pad = a.subPadding()
  let full = size + vec2(pad.l + pad.r, pad.t + pad.b)
  # Render at the on-screen size (mpv does the high-quality scaling); cap the
  # texture so extreme zoom doesn't allocate huge buffers.
  let cap = min(1'f32, 4096 / max(full.x, full.y))
  let (mx, my, (tw, th)) = a.applySubLayout(size, pad,
    (max(1, int(round(full.x * cap))), max(1, int(round(full.y * cap)))))
  let resized = tw != a.player.target.w or th != a.player.target.h
  a.player.target.ensureSize(tw, th)
  if resized or (flags and MpvRenderUpdateFrame) != 0:
    a.player.render.render(a.player.target)
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  # Size and shift the padded quad so the texels mpv filled with video land
  # exactly on the video's own rect (margins are whole texels, `full` isn't).
  let k = vec2(size.x / max(1, tw - mx[0] - mx[1]).float32, size.y / max(1, th - my[0] - my[1]).float32)
  let quadSize = vec2(tw.float32 * k.x, th.float32 * k.y)
  let sh = vec2((mx[1] - mx[0]).float32 * k.x / 2, (my[1] - my[0]).float32 * k.y / 2)
  let rad = a.xf.rotation * PI.float32 / 180
  let shift = vec2(sh.x * cos(rad) - sh.y * sin(rad), sh.x * sin(rad) + sh.y * cos(rad))
  a.quad.draw(a.player.target.tex, transformedCorners(center + shift, quadSize, a.xf.rotation), fb.vec2)
  glDisable(GL_SCISSOR_TEST)

proc drawPreview(a: App, fb: IVec2) =
  if a.preview == nil: return
  if a.previewFlag:
    a.previewFlag = false
    let flags = mpv_render_context_update(a.preview.render)
    if (flags and MpvRenderUpdateFrame) != 0 and a.preview.target.fbo != 0:
      a.preview.render.render(a.preview.target)
  if a.showPreview and a.preview.hasFrame:
    let q = a.px(a.previewQuad)
    a.quad.draw(a.preview.target.tex, rectCorners(q.xy, q.wh), fb.vec2)

# --- UI panels --------------------------------------------------------------

proc seekBarContext(a: App, pos: Vec2) =
  ## Opens the seek bar's context menu for the point pos on it.
  let r = a.seekRect
  let (x0, w, dur) = (r.x + 12, r.w - 24, a.player.duration)
  if dur <= 0 or not a.player.loaded: return
  a.ctxSeekT = clamp((pos.x - x0) / w, 0, 1) * dur
  a.ctxBookmark = -1
  var best = max(a.cfg.snapDistance, 4)
  for i, b in a.fileBookmarks:
    let d = abs(x0 + w * (b.time / dur) - pos.x)
    if d <= best:
      best = d
      a.ctxBookmark = i
  # Nearest chapter or bookmark, for the loop marks.
  a.ctxOnMarker = a.ctxBookmark >= 0
  if a.ctxOnMarker: a.ctxMarkerT = a.fileBookmarks[a.ctxBookmark].time
  for c in a.player.chapters:
    let d = abs(x0 + w * (c.time / dur) - pos.x)
    if d < best or (d <= best and not a.ctxOnMarker):
      best = d
      a.ctxOnMarker = true
      a.ctxMarkerT = c.time
  a.ctxMenu = cmSeekBar
  a.menus.openContext(pos)

proc seekBar(a: App, r: Rect) =
  let ui = a.ui
  let p = a.player
  a.seekRect = r
  ui.rect(r, colPanel)
  let x0 = r.x + 12
  let w = r.w - 24
  let cy = r.y + r.h / 2
  let dur = p.duration
  let active = a.seekDragging
  # The bar spans the window's width, so leaving it sideways leaves the window
  # too, and Windy keeps reporting the last pointer position from inside it.
  let mouseIn = ui.fakeMouse.x >= 0 or a.window.mouseInside
  let hov = (ui.hover(r) and mouseIn or active) and dur > 0 and p.loaded
  let th = if hov: 6'f32 else: 4'f32
  ui.rect(rect(x0, cy - th / 2, w, th), colTrack)
  let cur = if active: a.seekDragT else: p.timePos
  let frac = if dur > 0: clamp(cur / dur, 0, 1) else: 0
  ui.rect(rect(x0, cy - th / 2, w * frac, th), colAccent)

  # A-B loop: the looped span when active, and each mark set.
  if dur > 0 and p.loaded:
    if a.abLoop and a.loopReady:
      let (lx, rx) = (x0 + w * (a.loopA / dur), x0 + w * (a.loopB / dur))
      ui.rect(rect(lx, cy + th / 2 + 2, rx - lx, 2), colLoop)
    for (has, lt) in [(a.hasLoopA, a.loopA), (a.hasLoopB, a.loopB)]:
      if has:
        let lx = round(x0 + w * (lt / dur))
        ui.rect(rect(lx - 1, cy - 9, 2, 18), colLoop)

  # Markers: chapters and bookmarks, both snapped to.
  var markers: seq[(float, string, ColorRGBX)]
  for i, c in p.chapters:
    markers.add (c.time, (if c.title.len > 0: c.title else: &"Chapter {i + 1}"), colMarker)
  for i, b in a.fileBookmarks:
    markers.add (b.time, b.label(i), colBookmark)
  markers.sort(proc (x, y: (float, string, ColorRGBX)): int = cmp(x[0], y[0]))

  var t = 0.0
  var snapped = -1
  if hov:
    t = clamp((ui.mouse.x - x0) / w, 0, 1) * dur
    if a.cfg.snapWithShift == a.window.shift:
      var best = a.cfg.snapDistance
      for i, m in markers:
        let d = abs(x0 + w * (m[0] / dur) - ui.mouse.x)
        if d <= best:
          best = d
          snapped = i
      if snapped >= 0: t = markers[snapped][0]

  for i, m in markers:
    if dur <= 0: break
    let mx = round(x0 + w * (m[0] / dur))
    let hl = i == snapped
    ui.rect(rect(mx - (if hl: 1.5 else: 1), cy - (if hl: 8 else: 6), (if hl: 3 else: 2), (if hl: 16 else: 12)),
      if hl: colWhite else: m[2])

  if dur > 0 and p.loaded:
    ui.icon("knob16", vec2(x0 + w * frac, cy), colWhite)

  if hov and not active and ui.released(MouseRight):
    a.seekBarContext(ui.mouse)

  # Dragging / clicking
  if hov and ui.pressed() and not active:
    a.seekDragging = true
    ui.consumeClick()
    a.seekDragT = t
    a.lastDragSeekAt = 0
    p.stopped = false
  if a.seekDragging:
    if ui.down():
      a.seekDragT = t
      if now() - a.lastDragSeekAt > 0.06:
        a.lastDragSeekAt = now()
        a.seekTo(t, exact = false)
    else:
      a.seekDragging = false
      a.seekTo(t)

  # Hover label and thumbnail
  a.showPreview = false
  if hov:
    var label = fmtTime(t, a.cfg.showMillis)
    if snapped >= 0: label.add "  " & markers[snapped][1]
    else:
      for i in countdown(markers.high, 0):
        if markers[i][0] <= t:
          label.add "  " & markers[i][1]
          break
    let ts = ui.textSize(label, FontSmall)
    var boxW = max(ts.x + 16, 60)
    var imgH = 0'f32
    let wantPreview = a.cfg.seekPreview and p.hasRealVideo and a.preview != nil and
      fileExists(p.path)
    if wantPreview:
      let pw = 224'f32
      let asp = a.videoAspect
      imgH = round(pw / (if asp > 0: asp else: 16 / 9))
      boxW = max(boxW, pw + 8)
      a.preview.request(p.path, t)
      a.preview.target.ensureSize(int(pw * ui.scale), int(imgH * ui.scale))
    let boxH = ts.y + 8 + (if imgH > 0: imgH + 4 else: 0)
    var bx = clamp(ui.mouse.x - boxW / 2, 4, ui.size.x - boxW - 4)
    let by = r.y - boxH - 6
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(bx, by, boxW, boxH), colPopup)
    ui.border(rect(bx, by, boxW, boxH), colBorder)
    if imgH > 0:
      let q = rect(bx + (boxW - 224) / 2, by + 4, 224, imgH)
      if a.preview.hasFrame:
        a.previewQuad = q
        a.showPreview = true
      else:
        ui.rect(q, colVideoBg)
    ui.textIn(label, rect(bx, by + boxH - ts.y - 6, boxW, ts.y + 4), colText, FontSmall, h = CenterAlign)
    ui.sk.popLayer()

proc volumeSlider(a: App, r: Rect) =
  let ui = a.ui
  let v = a.player.volume
  let hov = ui.hover(r) or ui.activeId == "volume"
  let cy = r.y + r.h / 2
  ui.rect(rect(r.x, cy - 2, r.w, 4), colTrack)
  let frac = clamp(v / 100, 0, 1)
  ui.rect(rect(r.x, cy - 2, r.w * frac, 4),
    if a.player.muted: colTextDisabled elif v > 100: colMarker else: colAccent)
  ui.icon("knob16", vec2(r.x + r.w * frac, cy), if hov: colWhite else: colText)
  if ui.hover(r) and ui.pressed():
    ui.activeId = "volume"
    ui.consumeClick()
  if ui.activeId == "volume" and ui.down():
    a.player.setVolume(round(clamp((ui.mouse.x - r.x) / r.w, 0, 1) * 100))
  ui.tip(r, &"Volume {int(round(v))}%")

proc controls(a: App, r: Rect) =
  let ui = a.ui
  let p = a.player
  ui.rect(r, colPanel)
  let bw = 36'f32
  let bh = r.h - 8
  var x = r.x + 6
  let y = r.y + 4
  template btn(id, iconName, tipText: string, enabled: bool, toggled: bool, body: untyped) =
    if ui.iconButton(id, rect(x, y, bw, bh), iconName & "20", tipText, enabled, toggled):
      body
    x += bw + 2
  btn("play", "play", "Play", p.loaded or a.cfg.recentFiles.len > 0, p.playing): a.play()
  btn("pause", "pause", "Pause", p.loaded, p.loaded and p.paused and not p.stopped): a.pause()
  btn("stop", "stop", "Stop", p.loaded, p.stopped): a.stop()
  ui.rect(rect(x + 4, y + 6, 1, bh - 12), colBorder)
  x += 10
  let navOk = p.loaded and not a.playlistLocked
  btn("prev", "prev", "Previous", navOk, false): a.navigate(-1)
  btn("slower", "slower", "Slower playback", p.loaded, false): a.changeRate(-1)
  btn("faster", "faster", "Faster playback", p.loaded, false): a.changeRate(1)
  btn("next", "next", "Next", navOk, false): a.navigate(1)
  ui.rect(rect(x + 4, y + 6, 1, bh - 12), colBorder)
  x += 10
  # Click toggles Repeat > Forever; right-click opens the Repeat menu.
  let loopR = rect(x, y, bw, bh)
  btn("loop", "loop", "Repeat (right-click for options)", true,
      a.cfg.repeatForever or (a.abLoop and a.loopReady)):
    a.cfg.repeatForever = not a.cfg.repeatForever
    a.applyLoop()
  if ui.hover(loopR) and ui.released(MouseRight):
    a.ctxMenu = cmRepeat
    a.menus.openContext(ui.mouse)

  # Volume on the right.
  let sw = 100'f32
  let sr = rect(r.x + r.w - sw - 16, r.y, sw, r.h)
  a.volumeSlider(sr)
  let vb = rect(sr.x - bw - 6, y, bw, bh)
  let volIcon = if p.muted: "nosound20" else: "volume20"
  if ui.iconButton("mute", vb, volIcon, if p.muted: "Unmute" else: "Mute"):
    a.setMute(not p.muted)
  let pct = &"{int(round(p.volume))}%"
  let pw = ui.textSize(pct, FontSmall).x
  ui.textIn(pct, rect(vb.x - pw - 6, r.y, pw + 2, r.h), colTextDim, FontSmall)

type KeyHint = tuple[key, label: string]

proc modifierHints(a: App): seq[seq[KeyHint]] =
  ## Shortcuts reachable with the modifiers currently held, in groups: the
  ## keys set in Options > Player > Keys, one group per command group, then
  ## the mouse gestures.
  let w = a.window
  var (c, s, al) = (w.ctrl, w.shift, w.alt)
  if a.fakeMods.len > 0:
    (c, s, al) = ("ctrl" in a.fakeMods, "shift" in a.fakeMods, "alt" in a.fakeMods)
  var mods: set[KeyMod]
  if c: mods.incl kmCtrl
  if s: mods.incl kmShift
  if al: mods.incl kmAlt
  if mods == {}: return
  let rot = &"{a.cfg.rotateStep:g}°"
  # View toggles and pan/rotate/scale only show with "Show all shortcuts".
  let all = a.cfg.showAllShortcuts
  let viewToggles = {kaSeekBar, kaControls, kaStatus, kaPlaylist, kaRunLog, kaShowOsd}
  for g in KeyGroup:
    if g == kgPan and not all: continue
    var hints: seq[KeyHint]
    var done: set[KeyAction]
    # Clusters still on their default keys share one hint.
    for (acts, key, label) in [(@SubAlignActions, "Num1-9", "Align Subtitles"),
                               (@SubMoveActions, "Arrows", "Move Subtitles")]:
      if Actions[acts[0]].group == g and acts.allIt(a.cfg.isDefault(it)) and
         a.cfg.combos(acts[0]).len > 0 and a.cfg.combos(acts[0])[0].mods == mods:
        hints.add (key, label)
        for x in acts: done.incl x
    for act in KeyAction:
      if Actions[act].group != g or act in done: continue
      if act in viewToggles and not all: continue
      let ks = a.cfg.combos(act).filterIt(it.mods == mods)
      if ks.len == 0: continue
      let label =
        case act
        of kaRotateCw: "Rotate " & rot & " CW"
        of kaRotateCcw: "Rotate " & rot & " CCW"
        else: Actions[act].hint
      hints.add (ks.mapIt(shortKeyName(it.key)).join("/"), label)
    if hints.len > 0: result.add hints
  var mouse: seq[KeyHint]
  if mods == {kmCtrl}:
    if a.player.isSpherical:
      # 360° view: the wheel changes the field of view; Ctrl swaps what a drag does.
      mouse = @[("Wheel", "Field Of View"),
        ("Drag", if a.cfg.sphereDragMovesWindow: "Look Around" else: "Move Window")]
    else: mouse = @[("Wheel", "Zoom At Cursor")]
  elif mods == {kmAlt}: mouse = @[("MDrag", "Rotate Frame"), ("MMB", "Reset Rotation")]
  elif mods == {kmAlt, kmShift}: mouse = @[("MDrag", "Rotate In " & rot & " Steps")]
  elif mods == {kmCtrl, kmAlt}: mouse = @[("MDrag", "Rotate Around Cursor")]
  elif mods == {kmCtrl, kmAlt, kmShift}:
    mouse = @[("MDrag", "Rotate Around Cursor In " & rot & " Steps")]
  elif mods == {kmShift}:
    mouse = @[("Drag", if a.cfg.snapWithShift: "Seek Snapping To Markers" else: "Seek Without Snapping"),
      ("MDrag", "Pan Zoomed Video")]
  if mouse.len > 0: result.add mouse

proc keyHintBar(a: App, r: Rect, groups: seq[seq[KeyHint]]) =
  ## Blender-style row of [key] label pairs; groups split by a divider.
  ## Groups that don't fit wrap onto more rows, which grow the bar upward
  ## over the controls so the layout beneath doesn't move.
  let ui = a.ui
  let capH = r.h - 8
  proc mouseIcon(key: string): string =
    ## Mouse inputs (LMB, RMB, MMB, Wheel, Drag) draw as an icon, not a key cap.
    for (k, spec) in mouseIcons:
      if k == key: return spec[0]
  proc capW(key: string): float32 =
    let icon = mouseIcon(key)
    if icon.len > 0: ui.sk.getImageSize(icon).x
    else: max(capH, ui.textSize(key, FontSmall).x + 10)
  proc pairW(h: KeyHint): float32 = capW(h.key) + 5 + ui.textSize(h.label, FontSmall).x
  const PairGap = 14'f32
  const GroupGap = 25'f32
  let left = r.x + 10
  let right = r.x + r.w - 10
  # Lay out first: (row, x) per pair, plus where the group dividers go.
  var pos: seq[seq[(int, float32)]]
  var dividers: seq[(int, float32)]
  var (row, x) = (0, left)
  for gi, g in groups:
    var gw = 0'f32
    for i, h in g: gw += pairW(h) + (if i > 0: PairGap else: 0)
    if gi > 0:
      if x + GroupGap + gw > right and x > left: (row, x) = (row + 1, left)
      else:
        dividers.add (row, x + GroupGap / 2)
        x += GroupGap
    pos.add @[]
    for i, h in g:
      if i > 0:
        if x + PairGap + pairW(h) > right and x > left: (row, x) = (row + 1, left)
        else: x += PairGap
      pos[^1].add (row, x)
      x += pairW(h)
  let rows = row + 1
  let top = r.y - (rows - 1).float32 * r.h
  let bar = rect(r.x, top, r.w, r.y + r.h - top)
  ui.rect(bar, colPanel)
  ui.rect(rect(bar.x, bar.y, bar.w, 1), colBorder)
  for (ri, dx) in dividers:
    ui.rect(rect(dx, top + ri.float32 * r.h + 6, 1, r.h - 12), colBorder)
  for gi, g in groups:
    for i, h in g:
      let (ri, hx) = pos[gi][i]
      let ry = top + ri.float32 * r.h
      let cap = rect(hx, ry + (r.h - capH) / 2, capW(h.key), capH)
      let icon = mouseIcon(h.key)
      if icon.len > 0:
        ui.icon(icon, cap.xy + cap.wh / 2, colText)
      else:
        ui.rect(cap, colPanelRaised)
        ui.border(cap, colBorder)
        ui.textIn(h.key, cap, colText, FontSmall, h = CenterAlign)
      let lw = ui.textSize(h.label, FontSmall).x
      ui.textIn(h.label, rect(cap.x + cap.w + 5, ry, lw + 2, r.h), colTextDim, FontSmall)

proc status(a: App, r: Rect) =
  let ui = a.ui
  let p = a.player
  if (a.window.focused or a.fakeMods.len > 0) and a.overlay == ovNone and not a.menus.isOpen:
    let hints = a.modifierHints()
    if hints.len > 0:
      a.keyHintBar(r, hints)
      if ui.hover(r) and ui.released(MouseRight):
        a.ctxMenu = cmStatus
        a.menus.openContext(ui.mouse)
      return
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, r.w, 1), colBorder)
  let fileIcon =
    if not p.loaded: "nofile16"
    elif p.hasRealVideo: "film16"
    else: "music16"
  ui.icon(fileIcon, vec2(r.x + 16, r.y + r.h / 2), if p.loaded: colAccent else: colTextDim)
  let state =
    if not p.loaded: "Stopped"
    elif p.stopped: "Stopped"
    elif p.paused: "Paused"
    else: "Playing"
  ui.textIn(state, rect(r.x + 30, r.y, 120, r.h), colText, FontSmall)
  if p.loadError.len > 0:
    ui.textIn("Error: " & p.loadError, rect(r.x + 100, r.y, r.w / 2, r.h), colMarker, FontSmall)

  # Right side: audio icon, time.
  let audioIcon =
    if not p.loaded or p.audioChannels == 0 or p.muted or p.selectedTrack("audio") == 0: "nosound16"
    elif p.audioChannels == 1: "mono16"
    else: "stereo16"
  let iw = ui.sk.getImageSize(audioIcon).x
  let ix = r.x + r.w - iw / 2 - 12
  ui.icon(audioIcon, vec2(ix, r.y + r.h / 2), colText)
  let audioTip =
    case audioIcon
    of "stereo16": &"{p.audioChannels} channels"
    of "mono16": "Mono"
    else: "No sound"
  ui.tip(rect(ix - iw / 2, r.y, iw, r.h), audioTip)
  let ms = a.cfg.showMillis
  let pos = if a.seekDragging: a.seekDragT else: p.timePos
  var timeText =
    (if a.cfg.showRemaining: "-" & fmtTime(max(0.0, p.duration - pos), ms) else: fmtTime(pos, ms)) &
    " / " & fmtTime(p.duration, ms)
  if p.loaded and abs(p.speed - 1) > 0.001:
    timeText = &"{p.speed:g}x   " & timeText
  let tw = ui.textSize(timeText, FontSmall).x
  let timeRect = rect(ix - iw / 2 - tw - 14, r.y, tw + 4, r.h)
  ui.textIn(timeText, timeRect, colText, FontSmall)
  if ui.hover(timeRect) and ui.released():
    a.cfg.showRemaining = not a.cfg.showRemaining
    a.cfg.save()
  if ui.hover(timeRect) and ui.released(MouseRight):
    a.ctxMenu = cmTime
    a.menus.openContext(ui.mouse)
  elif ui.hover(r) and ui.released(MouseRight):
    a.ctxMenu = cmStatus
    a.menus.openContext(ui.mouse)

proc fmtSize(bytes: int64): string =
  if bytes < 1000: return &"{bytes} B"
  var v = bytes.float / 1024
  var unit = 0
  while v >= 1000 and unit < 3:
    v /= 1024
    inc unit
  &"{v:.1f} " & ["KB", "MB", "GB", "TB"][unit]

proc playlistColumns(a: App): seq[PlaylistColumn] =
  ## The detail columns right of Filename, each as wide as its widest text.
  let ui = a.ui
  let col = proc (label, sample: string, sort: PlaylistSort): PlaylistColumn =
    PlaylistColumn(label: label, sort: sort,
      w: max(ui.textSize(label, FontSmall).x, ui.textSize(sample, FontSmall).x) + 18)
  result.add col("Duration", "00:00:00", psDuration)
  if a.cfg.playlistShowSize: result.add col("Size", "999.9 MB", psSize)
  if a.cfg.playlistShowDimensions: result.add col("Dimensions", "3840×2160", psDimensions)

proc cellText(a: App, path: string, by: PlaylistSort): string =
  case by
  of psName: path.extractFilename
  of psDuration:
    let d = a.mediaInfo.getOrDefault(path).duration
    if d > 0: fmtTime(d) else: ""
  of psSize:
    let b = a.fileSize(path)
    if b >= 0: fmtSize(b) else: ""
  of psDimensions:
    let m = a.mediaInfo.getOrDefault(path)
    if m.width > 0: &"{m.width}×{m.height}" else: ""

proc playlistPanel(a: App, r: Rect) =
  let ui = a.ui
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, 1, r.h), colBorder)
  # Dragging the left edge resizes the panel; the video frame takes the rest.
  let grip = rect(r.x, r.y, PlaylistGripW, r.h)
  if ui.hover(grip) and ui.pressed():
    ui.activeId = "plresize"
    a.plResizeFrom = (ui.mouse.x, r.w)
    ui.consumeClick()
  if ui.activeId == "plresize":
    let (x0, w0) = a.plResizeFrom
    a.cfg.playlistWidth = clamp(w0 + x0 - ui.mouse.x, PlaylistMinWidth,
      max(PlaylistMinWidth, ui.size.x - MinWindow.x.float32 / 2))
  let header = rect(r.x, r.y, r.w, 30)
  ui.icon("playlist16", vec2(r.x + 18, header.y + 15), colAccent)
  ui.textIn(&"Playlist ({a.playlist.len})", rect(r.x + 32, header.y, r.w - 70, 30), colText)
  if ui.iconButton("pl-close", rect(r.x + r.w - 30, header.y + 3, 24, 24), "close16", "Close (Ctrl+4)"):
    a.setPlaylistShown(false)
  ui.rect(rect(r.x + 1, header.y + 29, r.w - 1, 1), colBorder)
  if a.playlistLocked:
    a.plListRect = Rect()
    ui.textIn("Locked while synchronized", rect(r.x, header.y + 30, r.w, r.h - 30),
      colTextDim, FontSmall, h = CenterAlign)
    return

  # Column headers: Filename takes what the detail columns leave.
  let colHdr = rect(r.x + 1, r.y + 30, r.w - 1, PlaylistHeaderH)
  var cells: seq[(Rect, PlaylistColumn)]
  var x = colHdr.x + colHdr.w
  for c in a.playlistColumns.reversed:
    x -= c.w
    cells.insert((rect(x, colHdr.y, c.w, colHdr.h), c), 0)
  cells.insert((rect(colHdr.x, colHdr.y, max(0'f32, x - colHdr.x), colHdr.h),
    PlaylistColumn(label: "Filename", sort: psName)), 0)
  ui.rect(colHdr, colPanelRaised)
  ui.sk.pushClipRect(colHdr)
  for i, (cr, c) in cells:
    if ui.hover(cr) and not ui.hover(grip):
      ui.rect(cr, colHover)
      ui.tip(cr, "Sort by " & c.label)
      if ui.pressed():
        ui.consumeClick()
        a.sortPlaylist(c.sort)
    if i == 0:
      ui.textIn(c.label, rect(cr.x + 28, cr.y, cr.w - 32, cr.h), colTextDim, FontSmall)
    else:
      ui.rect(rect(cr.x, cr.y + 4, 1, cr.h - 8), colBorder)
      ui.textIn(c.label, rect(cr.x, cr.y, cr.w - 9, cr.h), colTextDim, FontSmall, h = RightAlign)
  ui.sk.popClipRect()
  ui.rect(rect(colHdr.x, colHdr.y + colHdr.h - 1, colHdr.w, 1), colBorder)

  let list = rect(r.x + 1, colHdr.y + colHdr.h, r.w - 1, r.h - 30 - colHdr.h)
  let rowH = PlaylistRowH
  a.plListRect = list
  if ui.hover(colHdr) and ui.released(MouseRight):
    a.ctxMenu = cmPlaylistColumns
    a.menus.openContext(ui.mouse)
  elif ui.hover(r) and ui.released(MouseRight):
    # Right-click selects the row under the pointer (none below the last one).
    let i = int((ui.mouse.y - list.y + a.plScroll) / rowH)
    a.plSelected = if ui.mouse.y >= list.y and i < a.playlist.len: i else: -1
    a.ctxMenu = cmPlaylist
    a.menus.openContext(ui.mouse)
  if a.playlist.len == 0:
    ui.textIn("Empty. Use File > Open File...", list, colTextDim, FontSmall, h = CenterAlign)
    return
  let maxScroll = max(0'f32, a.playlist.len.float32 * rowH - list.h)
  if a.plReveal:
    a.plReveal = false
    if a.plSelected >= 0:
      let y = a.plSelected.float32 * rowH
      a.plScroll = clamp(a.plScroll, y + rowH - list.h, y)
  if ui.hover(list) and ui.scroll() != 0:
    a.plScroll += ui.scroll() * rowH * 3
    ui.scrollConsumed = true
  a.plScroll = clamp(a.plScroll, 0, maxScroll)
  ui.sk.pushClipRect(list)
  let first = int(a.plScroll / rowH)
  let last = min(a.playlist.len, first + int(list.h / rowH) + 2) - 1
  for i in first .. last:
    let row = rect(list.x, list.y + i.float32 * rowH - a.plScroll, list.w, rowH)
    let hov = ui.hover(row) and ui.hover(list) and not ui.hover(grip)
    if i == a.plSelected: ui.rect(row, colPressed)
    elif hov: ui.rect(row, colHover)
    let current = i == a.plIndex
    if current: ui.icon("play16", vec2(row.x + 14, row.y + rowH / 2), colAccent)
    let path = a.playlist[i]
    let nameW = cells[0][0].w - 32
    ui.textIn(ui.ellipsize(path.extractFilename, nameW), rect(row.x + 28, row.y, nameW, rowH),
      if current: colAccent else: colText)
    for (cr, c) in cells[1 .. ^1]:
      ui.textIn(a.cellText(path, c.sort), rect(cr.x, row.y, cr.w - 9, rowH),
        if current: colAccent else: colTextDim, FontSmall, h = RightAlign)
    if hov and ui.pressed():
      a.plSelected = i
      ui.consumeClick()
    if hov and a.window.buttonPressed[DoubleClick]:
      a.playIndex(i)
  ui.sk.popClipRect()
  a.probeNext(first .. last)

proc runLogPanel(a: App, r: Rect) =
  ## The Run menu's command lines and what they printed, newest at the bottom.
  let ui = a.ui
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y + r.h - 1, r.w, 1), colBorder)
  # Dragging the bottom edge resizes the panel; the video frame takes the rest.
  let grip = rect(r.x, r.y + r.h - RunLogGripH, r.w, RunLogGripH)
  if ui.hover(grip) and ui.pressed():
    ui.activeId = "rlresize"
    a.rlResizeFrom = (ui.mouse.y, r.h)
    ui.consumeClick()
  if ui.activeId == "rlresize":
    let (y0, h0) = a.rlResizeFrom
    let below = (if a.fullscreen: 0'f32 else: MenuBarHeight + a.bottomHeight) +
      MinWindow.y.float32 / 2
    a.cfg.runLogHeight = clamp(h0 + ui.mouse.y - y0, RunLogMinHeight,
      max(RunLogMinHeight, ui.size.y - below))

  let header = rect(r.x, r.y, r.w, RunLogHeaderH)
  let running = a.runLog.countIt(it.running)
  ui.icon("terminal16", vec2(r.x + 18, header.y + header.h / 2), colAccent)
  ui.textIn(if running > 0: &"Run log ({running} running)" else: "Run log",
    rect(r.x + 32, header.y, r.w - 150, header.h), colText)
  # Header buttons, right to left: Close, Clear (finished runs), Stop (running ones).
  if ui.iconButton("rl-close", rect(r.x + r.w - 30, header.y + 2, 24, 24), "close16", "Close (Ctrl+5)"):
    a.setRunLogShown(false)
  var bx = r.x + r.w - 38
  let headerButton = proc (label, tip: string): bool =
    let b = rect(bx - 60, header.y + 4, 60, header.h - 8)
    bx -= 66
    let hov = ui.hover(b)
    ui.rect(b, if hov: colHover else: colPanelRaised)
    ui.border(b, colBorder)
    ui.textIn(label, b, colText, FontSmall, h = CenterAlign)
    ui.tip(b, tip)
    if hov and ui.pressed():
      ui.consumeClick()
      return true
  if a.runLog.len > running and headerButton("Clear", "Remove the finished runs"):
    a.runLog.keepItIf(it.running)
  if running > 0 and headerButton("Stop", "Stop the running command lines"):
    for e in a.runLog: e.stop()
  ui.rect(rect(r.x, header.y + header.h - 1, r.w, 1), colBorder)

  let list = rect(r.x, header.y + header.h, r.w, max(0'f32, r.h - header.h - RunLogGripH))
  if a.runLog.len == 0:
    ui.textIn("Nothing has run yet. Command lines run from the Run menu show their output here.",
      list, colTextDim, FontSmall, h = CenterAlign)
    return

  # One row per line: each run's heading, its output, then how it ended.
  var rows: seq[(string, ColorRGBX)]
  for i, e in a.runLog:
    if i > 0: rows.add ("", colText)
    rows.add (e.started.format("HH:mm:ss") & "  " & e.title & "  —  " & e.dir, colAccent)
    for line in e.output: rows.add (line, colText)
    if e.error.len > 0: rows.add (e.error, colError)
    elif e.running: rows.add ((if e.stopped: "Stopping…" else: "Running…"), colMarker)
    elif e.stopped: rows.add ("Stopped", colMarker)
    elif e.code == 0: rows.add ("Finished", colTextDim)
    else: rows.add (&"Failed (exit code {e.code})", colError)

  let rowH = RunLogRowH
  let pad = 6'f32
  let contentH = rows.len.float32 * rowH + 2 * pad
  let maxScroll = max(0'f32, contentH - list.h)
  if ui.hover(list) and ui.scroll() != 0:
    a.rlScroll += ui.wheelNotches * rowH * RunLogWheelRows
    a.rlScroll = clamp(a.rlScroll, 0, maxScroll)
    a.rlFollow = a.rlScroll >= maxScroll
    ui.scrollConsumed = true

  # Scroll bar: drag the thumb, or click the track to jump there.
  let track = rect(list.x + list.w - RunLogBarW - 2, list.y + 2, RunLogBarW, max(0'f32, list.h - 4))
  if maxScroll > 0 and track.h > 0:
    let thumbH = max(24'f32, track.h * list.h / contentH).min(track.h)
    let span = track.h - thumbH
    var thumb = rect(track.x, track.y + span * a.rlScroll / maxScroll, track.w, thumbH)
    if ui.hover(track) and ui.pressed():
      ui.consumeClick()
      if not ui.hover(thumb):
        # Center the thumb on the pointer, then keep dragging from there.
        a.rlScroll = clamp((ui.mouse.y - track.y - thumbH / 2) / span * maxScroll, 0, maxScroll)
      ui.activeId = "rlscroll"
      a.rlThumbFrom = (ui.mouse.y, a.rlScroll)
    if ui.activeId == "rlscroll":
      let (y0, s0) = a.rlThumbFrom
      if span > 0:
        a.rlScroll = clamp(s0 + (ui.mouse.y - y0) / span * maxScroll, 0, maxScroll)
      a.rlFollow = a.rlScroll >= maxScroll
    a.rlScroll = clamp(a.rlScroll, 0, maxScroll)
    thumb.y = track.y + span * a.rlScroll / maxScroll
    ui.rect(track, colTrack)
    ui.rect(thumb, if ui.activeId == "rlscroll": colAccent
      elif ui.hover(thumb): colTextDim else: colTextDisabled)
  if a.rlFollow: a.rlScroll = maxScroll
  a.rlScroll = clamp(a.rlScroll, 0, maxScroll)

  let textW = list.w - 24 - (if maxScroll > 0: RunLogBarW + 4 else: 0)
  ui.sk.pushClipRect(rect(list.x, list.y, list.w - RunLogBarW - 4, list.h))
  let first = max(0, int((a.rlScroll - pad) / rowH))
  let last = min(rows.len, first + int(list.h / rowH) + 2) - 1
  for i in first .. last:
    let y = list.y + pad + i.float32 * rowH - a.rlScroll
    ui.textIn(rows[i][0], rect(list.x + 12, y, textW, rowH), rows[i][1], FontSmall)
  ui.sk.popClipRect()

proc dropFiles(a: App, paths: seq[string]) =
  ## Dropped on the playlist: insert at the row boundary under the pointer and
  ## keep playing. Anywhere else: replace the playlist and play.
  let list = a.plListRect
  if list.w > 0 and a.dropAt.inside(list):
    let at = int((a.dropAt.y - list.y + a.plScroll) / PlaylistRowH + 0.5)
    a.addToPlaylist(paths, at)
  else:
    a.openPaths(paths)

proc idleScreen(a: App, area: Rect) =
  let ui = a.ui
  let c = area.xy + area.wh / 2
  if a.player.loaded and not a.player.hasVideo and not a.player.stopped:
    ui.icon("music96", c - vec2(0, 30), colAccentDim)
    let name = ui.ellipsize(a.player.path.extractFilename, area.w - 40)
    ui.textIn(name, rect(area.x, c.y + 30, area.w, 30), colTextDim, h = CenterAlign)
  elif (not a.player.loaded or a.player.stopped) and area.h > 140:
    ui.icon("crown96", c - vec2(0, 24), colAccentDim)
    ui.textIn(AppName, rect(area.x, c.y + 34, area.w, 30), colTextDim, FontTitle, h = CenterAlign)

proc sphereOsd(a: App, area: Rect) =
  ## The OSD message of a 360° view (see osd), top left of the frame.
  if not a.player.isSpherical or now() >= a.osdUntil or a.osdMsg.len == 0: return
  let ui = a.ui
  let sz = ui.textSize(a.osdMsg, FontTitle)
  let r = rect(area.x + 16, area.y + 16, sz.x + 20, sz.y + 10)
  ui.rect(r, rgbx(0, 0, 0, 170))
  ui.text(a.osdMsg, r.xy + vec2(10, 5), colText, FontTitle)

proc syncOutline(a: App, r: Rect) =
  ## Synchronized players are framed in their group's color: solid around the
  ## master, dashed around the others.
  if not a.synced: return
  let ui = a.ui
  # A hue per master, kept semi-saturated so it reads on dark and on video.
  let hue = float32((a.syncMaster * 137) mod 360)
  let col = hsl(hue, 55, 60).color.rgbx
  const t = 1'f32
  if a.isSyncMaster:
    ui.border(r, col, t)
    return
  const dash = 14'f32
  const gap = 8'f32
  var x = r.x
  while x < r.x + r.w:
    let w = min(dash, r.x + r.w - x)
    ui.rect(rect(x, r.y, w, t), col)
    ui.rect(rect(x, r.y + r.h - t, w, t), col)
    x += dash + gap
  var y = r.y
  while y < r.y + r.h:
    let h = min(dash, r.y + r.h - y)
    ui.rect(rect(r.x, y, t, h), col)
    ui.rect(rect(r.x + r.w - t, y, t, h), col)
    y += dash + gap

# --- overlays ---------------------------------------------------------------

proc overlayFrame(a: App, title: string, size: Vec2): Rect =
  let ui = a.ui
  ui.rect(rect(vec2(0, 0), ui.size), colScrim)
  let r = rect(((ui.size - size) / 2).floor, size)
  ui.rect(rect(r.xy + vec2(4, 6), r.wh), colShadow)
  ui.rect(r, colPanel)
  ui.border(r, colBorder)
  ui.textIn(title, rect(r.x + 20, r.y + 12, r.w - 60, 30), colText, FontTitle)
  if ui.iconButton("ov-close", rect(r.x + r.w - 40, r.y + 10, 30, 30), "close20", "Close"):
    a.overlay = ovNone
  ui.rect(rect(r.x + 1, r.y + 50, r.w - 2, 1), colBorder)
  # A press on the scrim dismisses it, without reaching anything beneath.
  if (ui.pressed() or ui.pressed(MouseRight)) and not ui.mouse.inside(r):
    a.overlay = ovNone
    ui.consumeClick()
  r

proc beginDialogDraw(a: App, w: Window, sk: Silky, size: IVec2): bool =
  ## Starts drawing a dialog window's frame (after the main window's swap).
  ## On X11 it is drawn in the main window's buffer and put into the dialog
  ## by X, so it needs no GL buffers of its own (see xwin_x11's putPixelsOn).
  when defined(windows): w.beginDrawOn()
  else:
    sk.beginOffscreen(a.window.size, size, colPanel)
    true

proc dialogImage(size: IVec2): Image =
  ## The dialog frame just drawn (for screenshots).
  when defined(windows): readFramebuffer(size) else: offscreenImage(size)

proc endDialogDraw(a: App, w: Window, sk: Silky, size: IVec2) =
  ## Presents the dialog frame begun by beginDialogDraw.
  when defined(windows): w.endDrawOn(a.window)
  else:
    sk.endOffscreen()
    w.putPixels(size, offscreenPixels())

proc renderOptions(a: App, shot: string) =
  ## Draws the Options window. Like the menu popups, call after the main
  ## window's swap.
  if a.overlay != ovOptions: return
  let w = a.optWin
  let ui = a.optUi
  if w.closeRequested:  # its title bar's close button, Alt+F4
    w.closeRequested = false
    a.closeOptions(false)
    return
  a.applyUiScale()
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  # A text field being edited takes Escape itself.
  let esc = w.buttonPressed[KeyEscape] and ui.focusId.len == 0
  if not a.beginDialogDraw(w, a.optSk, size): return  # retried next frame
  ui.beginFrame()
  a.optSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let action = a.optionsDlg.draw(ui, a.cfg, rect(vec2(0, 0), ui.size))
  ui.drawTooltip()
  a.optSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-options.png")
  a.endDialogDraw(w, a.optSk, size)
  case action
  of oaOk: a.closeOptions(true)
  of oaCancel: a.closeOptions(false)
  of oaNone:
    if esc: a.closeOptions(false)
  let req = a.optionsDlg.request
  a.optionsDlg.request = prNone
  case req
  of prNone: discard
  of prBrowseScreenshots:
    a.ask(dkOpenDir, "optshotdir", "Screenshot Folder", a.cfg.screenshotFolder)
  of prBrowseOpen:
    let d = a.cfg.openDir.expandPath
    a.ask(dkOpenDir, "optopendir", "Start Folder",
      if d.len > 0 and dirExists(d): d else: a.startDir)
  of prShowSettings:
    try: createDir(configDir())
    except OSError: discard
    when defined(windows): a.spawn("explorer.exe", configDir())
    else: a.spawn("xdg-open", configDir())
  if a.optionsDlg.assocApplied:
    a.optionsDlg.assocApplied = false
    # Let KDE's service cache notice the new defaults right away.
    if findExe("kbuildsycoca6").len > 0: a.spawn("kbuildsycoca6")

proc renderRename(a: App, shot: string) =
  ## Draws the Rename Bookmark window; Enter does what its button does.
  if a.overlay != ovRename: return
  let w = a.renWin
  let ui = a.renUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeRename()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let enter = w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]
  let esc = w.buttonPressed[KeyEscape]
  if not a.beginDialogDraw(w, a.renSk, size): return  # retried next frame
  ui.beginFrame()
  a.renSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let W = ui.size.x
  ui.textIn("Name", rect(16, 10, W - 32, 22), colTextDim, FontSmall)
  discard ui.textField("ren-name", rect(16, 34, W - 32, 28), a.renText, a.renPlaceholder)
  let ok = ui.textButton("ren-ok", rect(W - 116, 74, 100, 28), "Rename", primary = true)
  ui.drawTooltip()
  a.renSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-rename.png")
  a.endDialogDraw(w, a.renSk, size)
  if ok or enter:
    a.renameBookmark(a.renPath, a.renTime, a.renText.strip)
    a.closeRename()
  elif esc:
    a.closeRename()

proc renderCommands(a: App, shot: string) =
  ## Draws the Commands window window and carries out its buttons.
  if a.overlay != ovCommands: return
  let w = a.cmdWin
  let ui = a.cmdUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeCommands()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  if not a.beginDialogDraw(w, a.cmdSk, size): return  # retried next frame
  ui.beginFrame()
  a.cmdSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let path = if a.player.loaded: a.player.path else: ""
  let action = a.cmdDlg.draw(ui, rect(vec2(0, 0), ui.size), path)
  ui.drawTooltip()
  a.cmdSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-commands.png")
  a.endDialogDraw(w, a.cmdSk, size)
  let d = a.cmdDlg
  case action
  of caNone: discard
  of caCancel: a.closeCommands()
  of caApply:
    let (orig, c) = (d.origTitle, d.commandLine)
    a.editCommandLines(proc (cmds: var seq[CommandLine]) =
      let i = cmds.mapIt(it.title).find(orig)
      if orig.len > 0 and i >= 0: cmds[i] = c
      else: cmds.add c)
    if orig.len > 0: moveValues(orig, c.title)
    a.closeCommands()
  of caDelete:
    let orig = d.origTitle
    a.editCommandLines(proc (cmds: var seq[CommandLine]) =
      cmds.keepItIf(it.title != orig))
    moveValues(orig, "")
    d.saved = a.commands
    d.load(a.latestCommandLine)

proc renderPick(a: App, shot: string) =
  ## Draws the Run window; Run executes the command line with the bookmarks
  ## chosen.
  if a.overlay != ovPick: return
  let w = a.pickWin
  let ui = a.pickUi
  if w.closeRequested:
    w.closeRequested = false
    a.closePick()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  let marks = a.fileBookmarks
  if not a.beginDialogDraw(w, a.pickSk, size): return  # retried next frame
  ui.beginFrame()
  a.pickSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let action = a.pickDlg.draw(ui, rect(vec2(0, 0), ui.size), marks)
  ui.drawTooltip()
  a.pickSk.endUi()
  ui.endFrame()
  if shot.len > 0: dialogImage(size).writeFile(shot.changeFileExt("") & "-pick.png")
  a.endDialogDraw(w, a.pickSk, size)
  case action
  of paNone: discard
  of paCancel: a.closePick()
  of paRun:
    let d = a.pickDlg
    var picks = a.extPicks
    var used = initTable[string, RunValue]()
    for i, row in d.rows:
      if row.kind == ckValue:
        picks[row.name] = d.texts[i]
        used[row.name] = RunValue(value: d.texts[i])
      elif d.picks[i] >= 0 and d.picks[i] < marks.len:
        picks[row.name] = fmtTime(marks[d.picks[i]].time, millis = true)
        used[row.name] = RunValue(mark: d.picks[i], time: marks[d.picks[i]].time)
    d.cmd.rememberValues(used)
    a.closePick()
    a.execute(d.cmd, picks)

proc propertiesOverlay(a: App) =
  ## Scrollable sections, two columns: field name and value.
  const
    RowH = 21'f32
    HeadH = 34'f32
    KeyW = 260'f32
    Pad = 24'f32
  let ui = a.ui
  var contentH = 0'f32
  for s in a.props: contentH += HeadH + s.rows.len.float32 * RowH
  let size = vec2(min(900'f32, ui.size.x - 40),
    min(64 + contentH + 8 + 56, ui.size.y - 40))
  let r = a.overlayFrame("Properties", size)
  let body = rect(r.x + 1, r.y + 52, r.w - 2, r.h - 52 - 51)
  a.propPageH = body.h
  let maxScroll = max(0'f32, contentH + 8 - body.h)
  if ui.hover(body) and ui.scroll() != 0:
    a.propScroll += ui.wheelNotches * RowH * RunLogWheelRows
    ui.scrollConsumed = true
  a.propScroll = clamp(a.propScroll, 0, maxScroll)

  # Scroll bar: drag the thumb, or click the track to jump there.
  let track = rect(r.x + r.w - RunLogBarW - 4, body.y + 2, RunLogBarW, max(0'f32, body.h - 4))
  if maxScroll > 0 and track.h > 0:
    let thumbH = max(24'f32, track.h * body.h / (contentH + 8)).min(track.h)
    let span = track.h - thumbH
    var thumb = rect(track.x, track.y + span * a.propScroll / maxScroll, track.w, thumbH)
    if ui.hover(track) and ui.pressed():
      ui.consumeClick()
      if not ui.hover(thumb):
        # Center the thumb on the pointer, then keep dragging from there.
        a.propScroll = clamp((ui.mouse.y - track.y - thumbH / 2) / span * maxScroll, 0, maxScroll)
      ui.activeId = "propscroll"
      a.propThumbFrom = (ui.mouse.y, a.propScroll)
    if ui.activeId == "propscroll" and span > 0:
      let (y0, s0) = a.propThumbFrom
      a.propScroll = clamp(s0 + (ui.mouse.y - y0) / span * maxScroll, 0, maxScroll)
    thumb.y = track.y + span * a.propScroll / maxScroll
    ui.rect(track, colTrack)
    ui.rect(thumb, if ui.activeId == "propscroll": colAccent
      elif ui.hover(thumb): colTextDim else: colTextDisabled)

  ui.sk.pushClipRect(body)
  let outerClip = ui.hitClip
  ui.hitClip = body
  let x = r.x + Pad
  let valW = r.w - Pad * 2 - KeyW - 12 - RunLogBarW
  var y = body.y + 4 - a.propScroll
  for s in a.props:
    if y + HeadH > body.y and y < body.y + body.h:
      ui.textIn(s.title, rect(x, y + 4, r.w - Pad * 2, 24), colAccent)
      ui.rect(rect(x, y + 29, r.w - Pad * 2, 1), colBorder)
    y += HeadH
    for (k, v) in s.rows:
      if y + RowH > body.y and y < body.y + body.h:
        ui.textIn(ui.ellipsize(k, KeyW - 8, FontSmall), rect(x, y, KeyW, RowH), colTextDim, FontSmall)
        let shown = ui.ellipsize(v, valW, FontSmall)
        let vr = rect(x + KeyW, y, valW, RowH)
        ui.textIn(shown, vr, colText, FontSmall)
        if shown != v: ui.tip(vr, v)
      y += RowH
  ui.hitClip = outerClip
  ui.sk.popClipRect()
  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  if ui.textButton("prop-copy", rect(r.x + Pad, by, 150, 30), "Copy to Clipboard"):
    setClipboardString(a.props.toText)
    a.osd("Properties copied")
  if ui.textButton("prop-close", rect(r.x + r.w - 116, by, 92, 30), "Close", primary = true):
    a.overlay = ovNone
  ui.drawTooltip()

type ShortcutGroup = tuple[title: string, rows: seq[(string, string)]]

proc keysText(a: App, acts: openArray[KeyAction], whenDefault = ""): string =
  ## Keys of the commands on one row, "Up / Down"; whenDefault replaces them
  ## while they're all on their default keys ("0 ... 9"). Commands without a
  ## key are left out.
  if whenDefault.len > 0 and acts.allIt(a.cfg.isDefault(it)): return whenDefault
  acts.mapIt(a.cfg.keysText(it)).filterIt(it.len > 0).join(" / ")

proc shortcutColumns(a: App): array[2, seq[ShortcutGroup]] =
  ## The F1 window's rows, with the keys set in Options > Player > Keys.
  ## Rows whose commands have no key are left out.
  proc keyRows(a: App, title: string,
               rows: openArray[(string, seq[KeyAction], string)]): ShortcutGroup =
    result.title = title
    for (label, acts, whenDefault) in rows:
      let keys = a.keysText(acts, whenDefault)
      if keys.len > 0: result.rows.add (label, keys)
  result[0] = @[
    a.keyRows("File", [
      ("Open file", @[kaOpenFile], ""), ("Load subtitle file", @[kaLoadSubtitle], ""),
      ("Load audio file", @[kaLoadAudio], ""),
      ("Open from clipboard", @[kaOpenClipboard], ""),
      ("Copy to clipboard", @[kaCopyClipboard], ""), ("Close", @[kaClose], ""),
      ("Save screenshot", @[kaScreenshot], ""), ("Properties", @[kaProperties], ""),
      ("Exit", @[kaExit], "")]),
    a.keyRows("Playback", [
      ("Play / Pause", @[kaPlayPause], ""), ("Stop", @[kaStop], ""),
      ("Frame forward / back", @[kaFrameForward, kaFrameBack], ""),
      ("Faster / slower playback", @[kaFaster, kaSlower], "Shift+. / Shift+,"),
      ("Repeat forever", @[kaRepeatForever], ""),
      ("Volume up / down", @[kaVolumeUp, kaVolumeDown], ""), ("Mute", @[kaMute], ""),
      ("Next / previous audio track", @[kaNextAudio, kaPrevAudio], ""),
      ("Next / previous subtitle track", @[kaNextSub, kaPrevSub], "")]),
    a.keyRows("Navigate", [
      ("Jump forward / back", @[kaJumpForward, kaJumpBack], ""),
      ("Go to beginning", @[kaGoBeginning], ""),
      ("Jump to 10% ... 90%", @SeekActions, "1 ... 9"),
      ("Next / previous chapter", @[kaNextChapter, kaPrevChapter], ""),
      ("Next / previous file", @[kaNextFile, kaPrevFile], ""),
      ("Add bookmark", @[kaAddBookmark], ""),
      ("Remove selected playlist item", @[kaRemoveFromPlaylist], "")]),
    a.keyRows("Subtitles", [
      ("Align (numpad as a 3x3 grid)",
        @[kaSubBottomLeft, kaSubBottom, kaSubBottomRight, kaSubLeft, kaSubCenter, kaSubRight,
          kaSubTopLeft, kaSubTop, kaSubTopRight], "Shift+Numpad 1 ... 9"),
      ("Move", @SubMoveActions, "Shift+Arrows"),
      ("Bigger / smaller", @[kaSubBigger, kaSubSmaller], "Shift+Numpad + / -")]),
    ("Text fields", @[
      ("Next / previous word", "Ctrl+Right / Ctrl+Left"),
      ("Select next / previous word", "Ctrl+Shift+Right / Left")])]
  var view = a.keyRows("View", [
    ("Seek bar", @[kaSeekBar], ""), ("Controls", @[kaControls], ""),
    ("Status", @[kaStatus], ""), ("Playlist", @[kaPlaylist], ""),
    ("Run log", @[kaRunLog], ""), ("Show OSD", @[kaShowOsd], ""),
    ("Full screen", @[kaFullScreen], "")])
  view.rows.add ("Leave full screen / close dialog", "Esc")
  view.rows.add a.keyRows("", [("Options", @[kaOptions], ""),
    ("Keyboard shortcuts", @[kaShortcuts], "")]).rows
  result[1] = @[
    view,
    a.keyRows("Pan, Rotate & Scale", [
      ("Center", @[kaCenter], ""), ("Move up / down", @[kaMoveUp, kaMoveDown], "Numpad 8 / 2"),
      ("Move left / right", @[kaMoveLeft, kaMoveRight], "Numpad 4 / 6"),
      ("0 degrees", @[kaRotate0], ""),
      ("Rotate clockwise / counter-clockwise", @[kaRotateCw, kaRotateCcw], "Alt+Numpad 6 / 4"),
      ("Restore size", @[kaRestoreSize], ""),
      ("Increase / decrease size", @[kaSizeUp, kaSizeDown], "Ctrl+Numpad 9 / 3"),
      ("Increase / decrease width", @[kaWidthUp, kaWidthDown], "Ctrl+Numpad 6 / 4"),
      ("Increase / decrease height", @[kaHeightUp, kaHeightDown], "Ctrl+Numpad 8 / 2"),
      ("Reset", @[kaPanReset], "")]),
    ("Mouse", @[
      ("Play / Pause", "Click video"), ("Full screen", "Double-click video"),
      ("Move window", "Drag video"), ("Context menu", "Right-click"),
      ("Volume", "Wheel"), ("Zoom at cursor", "Ctrl+Wheel"),
      ("Restore zoom / panning", "Middle-click video"),
      ("Pan zoomed video", "Shift+Middle-drag video"),
      ("Rotate frame (Shift: in Rotate steps)", "Alt+Middle-drag video"),
      ("Reset rotation", "Alt+Middle-click video"),
      ("Rotate around cursor (Shift: in steps)", "Ctrl+Alt+Middle-drag video"),
      ("360° video: look around / move window", "Drag / Ctrl+Drag video"),
      ("360° video: field of view", "Ctrl+Wheel"),
      ("360° video: reset view", "Middle-click video"),
      ("Toggle seek snapping", "Shift+Drag seek bar"),
      ("Repeat options", "Right-click loop button"),
      ("Select word / all in a text field", "Double / Triple-click")])]
  for col in result.mitems:
    col.keepItIf(it.rows.len > 0)

proc shortcutsOverlay(a: App) =
  let ui = a.ui
  const
    RowH = 21'f32
    HeadH = 32'f32
    ColW = 420'f32
    ColGap = 32'f32
    Pad = 24'f32
  let columns = a.shortcutColumns
  var colH = 0'f32
  for col in columns:
    var h = 0'f32
    for g in col: h += HeadH + g.rows.len.float32 * RowH
    colH = max(colH, h)
  let r = a.overlayFrame("Keyboard Shortcuts",
    vec2(Pad * 2 + ColW * 2 + ColGap, 60 + colH + Pad - 8))
  for ci, col in columns:
    let x = r.x + Pad + ci.float32 * (ColW + ColGap)
    var y = r.y + 58
    for g in col:
      ui.textIn(g.title, rect(x, y, ColW, 24), colAccent)
      ui.rect(rect(x, y + 25, ColW, 1), colBorder)
      y += HeadH
      for (k, v) in g.rows:
        let vw = ui.textSize(v, FontSmall).x
        ui.textIn(k, rect(x, y, ColW - vw - 12, RowH), colText, FontSmall)
        ui.textIn(v, rect(x + ColW - vw - 2, y, vw + 2, RowH), colTextDim, FontSmall, h = RightAlign)
        y += RowH

proc aboutOverlay(a: App) =
  let ui = a.ui
  let r = a.overlayFrame("About", vec2(420, 260))
  ui.icon("crown96", vec2(r.x + r.w / 2, r.y + 110), colAccent)
  ui.textIn(AppName & " " & AppVersion, rect(r.x, r.y + 160, r.w, 26), colText, h = CenterAlign)
  ui.textIn("Built with Nim, Silky and libmpv " & a.player.h.getStr("mpv-version").replace("mpv ", ""),
    rect(r.x, r.y + 188, r.w, 22), colTextDim, FontSmall, h = CenterAlign)

# --- frame ------------------------------------------------------------------

proc frame(a: App) =
  let w = a.window
  let ui = a.ui
  let fb = w.size
  if fb.x <= 0 or fb.y <= 0: return

  a.applyUiScale()
  ui.beginFrame()
  let (root, ctxRoot) = a.buildMenu()

  # Layout
  let fs = a.fullscreen
  let bottomH = a.bottomHeight
  let menuH = if fs: 0'f32 else: MenuBarHeight
  let W = ui.size.x
  let H = ui.size.y
  let plW = if a.cfg.showPlaylist: min(a.playlistWidth, W) else: 0
  # The run log spans the window's width under the menu bar (in full screen,
  # over the top of the video).
  let rlH = if a.cfg.showRunLog: min(a.runLogHeight, max(0'f32, H - menuH - bottomH)) else: 0
  let rlRect = rect(0, menuH, W, rlH)
  let top = menuH + rlH
  let videoArea =
    if fs: rect(0, 0, W, H)
    else: rect(0, top, max(0'f32, W - plW), max(0'f32, H - top - bottomH))
  a.videoRect = videoArea
  let revealZone = H - bottomH - 48
  let mouseIn = ui.fakeMouse.x >= 0 or w.mouseInside
  let bottomVisible = not fs or ui.mouse.y >= revealZone and mouseIn or
    a.seekDragging or ui.activeId == "volume"
  let bottomRect = rect(0, H - bottomH, W, bottomH)
  let plRect =
    if fs: rect(W - plW, rlH, plW, (if bottomVisible: H - bottomH else: H) - rlH)
    else: rect(W - plW, top, plW, H - top - bottomH)

  # Input capture order: overlays > menus > everything else.
  if a.overlay != ovNone:
    ui.captured = true
  else:
    a.menus.captureInput(ui)

  # GL video pass (beneath the UI).
  a.sk.beginUi(w, fb)
  glViewport(0, 0, fb.x, fb.y)
  glClearColor(colBackground.r.float32 / 255, colBackground.g.float32 / 255,
    colBackground.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  a.drawVideo(a.px(videoArea), fb)
  a.idleScreen(videoArea)
  a.sphereOsd(videoArea)

  # Video-frame mouse handling: click = play/pause, drag = move window.
  if ui.hover(videoArea) and not (fs and bottomVisible and ui.mouse.y >= H - bottomH) and
     not (a.cfg.showPlaylist and ui.mouse.inside(plRect)) and
     not (a.cfg.showRunLog and ui.mouse.inside(rlRect)):
    if ui.pressed():
      a.videoPress = true
      a.videoPressPos = ui.mouse
    if a.window.buttonPressed[DoubleClick]:
      a.setFullscreen(not a.fullscreen)
      a.videoPress = false
    if ui.released(MouseRight):
      a.ctxMenu = cmVideo
      a.menus.openContext(ui.mouse)
    if ui.scroll() != 0 and not (a.cfg.showPlaylist and ui.mouse.inside(plRect)):
      if w.ctrl and a.player.isSpherical: a.changeFov(ui.wheelNotches)
      elif w.ctrl: a.zoomAt(a.px(videoArea), ui.mouse * a.sk.uiScale, ui.wheelNotches)
      else: a.volumeStep(ui.scroll() < 0)
      ui.scrollConsumed = true
    if ui.pressed(MouseMiddle) and a.player.isSpherical:
      a.resetLook(); a.osd("View reset")
    elif ui.pressed(MouseMiddle) and w.alt:
      a.beginRotate(a.px(videoArea), ui.mouse * a.sk.uiScale, w.ctrl)
    elif ui.pressed(MouseMiddle) and w.shift and a.canPan(a.px(videoArea)):
      a.panDrag = true
      a.panFrom = ui.mouse * a.sk.uiScale
      a.panStart = a.xf.pan
    elif ui.pressed(MouseMiddle) and (a.xf.zoom != 1 or a.xf.pan != vec2(0, 0)):
      a.xf.zoom = 1; a.xf.pan = vec2(0, 0); a.xfChanged("Zoom: 100%")
  if a.rotDrag:
    if not ui.down(MouseMiddle):
      a.rotDrag = false
      if not a.rotMoved:  # Alt+Middle-click
        a.xf.rotation = 0; a.xfChanged("Rotation: 0°")
    else: a.rotateDrag(a.px(videoArea), ui.mouse * a.sk.uiScale, w.shift)
  if a.panDrag:
    if not ui.down(MouseMiddle): a.panDrag = false
    else: a.panDragTo(a.px(videoArea), ui.mouse * a.sk.uiScale)
  if a.videoPress:
    if not ui.down():
      a.videoPress = false
      if ui.window.buttonReleased[MouseLeft]:
        a.togglePlay()
    elif (ui.mouse - a.videoPressPos).length > 4:
      a.videoPress = false
      # 360° view: a drag looks around, Ctrl+drag moves the window (or the
      # other way round, from the frame's context menu). Full screen only looks.
      if a.player.isSpherical and (fs or w.ctrl == a.cfg.sphereDragMovesWindow):
        a.lookDragging = true
        a.lookLast = a.videoPressPos
        a.lookDrag(ui.mouse)
      elif not fs: w.startWindowDrag()
  if a.lookDragging:
    if not ui.down() or not a.player.isSpherical: a.lookDragging = false
    else: a.lookDrag(ui.mouse)

  # Chrome
  if a.cfg.showPlaylist: a.playlistPanel(plRect)
  else: a.plListRect = Rect()
  if a.cfg.showRunLog: a.runLogPanel(rlRect)
  if bottomVisible and bottomH > 0:
    var y = H - bottomH
    if a.cfg.showSeekBar:
      a.seekBar(rect(0, y, W, SeekBarHeight)); y += SeekBarHeight
    if a.cfg.showControls:
      a.controls(rect(0, y, W, ControlsHeight)); y += ControlsHeight
    if a.cfg.showStatus:
      a.status(rect(0, y, W, StatusHeight))
    if bottomRect.h > 0 and ui.hover(bottomRect) and ui.scroll() != 0:
      a.volumeStep(ui.scroll() < 0)
      ui.scrollConsumed = true
  else:
    a.showPreview = false
    a.seekDragging = false
  if not fs:
    a.menus.drawBar(ui, root, rect(0, 0, W, MenuBarHeight))

  # Overlays draw on the popup layer with the mouse released to them.
  if a.overlay != ovNone:
    ui.captured = false
    ui.sk.pushLayer(PopupsLayer)
    case a.overlay
    of ovOptions:  # its own window; clicks here bring it back up
      if ui.pressed(): a.optWin.activate()
    of ovRename:
      if ui.pressed(): a.renWin.activate()
    of ovCommands:
      if ui.pressed(): a.cmdWin.activate()
    of ovPick:
      if ui.pressed(): a.pickWin.activate()
    of ovProperties: a.propertiesOverlay()
    of ovShortcuts: a.shortcutsOverlay()
    of ovAbout: a.aboutOverlay()
    of ovNone: discard
    ui.sk.popLayer()
    if ui.pressed() and a.overlay != ovNone: ui.consumeClick()
  else:
    ui.captured = false
    a.menus.updatePopups(ui, root, ctxRoot)
    ui.drawTooltip()
  ui.sk.pushLayer(PopupsLayer)
  a.syncOutline(rect(0, 0, W, H))
  ui.sk.popLayer()

  # Cursor auto-hide over playing video.
  if ui.mouse != a.lastMouse:
    a.lastMouse = ui.mouse
    a.lastMouseMove = now()
  let hide = a.player.playing and a.player.hasVideo and
    ui.mouse.inside(videoArea) and not a.menus.isOpen and a.overlay == ovNone and
    not (a.cfg.showRunLog and ui.mouse.inside(rlRect)) and
    not (fs and bottomVisible) and now() - a.lastMouseMove > 1.0
  let resize = ui.activeId == "plresize" or a.cfg.showPlaylist and
    ui.hover(rect(plRect.x, plRect.y, PlaylistGripW, plRect.h)) and a.overlay == ovNone and
    not a.menus.isOpen
  let resizeV = ui.activeId == "rlresize" or a.cfg.showRunLog and
    ui.hover(rect(0, rlRect.y + rlRect.h - RunLogGripH, W, RunLogGripH)) and
    a.overlay == ovNone and not a.menus.isOpen
  let shape = if hide: ptHidden elif resize: ptResize elif resizeV: ptResizeV else: ptArrow
  if shape != a.pointerShape:
    a.pointerShape = shape
    w.cursor = case shape
      of ptHidden: hiddenCursor()
      of ptResize: Cursor(kind: ResizeLeftRightCursor)
      of ptResizeV: Cursor(kind: ResizeUpDownCursor)
      of ptArrow: Cursor(kind: ArrowCursor)

  a.sk.endUi()
  a.drawPreview(fb)
  ui.endFrame()
  let shot = a.shotPath
  if shot.len > 0:
    readFramebuffer(fb).writeFile(shot)
    a.shotPath = ""
  w.swapBuffers()
  mpv_render_context_report_swap(a.player.render)
  # Menu popups live in their own windows. Draw them only after the main swap:
  # pointing the context at another drawable discards the main back buffer.
  a.menus.renderPopups(ui, if shot.len == 0: nil else:
    proc (level: int, image: Image) =
      image.writeFile(shot.changeFileExt("") & &"-menu{level}.png"))
  a.renderOptions(shot)
  a.renderRename(shot)
  a.renderCommands(shot)
  a.renderPick(shot)

# --- setup & main loop --------------------------------------------------------

proc keyUi(a: App): Ui =
  ## The Ui of the window taking the keyboard.
  case a.overlay
  of ovOptions: a.optUi
  of ovRename: a.renUi
  of ovCommands: a.cmdUi
  of ovPick: a.pickUi
  else: a.ui

proc runScriptStep(a: App, st: ScriptStep) =
  let arg = st.args.join(" ")
  case st.cmd
  of "open": a.openPaths(@[arg])
  of "menu":
    var path: seq[int]
    for x in st.args[1 .. ^1]: path.add parseInt(x)
    a.menus.openBar(parseInt(st.args[0]), path)
  of "ctx": a.ctxMenu = cmVideo; a.menus.openContext(vec2(parseFloat(st.args[0]), parseFloat(st.args[1])))
  of "plctx": a.ctxMenu = cmPlaylist; a.menus.openContext(vec2(parseFloat(st.args[0]), parseFloat(st.args[1])))
  of "sbctx": a.seekBarContext(vec2(parseFloat(st.args[0]), parseFloat(st.args[1])))
  of "plselect": a.plSelected = parseInt(arg)
  of "plaction":  # playlist context menu item by label
    a.ctxMenu = cmPlaylist
    for n in a.buildMenu().context.children:
      if n.label == arg and n.enabled and n.action != nil: n.action()
    a.ctxMenu = cmVideo
  of "pldump": stderr.writeLine "playlist ", a.plIndex, " ", $a.playlist.mapIt(it.extractFilename)
  of "close": a.menus.close()
  of "mouse":
    a.ui.fakeMouse = if arg == "off": vec2(-1, -1)
                     else: vec2(parseFloat(st.args[0]), parseFloat(st.args[1]))
  of "mods": a.fakeMods = if arg == "off": "" else: arg
  of "optpage":
    a.ensureOptionsWindow()
    for p in OptionsPage:
      if ($p).toLowerAscii.startsWith(arg.toLowerAscii): a.optionsDlg.selectPage(a.optUi, p)
  of "optkey":  # id [combo]: Options > Keys; gives the command combo ("none" clears), else asks for a key
    for act in KeyAction:
      if $act == st.args[0]:
        if st.args.len > 1:
          let k = if st.args[1] == "none": KeyCombo() else: parseCombo(st.args[1 .. ^1].join(" "))
          a.optionsDlg.assignKeys(a.cfg, act, if k.key == ButtonUnknown: @[] else: @[k])
        else: a.optionsDlg.startCapture(a.optUi, act)
  of "key":  # combo: runs the command bound to it, as pressing it would
    let k = parseCombo(arg)
    for act in KeyAction:
      if k in a.cfg.combos(act):
        a.runAction(act)
        break
  of "focus": a.keyUi.focusId = arg
  of "type": a.keyUi.typedPending.add arg
  of "overlay":
    a.showOverlay(case arg
      of "options": ovOptions
      of "properties": ovProperties
      of "shortcuts": ovShortcuts
      of "about": ovAbout
      else: ovNone)
  of "commands": a.showCommands()
  of "cmdcard":  # name [value|reference [content]]: a card at the caret
    let kind = if st.args.len > 1 and st.args[1] == "reference": ckReference else: ckValue
    a.cmdDlg.addCard(st.args[0], kind, if st.args.len > 2: st.args[2 .. ^1].join(" ") else: "")
  of "cmdapply": a.cmdDlg.applyRequested = true
  of "run": a.runMenuPath(@["Run", arg])
  of "runstop": (for e in a.runLog: e.stop())  # the run log's Stop button
  of "pick":  # row bookmark: choose a bookmark (0-based) in the Run window
    a.pickDlg.picks[parseInt(st.args[0])] = parseInt(st.args[1])
  of "pickrun": a.pickDlg.runRequested = true
  of "picktext":  # row text: a value for this run
    a.pickDlg.texts[parseInt(st.args[0])] = st.args[1 .. ^1].join(" ")
  of "pickopen": a.pickDlg.openRow = parseInt(arg)
  of "action": a.runMenuPath(arg.split('/'))
  of "dialogresult": a.handleDialogResult(st.args[0], @[st.args[1 .. ^1].join(" ")])  # purpose path
  of "fs": a.setFullscreen(arg == "1")
  of "subs":  # alignX alignY dx dy scale
    a.subs = SubLayout(alignX: parseInt(st.args[0]), alignY: parseInt(st.args[1]),
      offset: vec2(parseFloat(st.args[2]), parseFloat(st.args[3])), scale: parseFloat(st.args[4]))
  of "seek": a.seekTo(parseFloat(arg))
  of "look":  # yaw pitch fov: the 360° camera, degrees
    (a.lookYaw, a.lookPitch, a.lookFov) = (parseFloat(st.args[0]).float32,
      parseFloat(st.args[1]).float32, parseFloat(st.args[2]).float32)
  of "pause": a.togglePlay()
  of "sync":  # all | none | add <pid> | remove <pid> | addany (first peer found)
    if arg == "addany":
      if a.peers != nil and a.peers.peers.len > 0: a.syncRequest("add", a.peers.peers[0].pid)
    else: a.syncRequest(st.args[0], if st.args.len > 1: parseInt(st.args[1]) else: 0)
  of "syncdump":
    if a.peers == nil: return
    stderr.writeLine "sync ", a.peers.pid, " master=", a.syncMaster, " members=", $a.syncMembers,
      " peers=", $a.peers.peers.mapIt((it.pid, it.title, it.master)),
      " playlist=", $a.playlist.mapIt(it.extractFilename), " index=", a.plIndex,
      " path=", a.player.path.extractFilename, " t=", a.player.timePos,
      " paused=", a.player.paused, " stopped=", a.player.stopped, " speed=", a.player.speed
  of "size": a.window.size = ivec2(parseInt(st.args[0]).int32, parseInt(st.args[1]).int32)
  of "shot": a.shotPath = arg
  of "quit": a.window.closeRequested = true
  of "uiscale": a.cfg.uiScale = parseFloat(arg)  # percent, as Options sets it
  of "set": a.player.h.setProp(st.args[0], st.args[1 .. ^1].join(" "))
  of "dump":
    for prop in st.args:
      stderr.writeLine "dump ", prop, " = ", a.player.h.getStr(prop)
  else: stderr.writeLine "script: unknown command ", st.cmd

proc main() =
  discard setlocale(LC_NUMERIC, "C")
  when defined(windows): attachStdio()
  let a = App(plIndex: -1, plSelected: -1, optionsDlg: newOptionsDialog(),
    cmdDlg: newCmdDialog(), pickDlg: newPickDialog())
  a.cfg = loadConfig()
  a.script = loadScript()
  randomize()
  let files = commandLineParams().mapIt(if it.contains("://"): it else: it.absolutePath)
  # Debug scripts must not hand their files to (or take files from) a real
  # player the user has open.
  let scripted = a.script.steps.len > 0
  if files.len > 0 and a.cfg.openMode == omSamePlayer and not scripted and
     forwardToRunning(files):
    return
  if not scripted: a.instance = startServer()
  # Debug scripts only see other players in a folder of their own.
  if not scripted or existsEnv("MMP_SYNC_DIR"): a.peers = startPeerNet()
  a.positions = loadPositions()
  a.subScales = loadSubScales()
  a.bookmarks = loadBookmarks()
  if a.cfg.seedPresets(): a.cfg.save()
  a.commands = loadCommandLines()
  if a.cfg.rememberTransform:
    let t = a.cfg.transform
    a.xf = VideoTransform(pan: vec2(t.panX, t.panY), rotation: t.rotation,
      zoom: t.zoom, scaleX: t.scaleX, scaleY: t.scaleY)
  # vsync off: under XWayland the NVIDIA driver can block glXSwapBuffers for
  # whole seconds when KWin withholds frame callbacks (hidden/occluded window),
  # freezing UI and video. The compositor presents our buffers tear-free, mpv
  # paces video frames, and UI-only redraws are rate-capped in the main loop.
  let c = a.cfg
  let startSize =
    if c.rememberWindowSize and c.windowW >= MinWindow.x and c.windowH >= MinWindow.y:
      ivec2(c.windowW.int32, c.windowH.int32)
    else: ivec2(1024, 640)
  a.window = newWindow(AppName, startSize, vsync = false)
  a.window.icon = appIcon()
  a.window.initMainWindow()
  when defined(windows): setDialogOwner(a.window.getHWND)
  makeContextCurrent(a.window)
  loadExtensions()
  a.window.disableVsync()
  if c.rememberWindowPos and c.windowW > 0:
    # Only onto a monitor that still exists.
    let p = ivec2(c.windowX.int32, c.windowY.int32)
    let m = monitorAt(p + ivec2(40, 40))
    if p.x + 40 >= m.pos.x and p.y + 40 >= m.pos.y and
       p.x + 40 < m.pos.x + m.size.x and p.y + 40 < m.pos.y + m.size.y:
      a.window.moveFrame(p)

  let scale = a.uiScale
  let (img, atlas) = buildAtlas(scale)
  (a.atlasImg, a.atlas) = (img, atlas)
  a.sk = newSilky(a.window, img, atlas)
  a.sk.uiScale = scale
  a.sk.atlasScale = scale
  a.ui = newUi(a.sk, a.window)
  a.window.setAspectHints(0, ivec2(0, 0), a.minWindow)
  a.menus = newMenuSystem()
  a.quad = newQuadRenderer()

  a.player = newPlayer(a.cfg.volume, a.cfg.muted, a.cfg.showOsd)
  a.player.initRender()
  a.applyLoop()
  a.syncSettings()
  try:
    a.preview = newPreview()
    if a.preview != nil: a.preview.initRender()
  except MpvError as e:
    stderr.writeLine "seek preview disabled: ", e.msg
    a.preview = nil

  # Any input schedules redraws for a short while (hover effects, tooltips).
  let touch = proc () = a.dirtyUntil = now() + 1.2
  a.window.onMouseMove = touch
  a.window.onScroll = proc () =
    touch()
    a.inputPending = true
  a.window.onButtonPress = proc (b: Button) =
    touch()
    a.inputPending = true
  a.window.onButtonRelease = proc (b: Button) =
    touch()
    a.inputPending = true
  a.window.onResize = proc () = touch()
  a.window.onRune = proc (r: Rune) =
    touch()
    a.ui.typedPending.add $r
    a.inputPending = true
  # Windy reports a drop one file at a time; gather them so the whole drop
  # becomes one playlist (or one insertion when dropped on the playlist).
  a.window.onFileDrop = proc (path: string, data: string) =
    touch()
    if a.dropped.len == 0: a.dropAt = a.window.mousePos.vec2 / a.sk.uiScale
    a.dropped.add path
  a.window.onFocusChange = proc () =
    touch()
    # Popups take no focus, so focus moving elsewhere means a click outside
    # the app (or Alt+Tab): dismiss menus like a toolkit would. Checked a bit
    # later in the loop, since activating the window by clicking the menu bar
    # can produce a brief focus-out that must not close the menu just opened.
    a.focusLostAt = if a.window.focused: 0.0 else: now()
    a.dirtyUntil = now() + 0.5

  if files.len > 0: a.openPaths(files)
  elif c.rememberPlaylist:
    # Restored without playing; Play starts the entry that was current.
    a.playlist = c.playlist.filterIt(fileExists(it) or it.contains("://"))
    if a.playlist.len > 0:
      let cur = c.playlistIndex
      a.plSelected =
        if cur >= 0 and cur < c.playlist.len and c.playlist[cur] in a.playlist:
          a.playlist.find(c.playlist[cur])
        else: 0

  var lastFrame = 0.0
  while not a.window.closeRequested:
    # Silky's own text-input layer (unused here) switches rune input off at
    # the end of every UI frame and on focus changes; without it Windy drops
    # typed characters, so turn it back on before reading events.
    a.window.runeInputEnabled = true
    if a.optWin != nil: a.optWin.runeInputEnabled = true
    if a.renWin != nil: a.renWin.runeInputEnabled = true
    if a.cmdWin != nil: a.cmdWin.runeInputEnabled = true
    if a.pickWin != nil: a.pickWin.runeInputEnabled = true
    pollEvents()
    if a.dropped.len > 0:
      a.dropFiles(a.dropped)
      a.dropped.setLen 0
    let incoming = a.instance.poll()
    if incoming.len > 0 and a.playlistLocked:
      # The master's playlist rules; the files go there.
      a.peers.send(a.syncMaster, @["open"] & incoming.mapIt(
        if it.contains("://"): it else: it.absolutePath))
      a.osd("Opening in the synchronization master")
    elif incoming.len > 0:
      if a.overlay == ovOptions: a.closeOptions(false)
      if a.overlay == ovRename: a.closeRename()
      if a.overlay == ovCommands: a.closeCommands()
      if a.overlay == ovPick: a.closePick()
      a.overlay = ovNone
      a.ui.focusId = ""
      a.openPaths(incoming.mapIt(if it.contains("://"): it else: it.absolutePath))
      a.window.activate()
      a.dirtyUntil = now() + 0.5
    if a.menus.pollInput(): a.dirtyUntil = now() + 1.2
    if takeFrameReady(): a.frameFlag = true
    if takePreviewReady(): a.previewFlag = true
    let peerNews = a.pollPeers()
    let changed = a.player.pollEvents() or peerNews
    a.pollProbe()
    a.pollMediaKey()
    a.preview.pollEvents()
    a.pollDialog()
    a.pollJobs()
    for st in a.script.due: a.runScriptStep(st)
    if a.script.next < a.script.steps.len: a.dirtyUntil = now() + 0.5

    if a.player.justLoaded:
      a.player.justLoaded = false
      a.resetLook()
      a.lookDragging = false
      a.updateTitle()
      # The master moved to another file: the group follows to its start time.
      a.syncSend("seek", $a.resumedAt, "true")
      a.syncSend("play")
      if a.resumedAt > 0:
        a.osd("Resumed at " & fmtTime(a.resumedAt))
        a.resumedAt = 0
      a.hintsKey = ""
      if a.cfg.autoFitWindow: a.fitPending = true
    if a.fitPending and a.player.hasVideo:
      a.fitPending = false
      a.fitWindowToVideo()
    a.handleEof()
    # Re-checked every iteration while unfocused, so menus opened or kept
    # open after the focus left still close. The grace period also counts
    # from the opening, as the click that opens a menu on an inactive window
    # activates it a moment later. A press held on a popup is spared, so a
    # focus blip from clicking it can't swallow the item.
    if not a.menus.isOpen: a.menuOpenedAt = 0
    elif a.menuOpenedAt == 0: a.menuOpenedAt = now()
    if a.focusLostAt > 0 and now() - max(a.focusLostAt, a.menuOpenedAt) > 0.15 and
       not a.window.focused and a.menus.isOpen and
       not (pointerButtonsDown() and a.menus.pointerOverPopup(a.ui)):
      a.menus.close()
      a.dirtyUntil = now() + 0.5
    a.applyOnTop()
    a.applyKeepAwake()
    a.updateAspectHints()

    let t = now()
    a.pollVideoFrame()
    let wantDraw = a.renderNow or a.previewFlag or changed or t < a.dirtyUntil or
      t - lastFrame > 0.25 or a.dialog != nil and t - lastFrame > 0.1
    # Due video frames and input draw immediately (a skipped frame would lose
    # the press); other UI-only redraws are capped at ~240 fps.
    let needDraw = wantDraw and
      (a.renderNow or a.inputPending or t - lastFrame >= 1 / 240)
    if needDraw:
      a.inputPending = false
      a.handleKeys()
      a.frame()
      a.syncSettings()
      lastFrame = t
    else:
      sleep(1)

  if a.overlay == ovOptions: a.closeOptions(false)
  a.savePosition()
  a.cfg.volume = a.player.volume
  a.cfg.muted = a.player.muted
  a.cfg.transform = SavedTransform(panX: a.xf.pan.x, panY: a.xf.pan.y,
    rotation: a.xf.rotation, zoom: a.xf.zoom, scaleX: a.xf.scaleX, scaleY: a.xf.scaleY)
  if not a.fullscreen and not a.window.maximized:
    let (pos, size) = (a.window.framePos, a.window.size)
    (a.cfg.windowX, a.cfg.windowY, a.cfg.windowW, a.cfg.windowH) =
      (pos.x.int, pos.y.int, size.x.int, size.y.int)
  if a.cfg.rememberPlaylist:
    a.cfg.playlist = a.playlist
    a.cfg.playlistIndex = if a.plIndex >= 0: a.plIndex else: a.plSelected
  else:
    (a.cfg.playlist, a.cfg.playlistIndex) = (newSeq[string](), -1)
  a.cfg.save()
  a.instance.close()
  a.peers.close()
  for c in a.children: c.close()
  if a.preview != nil:
    mpv_render_context_free(a.preview.render)
    mpv_terminate_destroy(a.preview.h)
  mpv_render_context_free(a.player.render)
  mpv_terminate_destroy(a.player.h)

when isMainModule:
  main()
