## Local stream sockets addressed by a file path, for the single-instance
## server and Synchronize peers. Unix sockets where available; on Windows a
## loopback TCP port, published in a file at the path.

import std/[net, nativesockets, strutils]
when defined(windows):
  import std/winlean
else:
  import std/posix
  var MSG_DONTWAIT {.importc, header: "<sys/socket.h>".}: cint

proc listenAt*(path: string): Socket =
  ## A non-blocking listener reachable through path. Raises on failure.
  when defined(windows):
    result = newSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
    try:
      result.bindAddr(Port(0), "127.0.0.1")
      result.listen()
      writeFile(path, $result.getLocalAddr()[1].int)
    except CatchableError as e:
      result.close()
      raise e
  else:
    result = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    try:
      result.bindUnix(path)
      result.listen()
    except CatchableError as e:
      result.close()
      raise e
  result.getFd.setBlocking(false)

proc dial*(path: string): Socket =
  ## A blocking connection to the listener at path; nil when nobody listens.
  when defined(windows):
    var port: int
    try: port = parseInt(readFile(path).strip)
    except CatchableError: return nil  # no such file, or garbage in it
    result = newSocket(Domain.AF_INET, SockType.SOCK_STREAM, Protocol.IPPROTO_TCP)
    try:
      result.connect("127.0.0.1", Port(port), timeout = 1000)
    except CatchableError:
      result.close()
      result = nil
  else:
    result = newSocket(Domain.AF_UNIX, SockType.SOCK_STREAM, Protocol.IPPROTO_IP)
    try:
      result.connectUnix(path)
    except CatchableError:  # nobody listening, or the path is too long
      result.close()
      result = nil

proc sendAll*(s: Socket, data: string): bool =
  ## Whole message or nothing usable: false once the peer is unreachable.
  ## Never raises SIGPIPE.
  var off = 0
  while off < data.len:
    when defined(windows):
      let n = winlean.send(s.getFd, data[off].unsafeAddr, cint(data.len - off), 0)
      if n <= 0: return false
    else:
      let n = posix.send(s.getFd, data[off].unsafeAddr, data.len - off, MSG_NOSIGNAL)
      if n <= 0:
        if n < 0 and errno == EINTR: continue
        return false
    off += n
  true

proc recvAvailable*(s: Socket, buf: var string): bool =
  ## Appends whatever has arrived without waiting; false once the connection
  ## closed (or broke).
  var chunk: array[4096, char]
  while true:
    when defined(windows):
      var readable = @[s.getFd]
      if selectRead(readable, 0) <= 0: return true  # nothing pending
      let r = winlean.recv(s.getFd, chunk[0].addr, chunk.len.cint, 0)
      if r <= 0: return false
    else:
      let r = posix.recv(s.getFd, chunk[0].addr, chunk.len, MSG_DONTWAIT)
      if r == 0: return false
      if r < 0:
        if errno == EINTR: continue
        return errno == EAGAIN or errno == EWOULDBLOCK
    let old = buf.len
    buf.setLen old + r
    copyMem(buf[old].addr, chunk[0].addr, r)

proc processAlive*(pid: int): bool =
  ## False only when no process with this pid exists.
  when defined(windows):
    const ProcessQueryLimitedInformation = 0x1000'i32
    let h = openProcess(ProcessQueryLimitedInformation, 0, pid.DWORD)
    if h == 0: return getLastError() != 87  # ERROR_INVALID_PARAMETER: no such pid
    var code: DWORD
    result = getExitCodeProcess(h, code) == 0 or code == 259  # STILL_ACTIVE
    discard closeHandle(h)
  else:
    not (kill(Pid(pid), 0) != 0 and errno == ESRCH)
