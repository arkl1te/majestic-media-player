## Global keys: commands whose keys also work while another program has the
## keyboard (Options > Player > Keys, the Global column; none by default).
## One running player holds them, by a lock; the others wait for it to quit.
## Per platform, behind the same interface:
## - Linux on Wayland: the desktop portal's GlobalShortcuts. The desktop has
##   the last word: KDE asks the user about each new shortcut once and keeps
##   what they chose, never the key asked for again. So each key is a
##   shortcut of its own ("play-pause:space"): a changed key is a new one to
##   confirm, and the old one goes.
## - Linux on X11: XGrabKey on the root window, through a display connection
##   of its own, so the main window never gets those keys too.
## - Windows: RegisterHotKey; WM_HOTKEY comes through the main window's hook.

import std/[strutils, times, sequtils]
import windy
import config, keymap, xwin
when defined(windows):
  import win32api
else:
  import std/[os, posix]
  import portal

type
  GlobalKey* = object
    id*: string           ## the command's id and its key: "play-pause:space"
    label*: string        ## what the desktop shows for it
    combo*: KeyCombo

  GlobalKeyState* = enum
    gkWaiting       ## not settled yet; the desktop may be asking the user
    gkActive        ## works (the desktop may name its key otherwise: trigger)
    gkDeclined      ## the desktop gave it no key (its question was turned down)
    gkTaken         ## another program has the key
    gkUnsupported   ## no global keys on this desktop, or not this key
    gkOtherPlayer   ## another running player holds the global keys

  Backend = enum
    gbPortal, gbX11, gbWin32

  GlobalKeys* = ref object
    backend: Backend
    keys: seq[GlobalKey]
    states: seq[GlobalKeyState]
    triggers: seq[string]   ## the desktop's name for each key's trigger (portal)
    owner: bool             ## this player holds the lock, and so the keys
    retryAt: float          ## when to try the lock again
    reported: bool          ## the outcome of the last change was told
    when defined(windows):
      hwnd: HWND
      lock: HANDLE
      registered: seq[int32]
      pressed: seq[int]     ## WM_HOTKEY ids since the last poll
    else:
      parent: string        ## the main window, for the desktop's dialog
      lockFd: cint
      session, sessionReq, bindReq: string
      serial: int
      d: pointer            ## X11: the display connection of its own
      root: culong
      grabs: seq[tuple[code: cint, mods: cuint, index: int]]
      held: seq[cint]       ## keycodes down, to drop auto-repeats

# --- keys --------------------------------------------------------------------

proc keysymName(b: Button): string =
  ## The X keysym name, as XStringToKeysym and the portal's preferred
  ## triggers (the XDG shortcuts spec) read them; "" for none.
  case b
  of Key0 .. Key9: $(b.ord - Key0.ord)
  of KeyA .. KeyZ: $chr(ord('A') + b.ord - KeyA.ord)
  of KeyF1 .. KeyF12: "F" & $(b.ord - KeyF1.ord + 1)
  of Numpad0 .. Numpad9: "KP_" & $(b.ord - Numpad0.ord)
  of KeyBacktick: "grave"
  of KeyMinus: "minus"
  of KeyEqual: "equal"
  of KeyBackspace: "BackSpace"
  of KeyTab: "Tab"
  of KeyLeftBracket: "bracketleft"
  of KeyRightBracket: "bracketright"
  of KeyBackslash: "backslash"
  of KeySemicolon: "semicolon"
  of KeyApostrophe: "apostrophe"
  of KeyEnter: "Return"
  of KeyComma: "comma"
  of KeyPeriod: "period"
  of KeySlash: "slash"
  of KeySpace: "space"
  of KeyMenu: "Menu"
  of KeyDelete: "Delete"
  of KeyHome: "Home"
  of KeyEnd: "End"
  of KeyInsert: "Insert"
  of KeyPageUp: "Prior"
  of KeyPageDown: "Next"
  of KeyUp: "Up"
  of KeyDown: "Down"
  of KeyLeft: "Left"
  of KeyRight: "Right"
  of KeyPrintScreen: "Print"
  of KeyScrollLock: "Scroll_Lock"
  of KeyPause: "Pause"
  of NumpadDecimal: "KP_Decimal"
  of NumpadEnter: "KP_Enter"
  of NumpadAdd: "KP_Add"
  of NumpadSubtract: "KP_Subtract"
  of NumpadMultiply: "KP_Multiply"
  of NumpadDivide: "KP_Divide"
  of NumpadEqual: "KP_Equal"
  of KeyMediaPlayPause: "XF86AudioPlay"
  of KeyMediaStop: "XF86AudioStop"
  of KeyMediaPrevious: "XF86AudioPrev"
  of KeyMediaNext: "XF86AudioNext"
  of KeyVolumeMute: "XF86AudioMute"
  of KeyVolumeDown: "XF86AudioLowerVolume"
  of KeyVolumeUp: "XF86AudioRaiseVolume"
  else: ""

