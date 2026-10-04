## mpv-backed playback core: one instance for playback and a lightweight
## second instance that renders seek-bar thumbnails.

import std/[algorithm, atomics, json, strutils, os, times]
import mpv, videogl

type
  Track* = object
    id*: int
    kind*: string           ## "video", "audio", "sub"
    title*, lang*, codec*: string
    selected*, external*, albumArt*: bool
    channels*: int

  Chapter* = object
    time*: float
    title*: string

  Prop = enum
    pPause, pTimePos, pDuration, pEof, pTracks, pChapters, pVolume, pMute,
    pSpeed, pVideoParams, pAudioChannels, pIdle, pSeeking

  Player* = ref object
    h*: MpvHandle
    render*: MpvRenderContext
    target*: VideoTarget
    path*: string
    loaded*: bool             ## a file is open
    stopped*: bool            ## our Stop state (paused at 0, video hidden)
    paused*: bool
    seeking*: bool
    timePos*, duration*: float
    eofReached*: bool
    volume*: float
    muted*: bool
    speed*: float = 1
    tracks*: seq[Track]
    chapters*: seq[Chapter]
    videoW*, videoH*: int     ## display size (aspect-corrected)
    audioChannels*: int
    loadError*: string
    justLoaded*: bool         ## set on FILE_LOADED, cleared by the app
    eofHandled*: bool

  Preview* = ref object
    h*: MpvHandle
    render*: MpvRenderContext
    target*: VideoTarget
    path: string
    busy: bool                ## a seek is in flight
    wanted, shown: float      ## requested vs. displayed time
    hasFrame*: bool

var
  frameReady: Atomic[bool]
  previewReady: Atomic[bool]

proc onMainUpdate(d: pointer) {.cdecl.} = frameReady.store(true)
proc onPreviewUpdate(d: pointer) {.cdecl.} = previewReady.store(true)

proc takeFrameReady*(): bool = frameReady.exchange(false)
proc takePreviewReady*(): bool = previewReady.exchange(false)

proc newPlayer*(volume: float, muted, osd: bool): Player =
  result = Player(volume: volume, muted: muted)
  let h = mpv_create()
  if h == nil: raise newException(MpvError, "mpv_create failed")
  result.h = h
  h.setOpt("config", "no")
  h.setOpt("vo", "libmpv")
  h.setOpt("hwdec", "auto-safe")
  h.setOpt("keep-open", "yes")
  h.setOpt("idle", "yes")
  h.setOpt("terminal", "no")
  h.setOpt("input-default-bindings", "no")
  h.setOpt("input-vo-keyboard", "no")
  h.setOpt("osc", "no")
  h.setOpt("keepaspect", "no")         # we size the target to the aspect
  h.setOpt("volume-max", "200")
  h.setOpt("volume", $volume)
  h.setOpt("mute", if muted: "yes" else: "no")
  h.setOpt("osd-level", if osd: "1" else: "0")
  h.setOpt("sub-auto", "fuzzy")
  h.setOpt("screenshot-format", "png")
  h.setOpt("audio-client-name", "majestic-media-player")
  h.setOpt("audio-display", "embedded-first")
  check mpv_initialize(h), "mpv_initialize"
  # mpv's log goes to stderr only when MMP_DEBUG is set; load failures surface
  # in the status bar regardless.
  if existsEnv("MMP_DEBUG"):
    discard mpv_request_log_messages(h, "warn")
  for (p, name, fmt) in [
      (pPause, "pause", fmtFlag), (pTimePos, "time-pos", fmtDouble),
      (pDuration, "duration", fmtDouble), (pEof, "eof-reached", fmtFlag),
      (pTracks, "track-list", fmtNode), (pChapters, "chapter-list", fmtNode),
      (pVolume, "volume", fmtDouble), (pMute, "mute", fmtFlag),
      (pSpeed, "speed", fmtDouble), (pVideoParams, "video-params", fmtNode),
      (pAudioChannels, "audio-params/channel-count", fmtInt64),
      (pIdle, "idle-active", fmtFlag), (pSeeking, "seeking", fmtFlag)]:
    discard mpv_observe_property(h, p.uint64, name.cstring, fmt)

proc initRender*(p: Player) =
  ## Must run with the window's GL context current.
  # Non-blocking: the app waits for each frame's target time itself, so the UI
  # keeps running between video frames.
  p.render = createRenderContext(p.h, blockForTargetTime = false)
  mpv_render_context_set_update_callback(p.render, onMainUpdate, nil)

