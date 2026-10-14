## mpv-backed playback core: one instance for playback (the app runs a second
## as a seamless loop's standby, and a video-less third for a loop's sound)
## and a lightweight instance that renders seek-bar thumbnails.

import std/[algorithm, atomics, json, strutils, os, tables, times]
import mpv, videogl, spherical
from config import AudioExtensions
from ytdlp import YtdlSubLangs

type
  Track* = object
    id*: int
    kind*: string           ## "video", "audio", "sub"
    title*, lang*, codec*: string
    selected*, external*, albumArt*: bool
    file*: string           ## an external track's file
    channels*: int

  Chapter* = object
    time*: float
    title*: string

  Prop = enum
    pPause, pTimePos, pDuration, pEof, pTracks, pChapters, pVolume, pMute,
    pSpeed, pVideoParams, pAudioChannels, pIdle, pSeeking, pCacheState,
    pPausedForCache

  Player* = ref object
    h*: MpvHandle
    render*: MpvRenderContext
    target*: VideoTarget
    path*: string
    loaded*: bool             ## a file is open
    opening*: bool            ## a file is being opened (links take a while)
    stopped*: bool            ## our Stop state (paused at 0, video hidden)
    paused*: bool
    seeking*: bool
    timePos*, duration*: float
    timeAt: float             ## when timePos last changed, epochTime
    frameDur: float           ## the last step of timePos while playing, a frame
    eofReached*: bool
    backward*: bool           ## playing in reverse (ping-pong loops)
    threadless*: bool         ## opened without mpv's demuxer thread: turns
                              ## around to backward at once (mpv's thread
                              ## sleeps a second, or for good at the end of
                              ## a file, before reading further back)
    volume*: float
    muted*: bool
    speed*: float = 1
    tracks*: seq[Track]
    chapters*: seq[Chapter]
    buffered*: seq[(float, float)]  ## spans read ahead into the cache, seconds
    cacheAhead*: float = -1   ## seconds read ahead of the position (-1: unknown)
    buffering*: bool          ## playback held until the cache fills
    videoW*, videoH*: int     ## display size (aspect-corrected)
    pixelW*, pixelH*: int     ## stored size, as upright as shown (what ffmpeg
                              ## filters see, autorotation included)
    audioChannels*: int
    loadError*: string
    sphere*: SphereInfo       ## 360° metadata of the open file
    justLoaded*: bool         ## set on FILE_LOADED, cleared by the app
    eofHandled*: bool
    props*: Table[string, string]  ## MirroredProps as they are now
    hidden*: bool             ## a seamless loop's standby: copies the shown
                              ## player's file details instead of finding them
    startDelay*: float = 0.04 ## seamless loops: how long it takes to get going
                              ## from paused, media seconds
    jumps*: int               ## seeks, steps and stops asked for through
                              ## this module (not a loop's own jumps back)
    soundKey: string          ## a loop sound's filters and track as set
    restarts*: int            ## playback restarts (after loads and seeks)
    expanded*: seq[string]    ## expandText results, in order

  Preview* = ref object
    h*: MpvHandle
    render*: MpvRenderContext
    target*: VideoTarget
    path: string
    busy: bool                ## a seek is in flight
    wanted, shown: float      ## requested vs. displayed time
    hasFrame*: bool

var
  # int, not bool: with MSVC, std/atomics' exchange is a 64-bit interlocked
  # exchange whatever the type, so on a bool it zeroes the 7 bytes after it
  # (other globals).
  frameReady: Atomic[int]
  previewReady: Atomic[int]
  osdReady: Atomic[int]

const
  MirroredProps* = ["aid", "vid", "sid", "secondary-sid", "volume", "speed",
    "sub-delay", "audio-delay", "sub-visibility", "slang", "alang",
    "sub-file-paths", "sub-align-x", "sub-align-y", "sub-margin-x",
    "sub-margin-y", "sub-pos", "sub-scale", "video-margin-ratio-left",
    "video-margin-ratio-right", "video-margin-ratio-top",
    "video-margin-ratio-bottom", "keepaspect", "video-scale-x",
    "video-scale-y", "osd-level", "osd-msg3", "osd-fractions", "osd-scale",
    "osd-margin-x", "osd-margin-y", "osd-outline-size", "osd-bar-align-x",
    "osd-bar-align-y", "osd-bar-w", "osd-bar-h", "osd-bar-outline-size",
    "osd-bar-marker-min-size", "loop-file", "ab-loop-a", "ab-loop-b"]
    ## What the app sets at runtime, observed (into `props`) so a second
    ## player can be made to look and sound the same (seamless loops)
  MirrorBase = 1000           ## observation ids of MirroredProps
  ExpandReply = 77'u64        ## reply id of expandText