proc trigger(k: KeyCombo): string =
  ## "CTRL+ALT+P", as the XDG shortcuts spec writes them; "" for no key.
  let name = keysymName(k.key)
  if name.len == 0: return ""
  if kmCtrl in k.mods: result.add "CTRL+"
  if kmShift in k.mods: result.add "SHIFT+"
  if kmAlt in k.mods: result.add "ALT+"
  result.add name

proc globalId*(a: KeyAction, k: KeyCombo): string =
  ## Letters, digits and + only after the command's id: the desktop keeps
  ## it in a settings file ("=" for one would break KDE's).
  $a & ":" & k.trigger.toLowerAscii

proc wantedKeys*(c: Config): seq[GlobalKey] =
  ## The added keys marked global, as the config has them.
  for x in c.addedKeys:
    if not x.global: continue
    let (ok, a) = findAction(x.action)
    let k = parseCombo(x.key)
    if not ok or k.trigger.len == 0: continue
    let id = globalId(a, k)
    if result.anyIt(it.id == id): continue
    result.add GlobalKey(id: id, label: Actions[a].label, combo: k)

proc actionOf*(id: string): tuple[ok: bool, action: KeyAction] =
  findAction(id.split(':')[0])

proc setAll(g: GlobalKeys, s: GlobalKeyState) =
  for x in g.states.mitems:
    if x == gkWaiting or s == gkOtherPlayer: x = s

# --- the lock: one player holds the keys --------------------------------------

when defined(windows):
  proc CreateMutexW(attr: pointer, initialOwner: int32, name: WideCString): HANDLE
    {.stdcall, importc, dynlib: "kernel32".}
  proc ReleaseMutex(h: HANDLE): int32 {.stdcall, importc, dynlib: "kernel32".}

  proc tryLock(g: GlobalKeys): bool =
    if g.lock == 0:
      g.lock = CreateMutexW(nil, 0, newWideCString("Local\\MajesticMediaPlayerGlobalKeys"))
      if g.lock == 0: return true   # none to be had: hold the keys anyway
    # Free, or left behind by a player that quit (WAIT_ABANDONED).
    WaitForSingleObject(g.lock, 0).int in [0, 0x80]

  proc unlock(g: GlobalKeys) =
    if g.lock != 0:
      if g.owner: discard ReleaseMutex(g.lock)
      discard CloseHandle(g.lock)
      g.lock = 0
else:
  proc flock(fd: cint, op: cint): cint {.importc, header: "<sys/file.h>".}

  proc lockPath(): string =
    # MMP_INSTANCE_DIR: debug scripts sharing files among themselves (instance).
    getEnv("MMP_INSTANCE_DIR", getEnv("XDG_RUNTIME_DIR", getTempDir())) /
      "majestic-media-player-keys.lock"

  proc tryLock(g: GlobalKeys): bool =
    if g.lockFd < 0:
      g.lockFd = posix.open(cstring(lockPath()), O_CREAT or O_RDWR or O_CLOEXEC, 0o600)
      if g.lockFd < 0: return true  # none to be had: hold the keys anyway
    flock(g.lockFd, 2 or 4) == 0    # LOCK_EX | LOCK_NB

  proc unlock(g: GlobalKeys) =
    if g.lockFd >= 0:
      discard flock(g.lockFd, 8)    # LOCK_UN
      discard posix.close(g.lockFd)
      g.lockFd = -1

