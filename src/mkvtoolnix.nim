## MKVToolNix's mkvpropedit, which embeds bookmarks as chapters: finds it (the
## copy the player installed, else on PATH, else where its Windows installer
## puts it) and installs it like yt-dlp's standalone build: the latest
## release's AppImage, extracted (no FUSE needed), on Linux; its portable
## build on Windows.

import std/[os, osproc, strutils, strformat]
import runlog

const
  LatestXml = "https://mkvtoolnix.download/latest-release.xml"
  ReleaseUrl = "https://mkvtoolnix.download/"
  KeptLines = 40              ## output lines kept, for errorText

type
  MkvStage* = enum
    mkLatest    ## the latest release's version
    mkDownload  ## its AppImage or portable archive
    mkExtract   ## unpacking it

  MkvJob* = ref object
    stage*: MkvStage
    p: Process                ## nil once finished
    partial: string           ## output after the last line break
    lines: seq[string]        ## its last lines, stdout and stderr together
    code*: int = -1           ## exit code once finished; -1 while running
    progress*: float = -1     ## mkDownload: percent done, as last printed
    version: string
    archive: string           ## what mkDownload makes

proc appDir(): string =
  ## Where the player keeps MKVToolNix.
  when defined(windows): getEnv("LOCALAPPDATA") / "Programs" / "MKVToolNix"
  else: getDataDir() / "majestic-media-player" / "mkvtoolnix"

proc mkvManagedPath*(): string =
  ## The mkvpropedit the player installs: on Linux a script running the
  ## extracted AppImage's, on PATH for most setups (as yt-dlp's is).
  when defined(windows): appDir() / "mkvpropedit.exe"
  else: getHomeDir() / ".local" / "bin" / "mkvpropedit"

proc canInstallMkvtoolnix*(): bool =
  ## MKVToolNix publishes builds the player can install for these.
  when defined(windows) or (defined(linux) and defined(amd64)): true else: false

proc findMkvpropedit*(custom = ""): string =
  ## `custom` (Options > Player > Paths) when that file exists; else the
  ## mkvpropedit the player installed, else the one on PATH, else (on
  ## Windows, whose installer doesn't add it to PATH) the installed one; ""
  ## when there is none.
  let c = custom.strip.expandTilde
  if c.len > 0 and fileExists(c): return c
  if fileExists(mkvManagedPath()): return mkvManagedPath()
  result = findExe("mkvpropedit")
  when defined(windows):
    if result.len == 0:
      for v in ["ProgramFiles", "ProgramFiles(x86)"]:
        let f = getEnv(v) / "MKVToolNix" / "mkvpropedit.exe"
        if getEnv(v).len > 0 and fileExists(f): return f

proc running*(j: MkvJob): bool = j != nil and j.p != nil

proc run(j: MkvJob, stage: MkvStage, exe: string, args: openArray[string], dir = "") =
  j.stage = stage
  j.lines.setLen 0
  j.partial.setLen 0
  try:
    j.p = startProcess(exe, workingDir = dir, args = args,
      options = {poUsePath, poStdErrToStdOut, poDaemon})
    j.p.nonBlocking()
  except OSError as e:
    j.lines.add e.msg
    j.code = 127

proc installMkvtoolnix*(): MkvJob =
  ## Looks up the latest release, then downloads and unpacks it into appDir.
  result = MkvJob()
  result.run(mkLatest, "curl", ["-fsSL", "--max-time", "15", LatestXml])

proc percentIn(s: string): float =
  ## The number before the last '%' in s, else -1.
  let e = s.rfind('%')
  if e < 0: return -1
  var b = e
  while b > 0 and s[b - 1] in {'0' .. '9', '.'}: dec b
  try: parseFloat(s[b ..< e]) except ValueError: -1

proc addLine(j: MkvJob, line: string) =
  let l = line.strip
  if l.len == 0: return
  if j.stage == mkDownload and l.startsWith("#"):
    let pc = percentIn(l)
    if pc >= 0: j.progress = pc
    return
  j.lines.add l
  if j.lines.len > KeptLines: j.lines.delete(0)

proc read(j: MkvJob) =
  for ch in j.p.readPipe():
    if ch in {'\n', '\r'}:
      j.addLine(j.partial)
      j.partial.setLen 0
    else: j.partial.add ch

