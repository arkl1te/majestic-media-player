## Keeps the display awake through org.freedesktop.ScreenSaver.Inhibit on the
## session bus (KDE, GNOME and most desktops implement it). mpv's own
## stop-screensaver only acts on windows mpv creates, not on a render context
## drawn into ours. The desktop drops an inhibition when its caller's bus
## connection closes, so the connection stays open for the app's lifetime.
## libdbus is loaded at run time: without it (or a session bus) this is a no-op.

import std/dynlib

type
  DBusError = object
    name, message: cstring
    bits: cuint
    padding: pointer
  Conn = pointer
  Msg = pointer

  Inhibitor* = object
    conn: Conn
    cookie: uint32
    active: bool
    wanted: bool   ## last state asked for; a failed Inhibit waits for a change
    failed: bool   ## no libdbus or no session bus; don't retry

const
  BusSession = 0.cint
  TypeInvalid = 0.cint
  TypeString = 's'.cint
  TypeUint32 = 'u'.cint
  TimeoutMs = 1000.cint
  Dest = "org.freedesktop.ScreenSaver"
  Path = "/org/freedesktop/ScreenSaver"

var
  lib: LibHandle
  errorInit: proc (e: ptr DBusError) {.cdecl.}
  errorFree: proc (e: ptr DBusError) {.cdecl.}
  busGet: proc (kind: cint, e: ptr DBusError): Conn {.cdecl.}
  setExitOnDisconnect: proc (c: Conn, exit: cint) {.cdecl.}
  newMethodCall: proc (dest, path, iface, meth: cstring): Msg {.cdecl.}
  appendArgs: proc (m: Msg, first: cint): cint {.cdecl, varargs.}
  getArgs: proc (m: Msg, e: ptr DBusError, first: cint): cint {.cdecl, varargs.}
  sendBlocking: proc (c: Conn, m: Msg, timeout: cint, e: ptr DBusError): Msg {.cdecl.}
  unref: proc (m: Msg) {.cdecl.}

proc loadDbus(): bool =
  if lib != nil: return true
  lib = loadLib("libdbus-1.so.3")
  if lib == nil: lib = loadLib("libdbus-1.so")
  if lib == nil: return false
  template sym(v, name: untyped) =
    v = cast[typeof(v)](lib.symAddr(name))
    if v == nil:
      unloadLib(lib)
      lib = nil
      return false
  sym(errorInit, "dbus_error_init")
  sym(errorFree, "dbus_error_free")
  sym(busGet, "dbus_bus_get")
  sym(setExitOnDisconnect, "dbus_connection_set_exit_on_disconnect")
  sym(newMethodCall, "dbus_message_new_method_call")
  sym(appendArgs, "dbus_message_append_args")
  sym(getArgs, "dbus_message_get_args")
  sym(sendBlocking, "dbus_connection_send_with_reply_and_block")
  sym(unref, "dbus_message_unref")
  true

proc connect(ih: var Inhibitor): bool =
  if ih.conn != nil: return true
  if ih.failed: return false
  if not loadDbus():
    ih.failed = true
    return false
  var err: DBusError
  errorInit(addr err)
  ih.conn = busGet(BusSession, addr err)
  if ih.conn == nil:
    stderr.writeLine "inhibit: no session bus: ", err.message
    errorFree(addr err)
    ih.failed = true
    return false
  # The shared connection exits the process when the bus goes away by default.
  setExitOnDisconnect(ih.conn, 0)
  true

proc call(ih: var Inhibitor, m: Msg): Msg =
  var err: DBusError
  errorInit(addr err)
  result = sendBlocking(ih.conn, m, TimeoutMs, addr err)
  unref(m)
  if result == nil:
    stderr.writeLine "inhibit: ", err.message
    errorFree(addr err)

proc inhibit(ih: var Inhibitor) =
  if not ih.connect(): return
  let m = newMethodCall(Dest, Path, Dest, "Inhibit")
  if m == nil: return
  var app: cstring = "Majestic Media Player"
  var why: cstring = "Playing video"
  discard appendArgs(m, TypeString, addr app, TypeString, addr why, TypeInvalid)
  let reply = ih.call(m)
  if reply == nil: return
  var err: DBusError
  errorInit(addr err)
  var cookie: uint32
  if getArgs(reply, addr err, TypeUint32, addr cookie, TypeInvalid) != 0:
    (ih.cookie, ih.active) = (cookie, true)
  else:
    errorFree(addr err)
  unref(reply)

proc release(ih: var Inhibitor) =
  if not ih.active: return
  ih.active = false
  let m = newMethodCall(Dest, Path, Dest, "UnInhibit")
  if m == nil: return
  var cookie = ih.cookie
  discard appendArgs(m, TypeUint32, addr cookie, TypeInvalid)
  let reply = ih.call(m)
  if reply != nil: unref(reply)

proc set*(ih: var Inhibitor, on: bool) =
  ## Inhibits or releases; cheap to call every frame, as it only acts on change.
  if on == ih.wanted: return
  ih.wanted = on
  if on: ih.inhibit() else: ih.release()