proc parseTracks(p: Player, j: JsonNode) =
  p.tracks.setLen 0
  if j.kind != JArray: return
  for t in j:
    p.tracks.add Track(
      id: t{"id"}.getInt, kind: t{"type"}.getStr,
      title: t{"title"}.getStr, lang: t{"lang"}.getStr,
      codec: t{"codec"}.getStr, selected: t{"selected"}.getBool,
      external: t{"external"}.getBool, albumArt: t{"albumart"}.getBool,
      channels: t{"demux-channel-count"}.getInt)

proc parseChapters(p: Player, j: JsonNode) =
  p.chapters.setLen 0
  if j.kind != JArray: return
  for c in j:
    p.chapters.add Chapter(time: c{"time"}.getFloat, title: c{"title"}.getStr)

proc handleProp(p: Player, id: Prop, ev: ptr MpvEventProperty) =
  let d = ev.data
  template f: float = (if d == nil: 0.0 else: cast[ptr cdouble](d)[].float)
  template b: bool = (d != nil and cast[ptr cint](d)[] != 0)
  case id
  of pPause: p.paused = b
  of pTimePos: p.timePos = f
  of pDuration: p.duration = f
  of pEof:
    p.eofReached = b
    if not p.eofReached: p.eofHandled = false
  of pVolume: p.volume = f
  of pMute: p.muted = b
  of pSpeed: p.speed = f
  of pSeeking: p.seeking = b
  of pAudioChannels:
    p.audioChannels = if d == nil: 0 else: cast[ptr int64](d)[].int
  of pIdle: discard
  of pTracks, pChapters, pVideoParams:
    let j = if d == nil or ev.format != fmtNode: newJNull()
            else: cast[ptr MpvNode](d)[].toJson
    case id
    of pTracks: p.parseTracks(j)
    of pChapters: p.parseChapters(j)
    else:
      if j.kind == JObject:
        p.videoW = j{"dw"}.getInt
        p.videoH = j{"dh"}.getInt
      else:
        p.videoW = 0
        p.videoH = 0

proc pollEvents*(p: Player): bool =
  ## Drains the mpv event queue. Returns true if anything changed.
  while true:
    let ev = mpv_wait_event(p.h, 0)
    if ev.eventId == evNone: break
    result = true
    case ev.eventId
    of evPropertyChange:
      let id = ev.replyUserdata.int
      if id in Prop.low.int .. Prop.high.int:
        p.handleProp(Prop(id), cast[ptr MpvEventProperty](ev.data))
    of evFileLoaded:
      p.loaded = true
      p.justLoaded = true
      p.loadError = ""
      p.eofHandled = false
    of evEndFile:
      let e = cast[ptr MpvEventEndFile](ev.data)
      if e.reason == efError:
        p.loadError = $mpv_error_string(e.error)
        p.loaded = false
    of evLogMessage:
      type LogMsg = object
        prefix, level, text: cstring
      let m = cast[ptr LogMsg](ev.data)
      stderr.write "[mpv/", $m.prefix, "] ", $m.text
    else: discard

proc load*(p: Player, path: string, start = 0.0) =
  ## Opens path, starting at `start` seconds when given.
  p.path = path
  p.stopped = false
  p.eofReached = false
  p.eofHandled = false
  p.timePos = start
  p.duration = 0
  p.loadError = ""
  if start > 0:
    p.h.command("loadfile", path, "replace", "-1",
      "start=" & formatFloat(start, ffDecimal, 3))
  else:
    p.h.command("loadfile", path, "replace")
  p.h.setProp("pause", false)

proc close*(p: Player) =
  p.h.command("stop")
  p.path = ""
  p.loaded = false
  p.stopped = false
  p.tracks.setLen 0
  p.chapters.setLen 0
  p.videoW = 0
  p.videoH = 0
  p.timePos = 0
  p.duration = 0

proc hasVideo*(p: Player): bool =
  p.loaded and p.videoW > 0 and p.videoH > 0

proc hasRealVideo*(p: Player): bool =
  ## A selected video track that is not just cover art.
  if not p.hasVideo: return false
  for t in p.tracks:
    if t.kind == "video" and t.selected and not t.albumArt: return true

proc playing*(p: Player): bool = p.loaded and not p.paused and not p.stopped

