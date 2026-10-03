## Non-blocking native file dialogs via kdialog (KDE) or zenity.
## The dialog runs as a child process; poll() each frame for the result.

import std/[os, osproc, strutils, streams]

type
  DialogKind* = enum
    dkOpenFiles, dkOpenFile, dkOpenDir, dkSaveFile

  Dialog* = ref object
    process: Process
    purpose*: string         # caller-defined tag, e.g. "open", "subtitle"

proc which(exe: string): bool = findExe(exe).len > 0

proc globs(exts: seq[string]): string =
  for i, e in exts:
    if i > 0: result.add " "
    result.add "*." & e

proc startDialog*(kind: DialogKind, purpose, title, startPath: string,
                  filterExts: seq[string] = @[], filterName = ""): Dialog =
  var cmd: string
  var args: seq[string]
  if which("kdialog"):
    cmd = "kdialog"
    args = @["--title", title]
    let filter =
      if filterExts.len > 0:
        filterName & " (" & globs(filterExts) & ")|All files (*)"
      else: ""
    case kind
    of dkOpenFiles:
      args.add ["--getopenfilename", startPath, filter, "--multiple", "--separate-output"]
    of dkOpenFile:
      args.add ["--getopenfilename", startPath, filter]
    of dkOpenDir:
      args.add ["--getexistingdirectory", startPath]
    of dkSaveFile:
      args.add ["--getsavefilename", startPath, filter]
  elif which("zenity"):
    cmd = "zenity"
    args = @["--file-selection", "--title=" & title, "--filename=" & startPath]
    case kind
    of dkOpenFiles: args.add ["--multiple", "--separator=\n"]
    of dkOpenDir: args.add "--directory"
    of dkSaveFile: args.add ["--save", "--confirm-overwrite"]
    of dkOpenFile: discard
    if filterExts.len > 0 and kind != dkOpenDir:
      args.add "--file-filter=" & filterName & " | " & globs(filterExts)
      args.add "--file-filter=All files | *"
  else:
    stderr.writeLine "No file dialog available: install kdialog or zenity."
    return nil
  result = Dialog(purpose: purpose,
    process: startProcess(cmd, args = args, options = {poUsePath}))

proc poll*(d: Dialog, done: var bool): seq[string] =
  ## Returns the selected paths once the dialog has closed (empty if cancelled).
  done = false
  if d == nil or d.process == nil:
    done = true
    return
  if d.process.peekExitCode() == -1:
    return
  done = true
  let output = d.process.outputStream.readAll()
  let code = d.process.waitForExit()
  d.process.close()
  d.process = nil
  if code != 0: return
  for line in output.splitLines:
    let p = line.strip(leading = false)
    if p.len > 0: result.add p
