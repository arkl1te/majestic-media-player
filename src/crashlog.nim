## Crash log: when the app dies of an unhandled exception (a Nim defect such
## as an IndexDefect) or a fatal signal (a segfault), Nim's report — the stack
## trace and the error — is appended to crash.log in the config folder, with
## the version, the build, the time and what the app was showing. Then the
## report is shown as Nim would show it (stderr; a message box in the Windows
## GUI build), followed by where the log was saved.
##
## Nim hands its report to `errorMessageWriter` instead of showing it, so that
## is the hook; the process ends right after, as it would without it.

import std/[os, times, strutils]

const LogLimit = 1 shl 20  ## bytes; a bigger log starts over

var
  logPath: string
  appTitle: string             ## "Majestic Media Player 0.24.0"
  startedAt: float
  writing: bool                ## a crash while reporting one: show it plainly
  snapshot*: proc (): string {.closure.}
    ## what the app was doing, one "name: value" per line; called only for
    ## crashes on the main thread, where the app's state is safe to read
  mainThread {.threadvar.}: bool

when compileOption("exceptions", "goto"):
  # With goto-based exceptions (the default), the thread's error flag stays
  # set while Nim reports an unhandled exception, and every call that can
  # raise then returns at once as if one were in flight: the writer would
  # stop at its first such call. Nim emits this accessor into each module.
  proc nimErrorFlag(): ptr bool {.importc, nodecl.}

proc show(text: string) {.raises: [].} =
  try:
    stderr.write(text)
    stderr.flushFile()
  except CatchableError: discard
  when defined(windows) and defined(guiapp):
    proc MessageBoxW(hWnd: pointer, text, caption: WideCString, uType: uint32): int32 {.
      stdcall, dynlib: "user32", importc.}
    const MbIconError = 0x10'u32
    discard MessageBoxW(nil, newWideCString(text), newWideCString(appTitle), MbIconError)

proc append(text: string) =
  createDir(logPath.parentDir)
  let mode = if fileExists(logPath) and getFileSize(logPath) > LogLimit: fmWrite else: fmAppend
  var f = open(logPath, mode)
  try: f.write(text)
  finally: f.close()

proc writeReport(report: string) {.nimcall, gcsafe, raises: [], tags: [WriteIOEffect].} =
  {.cast(gcsafe), cast(tags: []).}:
    if writing or logPath.len == 0:
      show(report)
      return
    writing = true
    when declared(nimErrorFlag):
      # Left cleared: Nim quits right after the report either way, and set
      # again it would make Nim take the writer for failed and print it too.
      nimErrorFlag()[] = false
    var saved = false
    try:
      var text = "=== " & appTitle & " crashed on " &
        now().format("yyyy-MM-dd HH:mm:ss zzz") & "\n"
      text.add "Build: " & hostOS & " " & hostCPU & ", compiled " & CompileDate & " " &
        CompileTime & " UTC\n"
      text.add "Running for: " & formatFloat(epochTime() - startedAt, ffDecimal, 1) & " s\n"
      if not mainThread: text.add "Thread: not the main one\n"
      text.add "\n" & report
      if not report.endsWith("\n"): text.add "\n"
      append(text)  # first: reading the app's state below could crash too
      saved = true
      if mainThread and snapshot != nil:
        var state = "State:\n"
        try: state.add snapshot()
        except Exception: state.add "(unavailable)\n"
        if not state.endsWith("\n"): state.add "\n"
        append(state)
      append("\n")
    except Exception: discard
    if saved:
      show(report & "\nThe details were saved to " & logPath &
        "\nPlease send that file along when reporting this crash.\n")
    else:
      show(report)

proc installCrashLog*(dir, title: string) =
  ## Call first thing on the main thread: crashes are written to dir/crash.log.
  logPath = dir / "crash.log"
  appTitle = title
  startedAt = epochTime()
  mainThread = true
  errorMessageWriter = writeReport
