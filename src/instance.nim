## Single-instance support for "Same player for each media file": the running
## player listens on a local socket (see ipc), and a newly launched one hands
## its files over (one path per line) and exits.

import std/[net, nativesockets, os, strutils]
import ipc
when defined(windows):
  proc AllowSetForegroundWindow(pid: int32): int32 {.stdcall, importc, dynlib: "user32".}

type InstanceServer* = ref object
  sock: Socket
  path: string

proc socketPath(): string =
  getEnv("XDG_RUNTIME_DIR", getTempDir()) / "majestic-media-player.sock"

proc forwardToRunning*(paths: seq[string]): bool =
  ## Sends paths to an already running player. False if none is listening.
  let s = dial(socketPath())
  if s == nil: return false
  when defined(windows):
    # We were just launched, so we may raise windows; let the player do it.
    discard AllowSetForegroundWindow(-1)
  try:
    s.send(paths.join("\n") & "\n")
    result = true
  except OSError:
    discard
  s.close()

proc startServer*(): InstanceServer =
  ## Listens for paths from later launches; nil if another player already does.
  let path = socketPath()
  let live = dial(path)
  if live != nil:
    live.close()
    return nil
  removeFile(path)  # stale socket from a crashed instance
  var s: Socket
  try:
    s = listenAt(path)
  except CatchableError as e:
    stderr.writeLine "single instance: cannot listen on ", path, ": ", e.msg
    return nil
  InstanceServer(sock: s, path: path)

proc poll*(srv: InstanceServer): seq[string] =
  ## Paths received since the last call.
  if srv == nil: return
  while true:
    var client: Socket
    new(client)  # accept() fills in an allocated Socket
    try:
      srv.sock.accept(client)
    except OSError:
      break  # nothing pending
    client.getFd.setBlocking(true)
    try:
      while true:
        let line = client.recvLine(timeout = 1000)
        if line.len == 0: break
        result.add line
    except CatchableError:
      discard
    client.close()

proc close*(srv: InstanceServer) =
  if srv == nil: return
  srv.sock.close()
  removeFile(srv.path)