proc onMainUpdate(d: pointer) {.cdecl.} = frameReady.store(1)
proc onPreviewUpdate(d: pointer) {.cdecl.} = previewReady.store(1)
proc onOsdUpdate(d: pointer) {.cdecl.} = osdReady.store(1)

proc takeFrameReady*(): bool = frameReady.exchange(0) != 0
proc takePreviewReady*(): bool = previewReady.exchange(0) != 0
proc takeOsdReady*(): bool = osdReady.exchange(0) != 0

proc observe(h: MpvHandle) =
  for (p, name, fmt) in [
      (pPause, "pause", fmtFlag), (pTimePos, "time-pos", fmtDouble),
      (pDuration, "duration", fmtDouble), (pEof, "eof-reached", fmtFlag),
      (pTracks, "track-list", fmtNode), (pChapters, "chapter-list", fmtNode),
      (pVolume, "volume", fmtDouble), (pMute, "mute", fmtFlag),
      (pSpeed, "speed", fmtDouble), (pVideoParams, "video-params", fmtNode),
      (pAudioChannels, "audio-params/channel-count", fmtInt64),
      (pIdle, "idle-active", fmtFlag), (pSeeking, "seeking", fmtFlag),
      (pCacheState, "demuxer-cache-state", fmtNode),
      (pPausedForCache, "paused-for-cache", fmtFlag)]:
    discard mpv_observe_property(h, p.uint64, name.cstring, fmt)
  for i, name in MirroredProps:
    discard mpv_observe_property(h, uint64(MirrorBase + i), name.cstring, fmtString)

proc newPlayer*(volume: float, muted, osd: bool): Player =
  result = Player(volume: volume, muted: muted)
  let h = mpv_create()
  if h == nil: raise newException(MpvError, "mpv_create failed")
  result.h = h
  h.setOpt("config", "no")
  h.setOpt("vo", "libmpv")
  h.setOpt("hwdec", "auto-safe")
  # Direct rendering has the decoder wait on the render thread (ours) for
  # frame buffers, so any blocking mpv call from the UI could deadlock.
  h.setOpt("vd-lavc-dr", "no")
  h.setOpt("keep-open", "yes")
  h.setOpt("idle", "yes")
  h.setOpt("terminal", "no")
  h.setOpt("input-default-bindings", "no")
  h.setOpt("input-vo-keyboard", "no")
  h.setOpt("osc", "no")
  h.setOpt("keepaspect", "no")         # we size the target to the aspect
  h.setOpt("volume-max", "200")
  h.setOpt("volume-gain-min", "-150")  # silent enough while a loop sound plays
  h.setOpt("volume", $volume)
  h.setOpt("mute", if muted: "yes" else: "no")
  h.setOpt("osd-level", if osd: "1" else: "0")
  h.setOpt("sub-auto", "fuzzy")
  h.setOpt("screenshot-format", "png")
  h.setOpt("audio-client-name", "majestic-media-player")
  h.setOpt("audio-display", "embedded-first")
  # Links go through yt-dlp (useYtdlp), which also fetches their subtitles.
  h.setOpt("ytdl", "no")
  h.setOpt("ytdl-raw-options", "sub-langs=%" & $YtdlSubLangs.len & "%" &
    YtdlSubLangs)  # %n%: n bytes taken as they are
  check mpv_initialize(h), "mpv_initialize"
  # mpv's log goes to stderr only when MMP_DEBUG is set; load failures surface
  # in the status bar regardless.
  if existsEnv("MMP_DEBUG"):
    discard mpv_request_log_messages(h, "warn")
  observe(h)

proc useYtdlp*(p: Player, path: string) =
  ## Has mpv open links with the yt-dlp at path, through its built-in hook.
  ## The hook looks for yt-dlp once, on the first link, and keeps what it
  ## found (nothing included), so each path gets a hook of its own, loaded
  ## once there is a yt-dlp to find (setting ytdl later loads none).
  p.h.setProp("script-opts", "ytdl_hook-ytdl_path=" & path)
  p.h.command("load-script", "@ytdl_hook.lua")

