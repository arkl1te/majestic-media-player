## Majestic Media Player — an mpv-based video player with a Silky UI.

import std/[os, strutils, strformat, times, math, osproc, unicode, sequtils, algorithm,
  random, tables, streams]
import silky, vmath, bumpy, chroma, pixie, opengl
import mpv, videogl, xwin, config, dialogs, theme, ui, menutree, player, icons, debugscript,
  options, instance, playlists, peers, cmdlines, runlog, mediainfo
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

type
  Overlay = enum
    ovNone, ovOptions, ovProperties, ovShortcuts, ovAbout, ovRename, ovCommands, ovPick

  ContextMenu = enum
    cmVideo, cmTime, cmStatus, cmSeekBar, cmPlaylist, cmPlaylistColumns  ## where the right-click menu was opened

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
    bookmarks: Bookmarks      ## per-file bookmarks, shown on the seek bar
    renWin: Window            ## Rename Bookmark dialog, created on first use
    renSk: Silky
    renUi: Ui
    renPath: string           ## the bookmark being renamed: its file and time
    renTime: float
    renText: string
    renPlaceholder: string    ## its default label, shown when renText is empty
    cmdDlg: CmdDialog         ## Command-line Manager, its window created on first use
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
    lastMouse: Vec2
    lastMouseMove: float
    pointerShape: PointerShape
    # seek bar
    seekDragging: bool
    seekDragT: float
    seekRect: Rect            ## seek bar as last drawn
    ctxSeekT: float           ## seek bar time the context menu was opened at
    ctxBookmark: int          ## bookmark under the pointer then, else -1
    lastDragSeekAt: float
    previewQuad: Rect
    showPreview: bool
    # window management
    onTopApplied: bool
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

proc chromeSize(a: App): IVec2 =
  ## Window space not used by the video frame (windowed mode).
  ivec2(int32(if a.cfg.showPlaylist: a.playlistWidth else: 0),
        int32(MenuBarHeight + a.bottomHeight + (if a.cfg.showRunLog: a.runLogHeight else: 0)))

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
    a.window.setAspectHints(aspect, chrome, MinWindow)

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
  size.x = max(size.x, MinWindow.x)
  size.y = max(size.y, MinWindow.y)
  a.window.size = size

proc resizeKeepingVideo(a: App, delta: IVec2) =
  ## Grows/shrinks the window by delta when chrome is toggled, so the video
  ## frame keeps its size.
  if a.fullscreen or a.window.maximized: return
  a.window.size = a.window.size + delta

proc setFullscreen(a: App, on: bool) =
  if on == a.fullscreen: return
  a.menus.close()
  a.fullscreen = on
  a.window.fullscreen = on
  a.hintsKey = ""
  if on:
    a.window.setAspectHints(0, ivec2(0, 0), MinWindow)

proc applyOnTop(a: App) =
  let want = case a.cfg.onTop
    of otDefault: false
    of otAlways: true
    of otWhilePlaying: a.player.playing
    of otWhilePlayingVideo: a.player.playing and a.player.hasRealVideo
  if want != a.onTopApplied:
    a.onTopApplied = want
    a.window.setAlwaysOnTop(want)

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

proc clipboardPaths(): seq[string] =
  ## Files and URLs on the clipboard: a file manager's text/uri-list, or
  ## plain text holding paths or URLs, one per line.
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
  let paths = clipboardPaths()
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
  try:
    a.children.add startProcess(cmd, args = @args, options = {poUsePath, poParentStreams})
  except OSError as e:
    stderr.writeLine "cannot run ", cmd, ": ", e.msg

proc runAfterPlayback(a: App) =
  case a.afterPlayback
  of apNothing: discard
  of apNextInFolder:
    let f = a.folderNeighbor(1)
    if f.len > 0:
      a.playlist = @[f]
      a.playIndex(0)
  of apMonitorOff:
    if findExe("kscreen-doctor").len > 0: a.spawn("kscreen-doctor", "--dpms", "off")
    else: a.spawn("xset", "dpms", "force", "off")
  of apExit: a.window.closeRequested = true
  of apSleep: a.spawn("systemctl", "suspend")
  of apHibernate: a.spawn("systemctl", "hibernate")
  of apShutdown: a.spawn("systemctl", "poweroff")
  of apLogOff:
    if findExe("qdbus6").len > 0:
      a.spawn("qdbus6", "org.kde.Shutdown", "/Shutdown", "org.kde.Shutdown.logout")
    else:
      a.spawn("loginctl", "terminate-session", getEnv("XDG_SESSION_ID"))
  of apLock: a.spawn("loginctl", "lock-session")

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

proc fileBookmarks(a: App): seq[Bookmark] =
  if a.player.loaded: a.bookmarks.getOrDefault(a.player.path) else: @[]

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
  a.bookmarks = loadBookmarks()
  var marks = a.bookmarks.getOrDefault(path)
  edit(marks)
  if marks.len > 0: a.bookmarks[path] = marks
  else: a.bookmarks.del(path)
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
  if a.player.path.len > 0 and fileExists(a.player.path): a.player.path.parentDir
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
  var dir = getHomeDir() / "Pictures"
  if not dirExists(dir): dir = getHomeDir()
  a.ask(dkSaveFile, "screenshot", "Save Screenshot",
    dir / &"{base}_{stamp}.png", @["png", "jpg", "webp"], "Images")

const PlaylistFilters = @[("M3U playlist", @["m3u", "m3u8"]), ("PLS playlist", @["pls"])]