proc fail(j: MkvJob, msg: string) =
  j.lines.add msg
  j.code = 1

proc versionIn(xml: string): string =
  ## latest-release.xml's <latest-source><version>.
  let at = xml.find("<latest-source>")
  if at < 0: return
  let b = xml.find("<version>", at)
  let e = xml.find("</version>", b + 1)
  if b >= 0 and e > b: result = xml[b + 9 ..< e].strip

proc partDir(): string = appDir() & ".part"

proc download(j: MkvJob) =
  let v = j.version
  let url =
    when defined(windows): ReleaseUrl & &"windows/releases/{v}/mkvtoolnix-64-bit-{v}.7z"
    else: ReleaseUrl & &"appimage/MKVToolNix_GUI-{v}-x86_64.AppImage"
  try:
    removeDir(partDir())
    createDir(partDir())
  except OSError as e:
    j.fail(e.msg)
    return
  j.archive = partDir() / url.extractFilename
  j.progress = -1
  j.run(mkDownload, "curl", ["-fL", "--retry", "2", "-#", "-o", j.archive, url])

proc extract(j: MkvJob) =
  when defined(windows):
    # Windows' own tar reads 7z (Windows 11; not every Windows 10 build).
    j.run(mkExtract, "tar", ["-xf", j.archive, "-C", partDir()])
  else:
    try: j.archive.setFilePermissions(j.archive.getFilePermissions + {fpUserExec})
    except OSError as e:
      j.fail(e.msg)
      return
    j.run(mkExtract, j.archive, ["--appimage-extract"], partDir())

proc settle(j: MkvJob) =
  ## Puts the unpacked release in appDir, and (Linux) the script running it
  ## at mkvManagedPath.
  try:
    removeFile(j.archive)
    let unpacked = partDir() / (when defined(windows): "mkvtoolnix" else: "squashfs-root")
    if not fileExists(unpacked / (when defined(windows): "mkvpropedit.exe"
                                  else: "usr" / "bin" / "mkvpropedit")):
      j.fail("mkvpropedit wasn't in the download")
      return
    removeDir(appDir())
    moveDir(unpacked, appDir())
    removeDir(partDir())
    when not defined(windows):
      let script = mkvManagedPath()
      createDir(script.parentDir)
      let d = quoteShell(appDir())
      writeFile(script, "#!/bin/sh\n" &
        "# MKVToolNix's mkvpropedit, installed by Majestic Media Player.\n" &
        &"d={d}\n" &
        "LD_LIBRARY_PATH=\"$d/usr/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\" " &
        "exec \"$d/usr/bin/mkvpropedit\" \"$@\"\n")
      script.setFilePermissions(script.getFilePermissions +
        {fpUserExec, fpGroupExec, fpOthersExec})
  except OSError, IOError:
    j.fail(getCurrentExceptionMsg())

proc cleanUp(j: MkvJob) =
  try: removeDir(partDir())
  except OSError: discard

proc poll*(j: MkvJob): bool =
  ## Reads what it printed and goes on to the next stage once one is done.
  ## True when anything changed.
  if not j.running: return
  let before = (j.stage, j.progress)
  j.read()
  let code = j.p.peekExitCode
  if code == -1: return (j.stage, j.progress) != before
  j.read()
  j.addLine(j.partial)
  j.partial.setLen 0
  j.p.close()
  j.p = nil
  if code != 0:
    j.code = code
    j.cleanUp()
    return true
  case j.stage
  of mkLatest:
    j.version = versionIn(j.lines.join("\n"))
    if j.version.len == 0: j.fail("couldn't find the latest release")
    else: j.download()
  of mkDownload: j.extract()
  of mkExtract:
    j.settle()
    if j.code == -1: j.code = 0
  if j.code > 0: j.cleanUp()
  true

proc stop*(j: MkvJob) =
  if not j.running: return
  try:
    j.p.terminate()
    discard j.p.waitForExit(1000)
    j.p.close()
  except OSError: discard
  j.p = nil
  j.code = 130
  j.cleanUp()

proc errorText*(j: MkvJob): string =
  ## What went wrong: its last line.
  if j.lines.len > 0: j.lines[^1] else: "exit code " & $j.code