proc newLoopSound*(volume: float): Player =
  ## A video-less player for an A-B loop's sound (loopSoundAt); paused,
  ## muted and hidden until the app has it play.
  result = Player(volume: volume, muted: true, hidden: true, startDelay: 0.02)
  let h = mpv_create()
  if h == nil: raise newException(MpvError, "mpv_create failed")
  result.h = h
  for (k, v) in [("config", "no"), ("vid", "no"), ("sid", "no"),
                 ("audio-display", "no"), ("sub-auto", "no"),
                 ("audio-file-auto", "no"), ("cover-art-auto", "no"),
                 ("load-scripts", "no"), ("keep-open", "yes"), ("idle", "yes"),
                 ("pause", "yes"), ("terminal", "no"),
                 ("input-default-bindings", "no"), ("volume-max", "200"),
                 ("volume", $volume), ("mute", "yes"),
                 ("audio-client-name", "majestic-media-player")]:
    h.setOpt(k, v)
  check mpv_initialize(h), "loop sound mpv_initialize"
  if existsEnv("MMP_DEBUG"):
    discard mpv_request_log_messages(h, "warn")
  observe(h)

proc loopSoundAt*(p: Player, path, aid: string, a, b, start: float) =
  ## Has the loop sound wait, paused, at A of the loop from A to B (path's
  ## audio track `aid`): from there it plays A to B over and over, seamless
  ## to the sample, as ffmpeg's atrim and aloop filters keep the loop's sound
  ## and repeat it. Decoding begins at `start`, a little before A, so A
  ## sounds as in continuous play. Again on the same loop: back to A.
  let f = (proc (t: float): string = formatFloat(t, ffDecimal, 6))
  let af = "lavfi=[atrim=start=" & f(a) & ":end=" & f(b) &
    ",aloop=loop=-1:size=2147483647]"  # its size: all there is
  p.h.setProp("pause", true)
  p.stopped = false
  p.eofReached = false
  p.timePos = a
  if af & aid != p.soundKey:
    p.soundKey = af & aid
    p.h.setProp("aid", aid)
    p.h.setProp("af", af)
  if path != p.path or not p.loaded:
    p.path = path
    p.loaded = false
    p.loadError = ""
    p.h.commandAsync("loadfile", path, "replace", "-1", "start=" & f(start))
  else:
    # A seek starts the filters over, so the loop's sound with them.
    p.h.commandAsync("seek", f(start), "absolute", "exact")

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
      file: t{"external-filename"}.getStr,
      channels: t{"demux-channel-count"}.getInt)

proc parseChapters(p: Player, j: JsonNode) =
  p.chapters.setLen 0
  if j.kind != JArray: return
  for c in j:
    p.chapters.add Chapter(time: c{"time"}.getFloat, title: c{"title"}.getStr)

proc posNow*(p: Player): float =
  ## The playback position now, finer than timePos (which moves a frame at a
  ## time): what has played since the shown frame's time came in. Never past
  ## the next frame, so a stalled player (just looped or sought) isn't taken
  ## for a playing one.
  if p.paused or p.seeking or p.eofReached or p.stopped or not p.loaded: return p.timePos
  let d = min((epochTime() - p.timeAt) * p.speed, p.frameDur)
  if p.backward: p.timePos - d else: p.timePos + d

proc setBackward*(p: Player, on: bool) =
  ## Which way playback goes; mpv turns around where it is (a seek).
  if on == p.backward: return
  p.backward = on
  p.h.setProp("play-direction", if on: "backward" else: "forward")

proc handleProp(p: Player, id: Prop, ev: ptr MpvEventProperty) =
  let d = ev.data
  template f: float = (if d == nil: 0.0 else: cast[ptr cdouble](d)[].float)
  template b: bool = (d != nil and cast[ptr cint](d)[] != 0)
  case id
  of pPause: p.paused = b
  of pTimePos:
    let step = abs(f - p.timePos)
    if step > 0.001 and step < 0.1: p.frameDur = step
    p.timePos = f
    p.timeAt = epochTime()
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
  of pCacheState:
    p.buffered.setLen 0
    p.cacheAhead = -1
    if d != nil and ev.format == fmtNode:
      let j = cast[ptr MpvNode](d)[].toJson
      for r in j{"seekable-ranges"}.getElems:
        p.buffered.add (r{"start"}.getFloat, r{"end"}.getFloat)
      if j{"cache-duration"} != nil: p.cacheAhead = j{"cache-duration"}.getFloat
  of pPausedForCache: p.buffering = b
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
        let turned = j{"rotate"}.getInt mod 180 != 0
        p.pixelW = j{if turned: "h" else: "w"}.getInt
        p.pixelH = j{if turned: "w" else: "h"}.getInt
      else:
        p.videoW = 0
        p.videoH = 0
        p.pixelW = 0
        p.pixelH = 0