proc togglePause*(p: Player) =
  if not p.loaded: return
  if p.stopped:
    p.stopped = false
    p.h.setProp("pause", false)
  elif p.eofReached:
    p.h.commandAsync("seek", "0", "absolute")
    p.h.setProp("pause", false)
  else:
    p.h.setProp("pause", not p.paused)

proc play*(p: Player) =
  if p.loaded:
    p.stopped = false
    if p.eofReached: p.h.commandAsync("seek", "0", "absolute")
    p.h.setProp("pause", false)

proc pause*(p: Player) =
  if p.loaded: p.h.setProp("pause", true)

proc stop*(p: Player) =
  if not p.loaded: return
  p.h.setProp("pause", true)
  p.h.commandAsync("seek", "0", "absolute", "exact")
  p.stopped = true

proc seek*(p: Player, t: float, exact = true) =
  if not p.loaded: return
  p.h.commandAsync("seek", formatFloat(max(t, 0), ffDecimal, 3), "absolute",
    if exact: "exact" else: "keyframes")

proc osd*(p: Player, msg: string) =
  p.h.commandAsync("show-text", msg, "1500")

proc setVolume*(p: Player, v: float) =
  p.volume = clamp(v, 0, 200)
  p.h.setProp("volume", p.volume)

proc selectedTrack*(p: Player, kind: string): int =
  for t in p.tracks:
    if t.kind == kind and t.selected: return t.id
  0

proc trackLabel*(t: Track): string =
  result = "#" & $t.id
  if t.title.len > 0: result.add ": " & t.title
  if t.lang.len > 0: result.add " [" & t.lang & "]"
  if t.codec.len > 0: result.add " (" & t.codec & ")"
  if t.external: result.add " · external"

# --- thumbnail preview ------------------------------------------------------

proc newPreview*(): Preview =
  result = Preview(wanted: -1, shown: -1)
  let h = mpv_create()
  if h == nil: return nil
  result.h = h
  h.setOpt("config", "no")
  h.setOpt("vo", "libmpv")
  h.setOpt("hwdec", "auto-safe")
  h.setOpt("terminal", "no")
  h.setOpt("audio", "no")
  h.setOpt("sid", "no")
  h.setOpt("pause", "yes")
  h.setOpt("keep-open", "always")
  h.setOpt("idle", "yes")
  h.setOpt("hr-seek", "no")
  h.setOpt("osd-level", "0")
  h.setOpt("keepaspect", "no")
  h.setOpt("demuxer-readahead-secs", "0")
  h.setOpt("cache", "no")
  h.setOpt("load-scripts", "no")
  check mpv_initialize(h), "preview mpv_initialize"

proc initRender*(pv: Preview) =
  pv.render = createRenderContext(pv.h, blockForTargetTime = false)
  mpv_render_context_set_update_callback(pv.render, onPreviewUpdate, nil)

proc request*(pv: Preview, path: string, t: float) =
  ## Ask for a thumbnail at time t. Seeks are coalesced: only the latest
  ## request is issued once the previous one completes.
  if pv == nil: return
  if path != pv.path:
    pv.path = path
    pv.hasFrame = false
    pv.busy = true
    pv.shown = -1
    pv.h.command("loadfile", path, "replace", "-1",
      "start=" & formatFloat(t, ffDecimal, 2))
  pv.wanted = t
  if not pv.busy and abs(pv.wanted - pv.shown) > 0.05:
    pv.busy = true
    pv.shown = pv.wanted
    pv.h.commandAsync("seek", formatFloat(t, ffDecimal, 2), "absolute", "keyframes")

proc pollEvents*(pv: Preview) =
  if pv == nil: return
  while true:
    let ev = mpv_wait_event(pv.h, 0)
    if ev.eventId == evNone: break
    case ev.eventId
    of evPlaybackRestart:
      pv.busy = false
      pv.hasFrame = true
      if pv.shown < 0: pv.shown = pv.wanted
      if abs(pv.wanted - pv.shown) > 0.05:
        let t = pv.wanted
        pv.request(pv.path, t)
    of evEndFile:
      pv.busy = false
    else: discard

proc forget*(pv: Preview) =
  ## Drop the loaded file (e.g. when the main file is closed).
  if pv == nil or pv.path.len == 0: return
  pv.h.command("stop")
  pv.path = ""
  pv.hasFrame = false
  pv.busy = false