# --- Windows: RegisterHotKey ----------------------------------------------------

when defined(windows):
  proc RegisterHotKey(h: HWND, id: int32, mods, vk: uint32): int32
    {.stdcall, dynlib: "user32", importc.}
  proc UnregisterHotKey(h: HWND, id: int32): int32 {.stdcall, dynlib: "user32", importc.}
  proc MapVirtualKeyW(code, mapType: uint32): uint32 {.stdcall, dynlib: "user32", importc.}

  const WmHotkey = 0x0312'u32

  proc virtualKey(b: Button): uint32 =
    ## The key's virtual-key code, 0 for none. Punctuation goes by its place
    ## (scancode), as Windy reads it.
    case b
    of Key0 .. Key9: uint32(0x30 + b.ord - Key0.ord)
    of KeyA .. KeyZ: uint32(0x41 + b.ord - KeyA.ord)
    of KeyF1 .. KeyF12: uint32(0x70 + b.ord - KeyF1.ord)
    of Numpad0 .. Numpad9: uint32(0x60 + b.ord - Numpad0.ord)
    of NumpadMultiply: 0x6A
    of NumpadAdd: 0x6B
    of NumpadSubtract: 0x6D
    of NumpadDecimal: 0x6E
    of NumpadDivide: 0x6F
    of KeyBackspace: 0x08
    of KeyTab: 0x09
    of KeyEnter, NumpadEnter: 0x0D
    of KeyPause: 0x13
    of KeySpace: 0x20
    of KeyPageUp: 0x21
    of KeyPageDown: 0x22
    of KeyEnd: 0x23
    of KeyHome: 0x24
    of KeyLeft: 0x25
    of KeyUp: 0x26
    of KeyRight: 0x27
    of KeyDown: 0x28
    of KeyPrintScreen: 0x2C
    of KeyInsert: 0x2D
    of KeyDelete: 0x2E
    of KeyMenu: 0x5D
    of KeyScrollLock: 0x91
    of KeyMediaNext: 0xB0
    of KeyMediaPrevious: 0xB1
    of KeyMediaStop: 0xB2
    of KeyMediaPlayPause: 0xB3
    of KeyVolumeMute: 0xAD
    of KeyVolumeDown: 0xAE
    of KeyVolumeUp: 0xAF
    else:
      let scancode =
        case b
        of KeyMinus: 0x0C'u32
        of KeyEqual: 0x0D
        of KeyLeftBracket: 0x1A
        of KeyRightBracket: 0x1B
        of KeySemicolon: 0x27
        of KeyApostrophe: 0x28
        of KeyBacktick: 0x29
        of KeyBackslash: 0x2B
        of KeyComma: 0x33
        of KeyPeriod: 0x34
        of KeySlash: 0x35
        else: 0
      if scancode == 0: 0'u32 else: MapVirtualKeyW(scancode, 1)  # MAPVK_VSC_TO_VK

  proc winApply(g: GlobalKeys) =
    for i, k in g.keys:
      let vk = virtualKey(k.combo.key)
      if vk == 0:
        g.states[i] = gkUnsupported
        continue
      var mods = 0x4000'u32  # MOD_NOREPEAT
      if kmAlt in k.combo.mods: mods = mods or 1
      if kmCtrl in k.combo.mods: mods = mods or 2
      if kmShift in k.combo.mods: mods = mods or 4
      let id = int32(i + 1)
      if RegisterHotKey(g.hwnd, id, mods, vk) != 0:
        g.registered.add id
        g.states[i] = gkActive
      else:
        # ERROR_HOTKEY_ALREADY_REGISTERED: another program's.
        g.states[i] = if GetLastError() == 1409: gkTaken else: gkUnsupported

  proc winRelease(g: GlobalKeys) =
    for id in g.registered: discard UnregisterHotKey(g.hwnd, id)
    g.registered = @[]
    g.pressed = @[]

