## Persistent settings, stored at ~/.config/majestic-media-player/config.json.

import std/[os, strutils, tables, sequtils, math, algorithm]
import jsony, crunchy/sha256

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
    showRunLog*: bool = false
    seededPresets*: seq[string]    # preset command lines already offered once
    runLogHeight*: float = 200     # pixels, changed by dragging its bottom edge
    showOsd*: bool = true
    frameMode*: FrameMode = fmTouchInside
    aspectOverride*: string = ""   # "" = original, else "4:3", "16:9", ...
    preserveAspect*: bool = true
    onTop*: OnTopMode = otDefault
    repeatForever*: bool = false
    repeatMode*: RepeatMode = rmPlaylist
    # Options > Player
    uiScale*: float = 100          # percent
    openMode*: OpenMode = omSamePlayer
    osdTimestamp*: bool = false
    showMillis*: bool = false      # timestamps as HH:MM:SS.mmm
    showRemaining*: bool = false   # status/OSD time as -remaining / duration
    showAllShortcuts*: bool = false  # status bar hints include view toggles and grab/rotate/scale
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
    keepDisplayOn*: bool = true    # inhibit screen blanking while video plays
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

  BookmarkEntry* = object
    path*: string                 ## where the file was last seen, for people
    marks*: seq[Bookmark]         ## sorted by time

  BookmarkEntryJson = object
    path: string
    marks: seq[Bookmark]

  Bookmarks* = OrderedTable[string, BookmarkEntry]  ## mediaKey -> entry

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

proc parseHook*(s: string, i: var int, v: var BookmarkEntry) =
  ## Entries, or the bare bookmark lists that older versions wrote (keyed by
  ## path, so the path is filled in from the key once loaded).
  eatSpace(s, i)
  if i < s.len and s[i] == '{':
    var o: BookmarkEntryJson
    parseHook(s, i, o)
    v = BookmarkEntry(path: o.path, marks: o.marks)
  else:
    v = BookmarkEntry()
    parseHook(s, i, v.marks)

