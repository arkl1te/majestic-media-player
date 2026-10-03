## Majestic Media Player — an mpv-based video player with a Silky UI.

import std/[os, strutils, strformat, times, math, osproc, unicode, sequtils]
import silky, vmath, bumpy, chroma, pixie, opengl
import mpv, videogl, xwin, config, dialogs, theme, ui, menutree, player, icons, debugscript

const
  AppName = "Majestic Media Player"
  AppVersion = "0.1.0"
  FontData = staticRead("../assets/fonts/IBMPlexSans-Regular.ttf")
  MinWindow = ivec2(480, 270)

type
  Overlay = enum
    ovNone, ovOptions, ovProperties, ovShortcuts, ovAbout

  VideoTransform = object
    pan: Vec2
    rotation: float32
    zoom: float32 = 1
    scaleX: float32 = 1
    scaleY: float32 = 1

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
    xf: VideoTransform
    afterPlayback: AfterPlayback
    overlay: Overlay
    props: seq[(string, string)]
    dialog: Dialog
    children: seq[Process]
    fullscreen: bool
    # mouse interaction with the video frame
    videoPress: bool
    videoPressPos: Vec2
    lastMouse: Vec2
    lastMouseMove: float
    cursorHidden: bool
    # seek bar
    seekDragging: bool
    seekDragT: float
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
    inputPending: bool        ## button/key/scroll this iteration; Windy clears
                              ## those per pollEvents, so draw before the next
    videoRect: Rect
    script: Script
    shotPath: string

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

proc chromeSize(a: App): IVec2 =
  ## Window space not used by the video frame (windowed mode).
  ivec2(int32(if a.cfg.showPlaylist: PlaylistWidth else: 0),
        int32(MenuBarHeight + a.bottomHeight))

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
  let t =
    if a.player.path.len > 0: a.player.path.fileTitle & " - " & AppName
    else: AppName
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

# --- playback actions -------------------------------------------------------

proc applyLoop(a: App) =
  a.player.h.setProp("loop-file",
    if a.cfg.repeatForever and a.cfg.repeatMode == rmFile: "inf" else: "no")

proc playIndex(a: App, i: int) =
  if i < 0 or i >= a.playlist.len: return
  a.plIndex = i
  a.plSelected = i
  let path = a.playlist[i]
  a.xf = VideoTransform()
  a.player.load(path)
  a.applyLoop()
  a.cfg.addRecent(path)
  a.cfg.lastDir = path.parentDir
  a.updateTitle()

proc openPaths(a: App, paths: seq[string]) =
  var files: seq[string]
  for p in paths:
    if dirExists(p): files.add mediaFilesIn(p, isMediaFile)
    elif fileExists(p) or p.contains("://"): files.add p
  if files.len == 0:
    a.osd("Nothing playable found")
    return
  a.playlist = files
  a.plScroll = 0
  a.playIndex(0)

proc closeFile(a: App) =
  a.player.close()
  a.preview.forget()
  a.playlist.setLen 0
  a.plIndex = -1
  a.plSelected = -1
  a.updateTitle()

proc reopenLast(a: App): bool =
  ## With nothing loaded, Play reopens the most recently opened file.
  if a.player.loaded: return false
  for r in a.cfg.recentFiles:
    if fileExists(r) or r.contains("://"):
      a.openPaths(@[r])
      return true

proc playPause(a: App) =
  if not a.reopenLast(): a.player.togglePause()

proc folderNeighbor(a: App, dir: int): string =
  if a.player.path.len == 0 or not fileExists(a.player.path): return
  let files = mediaFilesIn(a.player.path.parentDir, isMediaFile)
  let i = files.find(a.player.path.absolutePath)
  let j = (if i < 0: files.find(a.player.path) else: i) + dir
  if j >= 0 and j < files.len: files[j] else: ""

proc navigate(a: App, dir: int) =
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

proc handleEof(a: App) =
  let p = a.player
  if not (p.loaded and p.eofReached and not p.eofHandled and not p.stopped): return
  p.eofHandled = true
  if a.cfg.repeatForever and a.cfg.repeatMode == rmPlaylist and a.playlist.len > 0:
    a.playIndex((a.plIndex + 1) mod a.playlist.len)
  elif a.plIndex + 1 < a.playlist.len:
    a.playIndex(a.plIndex + 1)
  else:
    a.runAfterPlayback()