proc loadPlaylistDialog(a: App) =
  a.ask(dkOpenFile, "plload", "Load Playlist", exts = @PlaylistExtensions,
    filterName = "Playlists", extraFilters = PlaylistFilters)

proc savePlaylistDialog(a: App) =
  a.ask(dkSaveFile, "plsave", "Save Playlist", a.startDir / "Playlist.m3u",
    extraFilters = PlaylistFilters)

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

proc handleDialogResult(a: App, purpose: string, paths: seq[string]) =
  if paths.len == 0: return
  case purpose
  of "open": a.openPaths(paths)
  of "opendir": a.openPaths(paths[0 .. 0])
  of "pladd": a.addToPlaylist(paths)
  of "plload": a.loadPlaylist(paths[0])
  of "plsave": a.savePlaylist(paths[0])
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
  ## same decorations), kept on the main window's monitor.
  var pos = a.window.framePos + (a.window.size - size) div 2
  let m = monitorAt(a.window.pos + a.window.size div 2)
  pos.x = clamp(pos.x, m.pos.x, max(m.pos.x, m.pos.x + m.size.x - size.x))
  pos.y = clamp(pos.y, m.pos.y, max(m.pos.y, m.pos.y + m.size.y - size.y))
  w.placeDialog(pos, size)
  w.visible = true
  w.activate()

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
  ## Opens the Command-line Manager on the command line created last.
  a.menus.close()
  a.commands = loadCommandLines()
  a.cmdDlg.saved = a.commands
  a.cmdDlg.load(a.latestCommandLine)
  if a.cmdWin == nil:
    (a.cmdWin, a.cmdSk, a.cmdUi) = a.newDialogWindow("Command-line Manager", CommandsSize)
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

