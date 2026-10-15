## yt-dlp: finds it (on PATH, else the copy the player installed) and runs
## it in the background: looking up a link's captions and subtitles, checking
## for a newer release, updating itself (yt-dlp -U) and installing its standalone
## build, which can then keep itself up to date with -U too.

import std/[os, osproc, json, strutils, algorithm, sequtils]
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
    ytVersion   ## the installed version
    ytLatest    ## the latest release's version
    ytUpdate    ## yt-dlp -U
    ytInstall   ## the standalone build, to managedPath
    ytCaptions  ## a link's automatic captions
    ytSubs      ## a link's subtitles, as files
    ytPlaylist  ## a playlist's videos, as they're found
    ytDownload  ## a link's video, whole, to a file (File > Save)

  YtJob* = ref object
    task*: YtTask
    url*: string              ## ytCaptions, ytSubs: the link
    p: Process                ## nil once finished
    partial: string           ## output after the last line break
    lines*: seq[string]       ## output lines, stdout and stderr together
    code*: int = -1           ## exit code once finished; -1 while running
    progress*: float = -1     ## percent done, as last printed
    bytes*, total*: int64     ## ytDownload: bytes downloaded, of how many (0: unknown)
    streamBase: int64         ## ytDownload: the streams downloaded before this one
    streamDone, streamTotal: int64  ## and this one's bytes, as last printed
    inStream: bool            ## ytDownload: a stream downloading (not a subtitle)
    step*, steps*: int        ## ytDownload: of video, audio and merging them,
                              ## which it's on (steps 0: one stream, no merging)
    data: string              ## ytCaptions: what it printed
    dest: string              ## ytInstall: where it goes; ytSubs: the start
                              ## of its files' paths
    subs*: seq[string]        ## ytSubs: the files it made
    items*: seq[tuple[id, title: string]]  ## ytPlaylist: the videos found so far

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

proc removeDownloads*() =
  ## Deletes what older versions downloaded (links now always stream).
  try: removeDir(downloadDir())
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

proc cookieArgs(cookies: string): seq[string] =
  if cookies.len > 0: @["--cookies-from-browser", cookies] else: @[]

proc captions*(exe, url: string, cookies = ""): YtJob =
  ## `cookies`: the browser to sign in with (cookieBrowsers), "" for none.
  start(ytCaptions, exe, @["--no-warnings", "--no-playlist"] & cookieArgs(cookies) &
    @["-O", "MMPCAPS %(automatic_captions)j", "--", url], url)

proc playlistItems*(exe, url: string, cookies = ""): YtJob =
  ## Lists a playlist's videos (url: the playlist's link, or a video's in it),
  ## each printed as soon as its page of the list comes in.
  start(ytPlaylist, exe, @["--no-warnings", "--flat-playlist", "--lazy-playlist",
    "--yes-playlist"] & cookieArgs(cookies) & @["-O", "MMPITEM %(id)s %(title)s", "--", url], url)

proc subtitles*(exe, url, dest: string, cookies = ""): YtJob =
  ## Downloads url's subtitles (not its video) as dest.<lang>.<ext>.
  try: createDir(dest.parentDir)
  except OSError: discard
  result = start(ytSubs, exe, @["--no-warnings", "--no-playlist", "--skip-download"] &
    cookieArgs(cookies) & @["--write-subs", "--sub-langs", YtdlSubLangs, "--sub-format",
    "ass/srt/best", "-P", dest.parentDir, "-o", dest.extractFilename & ".%(ext)s", "--", url], url)
  result.dest = dest

proc download*(exe, url, dir, name, ext: string, cookies = ""): YtJob =
  ## Downloads url whole (as the yt-dlp hook streams it: best video and
  ## audio) into dir as `name` (an output template), an `ext` (mkv, mp4) with
  ## its subtitles and chapters.
  start(ytDownload, exe, @["--no-playlist", "--newline", "--force-overwrites",
    "-f", "bv*+ba/b", "--merge-output-format", ext, "--remux-video", ext,
    "--embed-subs", "--sub-langs", YtdlSubLangs, "--embed-chapters", "--progress-template",
    "download:MMPPROG %(progress.downloaded_bytes)s %(progress.total_bytes)s " &
    "%(progress.total_bytes_estimate)s"] & cookieArgs(cookies) &
    @["-P", dir, "-o", name, "--", url], url)

proc downloadScript*(exe, url, dest: string, cookies = ""): string =
  ## Bash lines downloading url whole (as the yt-dlp hook streams it: best
  ## video and audio) to dest, an .mkv with its subtitles and chapters, for
  ## a command line to run on; the script exits when it fails.
  let args = @[exe, "--no-playlist", "--newline", "-f", "bv*+ba/b",
    "--merge-output-format", "mkv", "--remux-video", "mkv", "--embed-subs",
    "--sub-langs", YtdlSubLangs, "--embed-chapters", "--no-part"] & cookieArgs(cookies) &
    @["-o", dest, "--", url]
  args.mapIt(quoteShellPosix(it)).join(" ") & " || exit\n"