proc volumeStep(a: App, up: bool) =
  ## Soft cap 100, hard cap 200: +5 below the soft cap, +2 above it, -5 down.
  let v = a.player.volume
  let nv =
    if up: (if v < 100: min(v + 5, 100) else: min(v + 2, 200))
    else: max(v - 5, 0)
  a.player.setVolume(nv)
  a.osd(&"Volume: {int(round(nv))}%")

proc setMute(a: App, on: bool) =
  a.player.h.setProp("mute", on)
  a.osd(if on: "Mute" else: "Unmute")

proc changeRate(a: App, dir: float) =
  if not a.player.loaded: return
  let s = clamp(a.player.speed + dir * a.cfg.rateStep, 0.25, 4.0)
  a.player.h.setProp("speed", s)
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

proc seekRelative(a: App, d: float) =
  if a.player.loaded:
    a.player.stopped = false
    a.player.h.commandAsync("seek", $d, "relative")

proc chapterStep(a: App, d: int) =
  if a.player.loaded and a.player.chapters.len > 0:
    a.player.h.commandStr("osd-msg add chapter " & $d)

proc xfChanged(a: App, msg: string) =
  a.osd(msg)

# --- dialogs ----------------------------------------------------------------

proc startDir(a: App): string =
  if a.player.path.len > 0 and fileExists(a.player.path): a.player.path.parentDir
  elif a.cfg.lastDir.len > 0 and dirExists(a.cfg.lastDir): a.cfg.lastDir
  else: getHomeDir()

proc ask(a: App, kind: DialogKind, purpose, title: string, start = "",
         exts: seq[string] = @[], filterName = "") =
  if a.dialog != nil: return
  a.menus.close()
  a.dialog = startDialog(kind, purpose, title,
    if start.len > 0: start else: a.startDir, exts, filterName)

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

proc handleDialogResult(a: App, purpose: string, paths: seq[string]) =
  if paths.len == 0: return
  case purpose
  of "open": a.openPaths(paths)
  of "opendir": a.openPaths(paths[0 .. 0])
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
  let h = a.player.h
  var p: seq[(string, string)]
  template add(k, v: string) =
    if v.len > 0: p.add (k, v)
  add "File", a.player.path.extractFilename
  add "Location", a.player.path.parentDir
  let size = h.getInt("file-size", -1)
  if size >= 0: add "Size", formatSize(size, includeSpace = true)
  add "Container", h.getStr("file-format")
  if a.player.duration > 0: add "Duration", fmtTime(a.player.duration)
  add "Title", h.getStr("media-title")
  if a.player.hasVideo:
    add "Video codec", h.getStr("video-format")
    add "Resolution", &"{h.getInt(\"width\")} x {h.getInt(\"height\")}"
    add "Display size", &"{a.player.videoW} x {a.player.videoH}"
    let fps = h.getFloat("container-fps")
    if fps > 0: add "Frame rate", &"{fps:.3f} fps"
    add "Hardware decoding", h.getStr("hwdec-current")
  add "Audio codec", h.getStr("audio-codec-name")
  let sr = h.getInt("audio-params/samplerate")
  if sr > 0: add "Sample rate", &"{sr} Hz"
  if a.player.audioChannels > 0: add "Channels", $a.player.audioChannels
  var counts: array[3, int]
  for t in a.player.tracks:
    case t.kind
    of "video": inc counts[0]
    of "audio": inc counts[1]
    of "sub": inc counts[2]
  add "Tracks", &"{counts[0]} video, {counts[1]} audio, {counts[2]} subtitle"
  if a.player.chapters.len > 0: add "Chapters", $a.player.chapters.len
  a.props = p