# --- Linux on X11: XGrabKey ---------------------------------------------------

when not defined(windows):
  type XKeyEvent = object
    kind: cint
    serial: culong
    sendEvent: cint
    display: pointer
    window, root, subwindow: culong
    time: culong
    x, y, xRoot, yRoot: cint
    state, keycode: cuint
    sameScreen: cint

  proc XOpenDisplay(name: cstring): pointer {.importc, cdecl.}
  proc XCloseDisplay(d: pointer): cint {.importc, cdecl.}
  proc XDefaultRootWindow(d: pointer): culong {.importc, cdecl.}
  proc XGrabKey(d: pointer, keycode: cint, modifiers: cuint, w: culong, ownerEvents: cint,
    pointerMode, keyboardMode: cint): cint {.importc, cdecl.}
  proc XUngrabKey(d: pointer, keycode: cint, modifiers: cuint, w: culong): cint {.importc, cdecl.}
  proc XStringToKeysym(s: cstring): culong {.importc, cdecl.}
  proc XKeysymToKeycode(d: pointer, sym: culong): uint8 {.importc, cdecl.}
  proc XPending(d: pointer): cint {.importc, cdecl.}
  proc XNextEvent(d: pointer, ev: pointer): cint {.importc, cdecl.}
  proc XSync(d: pointer, discardEvents: cint): cint {.importc, cdecl.}
  proc XFlush(d: pointer): cint {.importc, cdecl.}
  proc XkbSetDetectableAutoRepeat(d: pointer, detectable: cint, supported: ptr cint): cint {.importc, cdecl.}
  type XErrorHandler = proc (d: pointer, e: pointer): cint {.cdecl.}
  proc XSetErrorHandler(h: XErrorHandler): XErrorHandler {.importc, cdecl.}

  const
    ShiftMask = 1'u32
    LockMask = 2'u32
    ControlMask = 4'u32
    Mod1Mask = 8'u32   # Alt
    Mod2Mask = 16'u32  # Num Lock
    ## A grab is for exact modifiers, so also with Caps Lock and Num Lock on.
    LockVariants = [0'u32, LockMask, Mod2Mask, LockMask or Mod2Mask]
    ## Punctuation by place (evdev + 8), as Windy reads it.
    PositionalCodes = [(KeyMinus, 20), (KeyEqual, 21), (KeyLeftBracket, 34),
      (KeyRightBracket, 35), (KeySemicolon, 47), (KeyApostrophe, 48), (KeyBacktick, 49),
      (KeyBackslash, 51), (KeyComma, 59), (KeyPeriod, 60), (KeySlash, 61)]

  var grabFailed: bool

  proc onGrabError(d: pointer, e: pointer): cint {.cdecl.} =
    ## BadAccess: another program grabbed the key first.
    grabFailed = true
    0

  proc keycode(d: pointer, b: Button): cint =
    for (pb, code) in PositionalCodes:
      if pb == b: return code.cint
    let name = keysymName(b)
    if name.len == 0: return 0
    let sym = XStringToKeysym(cstring(name))
    if sym == 0: 0 else: XKeysymToKeycode(d, sym).cint

  proc x11Apply(g: GlobalKeys) =
    if g.d == nil:
      g.d = XOpenDisplay(nil)
      if g.d == nil:
        g.setAll gkUnsupported
        return
      g.root = XDefaultRootWindow(g.d)
      # Held keys repeat as presses alone, told apart from new ones by held.
      discard XkbSetDetectableAutoRepeat(g.d, 1, nil)
    let before = XSetErrorHandler(onGrabError)
    for i, k in g.keys:
      let code = keycode(g.d, k.combo.key)
      if code == 0:
        g.states[i] = gkUnsupported
        continue
      var mods = 0'u32
      if kmShift in k.combo.mods: mods = mods or ShiftMask
      if kmCtrl in k.combo.mods: mods = mods or ControlMask
      if kmAlt in k.combo.mods: mods = mods or Mod1Mask
      grabFailed = false
      for extra in LockVariants:
        discard XGrabKey(g.d, code, mods or extra, g.root, 0, 1, 1)  # GrabModeAsync
      discard XSync(g.d, 0)
      if grabFailed:
        for extra in LockVariants: discard XUngrabKey(g.d, code, mods or extra, g.root)
        g.states[i] = gkTaken
      else:
        g.grabs.add (code, mods, i)
        g.states[i] = gkActive
    discard XSync(g.d, 0)
    discard XSetErrorHandler(before)

  proc x11Release(g: GlobalKeys) =
    if g.d == nil: return
    for (code, mods, _) in g.grabs:
      for extra in LockVariants: discard XUngrabKey(g.d, code, mods or extra, g.root)
    discard XFlush(g.d)
    g.grabs = @[]
    g.held = @[]

  proc x11Poll(g: GlobalKeys): seq[int] =
    if g.d == nil: return
    var buf: array[24, clong]  # XEvent
    while XPending(g.d) > 0:
      discard XNextEvent(g.d, buf.addr)
      let ev = cast[ptr XKeyEvent](buf.addr)
      let code = ev.keycode.cint
      case ev.kind
      of 2:  # KeyPress
        if code in g.held: continue
        g.held.add code
        let mods = ev.state and (ShiftMask or ControlMask or Mod1Mask)
        for (c, m, i) in g.grabs:
          if c == code and m == mods: result.add i
      of 3: g.held.keepItIf(it != code)  # KeyRelease
      else: discard

# --- Linux on Wayland: the portal's GlobalShortcuts -------------------------------

when not defined(windows):
  const Desktop = "/org/freedesktop/portal/desktop"

  proc token(g: GlobalKeys): string =
    inc g.serial
    "mmpkeys" & $getCurrentProcessId() & "_" & $g.serial

  proc putOptions(it: ptr Iter, token: string, session = false) =
    var opts: Iter
    discard iterOpen(it, TypeArray, "{sv}", addr opts)
    dictEntry(addr opts, "handle_token", "s"): appendString(value, token)
    if session:
      dictEntry(addr opts, "session_handle_token", "s"): appendString(value, token)
    discard iterClose(it, addr opts)

  proc portalApply(g: GlobalKeys) =
    let tok = g.token
    g.sessionReq = request("GlobalShortcuts", "CreateSession", proc (it: ptr Iter) =
      putOptions(it, tok, session = true))
    if g.sessionReq.len == 0: g.setAll gkUnsupported

  proc portalBind(g: GlobalKeys) =
    let (tok, session, keys, parent) = (g.token, g.session, g.keys, g.parent)
    g.bindReq = request("GlobalShortcuts", "BindShortcuts", proc (it: ptr Iter) =
      appendPath(it, session)
      var list: Iter
      discard iterOpen(it, TypeArray, "(sa{sv})", addr list)
      for k in keys:
        var item, opts: Iter
        discard iterOpen(addr list, TypeStruct, nil, addr item)
        appendString(addr item, k.id)
        discard iterOpen(addr item, TypeArray, "{sv}", addr opts)
        dictEntry(addr opts, "description", "s"): appendString(value, k.label)
        dictEntry(addr opts, "preferred_trigger", "s"): appendString(value, k.combo.trigger)
        discard iterClose(addr item, addr opts)
        discard iterClose(addr list, addr item)
      discard iterClose(it, addr list)
      appendString(it, parent)
      putOptions(it, tok))
    if g.bindReq.len == 0: g.setAll gkUnsupported

  proc takeTriggers(g: GlobalKeys, list: ptr Iter) =
    ## The desktop's a(sa{sv}) of shortcuts: each one's key as it names it,
    ## none when it gave it none.
    if iterArgType(list) != TypeArray: return
    var items: Iter
    iterRecurse(list, addr items)
    while iterArgType(addr items) == TypeStruct:
      var item: Iter
      iterRecurse(addr items, addr item)
      let id = getString(addr item)
      var trigger = ""
      if iterNext(addr item) != 0 and iterArgType(addr item) == TypeArray:
        var opts, v: Iter
        iterRecurse(addr item, addr opts)
        if findResult(addr opts, "trigger_description", v): trigger = getString(addr v)
      for i, k in g.keys:
        if k.id == id:
          g.triggers[i] = trigger
          g.states[i] = if trigger.len > 0: gkActive else: gkDeclined
      discard iterNext(addr items)
    g.setAll gkDeclined  # the ones it left out

  proc portalRelease(g: GlobalKeys) =
    let none = proc (it: ptr Iter) = discard
    if g.bindReq.len > 0:
      discard call(g.bindReq, "org.freedesktop.portal.Request", "Close", none)
    if g.session.len > 0:
      discard call(g.session, "org.freedesktop.portal.Session", "Close", none)
    g.session = ""
    g.sessionReq = ""
    g.bindReq = ""

  proc portalPoll(g: GlobalKeys): seq[int] =
    if g.sessionReq.len > 0:
      let m = pollResponse(g.sessionReq)
      if m != nil:
        g.sessionReq = ""
        var results, v: Iter
        if responseCode(m, results) == 0 and findResult(addr results, "session_handle", v):
          g.session = getString(addr v)
        unref(m)
        if g.session.len > 0: g.portalBind()
        else: g.setAll gkUnsupported
    if g.bindReq.len > 0:
      let m = pollResponse(g.bindReq)
      if m != nil:
        g.bindReq = ""
        var results, v: Iter
        case responseCode(m, results)
        of 0:
          if findResult(addr results, "shortcuts", v): g.takeTriggers(addr v)
          else: g.setAll gkDeclined
        of 1: g.setAll gkDeclined  # its question was cancelled
        else: g.setAll gkUnsupported
        unref(m)
    for m in takeSignals():
      var it: Iter
      if g.session.len > 0 and iterInit(m, addr it) != 0 and getString(addr it) == g.session and
         iterNext(addr it) != 0:
        if m.isMember("Activated"):
          let id = getString(addr it)
          for i, k in g.keys:
            if k.id == id: result.add i
        elif m.isMember("ShortcutsChanged"):
          g.takeTriggers(addr it)
      unref(m)

# --- interface ------------------------------------------------------------------

proc newGlobalKeys*(window: Window): GlobalKeys =
  result = GlobalKeys()
  when defined(windows):
    result.backend = gbWin32
    result.hwnd = window.getHWND
    let g = result
    window.addMessageHook(proc (msg: UINT, wParam: WPARAM, lParam: LPARAM) =
      if msg == WmHotkey: g.pressed.add wParam.int)
  else:
    result.lockFd = -1
    result.parent = "x11:" & window.windowId.toHex.toLowerAscii
    result.backend =
      if getEnv("WAYLAND_DISPLAY").len > 0 or getEnv("XDG_SESSION_TYPE") == "wayland": gbPortal
      else: gbX11

proc apply(g: GlobalKeys) =
  case g.backend
  of gbWin32:
    when defined(windows): g.winApply()
  of gbX11:
    when not defined(windows): g.x11Apply()
  of gbPortal:
    when not defined(windows): g.portalApply()

proc release(g: GlobalKeys) =
  case g.backend
  of gbWin32:
    when defined(windows): g.winRelease()
  of gbX11:
    when not defined(windows): g.x11Release()
  of gbPortal:
    when not defined(windows): g.portalRelease()

proc setKeys*(g: GlobalKeys, keys: seq[GlobalKey]) =
  ## The keys to hold from now on (wantedKeys); the same ones again change
  ## nothing.
  if keys == g.keys: return
  if g.owner: g.release()
  g.keys = keys
  g.states = newSeq[GlobalKeyState](keys.len)
  g.triggers = newSeq[string](keys.len)
  g.reported = false
  if keys.len == 0:
    if g.owner: g.unlock()
    g.owner = false
  elif g.owner: g.apply()
  else: g.retryAt = 0

proc poll*(g: GlobalKeys): seq[string] =
  ## Every frame: the ids (GlobalKey.id) of the keys pressed since.
  if g.keys.len == 0: return
  if not g.owner:
    let t = epochTime()
    if t < g.retryAt: return
    g.retryAt = t + 2
    if not g.tryLock():
      g.setAll gkOtherPlayer
      return
    g.owner = true
    for s in g.states.mitems: s = gkWaiting
    g.apply()
  var hits: seq[int]
  case g.backend
  of gbWin32:
    when defined(windows):
      for id in move g.pressed: hits.add id - 1
  of gbX11:
    when not defined(windows): hits = g.x11Poll()
  of gbPortal:
    when not defined(windows): hits = g.portalPoll()
  for i in hits:
    if i in 0 .. g.keys.high: result.add g.keys[i].id

proc state*(g: GlobalKeys, id: string): tuple[known: bool, state: GlobalKeyState, trigger: string] =
  ## How the key with this id fares; not known when it isn't held (yet).
  for i, k in g.keys:
    if k.id == id: return (true, g.states[i], g.triggers[i])

proc dump*(g: GlobalKeys): string =
  ## For debug scripts: holding or not, each key's id, state and the
  ## desktop's name for it.
  result = "global owner=" & $g.owner & " backend=" & $g.backend
  for i, k in g.keys: result.add " " & k.id & "=" & $g.states[i] & "/" & g.triggers[i]

proc problem*(s: GlobalKeyState): bool = s in {gkDeclined, gkTaken, gkUnsupported}

proc takeReport*(g: GlobalKeys): string =
  ## Once the desktop answered for every key of the last change: what didn't
  ## work out, for the OSD; "" when all did (or it's not settled yet).
  if g.reported or g.keys.len == 0 or gkWaiting in g.states: return
  g.reported = true
  var bad: seq[string]
  var why = ""
  for i, k in g.keys:
    if g.states[i].problem:
      bad.add $k.combo
      if why.len == 0:
        why =
          case g.states[i]
          of gkDeclined: "the desktop gave it no key"
          of gkTaken: "another program has it"
          else: "not available here"
  if bad.len == 1: result = "Global key " & bad[0] & ": " & why
  elif bad.len > 1: result = "Global keys " & bad.join(", ") & ": " & why

proc canConfigure*(g: GlobalKeys): bool =
  ## The desktop can show its own settings for the keys (the portal's
  ## ConfigureShortcuts, version 2), where a declined one gets a key.
  when defined(windows): false
  else: g.backend == gbPortal and g.owner and g.session.len > 0

proc configure*(g: GlobalKeys): bool =
  ## Opens the desktop's settings for the keys; false when it can't.
  when defined(windows): false
  else:
    if not g.canConfigure: return false
    let (session, parent) = (g.session, g.parent)
    call(Desktop, "org.freedesktop.portal.GlobalShortcuts", "ConfigureShortcuts",
      proc (it: ptr Iter) =
        appendPath(it, session)
        appendString(it, parent)
        var opts: Iter
        discard iterOpen(it, TypeArray, "{sv}", addr opts)
        discard iterClose(it, addr opts))

proc close*(g: GlobalKeys) =
  if g.owner:
    g.release()
    g.unlock()
  g.owner = false
  when not defined(windows):
    if g.d != nil:
      discard XCloseDisplay(g.d)
      g.d = nil
