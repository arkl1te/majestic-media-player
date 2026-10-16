## Picks a color anywhere on the screen (Options > Subtitles' color picker).
## On Linux the desktop does it through the xdg-desktop-portal's
## Screenshot.PickColor (KDE and GNOME show their own magnifier, on X11 and
## Wayland alike; a Wayland app can't read other windows' pixels itself).
## The answer comes later as a Response signal, polled once per frame, so the
## window keeps drawing meanwhile. libdbus is loaded at run time: without it,
## a session bus or the portal, picking is simply unavailable.

type
  ScreenPick* = enum
    spIdle       ## nothing asked
    spWaiting    ## the desktop is letting the user pick
    spPicked     ## a color came back
    spCancelled  ## the user backed out
    spFailed     ## the desktop couldn't do it

when defined(windows):
  proc startScreenPick*(): bool = false
  proc pollScreenPick*(rgb: var (float, float, float)): ScreenPick = spIdle
else:
  import std/dynlib

  type
    DBusError = object
      name, message: cstring
      bits: cuint
      padding: pointer
    Iter = array[16, uint64]  ## DBusMessageIter (72 bytes on 64-bit), opaque
    Conn = pointer
    Msg = pointer

  const
    BusSession = 0.cint
    TypeInvalid = 0.cint
    TypeString = 's'.cint
    TypeUint32 = 'u'.cint
    TypeObjectPath = 'o'.cint
    TypeDouble = 'd'.cint
    TypeArray = 'a'.cint
    TypeVariant = 'v'.cint
    TypeStruct = 'r'.cint
    TypeDictEntry = 'e'.cint
    TimeoutMs = 5000.cint
    Dest = "org.freedesktop.portal.Desktop"
    Request = "org.freedesktop.portal.Request"

  var
    lib: LibHandle
    errorInit: proc (e: ptr DBusError) {.cdecl.}
    errorFree: proc (e: ptr DBusError) {.cdecl.}
    busGetPrivate: proc (kind: cint, e: ptr DBusError): Conn {.cdecl.}
    setExitOnDisconnect: proc (c: Conn, exit: cint) {.cdecl.}
    addMatch: proc (c: Conn, rule: cstring, e: ptr DBusError) {.cdecl.}
    newMethodCall: proc (dest, path, iface, meth: cstring): Msg {.cdecl.}
    getArgs: proc (m: Msg, e: ptr DBusError, first: cint): cint {.cdecl, varargs.}
    sendBlocking: proc (c: Conn, m: Msg, timeout: cint, e: ptr DBusError): Msg {.cdecl.}
    readWrite: proc (c: Conn, timeout: cint): cint {.cdecl.}
    popMessage: proc (c: Conn): Msg {.cdecl.}
    isSignal: proc (m: Msg, iface, name: cstring): cint {.cdecl.}
    getPath: proc (m: Msg): cstring {.cdecl.}
    unref: proc (m: Msg) {.cdecl.}
    iterInit: proc (m: Msg, it: ptr Iter): cint {.cdecl.}
    iterInitAppend: proc (m: Msg, it: ptr Iter) {.cdecl.}
    iterAppendBasic: proc (it: ptr Iter, kind: cint, value: pointer): cint {.cdecl.}
    iterOpen: proc (it: ptr Iter, kind: cint, sig: cstring, sub: ptr Iter): cint {.cdecl.}
    iterClose: proc (it: ptr Iter, sub: ptr Iter): cint {.cdecl.}
    iterArgType: proc (it: ptr Iter): cint {.cdecl.}
    iterRecurse: proc (it: ptr Iter, sub: ptr Iter) {.cdecl.}
    iterNext: proc (it: ptr Iter): cint {.cdecl.}
    iterGetBasic: proc (it: ptr Iter, value: pointer) {.cdecl.}

    conn: Conn
    failed: bool    ## no libdbus or no session bus; don't retry
    handle: string  ## the pending request's object path, "" when none

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
    sym(busGetPrivate, "dbus_bus_get_private")
    sym(setExitOnDisconnect, "dbus_connection_set_exit_on_disconnect")
    sym(addMatch, "dbus_bus_add_match")
    sym(newMethodCall, "dbus_message_new_method_call")
    sym(getArgs, "dbus_message_get_args")
    sym(sendBlocking, "dbus_connection_send_with_reply_and_block")
    sym(readWrite, "dbus_connection_read_write")
    sym(popMessage, "dbus_connection_pop_message")
    sym(isSignal, "dbus_message_is_signal")
    sym(getPath, "dbus_message_get_path")
    sym(unref, "dbus_message_unref")
    sym(iterInit, "dbus_message_iter_init")
    sym(iterInitAppend, "dbus_message_iter_init_append")
    sym(iterAppendBasic, "dbus_message_iter_append_basic")
    sym(iterOpen, "dbus_message_iter_open_container")
    sym(iterClose, "dbus_message_iter_close_container")
    sym(iterArgType, "dbus_message_iter_get_arg_type")
    sym(iterRecurse, "dbus_message_iter_recurse")
    sym(iterNext, "dbus_message_iter_next")
    sym(iterGetBasic, "dbus_message_iter_get_basic")
    true

  proc connect(): bool =
    ## A connection of its own: the shared one belongs to the inhibitor's
    ## blocking calls, and this one pops every message that comes in.
    if conn != nil: return true
    if failed: return false
    if not loadDbus():
      failed = true
      return false
    var err: DBusError
    errorInit(addr err)
    conn = busGetPrivate(BusSession, addr err)
    if conn == nil:
      stderr.writeLine "screenpick: no session bus: ", err.message
      errorFree(addr err)
      failed = true
      return false
    setExitOnDisconnect(conn, 0)
    # Before the call: the answer may come before the call returns its path.
    addMatch(conn, "type='signal',sender='" & Dest & "',interface='" & Request &
      "',member='Response'", addr err)
    if err.name != nil:
      stderr.writeLine "screenpick: ", err.message
      errorFree(addr err)
    true

  proc startScreenPick*(): bool =
    ## Asks the desktop to let the user pick a color; false when it can't.
    if not connect(): return false
    let msg = newMethodCall(Dest, "/org/freedesktop/portal/desktop",
      "org.freedesktop.portal.Screenshot", "PickColor")
    if msg == nil: return false
    var it, opts: Iter
    iterInitAppend(msg, addr it)
    var parent: cstring = ""  # no parent window handle
    discard iterAppendBasic(addr it, TypeString, addr parent)
    discard iterOpen(addr it, TypeArray, "{sv}", addr opts)  # no options
    discard iterClose(addr it, addr opts)
    var err: DBusError
    errorInit(addr err)
    let reply = sendBlocking(conn, msg, TimeoutMs, addr err)
    unref(msg)
    if reply == nil:
      stderr.writeLine "screenpick: PickColor: ", err.message
      errorFree(addr err)
      return false
    var path: cstring
    if getArgs(reply, addr err, TypeObjectPath, addr path, TypeInvalid) == 0:
      stderr.writeLine "screenpick: PickColor: ", err.message
      errorFree(addr err)
      unref(reply)
      return false
    handle = $path
    unref(reply)
    true

  proc readColor(m: Msg, rgb: var (float, float, float)): ScreenPick =
    ## Response(u response, a{sv} results): 0 is success, results["color"]
    ## a (ddd) of 0..1.
    var it: Iter
    if iterInit(m, addr it) == 0 or iterArgType(addr it) != TypeUint32: return spFailed
    var code: uint32
    iterGetBasic(addr it, addr code)
    if code == 1: return spCancelled
    if code != 0 or iterNext(addr it) == 0 or iterArgType(addr it) != TypeArray: return spFailed
    var arr: Iter
    iterRecurse(addr it, addr arr)
    while iterArgType(addr arr) == TypeDictEntry:
      var entry, variant, st: Iter
      iterRecurse(addr arr, addr entry)
      var key: cstring
      iterGetBasic(addr entry, addr key)
      if $key == "color" and iterNext(addr entry) != 0 and iterArgType(addr entry) == TypeVariant:
        iterRecurse(addr entry, addr variant)
        if iterArgType(addr variant) != TypeStruct: return spFailed
        iterRecurse(addr variant, addr st)
        var c: array[3, float64]
        for i in 0 .. 2:
          if iterArgType(addr st) != TypeDouble: return spFailed
          iterGetBasic(addr st, addr c[i])
          discard iterNext(addr st)
        rgb = (c[0].float, c[1].float, c[2].float)
        return spPicked
      discard iterNext(addr arr)
    spFailed

  proc pollScreenPick*(rgb: var (float, float, float)): ScreenPick =
    ## Once per frame after startScreenPick: spWaiting until the answer came.
    if handle.len == 0: return spIdle
    result = spWaiting
    discard readWrite(conn, 0)
    while true:
      let m = popMessage(conn)
      if m == nil: break
      if result == spWaiting and isSignal(m, Request, "Response") != 0 and $getPath(m) == handle:
        result = readColor(m, rgb)
        handle = ""
      unref(m)