proc showOverlay(a: App, o: Overlay) =
  a.menus.close()
  if o == ovProperties:
    if not a.player.loaded: return
    a.gatherProperties()
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
  let file = root.sub("File")
  file.item("Open File...", "Ctrl+O", action = proc () = a.openFileDialog())
  let recent = file.sub("Open Recent", enabled = a.cfg.recentFiles.len > 0)
  let openOne = proc (path: string) = a.openPaths(@[path])
  for r in a.cfg.recentFiles:
    recent.item(r.extractFilename, action = bindAct(openOne, r))
  if a.cfg.recentFiles.len > 0:
    recent.sep()
    recent.item("Clear List", action = proc () = a.cfg.recentFiles.setLen 0)
  file.item("Open Directory...", action = proc () =
    a.ask(dkOpenDir, "opendir", "Open Directory"))
  file.item("Close", "Ctrl+C", enabled = loaded, action = proc () = a.closeFile())
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
    a.resizeKeepingVideo(ivec2(int32(if a.cfg.showPlaylist: PlaylistWidth else: -PlaylistWidth), 0)))
  view.sep()
  view.check("Show OSD", "", cfg.showOsd, action = proc () =
    a.cfg.showOsd = not a.cfg.showOsd
    a.player.h.setProp("osd-level", if a.cfg.showOsd: "1" else: "0"))
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
  play.item("Stop", "", enabled = loaded, action = proc () = a.player.stop())
  let (playPause, stop) = (play.children[0], play.children[1])
  play.item("Frame Forward", ".", enabled = loaded, action = proc () = a.frameStep(true))
  play.item("Frame Back", ",", enabled = loaded, action = proc () = a.frameStep(false))
  play.item(&"Increase Rate (+{a.cfg.rateStep:g}x)", "Shift+.", enabled = loaded,
    action = proc () = a.changeRate(1))
  play.item(&"Decrease Rate (-{a.cfg.rateStep:g}x)", "Shift+,", enabled = loaded,
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
  nav.item("Previous File", "Page Up", enabled = loaded, action = proc () = a.navigate(-1))
  nav.item("Next File", "Page Down", enabled = loaded, action = proc () = a.navigate(1))
  nav.sep()
  nav.item(&"Jump Back {a.cfg.seekStep:g}s", "Left", enabled = loaded,
    action = proc () = a.seekRelative(-a.cfg.seekStep))
  nav.item(&"Jump Forward {a.cfg.seekStep:g}s", "Right", enabled = loaded,
    action = proc () = a.seekRelative(a.cfg.seekStep))
  nav.item("Go To Beginning", "Home", enabled = loaded, action = proc () = a.player.seek(0))
  nav.sep()
  let hasCh = p.chapters.len > 0
  nav.item("Previous Chapter", "Ctrl+Left", enabled = hasCh, action = proc () = a.chapterStep(-1))
  nav.item("Next Chapter", "Ctrl+Right", enabled = hasCh, action = proc () = a.chapterStep(1))
  let chm = nav.sub("Chapters", enabled = hasCh)
  for i, c in p.chapters:
    let label = fmtTime(c.time) & "  " & (if c.title.len > 0: c.title else: &"Chapter {i + 1}")
    chm.item(label, action = bindAct(proc (t: float) = a.player.seek(t), c.time))

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
  (root, ctx)

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
    if a.overlay != ovNone: a.overlay = ovNone
    elif a.menus.isOpen: a.menus.close()
    elif a.fullscreen: a.setFullscreen(false)
    return
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
  elif c and pressed[KeyC]: a.closeFile()
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
  elif none and pressed[KeyHome]: a.player.seek(0)
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
  elif none and pressed[KeyDelete] and a.cfg.showPlaylist and
       a.plSelected >= 0 and a.plSelected < a.playlist.len:
    a.playlist.delete(a.plSelected)
    if a.plIndex == a.plSelected: a.plIndex = -1
    elif a.plIndex > a.plSelected: dec a.plIndex
    a.plSelected = min(a.plSelected, a.playlist.len - 1)

  # View toggles and Grab/Rotate/Scale go through the menu actions so the
  # window-resizing side effects live in one place.
  var menuPath: seq[string]
  if c and not s and not al:
    if pressed[Key1]: menuPath = @["View", "Seek Bar"]
    elif pressed[Key2]: menuPath = @["View", "Controls"]
    elif pressed[Key3]: menuPath = @["View", "Status"]
    elif pressed[Key4]: menuPath = @["View", "Playlist"]
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
  # Render at the on-screen size (mpv does the high-quality scaling); cap the
  # texture so extreme zoom doesn't allocate huge buffers.
  let cap = min(1'f32, 4096 / max(size.x, size.y))
  let tw = max(1, int(round(size.x * cap)))
  let th = max(1, int(round(size.y * cap)))
  let resized = tw != a.player.target.w or th != a.player.target.h
  a.player.target.ensureSize(tw, th)
  if resized or (flags and MpvRenderUpdateFrame) != 0:
    a.player.render.render(a.player.target)
  glEnable(GL_SCISSOR_TEST)
  glScissor(GLint(area.x), GLint(fb.y.float32 - area.y - area.h), GLsizei(area.w), GLsizei(area.h))
  a.quad.draw(a.player.target.tex, transformedCorners(center, size, a.xf.rotation), fb.vec2)
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

proc seekBar(a: App, r: Rect) =
  let ui = a.ui
  let p = a.player
  ui.rect(r, colPanel)
  let x0 = r.x + 12
  let w = r.w - 24
  let cy = r.y + r.h / 2
  let dur = p.duration
  let active = a.seekDragging
  let hov = (ui.hover(r) or active) and dur > 0 and p.loaded
  let th = if hov: 6'f32 else: 4'f32
  ui.rect(rect(x0, cy - th / 2, w, th), colTrack)
  let cur = if active: a.seekDragT else: p.timePos
  let frac = if dur > 0: clamp(cur / dur, 0, 1) else: 0
  ui.rect(rect(x0, cy - th / 2, w * frac, th), colAccent)

  # Markers (chapters for now; the list is generic so other marks can be added).
  var markers: seq[(float, string, ColorRGBX)]
  for i, c in p.chapters:
    markers.add (c.time, (if c.title.len > 0: c.title else: &"Chapter {i + 1}"), colMarker)

  var t = 0.0
  var snapped = -1
  if hov:
    t = clamp((ui.mouse.x - x0) / w, 0, 1) * dur
    if a.cfg.snapToChapters and not a.window.shift:
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
        p.seek(t, exact = false)
    else:
      a.seekDragging = false
      p.seek(t, exact = true)

  # Hover label and thumbnail
  a.showPreview = false
  if hov:
    var label = fmtTime(t)
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
  btn("play", "play", "Play", p.loaded or a.cfg.recentFiles.len > 0, p.playing):
    if not a.reopenLast(): a.player.play()
  btn("pause", "pause", "Pause", p.loaded, p.loaded and p.paused and not p.stopped): a.player.pause()
  btn("stop", "stop", "Stop", p.loaded, p.stopped): a.player.stop()
  ui.rect(rect(x + 4, y + 6, 1, bh - 12), colBorder)
  x += 10
  btn("prev", "prev", "Previous", p.loaded, false): a.navigate(-1)
  btn("slower", "slower", "Decrease rate", p.loaded, false): a.changeRate(-1)
  btn("faster", "faster", "Increase rate", p.loaded, false): a.changeRate(1)
  btn("next", "next", "Next", p.loaded, false): a.navigate(1)

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

proc status(a: App, r: Rect) =
  let ui = a.ui
  let p = a.player
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
  var timeText = fmtTime(if a.seekDragging: a.seekDragT else: p.timePos) & " / " & fmtTime(p.duration)
  if p.loaded and abs(p.speed - 1) > 0.001:
    timeText = &"{p.speed:g}x   " & timeText
  let tw = ui.textSize(timeText, FontSmall).x
  ui.textIn(timeText, rect(ix - iw / 2 - tw - 14, r.y, tw + 4, r.h), colText, FontSmall)

proc playlistPanel(a: App, r: Rect) =
  let ui = a.ui
  ui.rect(r, colPanel)
  ui.rect(rect(r.x, r.y, 1, r.h), colBorder)
  let header = rect(r.x, r.y, r.w, 30)
  ui.icon("playlist16", vec2(r.x + 18, header.y + 15), colAccent)
  ui.textIn(&"Playlist ({a.playlist.len})", rect(r.x + 32, header.y, r.w - 40, 30), colText)
  ui.rect(rect(r.x + 1, header.y + 29, r.w - 1, 1), colBorder)
  let list = rect(r.x + 1, r.y + 30, r.w - 1, r.h - 30)
  let rowH = 26'f32
  if a.playlist.len == 0:
    ui.textIn("Empty. Use File > Open File...", list, colTextDim, FontSmall, h = CenterAlign)
    return
  let maxScroll = max(0'f32, a.playlist.len.float32 * rowH - list.h)
  if ui.hover(list) and ui.scroll() != 0:
    a.plScroll -= ui.scroll() * rowH * 3
    ui.scrollConsumed = true
  a.plScroll = clamp(a.plScroll, 0, maxScroll)
  ui.sk.pushClipRect(list)
  let first = int(a.plScroll / rowH)
  for i in first ..< min(a.playlist.len, first + int(list.h / rowH) + 2):
    let row = rect(list.x, list.y + i.float32 * rowH - a.plScroll, list.w, rowH)
    let hov = ui.hover(row) and ui.hover(list)
    if i == a.plSelected: ui.rect(row, colPressed)
    elif hov: ui.rect(row, colHover)
    let current = i == a.plIndex
    if current: ui.icon("play16", vec2(row.x + 14, row.y + rowH / 2), colAccent)
    let name = ui.ellipsize(a.playlist[i].extractFilename, row.w - 36)
    ui.textIn(name, rect(row.x + 28, row.y, row.w - 32, rowH),
      if current: colAccent else: colText)
    if hov and ui.pressed():
      a.plSelected = i
      ui.consumeClick()
    if hov and a.window.buttonPressed[DoubleClick]:
      a.playIndex(i)
  ui.sk.popClipRect()

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
  r

proc optionsOverlay(a: App) =
  let ui = a.ui
  let r = a.overlayFrame("Options", vec2(420, 470))
  var y = r.y + 66
  let x = r.x + 24
  ui.textIn("STEPS", rect(x, y, 200, 20), colTextDim, FontSmall); y += 26
  discard ui.stepper("o-pan", vec2(x, y), "Move (pixels)", a.cfg.panStep, 1, 1, 500); y += 32
  discard ui.stepper("o-rot", vec2(x, y), "Rotate (degrees)", a.cfg.rotateStep, 1, 1, 90); y += 32
  discard ui.stepper("o-size", vec2(x, y), "Resize (percent)", a.cfg.sizeStep, 1, 1, 50); y += 32
  discard ui.stepper("o-rate", vec2(x, y), "Playback rate", a.cfg.rateStep, 0.05, 0.05, 1, "x", 2); y += 32
  discard ui.stepper("o-seek", vec2(x, y), "Jump (seconds)", a.cfg.seekStep, 1, 1, 300, "s"); y += 42
  ui.textIn("SEEK BAR", rect(x, y, 200, 20), colTextDim, FontSmall); y += 26
  discard ui.checkbox("o-prev", vec2(x, y), "Show thumbnail preview on hover", a.cfg.seekPreview); y += 30
  discard ui.checkbox("o-snap", vec2(x, y), "Snap to chapters (hold Shift to bypass)", a.cfg.snapToChapters); y += 30
  ui.textIn("WINDOW", rect(x, y + 4, 200, 20), colTextDim, FontSmall); y += 30
  discard ui.checkbox("o-fit", vec2(x, y), "Resize window to fit video on open", a.cfg.autoFitWindow)
  if ui.textButton("o-done", rect(r.x + r.w - 110, r.y + r.h - 46, 90, 30), "Done", primary = true):
    a.overlay = ovNone
    a.cfg.save()

proc propertiesOverlay(a: App) =
  let ui = a.ui
  let r = a.overlayFrame("Properties", vec2(560, 90 + a.props.len.float32 * 26))
  var y = r.y + 64
  for (k, v) in a.props:
    ui.textIn(k, rect(r.x + 24, y, 150, 24), colTextDim)
    ui.textIn(ui.ellipsize(v, r.w - 210), rect(r.x + 180, y, r.w - 200, 24), colText)
    y += 26

const shortcutList = [
  ("Open file", "Ctrl+O"), ("Load subtitle", "Ctrl+Shift+O"), ("Close", "Ctrl+C"),
  ("Save screenshot", "Alt+I"), ("Exit", "Alt+X"), ("Options", "O"),
  ("Play / Pause", "Space or click video"), ("Frame forward / back", ". / ,"),
  ("Rate up / down", "Shift+. / Shift+,"), ("Jump back / forward", "Left / Right"),
  ("Previous / next chapter", "Ctrl+Left / Ctrl+Right"), ("Previous / next file", "Page Up / Page Down"),
  ("Jump to 0% ... 90%", "0 ... 9"),
  ("Volume up / down", "Up / Down or wheel"), ("Mute", "Ctrl+M"),
  ("Next / previous audio", "A / Shift+A"), ("Next / previous subtitle", "S / Shift+S"),
  ("Full screen", "Alt+Enter or double-click"), ("Toggle seek bar, controls, status, playlist", "Ctrl+1 ... Ctrl+4"),
  ("Move video", "Numpad 8 / 2 / 4 / 6, 5 centers"), ("Rotate", "Alt+Numpad 4 / 6, Alt+5 resets"),
  ("Resize video", "Ctrl+Numpad 9 / 3, 6 / 4, 8 / 2"), ("Context menu", "Right-click video"),
  ("Move window", "Drag the video")]

proc shortcutsOverlay(a: App) =
  let ui = a.ui
  let r = a.overlayFrame("Keyboard Shortcuts", vec2(600, 80 + shortcutList.len.float32 * 23))
  var y = r.y + 62
  for (k, v) in shortcutList:
    ui.textIn(k, rect(r.x + 24, y, 300, 22), colText, FontSmall)
    ui.textIn(v, rect(r.x + 300, y, r.w - 324, 22), colAccent, FontSmall, h = RightAlign)
    y += 23

proc aboutOverlay(a: App) =
  let ui = a.ui
  let r = a.overlayFrame("About", vec2(420, 260))
  ui.icon("crown96", vec2(r.x + r.w / 2, r.y + 110), colAccent)
  ui.textIn(AppName & " " & AppVersion, rect(r.x, r.y + 160, r.w, 26), colText, h = CenterAlign)
  ui.textIn("Built with Nim, Silky and libmpv " & a.player.h.getStr("mpv-version").replace("mpv ", ""),
    rect(r.x, r.y + 188, r.w, 22), colTextDim, FontSmall, h = CenterAlign)

# --- frame ------------------------------------------------------------------

proc readFramebuffer(size: IVec2): Image =
  result = newImage(size.x, size.y)
  glReadPixels(0, 0, size.x, size.y, GL_RGBA, GL_UNSIGNED_BYTE, result.data[0].addr)
  result.flipVertical()

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
  let plW = if a.cfg.showPlaylist: PlaylistWidth else: 0
  let videoArea =
    if fs: rect(0, 0, W, H)
    else: rect(0, menuH, max(0'f32, W - plW), max(0'f32, H - menuH - bottomH))
  a.videoRect = videoArea
  let revealZone = H - bottomH - 48
  let mouseIn = ui.fakeMouse.x >= 0 or w.mouseInside
  let bottomVisible = not fs or ui.mouse.y >= revealZone and mouseIn or
    a.seekDragging or ui.activeId == "volume"
  let bottomRect = rect(0, H - bottomH, W, bottomH)
  let plRect =
    if fs: rect(W - plW, 0, plW, if bottomVisible: H - bottomH else: H)
    else: rect(W - plW, menuH, plW, H - menuH - bottomH)

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
     not (a.cfg.showPlaylist and ui.mouse.inside(plRect)):
    if ui.pressed():
      a.videoPress = true
      a.videoPressPos = ui.mouse
    if a.window.buttonPressed[DoubleClick]:
      a.setFullscreen(not a.fullscreen)
      a.videoPress = false
    if ui.released(MouseRight):
      a.menus.openContext(ui.mouse)
    if ui.scroll() != 0 and not (a.cfg.showPlaylist and ui.mouse.inside(plRect)):
      a.volumeStep(ui.scroll() < 0)
      ui.scrollConsumed = true
  if a.videoPress:
    if not ui.down():
      a.videoPress = false
      if ui.window.buttonReleased[MouseLeft]:
        a.player.togglePause()
    elif (ui.mouse - a.videoPressPos).length > 4:
      a.videoPress = false
      if not fs: w.startWindowDrag()

  # Chrome
  if a.cfg.showPlaylist: a.playlistPanel(plRect)
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
    of ovOptions: a.optionsOverlay()
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

  # Cursor auto-hide over playing video.
  if ui.mouse != a.lastMouse:
    a.lastMouse = ui.mouse
    a.lastMouseMove = now()
  let hide = a.player.playing and a.player.hasVideo and
    ui.mouse.inside(videoArea) and not a.menus.isOpen and a.overlay == ovNone and
    not (fs and bottomVisible) and now() - a.lastMouseMove > 1.0
  if hide != a.cursorHidden:
    a.cursorHidden = hide
    w.cursor = if hide: hiddenCursor() else: Cursor(kind: ArrowCursor)

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

# --- setup & main loop --------------------------------------------------------

proc runScriptStep(a: App, st: ScriptStep) =
  let arg = st.args.join(" ")
  case st.cmd
  of "open": a.openPaths(@[arg])
  of "menu":
    var path: seq[int]
    for x in st.args[1 .. ^1]: path.add parseInt(x)
    a.menus.openBar(parseInt(st.args[0]), path)
  of "ctx": a.menus.openContext(vec2(parseFloat(st.args[0]), parseFloat(st.args[1])))
  of "close": a.menus.close()
  of "mouse":
    a.ui.fakeMouse = if arg == "off": vec2(-1, -1)
                     else: vec2(parseFloat(st.args[0]), parseFloat(st.args[1]))
  of "overlay":
    a.showOverlay(case arg
      of "options": ovOptions
      of "properties": ovProperties
      of "shortcuts": ovShortcuts
      of "about": ovAbout
      else: ovNone)
  of "action": a.runMenuPath(arg.split('/'))
  of "fs": a.setFullscreen(arg == "1")
  of "seek": a.player.seek(parseFloat(arg))
  of "pause": a.player.togglePause()
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
  for s in ["…", "–", "—", "•", "‘", "’", "“", "”", "→", "×", "°", "·", "▸"]:
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
  let a = App(plIndex: -1, plSelected: -1)
  a.cfg = loadConfig()
  a.script = loadScript()
  # vsync off: under XWayland the NVIDIA driver can block glXSwapBuffers for
  # whole seconds when KWin withholds frame callbacks (hidden/occluded window),
  # freezing UI and video. The compositor presents our buffers tear-free, mpv
  # paces video frames, and UI-only redraws are rate-capped in the main loop.
  a.window = newWindow(AppName, ivec2(1024, 640), vsync = false)
  a.window.icon = appIcon()
  makeContextCurrent(a.window)
  loadExtensions()
  a.window.disableVsync()
  a.window.setAspectHints(0, ivec2(0, 0), MinWindow)

  let (img, atlas) = buildAtlas()
  a.sk = newSilky(a.window, img, atlas)
  a.ui = newUi(a.sk, a.window)
  a.menus = newMenuSystem()
  a.quad = newQuadRenderer()

  a.player = newPlayer(a.cfg.volume, a.cfg.muted, a.cfg.showOsd)
  a.player.initRender()
  a.applyLoop()
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
  a.window.onFocusChange = proc () =
    touch()
    # Popups take no focus, so focus moving elsewhere means a click outside
    # the app (or Alt+Tab): dismiss menus like a toolkit would. Checked a bit
    # later in the loop, since activating the window by clicking the menu bar
    # can produce a brief focus-out that must not close the menu just opened.
    a.focusLostAt = if a.window.focused: 0.0 else: now()
    a.dirtyUntil = now() + 0.5

  var args = commandLineParams()
  if args.len > 0:
    a.openPaths(args.mapIt(if it.contains("://"): it else: it.absolutePath))

  var lastFrame = 0.0
  while not a.window.closeRequested:
    pollEvents()
    if a.menus.pollInput(): a.dirtyUntil = now() + 1.2
    if takeFrameReady(): a.frameFlag = true
    if takePreviewReady(): a.previewFlag = true
    let changed = a.player.pollEvents()
    a.preview.pollEvents()
    a.pollDialog()
    for st in a.script.due: a.runScriptStep(st)
    if a.script.next < a.script.steps.len: a.dirtyUntil = now() + 0.5

    if a.player.justLoaded:
      a.player.justLoaded = false
      a.updateTitle()
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
      lastFrame = t
    else:
      sleep(1)

  a.cfg.volume = a.player.volume
  a.cfg.muted = a.player.muted
  a.cfg.save()
  for c in a.children: c.close()
  if a.preview != nil:
    mpv_render_context_free(a.preview.render)
    mpv_terminate_destroy(a.preview.h)
  mpv_render_context_free(a.player.render)
  mpv_terminate_destroy(a.player.h)

when isMainModule:
  main()