# --- folder navigation -----------------------------------------------------

proc naturalCmp*(a, b: string): int =
  ## Case-insensitive compare that orders embedded numbers numerically.
  var i, j = 0
  while i < a.len and j < b.len:
    if a[i].isDigit and b[j].isDigit:
      var si = i
      var sj = j
      while i < a.len and a[i].isDigit: inc i
      while j < b.len and b[j].isDigit: inc j
      let na = a[si ..< i].strip(trailing = false, chars = {'0'})
      let nb = b[sj ..< j].strip(trailing = false, chars = {'0'})
      if na.len != nb.len: return cmp(na.len, nb.len)
      let c = cmp(na, nb)
      if c != 0: return c
    else:
      let c = cmp(a[i].toLowerAscii, b[j].toLowerAscii)
      if c != 0: return c
      inc i
      inc j
  cmp(a.len - i, b.len - j)

proc mediaFilesIn*(dir: string, isMedia: proc (p: string): bool): seq[string] =
  for kind, f in walkDir(dir):
    if kind in {pcFile, pcLinkToFile} and isMedia(f):
      result.add f
  result.sort(proc (a, b: string): int = naturalCmp(a.extractFilename, b.extractFilename))

# --- media probing -------------------------------------------------------------

type
  MediaInfo* = object
    duration*: float          ## seconds, 0 when unknown
    width*, height*: int      ## first real video track, 0 for audio only

  Prober* = ref object
    ## Headless, paused mpv with null outputs, for the playlist's columns and
    ## sorting. Probes one file at a time, either blocking or in the background.
    h: MpvHandle
    pending*: string          ## path being probed, "" when idle
    info*: MediaInfo          ## result of the last finished probe
    deadline: float
    loaded: bool              ## a file is open (released by finish)

proc newProber*(): Prober =
  let h = mpv_create()
  if h == nil: return nil
  for (k, v) in [("config", "no"), ("terminal", "no"), ("vo", "null"),
                 ("ao", "null"), ("sid", "no"), ("hwdec", "no"),
                 ("pause", "yes"), ("idle", "yes"), ("keep-open", "yes"),
                 ("load-scripts", "no"), ("cache", "no"), ("sub-auto", "no"),
                 ("audio-file-auto", "no"), ("cover-art-auto", "no")]:
    try: h.setOpt(k, v)
    except MpvError: discard
  if mpv_initialize(h) < 0:
    mpv_terminate_destroy(h)
    return nil
  Prober(h: h)

proc start*(pr: Prober, path: string, timeout = 3.0) =
  ## Begins probing path; poll until it returns true, then read `info`.
  pr.pending = path
  pr.info = MediaInfo()
  pr.deadline = epochTime() + timeout
  pr.loaded = true
  pr.h.command("loadfile", path, "replace")

proc poll*(pr: Prober, wait = 0.0): bool =
  ## Handles the pending probe's events, waiting up to `wait` seconds for one.
  ## True once it is done; `info` stays zeroed when the file failed or timed out.
  while pr.pending.len > 0:
    let left = pr.deadline - epochTime()
    if left <= 0: break
    let ev = mpv_wait_event(pr.h, min(wait, left))
    case ev.eventId
    of evNone: return false
    of evFileLoaded:
      # Skip a late event from a file an earlier probe abandoned.
      if pr.h.getStr("path") != pr.pending: continue
      pr.info.duration = pr.h.getFloat("duration")
      let tracks = pr.h.getNode("track-list")
      if tracks.kind == JArray:
        for t in tracks:
          if t{"type"}.getStr == "video" and not t{"albumart"}.getBool:
            pr.info.width = t{"demux-w"}.getInt
            pr.info.height = t{"demux-h"}.getInt
            break
      break
    of evEndFile:
      if cast[ptr MpvEventEndFile](ev.data).reason == efError: break
    of evShutdown: break
    else: discard
  pr.pending = ""
  true

proc probe*(pr: Prober, path: string, timeout = 3.0): MediaInfo =
  ## Opens path just long enough to read its duration and video size.
  if pr == nil: return
  pr.start(path, timeout)
  while not pr.poll(timeout): discard
  pr.info

proc finish*(pr: Prober) =
  ## Releases the last probed file.
  if pr != nil and pr.loaded:
    pr.pending = ""
    pr.loaded = false
    pr.h.command("stop")
