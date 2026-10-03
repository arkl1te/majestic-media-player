## Persistent settings, stored at ~/.config/majestic-media-player/config.json.

import std/[os, strutils]
import jsony

type
  FrameMode* = enum
    fmHalf, fmFull, fmDouble, fmStretch, fmTouchInside

  OnTopMode* = enum
    otDefault, otAlways, otWhilePlaying, otWhilePlayingVideo

  RepeatMode* = enum
    rmFile, rmPlaylist

  AfterPlayback* = enum
    apNothing, apNextInFolder, apMonitorOff, apExit, apSleep, apHibernate,
    apShutdown, apLogOff, apLock

  Config* = object
    recentFiles*: seq[string]
    lastDir*: string
    volume*: float = 100
    muted*: bool
    showSeekBar*: bool = true
    showControls*: bool = true
    showStatus*: bool = true
    showPlaylist*: bool = false
    showOsd*: bool = true
    frameMode*: FrameMode = fmTouchInside
    aspectOverride*: string = ""   # "" = original, else "4:3", "16:9", ...
    preserveAspect*: bool = true
    onTop*: OnTopMode = otDefault
    repeatForever*: bool = false
    repeatMode*: RepeatMode = rmPlaylist
    # Step sizes (editable in Options).
    panStep*: float = 10           # pixels
    rotateStep*: float = 5         # degrees
    sizeStep*: float = 5           # percent
    rateStep*: float = 0.25
    seekStep*: float = 5           # seconds
    seekPreview*: bool = true
    snapToChapters*: bool = true
    snapDistance*: float = 8       # pixels
    autoFitWindow*: bool = true

const MaxRecent = 15

proc newHook*(c: var Config) =
  c = Config()

proc configPath(): string =
  getConfigDir() / "majestic-media-player" / "config.json"

proc loadConfig*(): Config =
  result = Config()
  let path = configPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(Config)
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(c: Config) =
  let path = configPath()
  try:
    createDir(path.parentDir)
    writeFile(path, c.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

proc addRecent*(c: var Config, path: string) =
  let i = c.recentFiles.find(path)
  if i >= 0: c.recentFiles.delete(i)
  c.recentFiles.insert(path, 0)
  if c.recentFiles.len > MaxRecent:
    c.recentFiles.setLen(MaxRecent)

const MediaExtensions* = [
  "mkv", "mp4", "m4v", "webm", "avi", "mov", "wmv", "flv", "mpg", "mpeg", "ts",
  "m2ts", "mts", "3gp", "ogv", "vob", "rmvb", "divx", "f4v", "asf",
  "mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "alac", "ape",
  "wv", "mka", "aiff", "dts", "ac3"]

const SubtitleExtensions* = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi"]

proc isMediaFile*(path: string): bool =
  path.splitFile.ext.toLowerAscii.strip(chars = {'.'}) in MediaExtensions
