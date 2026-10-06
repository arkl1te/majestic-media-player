## Win32 counterparts of the X11 window helpers (see xwin_x11.nim): window
## moves, always-on-top, aspect-ratio sizing, file drops, a hidden cursor,
## pointer capture and the popup windows menus are drawn into.

import std/importutils
import windy, vmath, chroma
from pixie import Image, newImage
import win32api

proc hwnd(window: Window): HWND = window.getHWND

proc hdc(window: Window): HDC =
  privateAccess(Window)
  window.hdc

proc outerRect(h: HWND): RECT =
  discard GetWindowRect(h, result.addr)

proc frameSize(h: HWND): IVec2 =
  ## Outer size minus client size: what the borders and title bar take.
  var c: RECT
  discard GetClientRect(h, c.addr)
  let o = outerRect(h)
  ivec2((o.right - o.left) - c.right, (o.bottom - o.top) - c.bottom)

proc disableVsync*(window: Window) =
  ## WGL's swap interval belongs to the current context, so call this while
  ## window's is current. Windy already asked for none; this makes sure
  ## drivers that default to 1 don't block.
  type SwapIntervalExt = proc (interval: cint): BOOL {.stdcall.}
  let ext = cast[SwapIntervalExt](glProcAddress("wglSwapIntervalEXT"))
  if ext != nil: discard ext(0)

proc darkTitleBar(window: Window) =
  ## Dark-first: the title bar and borders follow the app, not the system
  ## theme (Windows 10 2004+; older builds ignore it).
  const DwmwaUseImmersiveDarkMode = 20'i32
  var on: BOOL = 1
  let h = window.hwnd
  discard DwmSetWindowAttribute(h, DwmwaUseImmersiveDarkMode, on.addr, sizeof(on).int32)
  # Windy has already shown the window, and Windows 10 keeps the light frame
  # until the next activation change: recompute the frame and repaint it now.
  discard SetWindowPos(h, 0, 0, 0, 0, 0, SWP_FRAMECHANGED or SWP_NOMOVE or
    SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE)
  if GetForegroundWindow() == h:
    discard SendMessageW(h, WM_NCACTIVATE, 0, 0)
    discard SendMessageW(h, WM_NCACTIVATE, 1, 0)

# --- main window hook ------------------------------------------------------------

type Hook = ref object
  window: Window
  prev: WNDPROC
  aspect: float              ## of the area left after chrome; <= 0: free
  chrome, minSize: IVec2     ## client-area sizes
  dragging: bool
  dragOffset: IVec2          ## pointer minus outer top-left, in screen pixels

var hooks: seq[Hook]

proc hookFor(h: HWND): Hook =
  for k in hooks:
    if k.window.hwnd == h: return k

proc constrainSizing(k: Hook, edge: WPARAM, r: var RECT) =
  ## Keeps (client - chrome) at k.aspect while the user drags an edge.
  let f = frameSize(k.window.hwnd)
  var cw = max(r.right - r.left - f.x, k.minSize.x)
  var ch = max(r.bottom - r.top - f.y, k.minSize.y)
  case edge.int
  of WMSZ_TOP, WMSZ_BOTTOM:
    cw = int32(float(ch - k.chrome.y) * k.aspect) + k.chrome.x
  else:
    ch = int32(float(cw - k.chrome.x) / k.aspect) + k.chrome.y
  if cw < k.minSize.x or ch < k.minSize.y:
    return  # too small to keep the ratio; the min-size limit wins
  case edge.int
  of WMSZ_LEFT, WMSZ_TOPLEFT, WMSZ_BOTTOMLEFT: r.left = r.right - cw - f.x
  else: r.right = r.left + cw + f.x
  case edge.int
  of WMSZ_TOP, WMSZ_TOPLEFT, WMSZ_TOPRIGHT: r.top = r.bottom - ch - f.y
  else: r.bottom = r.top + ch + f.y