proc runCommandLine(a: App, c: CommandLine) =
  ## Runs c, first asking for its bookmarks and values when it has any.
  let cards = c.parts.runCards
  if cards.len == 0:
    a.execute(c)
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
  a.pickDlg.start(c, marks.len)
  let (sw, sh) = a.pickDlg.size
  if a.pickWin == nil:
    (a.pickWin, a.pickSk, a.pickUi) = a.newDialogWindow("Run", ivec2(sw, sh))
  a.pickWin.title = c.title
  a.pickUi.focusId = ""
  a.pickUi.navId = "pk-0"
  a.pickUi.navVisible = false
  a.showDialog(a.pickWin, ivec2(sw, sh))
  a.overlay = ovPick

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

  # File
  let locked = a.playlistLocked  # synchronized: the master's playlist rules
  let file = root.sub("File")
  file.item("Open File...", "Ctrl+O", enabled = not locked, action = proc () = a.openFileDialog())
  let recent = file.sub("Open Recent", enabled = a.cfg.recentFiles.len > 0 and not locked)
  let openOne = proc (path: string) = a.openPaths(@[path])
  for r in a.cfg.recentFiles:
    recent.item(r.extractFilename, action = bindAct(openOne, r))
  if a.cfg.recentFiles.len > 0:
    recent.sep()
    recent.item("Clear List", action = proc () = a.cfg.recentFiles.setLen 0)
  file.item("Open Directory...", enabled = not locked, action = proc () =
    a.ask(dkOpenDir, "opendir", "Open Directory"))
  file.item("Open From Clipboard", "Ctrl+V", enabled = not locked,
    action = proc () = a.openFromClipboard())
  file.item("Copy to Clipboard", "Ctrl+C", enabled = loaded,
    action = proc () = a.copyToClipboard())
  file.item("Close", "Ctrl+X", enabled = loaded and not locked, action = proc () = a.closeFile())
  file.sep()
  file.item("Save Screenshot...", "Alt+I", enabled = loaded and p.hasVideo,
    action = proc () = a.screenshot())
  file.sep()
  let loadTrack = file.sub("Load Track From File", enabled = loaded)
  loadTrack.item("Subtitle File...", "Ctrl+Shift+O", action = proc () =
    a.ask(dkOpenFile, "subtitle", "Load Subtitle", exts = @SubtitleExtensions,
      filterName = "Subtitles"))
  loadTrack.item("Audio File...", action = proc () =
    a.ask(dkOpenFile, "audio", "Load Audio Track", exts = @MediaExtensions,
      filterName = "Audio files"))
  file.sep()
  file.item("Properties", enabled = loaded, action = proc () = a.showOverlay(ovProperties))
  file.sep()
  file.item("Exit", "Alt+X", action = proc () = a.window.closeRequested = true)
  let exitItem = file.children[^1]

  # View
  let view = root.sub("View")
  view.check("Seek Bar", "Ctrl+1", cfg.showSeekBar, action = proc () =
    a.cfg.showSeekBar = not a.cfg.showSeekBar
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showSeekBar: SeekBarHeight else: -SeekBarHeight))))
  view.check("Controls", "Ctrl+2", cfg.showControls, action = proc () =
    a.cfg.showControls = not a.cfg.showControls
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showControls: ControlsHeight else: -ControlsHeight))))
  view.check("Status", "Ctrl+3", cfg.showStatus, action = proc () =
    a.cfg.showStatus = not a.cfg.showStatus
    a.resizeKeepingVideo(ivec2(0, int32(if a.cfg.showStatus: StatusHeight else: -StatusHeight))))
  view.check("Playlist", "Ctrl+4", cfg.showPlaylist, action = proc () =
    a.cfg.showPlaylist = not a.cfg.showPlaylist
    let w = int32(a.playlistWidth)
    a.resizeKeepingVideo(ivec2(if a.cfg.showPlaylist: w else: -w, 0)))
  view.check("Run Log", "Ctrl+5", cfg.showRunLog, action = proc () =
    a.cfg.showRunLog = not a.cfg.showRunLog
    if a.cfg.showRunLog: a.rlFollow = true
    let h = int32(a.runLogHeight)
    a.resizeKeepingVideo(ivec2(0, if a.cfg.showRunLog: h else: -h)))
  view.sep()
  view.check("Show OSD", "", cfg.showOsd, action = proc () =
    a.cfg.showOsd = not a.cfg.showOsd
    a.syncSettings())
  view.check("Full Screen", "Alt+Enter", a.fullscreen, action = proc () =
    a.setFullscreen(not a.fullscreen))
  let fullScreen = view.children[^1]

  let grab = view.sub("Grab, Rotate && Scale".replace("&&", "&"))
  grab.item("Center", "Numpad 5", action = proc () =
    a.xf.pan = vec2(0, 0); a.xfChanged("Pan: center"))
  for (label, key, d) in [("Move Up", "Numpad 8", vec2(0, -1)), ("Move Down", "Numpad 2", vec2(0, 1)),
                          ("Move Left", "Numpad 4", vec2(-1, 0)), ("Move Right", "Numpad 6", vec2(1, 0))]:
    grab.item(label, key, action = bindAct(proc (dir: Vec2) =
      a.xf.pan += dir * a.cfg.panStep.float32
      a.xfChanged(&"Pan: {int(a.xf.pan.x)}, {int(a.xf.pan.y)}"), d))
  grab.sep()
  grab.item("0 Degrees", "Alt+Numpad 5", action = proc () =
    a.xf.rotation = 0; a.xfChanged("Rotation: 0°"))
  grab.item("Rotate Clockwise", "Alt+Numpad 6", action = proc () =
    a.xf.rotation = floorMod(a.xf.rotation + a.cfg.rotateStep.float32, 360)
    a.xfChanged(&"Rotation: {a.xf.rotation:g}°"))
  grab.item("Rotate Counter-clockwise", "Alt+Numpad 4", action = proc () =
    a.xf.rotation = floorMod(a.xf.rotation - a.cfg.rotateStep.float32, 360)
    a.xfChanged(&"Rotation: {a.xf.rotation:g}°"))
  grab.sep()
  grab.item("Restore Size", "Ctrl+Numpad 5", action = proc () =
    a.xf.zoom = 1; a.xf.scaleX = 1; a.xf.scaleY = 1; a.xfChanged("Size: 100%"))
  let step = a.cfg.sizeStep.float32 / 100
  for (label, key, which, d) in [
      ("Increase Size", "Ctrl+Numpad 9", 0, 1'f32), ("Decrease Size", "Ctrl+Numpad 3", 0, -1'f32),
      ("Increase Width", "Ctrl+Numpad 6", 1, 1'f32), ("Decrease Width", "Ctrl+Numpad 4", 1, -1'f32),
      ("Increase Height", "Ctrl+Numpad 8", 2, 1'f32), ("Decrease Height", "Ctrl+Numpad 2", 2, -1'f32)]:
    grab.item(label, key, action = bindAct(proc (wd: (int, float32)) =
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
  grab.item("Reset", action = proc () =
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
  view.item("Options...", "O", action = proc () = a.showOverlay(ovOptions))
  let options = view.children[^1]

  # Play
  let play = root.sub("Play")
  play.item(if p.playing: "Pause" else: "Play", "Space",
    enabled = loaded or a.cfg.recentFiles.len > 0,
    action = proc () = a.playPause())
  play.item("Stop", "", enabled = loaded, action = proc () = a.stop())
  let (playPause, stop) = (play.children[0], play.children[1])
  play.item("Frame Forward", ".", enabled = loaded, action = proc () = a.frameStep(true))
  play.item("Frame Back", ",", enabled = loaded, action = proc () = a.frameStep(false))
  play.item(&"Faster Playback (+{a.cfg.rateStep:g}x)", "Shift+.", enabled = loaded,
    action = proc () = a.changeRate(1))
  play.item(&"Slower Playback (-{a.cfg.rateStep:g}x)", "Shift+,", enabled = loaded,
    action = proc () = a.changeRate(-1))
  let rep = play.sub("Repeat")
  rep.check("Forever", "", cfg.repeatForever, action = proc () =
    a.cfg.repeatForever = not a.cfg.repeatForever; a.applyLoop())
  rep.sep()
  rep.radio("File", "", cfg.repeatMode == rmFile, action = proc () =
    a.cfg.repeatMode = rmFile; a.applyLoop())
  rep.radio("Playlist", "", cfg.repeatMode == rmPlaylist, action = proc () =
    a.cfg.repeatMode = rmPlaylist; a.applyLoop())
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
  vol.item("Up", "Up", action = proc () = a.volumeStep(true))
  vol.item("Down", "Down", action = proc () = a.volumeStep(false))
  vol.check("Mute", "Ctrl+M", p.muted, action = proc () = a.setMute(not a.player.muted))
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
  bm.item("Add Bookmark", "Insert", enabled = loaded, action = proc () = a.addBookmark(a.player.timePos))
  bm.item("Remove Bookmark", enabled = a.fileBookmarks.len > 0, action = proc () =
    let i = a.nearestBookmark(a.player.timePos)
    if i >= 0: a.removeBookmark(a.fileBookmarks[i].time))
  let marks = a.fileBookmarks
  if marks.len > 0:
    bm.sep()
    for i, b in marks:
      bm.item(fmtTime(b.time) & "  " & b.label(i), action = bindAct(proc (t: float) = a.seekTo(t), b.time))
  nav.sep()
  nav.item(&"Jump Forward {a.cfg.seekStep:g}s", "Right", enabled = loaded,
    action = proc () = a.seekRelative(a.cfg.seekStep))
  nav.item(&"Jump Back {a.cfg.seekStep:g}s", "Left", enabled = loaded,
    action = proc () = a.seekRelative(-a.cfg.seekStep))
  nav.item("Go To Beginning", "Home", enabled = loaded, action = proc () = a.seekTo(0))
  nav.sep()
  let hasCh = p.chapters.len > 0
  let canStep = hasCh or (a.cfg.bookmarksAsChapters and a.fileBookmarks.len > 0)
  let chm = nav.sub("Chapters", enabled = hasCh)
  for i, c in p.chapters:
    let label = fmtTime(c.time) & "  " & (if c.title.len > 0: c.title else: &"Chapter {i + 1}")
    chm.item(label, action = bindAct(proc (t: float) = a.seekTo(t), c.time))
  nav.item("Next Chapter", "Ctrl+Right", enabled = canStep, action = proc () = a.chapterStep(1))
  nav.item("Previous Chapter", "Ctrl+Left", enabled = canStep, action = proc () = a.chapterStep(-1))
  nav.sep()
  nav.item("Next File", "Page Down", enabled = loaded and not locked, action = proc () = a.navigate(1))
  nav.item("Previous File", "Page Up", enabled = loaded and not locked, action = proc () = a.navigate(-1))

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

  # Run: the Command-line Manager and the command lines it saved.
  let run = root.sub("Run")
  run.item("Command-line Manager...", action = proc () = a.showCommands())
  run.sep()
  if a.commands.len == 0:
    run.item("No command lines", enabled = false)
  let runOne = proc (c: CommandLine) = a.runCommandLine(c)
  for c in a.commands:
    run.item(c.title, action = bindAct(runOne, c))

  # Help
  let help = root.sub("Help")
  help.item("Keyboard Shortcuts", "F1", action = proc () = a.showOverlay(ovShortcuts))
  help.item("About " & AppName, action = proc () = a.showOverlay(ovAbout))

  # Right-click menu, built from the bar's nodes.
  let ctx = newMenuRoot()
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
    # Adds at the time clicked; removes or renames the bookmark clicked on.
    let sb = newMenuRoot()
    let i = a.ctxBookmark
    let on = i >= 0 and i < a.fileBookmarks.len
    let (t, bt) = (a.ctxSeekT, if on: a.fileBookmarks[i].time else: 0.0)
    sb.item("Add Bookmark", enabled = loaded and not on, action = proc () = a.addBookmark(t))
    sb.item("Remove Bookmark", enabled = on, action = proc () = a.removeBookmark(bt))
    sb.sep()
    sb.item("Rename Bookmark...", enabled = on, action = proc () = a.showRename(i))
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
    pl.item("Add Media File...", enabled = edit, action = proc () =
      a.ask(dkOpenFiles, "pladd", "Add Media File", exts = @MediaExtensions,
        filterName = "Media files"))
    pl.item("Remove Media File", "Delete", enabled = hasSel and edit, action = proc () =
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
  a.subs.scale = clamp(a.subs.scale + dir * SubScaleStep, 0.2'f32, 5'f32)
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

proc applySubLayout(a: App, video: Vec2, pad: tuple[l, r, t, b: float32]) =
  ## Pushes the placement for a video drawn `video` pixels big. The anchored
  ## cases use mpv's own margins, in scaled pixels: 720 of them span the
  ## height, and text subtitles' 384x288 canvas makes 960 span the width.
  let s = a.subs
  let full = video + vec2(pad.l + pad.r, pad.t + pad.b)
  let (kx, ky) = (full.x / 960, full.y / 720)
  let marginX =
    case s.alignX
    of 0: max(0, int(round(SubMarginX + s.offset.x / kx)))
    of 2: max(0, int(round(SubMarginX - s.offset.x / kx)))
    else: SubMarginX
  let marginY = if s.alignY == 0: max(0, int(round(SubMarginY + s.offset.y / ky))) else: SubMarginY
  let pos = if s.alignY == 2: clamp(100 + s.offset.y / video.y * 100, 0'f32, 150'f32) else: 100'f32
  # Subtitles scale with the target height; keep padding from growing them.
  let scale = s.scale * video.y / full.y
  let key = &"{s.alignX}|{s.alignY}|{marginX}|{marginY}|{pos:.3f}|{scale:.4f}|" &
    &"{pad.l / full.x:.5f}|{pad.r / full.x:.5f}|{pad.t / full.y:.5f}|{pad.b / full.y:.5f}"
  if key == a.subsKey: return
  a.subsKey = key
  let h = a.player.h
  h.setProp("sub-align-x", ["left", "center", "right"][s.alignX])
  h.setProp("sub-align-y", ["top", "center", "bottom"][s.alignY])
  h.setProp("sub-margin-x", $marginX)
  h.setProp("sub-margin-y", $marginY)
  h.setProp("sub-pos", pos)
  h.setProp("sub-scale", scale)
  h.setProp("video-margin-ratio-left", pad.l / full.x)
  h.setProp("video-margin-ratio-right", pad.r / full.x)
  h.setProp("video-margin-ratio-top", pad.t / full.y)
  h.setProp("video-margin-ratio-bottom", pad.b / full.y)

proc digitPressed(pressed: ButtonView): int =
  ## Top-row digit pressed this frame (0-9), or -1.
  const keys = [Key0, Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, Key9]
  for i, k in keys:
    if pressed[k]: return i
  -1

proc handleKeys(a: App) =
  let w = a.window
  let pressed = w.buttonPressed
  let (c, s, al) = (w.ctrl, w.shift, w.alt)
  let none = not c and not s and not al

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

  # Alt+Enter must be checked before anything grabs Enter.
  if al and (pressed[KeyEnter] or pressed[NumpadEnter]):
    a.setFullscreen(not a.fullscreen)
    return

  if c and s and pressed[KeyO]:
    if a.player.loaded:
      a.ask(dkOpenFile, "subtitle", "Load Subtitle", exts = @SubtitleExtensions,
        filterName = "Subtitles")
  elif c and pressed[KeyO]: a.openFileDialog()
  elif c and pressed[KeyX]: a.closeFile()
  elif c and pressed[KeyC]: a.copyToClipboard()
  elif c and pressed[KeyV]: a.openFromClipboard()
  elif al and pressed[KeyI]: a.screenshot()
  elif al and pressed[KeyX]: w.closeRequested = true
  elif none and pressed[KeyO]: a.showOverlay(ovOptions)
  elif none and pressed[KeyF1]: a.showOverlay(ovShortcuts)
  elif none and pressed[KeySpace]: a.playPause()
  elif c and pressed[KeyM]: a.setMute(not a.player.muted)
  elif none and pressed[KeyUp]: a.volumeStep(true)
  elif none and pressed[KeyDown]: a.volumeStep(false)
  elif none and pressed[KeyLeft]: a.seekRelative(-a.cfg.seekStep)
  elif none and pressed[KeyRight]: a.seekRelative(a.cfg.seekStep)
  elif c and pressed[KeyLeft]: a.chapterStep(-1)
  elif c and pressed[KeyRight]: a.chapterStep(1)
  elif none and pressed[KeyHome]: a.seekTo(0)
  elif none and pressed[KeyPageUp]: a.navigate(-1)
  elif none and pressed[KeyPageDown]: a.navigate(1)
  elif s and pressed[KeyPeriod]: a.changeRate(1)
  elif s and pressed[KeyComma]: a.changeRate(-1)
  elif none and pressed[KeyPeriod]: a.frameStep(true)
  elif none and pressed[KeyComma]: a.frameStep(false)
  elif pressed[KeyA] and not c and not al: a.cycleTrack("aid", not s)
  elif pressed[KeyS] and not c and not al: a.cycleTrack("sid", not s)
  elif none and a.player.loaded and (let k = digitPressed(pressed); k >= 0):
    a.player.stopped = false
    a.player.h.commandAsync("seek", $(k * 10), "absolute-percent")
    a.syncSend("seek", $(a.player.duration * k.float / 10), "true")
  elif none and pressed[KeyInsert]: a.addBookmark(a.player.timePos)
  elif none and pressed[KeyDelete] and a.cfg.showPlaylist:
    a.removeSelected()

  # View toggles and Grab/Rotate/Scale go through the menu actions so the
  # window-resizing side effects live in one place.
  var menuPath: seq[string]
  if c and not s and not al:
    if pressed[Key1]: menuPath = @["View", "Seek Bar"]
    elif pressed[Key2]: menuPath = @["View", "Controls"]
    elif pressed[Key3]: menuPath = @["View", "Status"]
    elif pressed[Key4]: menuPath = @["View", "Playlist"]
    elif pressed[Key5]: menuPath = @["View", "Run Log"]
  let g = "Grab, Rotate & Scale"
  if none:
    if pressed[Numpad5]: menuPath = @["View", g, "Center"]
    elif pressed[Numpad8]: menuPath = @["View", g, "Move Up"]
    elif pressed[Numpad2]: menuPath = @["View", g, "Move Down"]
    elif pressed[Numpad4]: menuPath = @["View", g, "Move Left"]
    elif pressed[Numpad6]: menuPath = @["View", g, "Move Right"]
  elif al and not c:
    if pressed[Numpad5]: menuPath = @["View", g, "0 Degrees"]
    elif pressed[Numpad6]: menuPath = @["View", g, "Rotate Clockwise"]
    elif pressed[Numpad4]: menuPath = @["View", g, "Rotate Counter-clockwise"]
  elif c and not al:
    if pressed[Numpad5]: menuPath = @["View", g, "Restore Size"]
    elif pressed[Numpad9]: menuPath = @["View", g, "Increase Size"]
    elif pressed[Numpad3]: menuPath = @["View", g, "Decrease Size"]
    elif pressed[Numpad6]: menuPath = @["View", g, "Increase Width"]
    elif pressed[Numpad4]: menuPath = @["View", g, "Decrease Width"]
    elif pressed[Numpad8]: menuPath = @["View", g, "Increase Height"]
    elif pressed[Numpad2]: menuPath = @["View", g, "Decrease Height"]
  if menuPath.len > 0: a.runMenuPath(menuPath)

  # Shift: subtitle alignment (numpad as a 3x3 grid), nudging and size.
  if s and not c and not al:
    const grid = [Numpad7, Numpad8, Numpad9, Numpad4, Numpad5, Numpad6, Numpad1, Numpad2, Numpad3]
    for i, k in grid:
      if pressed[k]: a.alignSubs(i mod 3, i div 3)
    if pressed[KeyUp]: a.moveSubs(vec2(0, -SubMoveStep))
    elif pressed[KeyDown]: a.moveSubs(vec2(0, SubMoveStep))
    elif pressed[KeyLeft]: a.moveSubs(vec2(-SubMoveStep, 0))
    elif pressed[KeyRight]: a.moveSubs(vec2(SubMoveStep, 0))
    if pressed[NumpadAdd]: a.scaleSubs(1)
    elif pressed[NumpadSubtract]: a.scaleSubs(-1)

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
  let (center, size) = a.videoGeometry(area)
  if size.x < 1 or size.y < 1: return
  # The target is padded around the video to move centered subtitles.
  let pad = a.subPadding()
  let full = size + vec2(pad.l + pad.r, pad.t + pad.b)
  a.applySubLayout(size, pad)
  # Render at the on-screen size (mpv does the high-quality scaling); cap the
  # texture so extreme zoom doesn't allocate huge buffers.
  let cap = min(1'f32, 4096 / max(full.x, full.y))
  let tw = max(1, int(round(full.x * cap)))
  let th = max(1, int(round(full.y * cap)))
  let resized = tw != a.player.target.w or th != a.player.target.h
  a.player.target.ensureSize(tw, th)
  if resized or (flags and MpvRenderUpdateFrame) != 0:
    a.player.render.render(a.player.target)
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  # Shift the padded quad so the video part stays where the video belongs.
  let sh = vec2((pad.r - pad.l) / 2, (pad.b - pad.t) / 2)
  let rad = a.xf.rotation * PI.float32 / 180
  let shift = vec2(sh.x * cos(rad) - sh.y * sin(rad), sh.x * sin(rad) + sh.y * cos(rad))
  a.quad.draw(a.player.target.tex, transformedCorners(center + shift, full, a.xf.rotation), fb.vec2)
  glDisable(GL_SCISSOR_TEST)

proc drawPreview(a: App, fb: IVec2) =
  if a.preview == nil: return
  if a.previewFlag:
    a.previewFlag = false
    let flags = mpv_render_context_update(a.preview.render)
    if (flags and MpvRenderUpdateFrame) != 0 and a.preview.target.fbo != 0:
      a.preview.render.render(a.preview.target)
  if a.showPreview and a.preview.hasFrame:
    a.quad.draw(a.preview.target.tex, rectCorners(a.previewQuad.xy, a.previewQuad.wh), fb.vec2)

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
      a.preview.target.ensureSize(int(pw), int(imgH))
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
  ## Shortcuts reachable with the modifiers currently held, in groups.
  let w = a.window
  var (c, s, al) = (w.ctrl, w.shift, w.alt)
  if a.fakeMods.len > 0:
    (c, s, al) = ("ctrl" in a.fakeMods, "shift" in a.fakeMods, "alt" in a.fakeMods)
  let rot = &"{a.cfg.rotateStep:g}°"
  # View toggles and grab/rotate/scale only show with "Show all shortcuts".
  let all = a.cfg.showAllShortcuts
  if c and s and not al:
    result = @[@[("O", "Load Subtitle")]]
  elif c and not s and not al:
    result = @[@[("←", "Previous Chapter"), ("→", "Next Chapter")],
      @[("M", "Mute")],
      @[("O", "Open File"), ("V", "Open From Clipboard"), ("C", "Copy to Clipboard"),
        ("X", "Close")]]
    if all:
      result.add @[@[("1", "Seek Bar"), ("2", "Controls"), ("3", "Status"), ("4", "Playlist"),
        ("5", "Run Log")],
        @[("Num5", "Reset Size"), ("Num9", "+Size"), ("Num3", "-Size"),
          ("Num6", "+Width"), ("Num4", "-Width"), ("Num8", "+Height"), ("Num2", "-Height")]]
  elif al and not c and not s:
    result = @[@[("Enter", "Fullscreen")], @[("I", "Screenshot")]]
    if all:
      result.add @[("Num4", "Rotate " & rot & " CCW"), ("Num5", "Reset Rotation"),
        ("Num6", "Rotate " & rot & " CW")]
    result.add @[("X", "Exit")]
  elif s and not c and not al:
    result = @[@[(",", "Slower Playback"), (".", "Faster Playback")],
      @[("A", "Previous Audio Track"), ("S", "Previous Subtitle Track")],
      @[("Num1-9", "Align Subtitles"), ("Arrows", "Move Subtitles"),
        ("Num+", "Bigger Subtitles"), ("Num-", "Smaller Subtitles")],
      @[("Drag", if a.cfg.snapWithShift: "Seek Snapping To Markers" else: "Seek Without Snapping")]]

proc keyHintBar(a: App, r: Rect, groups: seq[seq[KeyHint]]) =
  ## Blender-style row of [key] label pairs; groups split by a divider.
  ## Groups that don't fit wrap onto more rows, which grow the bar upward
  ## over the controls so the layout beneath doesn't move.
  let ui = a.ui
  let capH = r.h - 8
  proc capW(key: string): float32 = max(capH, ui.textSize(key, FontSmall).x + 10)
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
  ui.textIn(&"Playlist ({a.playlist.len})", rect(r.x + 32, header.y, r.w - 40, 30), colText)
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
    rect(r.x + 32, header.y, r.w - 120, header.h), colText)
  # Header buttons, right to left: Clear (finished runs), Stop (running ones).
  var bx = r.x + r.w - 10
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

proc readFramebuffer(size: IVec2): Image =
  result = newImage(size.x, size.y)
  glReadPixels(0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()

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
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  # A text field being edited takes Escape itself.
  let esc = w.buttonPressed[KeyEscape] and ui.focusId.len == 0
  w.beginDrawOn()
  ui.beginFrame()
  a.optSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let action = a.optionsDlg.draw(ui, a.cfg, rect(vec2(0, 0), size.vec2))
  ui.drawTooltip()
  a.optSk.endUi()
  ui.endFrame()
  if shot.len > 0: readFramebuffer(size).writeFile(shot.changeFileExt("") & "-options.png")
  w.endDrawOn(a.window)
  case action
  of oaOk: a.closeOptions(true)
  of oaCancel: a.closeOptions(false)
  of oaNone:
    if esc: a.closeOptions(false)
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
  w.beginDrawOn()
  ui.beginFrame()
  a.renSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let W = size.x.float32
  ui.textIn("Name", rect(16, 10, W - 32, 22), colTextDim, FontSmall)
  discard ui.textField("ren-name", rect(16, 34, W - 32, 28), a.renText, a.renPlaceholder)
  let ok = ui.textButton("ren-ok", rect(W - 116, 74, 100, 28), "Rename", primary = true)
  ui.drawTooltip()
  a.renSk.endUi()
  ui.endFrame()
  if shot.len > 0: readFramebuffer(size).writeFile(shot.changeFileExt("") & "-rename.png")
  w.endDrawOn(a.window)
  if ok or enter:
    a.renameBookmark(a.renPath, a.renTime, a.renText.strip)
    a.closeRename()
  elif esc:
    a.closeRename()

proc renderCommands(a: App, shot: string) =
  ## Draws the Command-line Manager window and carries out its buttons.
  if a.overlay != ovCommands: return
  let w = a.cmdWin
  let ui = a.cmdUi
  if w.closeRequested:
    w.closeRequested = false
    a.closeCommands()
    return
  let size = w.size
  if size.x <= 0 or size.y <= 0: return
  w.beginDrawOn()
  ui.beginFrame()
  a.cmdSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let path = if a.player.loaded: a.player.path else: ""
  let action = a.cmdDlg.draw(ui, rect(vec2(0, 0), size.vec2), path)
  ui.drawTooltip()
  a.cmdSk.endUi()
  ui.endFrame()
  if shot.len > 0: readFramebuffer(size).writeFile(shot.changeFileExt("") & "-commands.png")
  w.endDrawOn(a.window)
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
    a.closeCommands()
  of caDelete:
    let orig = d.origTitle
    a.editCommandLines(proc (cmds: var seq[CommandLine]) =
      cmds.keepItIf(it.title != orig))
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
  w.beginDrawOn()
  ui.beginFrame()
  a.pickSk.beginUi(w, size)
  glViewport(0, 0, size.x, size.y)
  glClearColor(colPanel.r.float32 / 255, colPanel.g.float32 / 255,
    colPanel.b.float32 / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT)
  let action = a.pickDlg.draw(ui, rect(vec2(0, 0), size.vec2), marks)
  ui.drawTooltip()
  a.pickSk.endUi()
  ui.endFrame()
  if shot.len > 0: readFramebuffer(size).writeFile(shot.changeFileExt("") & "-pick.png")
  w.endDrawOn(a.window)
  case action
  of paNone: discard
  of paCancel: a.closePick()
  of paRun:
    let d = a.pickDlg
    var picks = initTable[string, string]()
    for i, row in d.rows:
      if row.kind == ckValue: picks[row.name] = d.texts[i]
      elif d.picks[i] >= 0 and d.picks[i] < marks.len:
        picks[row.name] = fmtTime(marks[d.picks[i]].time, millis = true)
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

const shortcutColumns: array[2, seq[ShortcutGroup]] = [
  @[
    ("File", @[
      ("Open file", "Ctrl+O"), ("Load subtitle file", "Ctrl+Shift+O"),
      ("Open from clipboard", "Ctrl+V"), ("Copy to clipboard", "Ctrl+C"), ("Close", "Ctrl+X"),
      ("Save screenshot", "Alt+I"), ("Exit", "Alt+X")]),
    ("Playback", @[
      ("Play / Pause", "Space"), ("Frame forward / back", ". / ,"),
      ("Faster / slower playback", "Shift+. / Shift+,"),
      ("Volume up / down", "Up / Down"), ("Mute", "Ctrl+M"),
      ("Next / previous audio track", "A / Shift+A"),
      ("Next / previous subtitle track", "S / Shift+S")]),
    ("Navigate", @[
      ("Jump forward / back", "Right / Left"), ("Go to beginning", "Home"),
      ("Jump to 0% ... 90%", "0 ... 9"), ("Next / previous chapter", "Ctrl+Right / Ctrl+Left"),
      ("Next / previous file", "Page Down / Page Up"), ("Add bookmark", "Insert"),
      ("Remove selected playlist item", "Delete")]),
    ("Subtitles", @[
      ("Align (numpad as a 3x3 grid)", "Shift+Numpad 1 ... 9"),
      ("Move", "Shift+Arrows"), ("Bigger / smaller", "Shift+Numpad + / -")])],
  @[
    ("View", @[
      ("Seek bar", "Ctrl+1"), ("Controls", "Ctrl+2"), ("Status", "Ctrl+3"),
      ("Playlist", "Ctrl+4"), ("Run log", "Ctrl+5"), ("Full screen", "Alt+Enter"),
      ("Leave full screen / close dialog", "Esc"), ("Options", "O"),
      ("Keyboard shortcuts", "F1")]),
    ("Grab, Rotate & Scale", @[
      ("Center", "Numpad 5"), ("Move up / down", "Numpad 8 / 2"),
      ("Move left / right", "Numpad 4 / 6"), ("0 degrees", "Alt+Numpad 5"),
      ("Rotate clockwise / counter-clockwise", "Alt+Numpad 6 / 4"),
      ("Restore size", "Ctrl+Numpad 5"), ("Increase / decrease size", "Ctrl+Numpad 9 / 3"),
      ("Increase / decrease width", "Ctrl+Numpad 6 / 4"),
      ("Increase / decrease height", "Ctrl+Numpad 8 / 2")]),
    ("Mouse", @[
      ("Play / Pause", "Click video"), ("Full screen", "Double-click video"),
      ("Move window", "Drag video"), ("Context menu", "Right-click"),
      ("Volume", "Wheel"), ("Toggle seek snapping", "Shift+Drag seek bar")])]]

proc shortcutsOverlay(a: App) =
  let ui = a.ui
  const
    RowH = 21'f32
    HeadH = 32'f32
    ColW = 420'f32
    ColGap = 32'f32
    Pad = 24'f32
  var colH = 0'f32
  for col in shortcutColumns:
    var h = 0'f32
    for g in col: h += HeadH + g.rows.len.float32 * RowH
    colH = max(colH, h)
  let r = a.overlayFrame("Keyboard Shortcuts",
    vec2(Pad * 2 + ColW * 2 + ColGap, 60 + colH + Pad - 8))
  for ci, col in shortcutColumns:
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

  ui.beginFrame()
  let (root, ctxRoot) = a.buildMenu()

  # Layout
  let fs = a.fullscreen
  let bottomH = a.bottomHeight
  let menuH = if fs: 0'f32 else: MenuBarHeight
  let W = fb.x.float32
  let H = fb.y.float32
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
  a.drawVideo(videoArea, fb)
  a.idleScreen(videoArea)

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
      a.volumeStep(ui.scroll() < 0)
      ui.scrollConsumed = true
  if a.videoPress:
    if not ui.down():
      a.videoPress = false
      if ui.window.buttonReleased[MouseLeft]:
        a.togglePlay()
    elif (ui.mouse - a.videoPressPos).length > 4:
      a.videoPress = false
      if not fs: w.startWindowDrag()

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
    proc (level: int, size: IVec2) =
      readFramebuffer(size).writeFile(shot.changeFileExt("") & &"-menu{level}.png"))
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
  of "fs": a.setFullscreen(arg == "1")
  of "subs":  # alignX alignY dx dy scale
    a.subs = SubLayout(alignX: parseInt(st.args[0]), alignY: parseInt(st.args[1]),
      offset: vec2(parseFloat(st.args[2]), parseFloat(st.args[3])), scale: parseFloat(st.args[4]))
  of "seek": a.seekTo(parseFloat(arg))
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
  of "set": a.player.h.setProp(st.args[0], st.args[1 .. ^1].join(" "))
  of "dump":
    for prop in st.args:
      stderr.writeLine "dump ", prop, " = ", a.player.h.getStr(prop)
  else: stderr.writeLine "script: unknown command ", st.cmd

proc glyphSet(): seq[string] =
  result = AsciiGlyphs
  for cp in 0xA0 .. 0x17F: result.add $Rune(cp)
  for s in ["…", "–", "—", "•", "‘", "’", "“", "”", "→", "←", "×", "°", "·", "▸"]:
    result.add s

proc buildAtlas(): (Image, SilkyAtlas) =
  let fontPath = getTempDir() / "majestic-media-player-font.ttf"
  if not fileExists(fontPath) or getFileSize(fontPath) != FontData.len:
    writeFile(fontPath, FontData)
  let b = newAtlasBuilder(2048, 2)
  let glyphs = glyphSet()
  b.addFont(fontPath, FontMain, 15, glyphs)
  b.addFont(fontPath, FontSmall, 13, glyphs)
  b.addFont(fontPath, FontTitle, 20, glyphs)
  b.addIcons()
  discard b.addImage("crown96", renderIcon(crownPath, 24, 96))
  discard b.addImage("music96", renderIcon(musicPath, 24, 96))
  discard b.addImage("knob16", renderIcon("M12 4a8 8 0 1 0 0.001 0z", 24, 16))
  (b.atlasImage, b.atlas)

proc main() =
  discard setlocale(LC_NUMERIC, "C")
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
  a.bookmarks = loadBookmarks()
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
  makeContextCurrent(a.window)
  loadExtensions()
  a.window.disableVsync()
  a.window.setAspectHints(0, ivec2(0, 0), MinWindow)
  if c.rememberWindowPos and c.windowW > 0:
    # Only onto a monitor that still exists.
    let p = ivec2(c.windowX.int32, c.windowY.int32)
    let m = monitorAt(p + ivec2(40, 40))
    if p.x + 40 >= m.pos.x and p.y + 40 >= m.pos.y and
       p.x + 40 < m.pos.x + m.size.x and p.y + 40 < m.pos.y + m.size.y:
      a.window.moveFrame(p)

  let (img, atlas) = buildAtlas()
  (a.atlasImg, a.atlas) = (img, atlas)
  a.sk = newSilky(a.window, img, atlas)
  a.ui = newUi(a.sk, a.window)
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
    if a.dropped.len == 0: a.dropAt = a.window.mousePos.vec2
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
    a.preview.pollEvents()
    a.pollDialog()
    a.pollJobs()
    for st in a.script.due: a.runScriptStep(st)
    if a.script.next < a.script.steps.len: a.dirtyUntil = now() + 0.5

    if a.player.justLoaded:
      a.player.justLoaded = false
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