proc mediaKey*(path: string): string =
  ## Identifies a media file by its contents, so bookmarks follow it when it
  ## is moved or renamed: its size and a SHA-256 of its first and last 64 KiB
  ## (which mpv reads anyway, so they're usually cached). Streams and
  ## unreadable files fall back to their path.
  const chunk = 65536
  if path.len == 0 or path.contains("://"): return path
  var f: File
  if not f.open(path): return path
  defer: f.close()
  try:
    let size = f.getFileSize
    var data = newString(min(size, 2 * chunk))
    if size <= 2 * chunk:
      if data.len > 0 and f.readBuffer(data[0].addr, data.len) != data.len: return path
    else:
      for n, pos in [0'i64, size - chunk]:
        f.setFilePos(pos)
        if f.readBuffer(data[n * chunk].addr, chunk) != chunk: return path
    let digest = sha256(data)
    result = toHex(size, 12).toLowerAscii & "-"
    for b in digest[0 ..< 16]: result.add toHex(b, 2).toLowerAscii
  except CatchableError:
    result = path

# mediaKey on a thread of its own: a cold file on a spinning or network disk
# can take a few hundred ms to read.
var keyRequests: Channel[string]
var keyResults: Channel[(string, string)]
var keyWorker: Thread[void]

proc keyLoop() {.thread.} =
  while true:
    let path = keyRequests.recv()
    keyResults.send((path, mediaKey(path)))

proc requestMediaKey*(path: string) =
  ## Works out path's mediaKey in the background; see takeMediaKey.
  if not keyWorker.running:
    keyRequests.open()
    keyResults.open()
    createThread(keyWorker, keyLoop)
  keyRequests.send(path)

proc takeMediaKey*(): tuple[ok: bool, path, key: string] =
  ## A finished requestMediaKey, if any: the path and its key.
  if not keyWorker.running: return
  let (ok, r) = keyResults.tryRecv()
  if ok: result = (true, r[0], r[1])

proc label*(b: Bookmark, i: int): string =
  if b.name.len > 0: b.name else: "Bookmark " & $(i + 1)

proc toSimpleChapters*(marks: seq[Bookmark]): string =
  ## Matroska simple-chapter format (OGM style), which mkvmerge, mkvpropedit
  ## --chapters and mpv --chapters-file read:
  ##   CHAPTER01=00:51:32.881
  ##   CHAPTER01NAME=Gun Kata 1
  let digits = max(2, len($marks.len))
  for i, b in marks:
    let n = intToStr(i + 1, digits)
    let ms = max(0, int(round(b.time * 1000)))
    let s = ms div 1000
    result.add "CHAPTER" & n & "=" & intToStr(s div 3600, 2) & ":" &
      intToStr((s mod 3600) div 60, 2) & ":" & intToStr(s mod 60, 2) & "." &
      intToStr(ms mod 1000, 3) & "\n"
    result.add "CHAPTER" & n & "NAME=" & b.label(i) & "\n"

proc parseSimpleChapters*(text: string): seq[Bookmark] =
  ## Reads toSimpleChapters' format, sorted by time. Lines that aren't
  ## chapters are skipped; names like "Bookmark 3" (the default label) come
  ## back as unnamed. Raises ValueError when no chapter is found.
  var byNum: OrderedTable[string, Bookmark]
  for raw in text.splitLines:
    let line = (if raw.startsWith("\xEF\xBB\xBF"): raw[3 .. ^1] else: raw).strip
    let eq = line.find('=')
    if eq < 0 or not line.toUpperAscii.startsWith("CHAPTER"): continue
    var key = line[7 ..< eq].toUpperAscii
    let value = line[eq + 1 .. ^1]
    if key.endsWith("NAME"):
      key.setLen key.len - 4
      if key.len > 0 and key.allCharsInSet(Digits):
        byNum.mgetOrPut(key.strip(trailing = false, chars = {'0'}), Bookmark()).name = value.strip
    elif key.len > 0 and key.allCharsInSet(Digits):
      let parts = value.strip.split(':')
      if parts.len != 3: continue
      try:
        let t = float(parseInt(parts[0]) * 3600 + parseInt(parts[1]) * 60) + parseFloat(parts[2])
        byNum.mgetOrPut(key.strip(trailing = false, chars = {'0'}), Bookmark()).time = t
      except ValueError: discard
  for k, b in byNum: result.add b
  if result.len == 0: raise newException(ValueError, "no chapters found")
  result.sort(proc (x, y: Bookmark): int = cmp(x.time, y.time))
  for i, b in result.mpairs:
    if b.name == "Bookmark " & $(i + 1): b.name = ""

proc bookmarksPath(): string = configDir() / "bookmarks.json"

proc loadBookmarks*(): Bookmarks =
  let path = bookmarksPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(Bookmarks)
      for k, e in result.mpairs:
        if e.path.len == 0: e.path = k
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(b: Bookmarks) =
  let path = bookmarksPath()
  try:
    createDir(path.parentDir)
    writeFile(path, b.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

# --- command lines (Run menu) --------------------------------------------------

type
  CardKind* = enum
    ckValue = "value"             ## content is the text itself
    ckReference = "reference"     ## content is a key: "file" or "bookmark:N"

  CmdPart* = object
    ## Literal text, or a card: a variable placed in the command line.
    text*: string
    card*: bool
    name*: string
    kind*: CardKind
    content*: string

  CommandLine* = object
    title*: string
    parts*: seq[CmdPart]

proc commandLinesPath(): string = configDir() / "commandlines.json"

proc loadCommandLines*(): seq[CommandLine] =
  let path = commandLinesPath()
  if fileExists(path):
    try:
      result = readFile(path).fromJson(seq[CommandLine])
    except CatchableError as e:
      stderr.writeLine "config: ignoring unreadable ", path, ": ", e.msg

proc save*(cmds: seq[CommandLine]) =
  let path = commandLinesPath()
  try:
    createDir(path.parentDir)
    writeFile(path, cmds.toJson)
  except CatchableError as e:
    stderr.writeLine "config: cannot save ", path, ": ", e.msg

const PresetCommandLines = staticRead("../assets/presets/commandlines.json")

proc seedPresets*(c: var Config): bool =
  ## Adds the shipped command lines the user hasn't been offered yet, each
  ## once, so deleting one sticks. True when c changed and needs saving.
  var cmds = loadCommandLines()
  var added = false
  for p in PresetCommandLines.fromJson(seq[CommandLine]):
    if p.title in c.seededPresets: continue
    c.seededPresets.add p.title
    result = true
    if not cmds.anyIt(it.title == p.title):
      cmds.add p
      added = true
  if added: cmds.save()

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