proc dropFiles(k: Hook, drop: HANDLE) =
  privateAccess(Window)
  var pt: POINT
  discard DragQueryPoint(drop, pt.addr)
  k.window.state.mousePos = ivec2(pt.x, pt.y)
  let n = DragQueryFileW(drop, 0xFFFFFFFF'u32, nil, 0)
  for i in 0'u32 ..< n:
    let len = DragQueryFileW(drop, i, nil, 0)
    var buf = newSeq[uint16](len + 1)
    discard DragQueryFileW(drop, i, cast[ptr WCHAR](buf[0].addr), len + 1)
    let path = fromWide(cast[ptr WCHAR](buf[0].addr))
    if path.len > 0 and k.window.onFileDrop != nil:
      k.window.onFileDrop(path, "")
  DragFinish(drop)

proc hookProc(h: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  let k = hookFor(h)
  if k == nil: return DefWindowProcW(h, msg, wParam, lParam)
  case msg
  of WM_GETMINMAXINFO:
    result = CallWindowProcW(k.prev, h, msg, wParam, lParam)
    if k.minSize.x > 0:
      let f = frameSize(h)
      let mmi = cast[ptr MINMAXINFO](lParam)
      mmi.ptMinTrackSize = POINT(x: k.minSize.x + f.x, y: k.minSize.y + f.y)
    return 0
  of WM_SIZING:
    if k.aspect > 0:
      k.constrainSizing(wParam, cast[ptr RECT](lParam)[])
      return 1
  of WM_DROPFILES:
    k.dropFiles(cast[HANDLE](wParam))
    return 0
  of WM_MOUSEMOVE:
    if k.dragging:
      var p: POINT
      discard GetCursorPos(p.addr)
      discard SetWindowPos(h, 0, p.x - k.dragOffset.x, p.y - k.dragOffset.y, 0, 0,
        SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE)
  of WM_LBUTTONUP:
    if k.dragging:
      # Like the X11 move, the release ends the drag and never reaches the
      # app: a click there would toggle playback.
      k.dragging = false
      discard ReleaseCapture()
      privateAccess(Window)
      k.window.state.buttonDown.excl MouseLeft
      return 0
  of WM_CAPTURECHANGED:
    if k.dragging and cast[HWND](lParam) != h:
      k.dragging = false
      privateAccess(Window)
      k.window.state.buttonDown.excl MouseLeft
  else: discard
  CallWindowProcW(k.prev, h, msg, wParam, lParam)

proc initMainWindow*(window: Window) =
  ## Hooks the window procedure for what Windy doesn't do on Windows: file
  ## drops, minimum size, aspect-locked resizing and moving by the content.
  if hookFor(window.hwnd) != nil: return
  let k = Hook(window: window)
  hooks.add k
  window.darkTitleBar()
  k.prev = cast[WNDPROC](GetWindowLongPtrW(window.hwnd, GWLP_WNDPROC))
  discard SetWindowLongPtrW(window.hwnd, GWLP_WNDPROC, cast[LONG_PTR](hookProc))
  DragAcceptFiles(window.hwnd, 1)

proc startWindowDrag*(window: Window) =
  ## Moves the window with the pointer until the left button comes up. Done
  ## here rather than by the system's modal move loop, which would stall
  ## playback and drawing for as long as the drag lasts.
  let k = hookFor(window.hwnd)
  if k == nil or window.maximized: return
  var p: POINT
  discard GetCursorPos(p.addr)
  let o = outerRect(window.hwnd)
  k.dragOffset = ivec2(p.x - o.left, p.y - o.top)
  k.dragging = true
  discard SetCapture(window.hwnd)

proc activate*(window: Window) =
  ## Raises and focuses the window. Windows only lets the foreground process
  ## do that, so borrow its input state when we aren't it.
  let h = window.hwnd
  if IsIconic(h) != 0: discard ShowWindow(h, SW_RESTORE)
  if SetForegroundWindow(h) != 0: return
  let fg = GetWindowThreadProcessId(GetForegroundWindow(), nil)
  let me = GetCurrentThreadId()
  if fg != 0 and fg != me and AttachThreadInput(me, fg, 1) != 0:
    discard BringWindowToTop(h)
    discard SetForegroundWindow(h)
    discard AttachThreadInput(me, fg, 0)

proc framePos*(window: Window): IVec2 =
  ## Screen position of the window's outer (decorated) top-left corner.
  let o = outerRect(window.hwnd)
  ivec2(o.left, o.top)

proc moveFrame*(window: Window, pos: IVec2) =
  discard SetWindowPos(window.hwnd, 0, pos.x, pos.y, 0, 0,
    SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE)

proc setAlwaysOnTop*(window: Window, on: bool) =
  discard SetWindowPos(window.hwnd, if on: HWND_TOPMOST else: HWND_NOTOPMOST,
    0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE)

proc setAspectHints*(window: Window, aspect: float, chrome: IVec2, minSize: IVec2) =
  ## Keeps (window - chrome) at the given aspect while the user resizes, and
  ## the client area at least minSize. aspect <= 0 removes the constraint.
  window.initMainWindow()
  let k = hookFor(window.hwnd)
  k.aspect = aspect
  k.chrome = chrome
  k.minSize = minSize

proc setDialogFor*(window, parent: Window) =
  ## Makes window owned by parent: kept above it, minimized with it and left
  ## out of the taskbar. Call before showing it.
  discard SetWindowLongPtrW(window.hwnd, GWLP_HWNDPARENT, cast[LONG_PTR](parent.hwnd))
  window.darkTitleBar()
  let ex = GetWindowLongW(window.hwnd, GWL_EXSTYLE)
  discard SetWindowLongW(window.hwnd, GWL_EXSTYLE, ex and not WS_EX_APPWINDOW)

proc placeDialog*(window: Window, pos, size: IVec2) =
  ## Gives the window a client area of size with its outer top-left at pos.
  window.size = size
  window.moveFrame(pos)

proc monitorAt*(point: IVec2): tuple[pos, size: IVec2] =
  ## Screen rect of the monitor holding point, else the nearest one.
  result = (ivec2(0, 0), ivec2(1920, 1080))
  var mi: MONITORINFO
  mi.cbSize = sizeof(MONITORINFO).DWORD
  let m = MonitorFromPoint(POINT(x: point.x, y: point.y), MONITOR_DEFAULTTONEAREST)
  if m != 0 and GetMonitorInfoW(m, mi.addr) != 0:
    let r = mi.rcMonitor
    result = (ivec2(r.left, r.top), ivec2(r.right - r.left, r.bottom - r.top))

proc monitorSize*(window: Window): IVec2 =
  ## Size of the monitor that holds the window centre.
  monitorAt(window.pos + window.size div 2).size

proc pointerPos*(window: Window): tuple[screen, local: IVec2] =
  ## Pointer position on screen and relative to the window's content.
  var p: POINT
  discard GetCursorPos(p.addr)
  let screen = ivec2(p.x, p.y)
  (screen, screen - window.pos)

proc pointerButtonsDown*(): bool =
  ## Whether the left, middle or right mouse button is held anywhere.
  for vk in [VK_LBUTTON, VK_RBUTTON, VK_MBUTTON]:
    if (GetAsyncKeyState(vk).int and 0x8000) != 0: return true

var grabbedBy: HWND

proc grabPointer*(window: Window): bool =
  ## Captures the pointer for window while a menu is open, so presses on our
  ## other windows reach it. Windows never routes a click on another app's
  ## window to us; that one is caught as focus loss instead.
  discard SetCapture(window.hwnd)
  grabbedBy = window.hwnd
  true

proc ungrabPointer*() =
  if grabbedBy != 0 and GetCapture() == grabbedBy: discard ReleaseCapture()
  grabbedBy = 0

var hiddenCursorImage: Image

proc hiddenCursor*(): Cursor =
  if hiddenCursorImage == nil:
    hiddenCursorImage = newImage(1, 1)
  Cursor(kind: CustomCursor, image: hiddenCursorImage, hotspot: ivec2(0, 0))

# --- popup windows ------------------------------------------------------------

type
  PopupWindow* = ref object
    ## Borderless, never-activated window (like a toolkit's menu popup) that
    ## can extend past the main window. It is drawn with the main window's
    ## GL context, which works because both use the same pixel format.
    hwnd: HWND
    dc: HDC
    pos, size*: IVec2
    mapped, formatSet: bool

  PopupInput* = object
    activity*: bool          ## any pointer or paint event arrived
    leftPressed*, leftReleased*, anyPressed*: bool

const PopupClass = "MajesticPopup"

var
  popupClassReady: bool
  popupEvents: PopupInput    ## gathered by popupProc until pollInput drains it
  mainContext: HGLRC
  mainDc: HDC

proc popupProc(h: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM): LRESULT {.stdcall.} =
  case msg
  of WM_MOUSEACTIVATE:
    return MA_NOACTIVATE
  of WM_MOUSEMOVE, WM_PAINT:
    popupEvents.activity = true
    if msg == WM_PAINT:
      discard ValidateRect(h, nil)
      return 0
  of WM_LBUTTONDOWN:
    popupEvents.activity = true
    popupEvents.anyPressed = true
    popupEvents.leftPressed = true
    return 0
  of WM_RBUTTONDOWN, WM_MBUTTONDOWN:
    popupEvents.activity = true
    popupEvents.anyPressed = true
    return 0
  of WM_LBUTTONUP:
    popupEvents.activity = true
    popupEvents.leftReleased = true
    return 0
  else: discard
  DefWindowProcW(h, msg, wParam, lParam)

proc newPopupWindow*(background: ColorRGBX): PopupWindow =
  let inst = GetModuleHandleW(nil)
  var cls = toWide(PopupClass)
  if not popupClassReady:
    popupClassReady = true
    let c = background  # opaque, so premultiplied == straight
    var wc = WNDCLASSEXW(cbSize: sizeof(WNDCLASSEXW).UINT, lpfnWndProc: popupProc,
      hInstance: inst, hCursor: LoadCursorW(0, IDC_ARROW),
      hbrBackground: CreateSolidBrush(c.r.int32 or (c.g.int32 shl 8) or (c.b.int32 shl 16)),
      lpszClassName: cast[ptr WCHAR](cls[0].addr))
    discard RegisterClassExW(wc.addr)
  result = PopupWindow(pos: ivec2(-1, -1))
  result.hwnd = CreateWindowExW(WS_EX_TOOLWINDOW or WS_EX_TOPMOST or WS_EX_NOACTIVATE,
    cast[ptr WCHAR](cls[0].addr), nil, WS_POPUP, 0, 0, 1, 1, 0, 0, inst, nil)
  result.dc = GetDC(result.hwnd)

proc show*(p: PopupWindow, pos, size: IVec2) =
  if pos != p.pos or size != p.size:
    p.pos = pos
    p.size = size
    discard SetWindowPos(p.hwnd, HWND_TOPMOST, pos.x, pos.y, size.x, size.y,
      SWP_NOACTIVATE)
  if not p.mapped:
    p.mapped = true
    discard ShowWindow(p.hwnd, SW_SHOWNOACTIVATE)

proc hide*(p: PopupWindow) =
  if not p.mapped: return
  p.mapped = false
  discard ShowWindow(p.hwnd, SW_HIDE)

proc matchPixelFormat(dc: HDC) =
  ## Gives dc the pixel format of the current (main window's) drawable, so the
  ## main context can render into it.
  let fmt = GetPixelFormat(mainDc)
  var pfd: PIXELFORMATDESCRIPTOR
  discard DescribePixelFormat(mainDc, fmt, sizeof(PIXELFORMATDESCRIPTOR).UINT, pfd.addr)
  discard SetPixelFormat(dc, fmt, pfd.addr)

proc rememberMain() =
  mainContext = glCurrentContext()
  mainDc = glCurrentDc()

proc makeCurrentOn(dc: HDC): bool =
  ## A failed switch leaves no context current: rebind the main window's.
  result = glMakeCurrent(dc, mainContext) != 0
  if not result: discard glMakeCurrent(mainDc, mainContext)

proc beginDraw*(p: PopupWindow): bool =
  ## Points the current GL context at the popup; GL state carries over.
  ## False when that failed: skip the popup this frame (no endDraw).
  rememberMain()
  if not p.formatSet:
    p.formatSet = true
    matchPixelFormat(p.dc)
  makeCurrentOn(p.dc)

proc endDraw*(p: PopupWindow, main: Window) =
  ## Presents the popup and makes the main window current again.
  discard SwapBuffers(p.dc)
  discard glMakeCurrent(main.hdc, mainContext)

proc beginDrawOn*(target: Window): bool =
  ## Points the current (main window's) GL context at another window of the
  ## same pixel format, so it draws with the main window's GL resources.
  ## False when that failed: skip drawing target this frame (no endDrawOn).
  rememberMain()
  makeCurrentOn(target.hdc)

proc endDrawOn*(target, main: Window) =
  ## Presents target and makes the main window current again.
  discard SwapBuffers(target.hdc)
  discard glMakeCurrent(main.hdc, mainContext)

proc pollInput*(popups: openArray[PopupWindow], input: var PopupInput) =
  ## Hands over what the popups saw since the last call (Windy's pollEvents
  ## dispatched their messages to popupProc).
  if popupEvents.activity: input.activity = true
  input.leftPressed = input.leftPressed or popupEvents.leftPressed
  input.leftReleased = input.leftReleased or popupEvents.leftReleased
  input.anyPressed = input.anyPressed or popupEvents.anyPressed
  popupEvents = PopupInput()

# --- clipboard and power -------------------------------------------------------

proc putOnClipboard(fmt: UINT, data: openArray[byte]) =
  let mem = GlobalAlloc(GMEM_MOVEABLE, data.len.UINT_PTR)
  if mem == 0: return
  let p = GlobalLock(mem)
  if data.len > 0: copyMem(p, data[0].unsafeAddr, data.len)
  discard GlobalUnlock(mem)
  if SetClipboardData(fmt, mem) == 0: discard GlobalFree(mem)

proc setClipboardFile*(window: Window, path: string) =
  ## The file goes on the clipboard as a file (CF_HDROP), so Explorer pastes
  ## the file itself, and as its path for text fields.
  if OpenClipboard(window.hwnd) == 0: return
  discard EmptyClipboard()
  let w = toWide(path)  # NUL-terminated; CF_HDROP wants one more NUL after the list
  var drop = newSeq[byte](20 + w.len * 2 + 2)
  drop[0] = 20      # DROPFILES.pFiles: the list follows the 20-byte header
  drop[16] = 1      # DROPFILES.fWide
  copyMem(drop[20].addr, w[0].unsafeAddr, w.len * 2)
  putOnClipboard(CF_HDROP, drop)
  var text = newSeq[byte](w.len * 2)
  copyMem(text[0].addr, w[0].unsafeAddr, w.len * 2)
  putOnClipboard(CF_UNICODETEXT.UINT, text)
  discard CloseClipboard()

proc clipboardFiles*(window: Window): seq[string] =
  ## Files copied in Explorer (CF_HDROP); empty when there are none.
  if IsClipboardFormatAvailable(CF_HDROP) == 0: return
  if OpenClipboard(window.hwnd) == 0: return
  let drop = GetClipboardData(CF_HDROP)
  if drop != 0:
    let n = DragQueryFileW(drop, 0xFFFFFFFF'u32, nil, 0)
    for i in 0'u32 ..< n:
      let len = DragQueryFileW(drop, i, nil, 0)
      var buf = newSeq[uint16](len + 1)
      discard DragQueryFileW(drop, i, cast[ptr WCHAR](buf[0].addr), len + 1)
      result.add fromWide(cast[ptr WCHAR](buf[0].addr))
  discard CloseClipboard()

proc monitorOff*(window: Window) =
  const ScMonitorPower = 0xF170
  discard PostMessageW(window.hwnd, WM_SYSCOMMAND, ScMonitorPower, 2)

proc suspend*(hibernate: bool): bool =
  ## Sleep or hibernate now; false when Windows refused.
  enableShutdownPrivilege()
  SetSuspendState(BOOL(hibernate), 0, 0) != 0

proc lockSession*() =
  discard LockWorkStation()

proc attachStdio*() =
  ## A GUI-subsystem program starts without stdout/stderr, and writing to
  ## them would raise. Use the console of the terminal we were started from,
  ## if any, else discard the output.
  const AttachParentProcess = -1'i32
  proc AttachConsole(pid: int32): BOOL {.stdcall, dynlib: "kernel32", importc.}
  proc GetStdHandle(n: int32): HANDLE {.stdcall, dynlib: "kernel32", importc.}
  const StdOutputHandle = -11'i32
  let h = GetStdHandle(StdOutputHandle)
  if h != 0 and h != -1: return  # redirected (or a console build): keep it
  let target = if AttachConsole(AttachParentProcess) != 0: "CONOUT$" else: "NUL"
  discard reopen(stdout, target, fmWrite)
  discard reopen(stderr, target, fmWrite)
