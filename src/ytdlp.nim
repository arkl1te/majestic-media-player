## yt-dlp: finds it (on PATH, else the copy the player installed) and runs
## it in the background: downloading a link before opening it, checking for
## a newer release, updating itself (yt-dlp -U) and installing its standalone
## build, which can then keep itself up to date with -U too.

import std/[os, osproc, json, strutils, strformat, times, algorithm]
import runlog

const
  YtdlSubLangs* = "all,-live_chat"
    ## Every real subtitle (a live stream's chat replay isn't one). Automatic
    ## captions come apart (captions): asking for those here would bring the
    ## machine translations into every language, keyed like real subtitles.
  ReleaseUrl = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/"
  LatestApi = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"

type
  YtTask* = enum
    ytDownload  ## a link to a file, before opening it
    ytVersion   ## the installed version
    ytLatest    ## the latest release's version
    ytUpdate    ## yt-dlp -U
    ytInstall   ## the standalone build, to managedPath
    ytCaptions  ## a link's automatic captions

  YtJob* = ref object
    task*: YtTask
    url*: string              ## ytDownload: the link
    p: Process                ## nil once finished
    partial: string           ## output after the last line break
    lines*: seq[string]       ## output lines, stdout and stderr together
    code*: int = -1           ## exit code once finished; -1 while running
    progress*: float = -1     ## percent done, as last printed
    file*: string             ## ytDownload: the file it made
    parts*: seq[string]       ## ytDownload: and the streams to add to it,
                              ## when it couldn't merge them (no ffmpeg)
    chapters*: JsonNode       ## ytDownload: its chapters, as yt-dlp lists them
    data: string              ## ytCaptions: what it printed
    dest: string              ## ytInstall: where it goes

proc managedPath*(): string =
  ## Where the player installs yt-dlp: on PATH for most Linux setups.
  when defined(windows): getEnv("LOCALAPPDATA") / "Programs" / "yt-dlp" / "yt-dlp.exe"
  else: getHomeDir() / ".local" / "bin" / "yt-dlp"

proc findYtdlp*(): string =
  ## The yt-dlp the player installed, once it has (a launcher's PATH may lack
  ## ~/.local/bin, or have a package manager's yt-dlp first, which -U can't
  ## update); else the one on PATH; "" when there is none.
  if fileExists(managedPath()): managedPath() else: findExe("yt-dlp")

proc downloadDir*(): string = getCacheDir("majestic-media-player") / "yt-dlp"

proc pruneDownloads*(maxAge = 1.0) =
  ## Deletes downloads older than maxAge days.
  let cut = getTime() - initDuration(seconds = int(maxAge * 86400))
  try:
    for kind, f in walkDir(downloadDir()):
      if kind == pcFile and getLastModificationTime(f) < cut:
        try: removeFile(f)
        except OSError: discard
  except OSError: discard

proc running*(j: YtJob): bool = j != nil and j.p != nil

proc start(task: YtTask, exe: string, args: openArray[string], url = ""): YtJob =
  result = YtJob(task: task, url: url)
  try:
    result.p = startProcess(exe, args = args,
      options = {poUsePath, poStdErrToStdOut, poDaemon})
    result.p.nonBlocking()
  except OSError as e:
    result.lines.add e.msg
    result.code = 127

proc download*(exe, url: string): YtJob =
  ## Downloads url, with its subtitles, into downloadDir.
  try: createDir(downloadDir())
  except OSError: discard
  # Without ffmpeg, separate video and audio streams can't be put together:
  # one file that has both, else they stay apart (and the download fails).
  let format = if findExe("ffmpeg").len > 0: @[] else: @["-f", "b/bv*+ba"]
  start(ytDownload, exe, format & @["--newline", "--progress", "--no-playlist", "--no-mtime",
    "--write-subs", "--sub-langs", YtdlSubLangs,
    "--sub-format", "ass/srt/best",
    "--progress-template", "download:MMPPROG %(progress._percent_str)s",
    "--print", "after_move:MMPFILE %(filepath)s",
    "--print", "after_move:MMPCHAP %(chapters)j",
    "-P", downloadDir(), "-o", "%(title).150B [%(id)s].%(ext)s", "--", url], url)

proc captions*(exe, url: string): YtJob =
  start(ytCaptions, exe, ["--no-warnings", "--no-playlist", "-O",
    "MMPCAPS %(automatic_captions)j", "--", url], url)

proc originalCaptions*(j: YtJob): seq[tuple[url, title, lang: string]] =
  ## ytCaptions: the captions in the video's own language (YouTube keys them
  ## "<lang>-orig"; the others are machine translations of them), as srt,
  ## else vtt, when there is one.
  let all = try: parseJson(j.data) except CatchableError: return
  if all.kind != JObject: return
  for key, formats in all:
    if not key.endsWith("-orig") or formats.kind != JArray or formats.len == 0: continue
    var pick = formats[0]
    for ext in ["vtt", "srt"]:  # the later wins
      for f in formats:
        if f{"ext"}.getStr == ext: pick = f
    result.add (pick{"url"}.getStr, pick{"name"}.getStr(key) & " (automatic)",
      key[0 ..< key.len - 5])

proc version*(exe: string): YtJob = start(ytVersion, exe, ["--version"])

proc latest*(): YtJob =
  start(ytLatest, "curl", ["-fsSL", "--max-time", "15",
    "-H", "Accept: application/vnd.github+json", LatestApi])

proc update*(exe: string): YtJob = start(ytUpdate, exe, ["-U"])

