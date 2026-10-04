## Persistent settings, stored at ~/.config/majestic-media-player/config.json.

import std/[os, strutils, tables]
import jsony

type
  FrameMode* = enum
    fmHalf, fmFull, fmDouble, fmStretch, fmTouchInside

  OnTopMode* = enum
    otDefault, otAlways, otWhilePlaying, otWhilePlayingVideo

  RepeatMode* = enum
    rmFile, rmPlaylist

  OpenMode* = enum
    omSamePlayer, omNewPlayer

  AfterPlayback* = enum
    apNothing, apNextInFolder, apMonitorOff, apExit, apSleep, apHibernate,
    apShutdown, apLogOff, apLock

  SavedTransform* = object
    ## Grab, rotate & scale state, kept when "Remember last grab, rotation
    ## and scale" is on.
    panX*, panY*, rotation*: float
    zoom*: float = 1
    scaleX*: float = 1
    scaleY*: float = 1

  Config* = object
    recentFiles*: seq[string]
    lastDir*: string
    volume*: float = 100
    muted*: bool
    showSeekBar*: bool = true
    showControls*: bool = true
    showStatus*: bool = true
    showPlaylist*: bool = false
    playlistWidth*: float = 300    # pixels, changed by dragging its left edge
    playlistShowSize*: bool = false
    playlistShowDimensions*: bool = false
    showOsd*: bool = true
    frameMode*: FrameMode = fmTouchInside
    aspectOverride*: string = ""   # "" = original, else "4:3", "16:9", ...
    preserveAspect*: bool = true
    onTop*: OnTopMode = otDefault
    repeatForever*: bool = false
    repeatMode*: RepeatMode = rmPlaylist
    # Options > Player
    openMode*: OpenMode = omSamePlayer
    osdTimestamp*: bool = false
    showMillis*: bool = false      # timestamps as HH:MM:SS.mmm
    autoFitWindow*: bool = true
    rememberTime*: bool = false
    rememberWindowPos*: bool = false
    rememberWindowSize*: bool = false
    rememberTransform*: bool = false
    rememberPlaylist*: bool = false
    bookmarksAsChapters*: bool = false  # chapter steps also stop at bookmarks
    titleFullPath*: bool = false
    titleUseMediaTitle*: bool = false
    # Options > Playback
    rateStep*: float = 0.25
    seekStep*: float = 5           # seconds
    volumeStep*: float = 5
    seekPreview*: bool = true
    snapWithShift*: bool = false   # off: snap unless Shift; on: only with Shift
    snapDistance*: float = 8       # pixels
    subLangs*: string = ""         # "eng, jpn": preferred subtitle languages
    audioLangs*: string = ""
    # Options > Subtitles
    subDelay*: float = 0           # milliseconds
    subPaths*: string = ""         # extra subtitle folders, ';'-separated
    # Options > Miscellaneous
    panStep*: float = 10           # pixels
    rotateStep*: float = 5         # degrees
    sizeStep*: float = 5           # percent
    # Remembered state
    windowX*, windowY*: int
    windowW*, windowH*: int        # 0 = never saved
    transform*: SavedTransform
    playlist*: seq[string]         # kept when "Remember playlist" is on
    playlistIndex*: int = -1

const MaxRecent = 15

proc newHook*(c: var Config) =
  c = Config()

proc configDir(): string = getConfigDir() / "majestic-media-player"

proc configPath(): string = configDir() / "config.json"

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

# --- remembered playback positions -------------------------------------------

type Positions* = OrderedTable[string, float]

const MaxPositions = 500

proc positionsPath(): string = configDir() / "positions.json"

proc loadPositions*(): Positions =
  let path = positionsPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(Positions)
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(p: Positions) =
  let path = positionsPath()
  try:
    createDir(path.parentDir)
    writeFile(path, p.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

proc remember*(p: var Positions, path: string, t: float) =
  ## Most recent last, so the oldest entries go first when trimming.
  p.del(path)
  p[path] = t
  while p.len > MaxPositions:
    for k in p.keys:
      p.del(k)
      break

# --- bookmarks ---------------------------------------------------------------

type
  Bookmark* = object
    time*: float
    name*: string                 ## "" shows as "Bookmark N"

  BookmarkJson = object
    time: float
    name: string

  Bookmarks* = OrderedTable[string, seq[Bookmark]]  ## path -> sorted by time

proc parseHook*(s: string, i: var int, v: var Bookmark) =
  ## Objects, or the bare times that older versions wrote.
  eatSpace(s, i)
  if i < s.len and s[i] == '{':
    var o: BookmarkJson
    parseHook(s, i, o)
    v = Bookmark(time: o.time, name: o.name)
  else:
    v = Bookmark()
    parseHook(s, i, v.time)

proc bookmarksPath(): string = configDir() / "bookmarks.json"

proc loadBookmarks*(): Bookmarks =
  let path = bookmarksPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(Bookmarks)
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(b: Bookmarks) =
  let path = bookmarksPath()
  try:
    createDir(path.parentDir)
    writeFile(path, b.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

const VideoExtensions* = [
  "mkv", "mp4", "m4v", "webm", "avi", "mov", "wmv", "flv", "mpg", "mpeg", "ts",
  "m2ts", "mts", "3gp", "ogv", "vob", "rmvb", "divx", "f4v", "asf"]

const AudioExtensions* = [
  "mp3", "flac", "ogg", "opus", "m4a", "aac", "wav", "wma", "alac", "ape",
  "wv", "mka", "aiff", "dts", "ac3"]

const MediaExtensions* = @VideoExtensions & @AudioExtensions

const SubtitleExtensions* = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx", "smi"]

proc isMediaFile*(path: string): bool =
  path.splitFile.ext.toLowerAscii.strip(chars = {'.'}) in MediaExtensions