proc cookieBrowsers*(setting: string): seq[string] =
  ## The browsers whose cookies yt-dlp signs in with, in turn, for a link that
  ## asks to (age-restricted videos): "auto" tries each one installed, "none"
  ## none; anything else is a --cookies-from-browser value as it is
  ## ("brave", "firefox:~/.zen/profile"...).
  let s = setting.strip
  if s.len > 0 and s.toLowerAscii notin ["auto", "none"]: return @[s]
  if s.toLowerAscii == "none": return
  let home = getHomeDir()
  let dirs =
    when defined(windows):
      let local = getEnv("LOCALAPPDATA")
      let roaming = getEnv("APPDATA")
      @[("firefox", roaming / "Mozilla" / "Firefox"),
        ("brave", local / "BraveSoftware" / "Brave-Browser" / "User Data"),
        ("chrome", local / "Google" / "Chrome" / "User Data"),
        ("chromium", local / "Chromium" / "User Data"),
        ("edge", local / "Microsoft" / "Edge" / "User Data"),
        ("vivaldi", local / "Vivaldi" / "User Data"),
        ("opera", roaming / "Opera Software" / "Opera Stable")]
    elif defined(macosx):
      let sup = home / "Library" / "Application Support"
      @[("firefox", sup / "Firefox"), ("safari", home / "Library" / "Cookies"),
        ("brave", sup / "BraveSoftware" / "Brave-Browser"),
        ("chrome", sup / "Google" / "Chrome"), ("chromium", sup / "Chromium"),
        ("edge", sup / "Microsoft Edge"), ("vivaldi", sup / "Vivaldi"),
        ("opera", sup / "com.operasoftware.Opera")]
    else:
      let cfg = getConfigDir()
      @[("firefox", home / ".mozilla" / "firefox"),
        ("brave", cfg / "BraveSoftware" / "Brave-Browser"),
        ("chrome", cfg / "google-chrome"), ("chromium", cfg / "chromium"),
        ("edge", cfg / "microsoft-edge"), ("vivaldi", cfg / "vivaldi"),
        ("opera", cfg / "opera")]
  for (name, dir) in dirs:
    if dirExists(dir): result.add name

proc wantsSignIn*(err: string): bool =
  ## yt-dlp's error says the link needs a signed-in account (age-restricted,
  ## "confirm you're not a bot"...), which browser cookies give it.
  "Sign in" in err or "--cookies" in err

proc errorReason*(err: string): string =
  ## yt-dlp's "ERROR: [youtube] id: Sign in to confirm your age. Use ..." as
  ## "Sign in to confirm your age".
  result = err.strip
  if result.startsWith("ERROR:"): result = result[6 .. ^1].strip
  if result.startsWith("["):
    let c = result.find(": ")
    if c > 0: result = result[c + 2 .. ^1]
  let dot = result.find(". ")
  if dot > 0: result = result[0 ..< dot]
  result = result.strip(chars = {'.', ' '})

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
  if j.task == ytInstall and l.startsWith("#"):
    if pc >= 0: j.progress = pc
  elif j.task == ytDownload and l.startsWith("MMPPROG "):
    if not j.inStream: return  # a subtitle file
    proc num(s: string): int64 =
      try: int64(parseFloat(s)) except ValueError: 0
    let f = l.split(' ')
    if f.len < 4: return
    let done = num(f[1])
    let total = if num(f[2]) > 0: num(f[2]) else: num(f[3])
    (j.streamDone, j.streamTotal) = (done, total)
    j.bytes = j.streamBase + done
    j.total = if total > 0: j.streamBase + total else: 0
    if j.total > 0: j.progress = min(j.bytes.float * 100 / j.total.float, 100)
  elif j.task == ytDownload and l.startsWith("[info]") and " format(s): " in l:
    # "Downloading 1 format(s): 395+251": video and audio apart, merged after.
    let n = l.split(" format(s): ", 1)[1].count('+') + 1
    j.steps = if n > 1: n + 1 else: 0
    j.lines.add l
  elif j.task == ytDownload and l.startsWith("[download] Destination: "):
    # Each stream downloads in turn, counting from 0: the bytes add up.
    let ext = l.splitFile.ext.toLowerAscii
    j.inStream = ext notin [".vtt", ".srt", ".ass", ".ssa", ".ttml", ".srv1", ".srv2",
                            ".srv3", ".json3", ".lrc"]
    if j.inStream:
      j.streamBase += max(j.streamTotal, j.streamDone)
      (j.streamDone, j.streamTotal) = (0'i64, 0'i64)
      inc j.step
    j.lines.add l
  elif j.task == ytDownload and l.startsWith("[Merger]"):
    j.step = j.steps
    j.lines.add l
  elif l.startsWith("MMPCAPS "): j.data = l[8 .. ^1]
  elif l.startsWith("MMPITEM "):
    let item = l[8 .. ^1].split(' ', 1)
    let title = if item.len > 1: item[1] else: ""
    # Private and deleted videos stay listed, unplayable.
    if title notin ["[Private video]", "[Deleted video]"]: j.items.add (item[0], title)
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
  if j.task == ytSubs and j.code == 0:
    let prefix = j.dest.extractFilename & "."
    try:
      for kind, f in walkDir(j.dest.parentDir):
        if kind == pcFile and f.extractFilename.startsWith(prefix) and
           not f.endsWith(".part"): j.subs.add f
    except OSError: discard
    j.subs.sort()

proc poll*(j: YtJob): bool =
  ## Reads what it printed and notes when it exits. True when anything changed.
  if not j.running: return
  let before = (j.lines.len, j.progress, j.items.len)
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
  (j.lines.len, j.progress, j.items.len) != before

proc stop*(j: YtJob) =
  if not j.running: return
  try:
    j.p.terminate()
    discard j.p.waitForExit(1000)
    j.p.close()
  except OSError: discard
  j.p = nil
  j.code = 130

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