proc install*(): YtJob =
  ## Fetches the standalone build into managedPath.
  let name =
    when defined(windows): "yt-dlp.exe"
    elif defined(macosx): "yt-dlp_macos"
    elif defined(arm64): "yt-dlp_linux_aarch64"
    else: "yt-dlp_linux"
  let dest = managedPath()
  try: createDir(dest.parentDir)
  except OSError: discard
  result = start(ytInstall, "curl", ["-fL", "--retry", "2", "-#",
    "-o", dest & ".part", ReleaseUrl & name])
  result.dest = dest

proc percentIn(s: string): float =
  ## The number before the last '%' in s, else -1.
  let e = s.rfind('%')
  if e < 0: return -1
  var b = e
  while b > 0 and s[b - 1] in {'0' .. '9', '.'}: dec b
  try: parseFloat(s[b ..< e]) except ValueError: -1

proc addLine(j: YtJob, line: string) =
  let l = line.strip
  if l.len == 0: return
  let pc = percentIn(l)
  if l.startsWith("MMPPROG ") or (j.task == ytInstall and l.startsWith("#")):
    if pc >= 0: j.progress = pc
  elif l.startsWith("MMPFILE "): j.file = l[8 .. ^1]
  elif l.startsWith("MMPCAPS "): j.data = l[8 .. ^1]
  elif l.startsWith("MMPCHAP "):
    try: j.chapters = parseJson(l[8 .. ^1])
    except CatchableError: discard
  else: j.lines.add l

proc read(j: YtJob) =
  for ch in j.p.readPipe():
    if ch in {'\n', '\r'}:
      j.addLine(j.partial)
      j.partial.setLen 0
    else: j.partial.add ch

proc finish(j: YtJob) =
  if j.task == ytInstall and j.code == 0:
    try:
      moveFile(j.dest & ".part", j.dest)
      when not defined(windows):
        j.dest.setFilePermissions(j.dest.getFilePermissions +
          {fpUserExec, fpGroupExec, fpOthersExec})
    except OSError as e:
      j.lines.add e.msg
      j.code = 1
  elif j.task == ytInstall:
    try: removeFile(j.dest & ".part")
    except OSError: discard
  if j.task == ytDownload and j.code == 0 and not fileExists(j.file):
    # Unmerged: "<name>.f<format>.<ext>" for each stream; the largest
    # (the video) opens, the rest join it.
    let (dir, name, _) = j.file.splitFile
    var parts: seq[(int64, string)]
    try:
      for kind, f in walkDir(dir):
        if kind == pcFile and f.extractFilename.startsWith(name & ".f") and
           not f.endsWith(".part"):
          parts.add (getFileSize(f), f)
    except OSError: discard
    if parts.len == 0:
      j.lines.add "ERROR: no file was downloaded"
      j.code = 1
    else:
      parts.sort(Descending)
      j.file = parts[0][1]
      for p in parts[1 .. ^1]: j.parts.add p[1]

proc poll*(j: YtJob): bool =
  ## Reads what it printed and notes when it exits. True when anything changed.
  if not j.running: return
  let before = (j.lines.len, j.progress)
  j.read()
  let code = j.p.peekExitCode
  if code != -1:
    j.read()
    j.addLine(j.partial)
    j.p.close()
    j.p = nil
    j.code = code
    j.finish()
    return true
  (j.lines.len, j.progress) != before

proc stop*(j: YtJob) =
  if not j.running: return
  try:
    j.p.terminate()
    discard j.p.waitForExit(1000)
    j.p.close()
  except OSError: discard
  j.p = nil
  j.code = 130

proc chaptersFile*(j: YtJob): string =
  ## ytDownload: writes its chapters next to its file, as ffmetadata (what
  ## mpv's chapters-file reads), and returns that file; "" when none.
  if j.chapters == nil or j.chapters.kind != JArray or j.chapters.len == 0: return
  proc esc(s: string): string =
    for c in s:
      if c in {'=', ';', '#', '\\', '\n'}: result.add '\\'
      result.add c
  var text = ";FFMETADATA1\n"
  for c in j.chapters:
    let start = int(c{"start_time"}.getFloat * 1000)
    let stop = max(int(c{"end_time"}.getFloat * 1000), start)
    let title = esc(c{"title"}.getStr)
    text.add &"[CHAPTER]\nTIMEBASE=1/1000\nSTART={start}\nEND={stop}\ntitle={title}\n"
  result = j.file.changeFileExt("ffmetadata")
  try: writeFile(result, text)
  except IOError, OSError: result = ""

proc errorText*(j: YtJob): string =
  ## What went wrong: its last ERROR line, else its last line.
  for i in countdown(j.lines.high, 0):
    if j.lines[i].startsWith("ERROR:"): return j.lines[i][6 .. ^1].strip
  if j.lines.len > 0: j.lines[^1] else: "exit code " & $j.code

proc versionText*(j: YtJob): string =
  ## ytVersion: the installed version; ytLatest: the latest release's.
  if j.code != 0: return
  case j.task
  of ytVersion:
    if j.lines.len > 0: j.lines[^1] else: ""
  of ytLatest:
    try: parseJson(j.lines.join("\n")){"tag_name"}.getStr
    except CatchableError: ""
  else: ""

proc newer*(latest, current: string): bool =
  ## latest is a later release than current ("2026.08.19" vs "2026.06.09";
  ## nightlies add a fourth part).
  if latest.len == 0 or current.len == 0: return false
  let l = latest.split('.')
  let c = current.split('.')
  for i in 0 ..< max(l.len, c.len):
    let x = (if i < l.len: (try: parseInt(l[i]) except ValueError: 0) else: 0)
    let y = (if i < c.len: (try: parseInt(c[i]) except ValueError: 0) else: 0)
    if x != y: return x > y
  false