proc addSameNameAudio(p: Player) =
  ## A video's audio files of the same name (song.mkv + song.flac) join as
  ## external tracks, the first one selected. Audio-only files, cover art
  ## included, pick up nothing.
  if p.path.len == 0 or p.path.contains("://"): return
  var video = false
  for i in 0 ..< p.h.getInt("track-list/count"):
    let t = "track-list/" & $i & "/"
    if p.h.getStr(t & "type") == "video" and not p.h.getFlag(t & "albumart") and
       not p.h.getFlag(t & "external"):
      video = true
  if not video: return
  let (dir, name, _) = p.path.splitFile
  var found: seq[string]
  try:
    for kind, f in walkDir(dir):
      if kind notin {pcFile, pcLinkToFile} or f == p.path: continue
      let (_, n, ext) = f.splitFile
      if n == name and ext.toLowerAscii.strip(chars = {'.'}) in AudioExtensions:
        found.add f
  except OSError: return
  found.sort()
  for i, f in found:
    p.h.command("audio-add", f, if i == 0: "select" else: "auto", f.extractFilename)

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
      elif id in MirrorBase ..< MirrorBase + MirroredProps.len:
        let e = cast[ptr MpvEventProperty](ev.data)
        p.props[MirroredProps[id - MirrorBase]] =
          if e.data == nil or e.format != fmtString: "" else: $cast[ptr cstring](e.data)[]
    of evFileLoaded:
      # Read here rather than in load: the previous file may still show a
      # frame or two until mpv switches over.
      if not p.hidden:
        p.sphere = detectSphere(p.path)
        p.addSameNameAudio()
      p.loaded = true
      p.opening = false
      p.justLoaded = true
      p.loadError = ""
      p.eofHandled = false
    of evEndFile:
      let e = cast[ptr MpvEventEndFile](ev.data)
      if e.reason == efError:
        p.loadError = $mpv_error_string(e.error)
        p.loaded = false
        p.opening = false
    of evPlaybackRestart: inc p.restarts
    of evCommandReply:
      if ev.replyUserdata == ExpandReply and ev.error >= 0:
        let n = cast[ptr MpvNode](ev.data)
        if n.format == fmtString: p.expanded.add $n.u.str
    of evLogMessage:
      type LogMsg = object
        prefix, level, text: cstring
      let m = cast[ptr LogMsg](ev.data)
      stderr.write "[mpv/", $m.prefix, "] ", $m.text
    else: discard

proc load*(p: Player, path: string, start = 0.0, threadless = false, opts = "") =
  ## Opens path, starting at `start` seconds when given, with mpv's per-file
  ## options `opts` ("name=value,...").
  p.threadless = threadless
  p.h.setProp("demuxer-thread", if threadless: "no" else: "yes")
  p.path = path
  p.stopped = false
  p.eofReached = false
  p.eofHandled = false
  p.timePos = start
  p.duration = 0
  p.loadError = ""
  p.opening = true
  p.buffered.setLen 0
  p.cacheAhead = -1
  p.buffering = false
  p.setBackward(false)
  var o = opts
  if start > 0:
    o = "start=" & formatFloat(start, ffDecimal, 3) & (if o.len > 0: "," & o else: "")
  if o.len > 0: p.h.commandAsync("loadfile", path, "replace", "-1", o)
  else: p.h.commandAsync("loadfile", path, "replace")
  p.h.setProp("pause", false)

proc reopen*(p: Player, threadless: bool) =
  ## Opens the file again where it is, paused or playing as it was, for
  ## options mpv reads only on opening one. Its added tracks are gone then.
  p.threadless = threadless
  p.h.setProp("demuxer-thread", if threadless: "no" else: "yes")
  p.eofReached = false
  p.eofHandled = false
  inc p.jumps
  p.h.commandAsync("loadfile", p.path, "replace", "-1",
    "start=" & formatFloat(p.timePos, ffDecimal, 6))

proc externalFiles*(p: Player): seq[string] =
  ## The added tracks' files as mpv has them now (p.tracks may lag behind).
  for i in 0 ..< p.h.getInt("track-list/count"):
    let t = "track-list/" & $i & "/"
    if p.h.getFlag(t & "external"): result.add p.h.getStr(t & "external-filename")

proc close*(p: Player) =
  p.h.commandAsync("stop")
  p.path = ""
  p.loaded = false
  p.opening = false
  p.stopped = false
  p.buffered.setLen 0
  p.cacheAhead = -1
  p.buffering = false
  p.sphere = SphereInfo()
  p.tracks.setLen 0
  p.chapters.setLen 0
  p.videoW = 0
  p.videoH = 0
  p.pixelW = 0
  p.pixelH = 0
  p.timePos = 0
  p.duration = 0

proc hasVideo*(p: Player): bool =
  p.loaded and p.videoW > 0 and p.videoH > 0

proc hasRealVideo*(p: Player): bool =
  ## A selected video track that is not just cover art.
  if not p.hasVideo: return false
  for t in p.tracks:
    if t.kind == "video" and t.selected and not t.albumArt: return true

proc isSpherical*(p: Player): bool =
  ## Shown as a 360° view: equirectangular metadata on a real video track.
  p.sphere.is360 and p.hasRealVideo

proc playing*(p: Player): bool = p.loaded and not p.paused and not p.stopped

proc togglePause*(p: Player) =
  if not p.loaded: return
  if p.stopped:
    p.stopped = false
    p.h.setProp("pause", false)
  elif p.eofReached:
    inc p.jumps
    p.h.commandAsync("seek", "0", "absolute")
    p.h.setProp("pause", false)
  else:
    p.h.setProp("pause", not p.paused)

proc play*(p: Player) =
  if p.loaded:
    p.stopped = false
    if p.eofReached:
      inc p.jumps
      p.h.commandAsync("seek", "0", "absolute")
    p.h.setProp("pause", false)

proc pause*(p: Player) =
  if p.loaded: p.h.setProp("pause", true)

proc stop*(p: Player) =
  if not p.loaded: return
  inc p.jumps
  p.setBackward(false)
  p.h.setProp("pause", true)
  p.h.commandAsync("seek", "0", "absolute", "exact")
  p.stopped = true

proc seek*(p: Player, t: float, exact = true) =
  if not p.loaded: return
  inc p.jumps
  p.h.commandAsync("seek", formatFloat(max(t, 0), ffDecimal, 3), "absolute",
    if exact: "exact" else: "keyframes")

proc seekRelative*(p: Player, d: float) =
  inc p.jumps
  p.h.commandAsync("seek", $d, "relative")

proc seekPercent*(p: Player, percent: float) =
  inc p.jumps
  p.h.commandAsync("seek", $percent, "absolute-percent")

proc frameStep*(p: Player, forward: bool) =
  inc p.jumps
  p.h.commandAsync(if forward: "frame-step" else: "frame-back-step")

proc osd*(p: Player, msg: string) =
  p.h.commandAsync("show-text", msg, "1500")

proc expandText*(p: Player, text: string) =
  ## Expands mpv ${property} references as the OSD would show them; the
  ## result lands in `expanded` once mpv gets to it (after earlier requests).
  var args = ["expand-text".cstring, text.cstring, nil]
  discard mpv_command_async(p.h, ExpandReply, args[0].addr)

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

# --- detached OSD -----------------------------------------------------------

type
  OsdLayer* = ref object
    ## A video-less mpv that only draws OSD, onto a transparent target, so
    ## the OSD can stay put while the video is panned, rotated and scaled.
    h*: MpvHandle
    render*: MpvRenderContext
    target*: VideoTarget

proc newOsdLayer*(): OsdLayer =
  let h = mpv_create()
  if h == nil: raise newException(MpvError, "mpv_create failed")
  result = OsdLayer(h: h)
  h.setOpt("config", "no")
  h.setOpt("vo", "libmpv")
  h.setOpt("idle", "yes")
  h.setOpt("gpu-hwdec-interop", "no")  # nothing to decode
  h.setOpt("audio", "no")
  h.setOpt("terminal", "no")
  h.setOpt("input-default-bindings", "no")
  h.setOpt("input-vo-keyboard", "no")
  h.setOpt("osc", "no")
  h.setOpt("load-scripts", "no")
  h.setOpt("background", "color")
  h.setOpt("background-color", "#00000000")
  h.setOpt("osd-level", "0")
  check mpv_initialize(h), "osd mpv_initialize"

proc initRender*(o: OsdLayer) =
  o.render = createRenderContext(o.h, blockForTargetTime = false)
  mpv_render_context_set_update_callback(o.render, onOsdUpdate, nil)
  # Only now: a VO (which keeps the OSD while idle) opened before the render
  # context exists fails for good.
  o.h.setProp("force-window", "yes")

# --- thumbnail preview ------------------------------------------------------

proc newPreview*(): Preview =
  result = Preview(wanted: -1, shown: -1)
  let h = mpv_create()
  if h == nil: return nil
  result.h = h
  h.setOpt("config", "no")
  h.setOpt("vo", "libmpv")
  h.setOpt("hwdec", "auto-safe")
  h.setOpt("vd-lavc-dr", "no")         # see newPlayer
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
    pv.h.commandAsync("loadfile", path, "replace", "-1",
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
  pv.h.commandAsync("stop")
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
