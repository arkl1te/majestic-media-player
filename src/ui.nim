## Small immediate-mode widget layer on top of Silky's drawing primitives.

import std/[strformat, strutils, math]
import silky, vmath, bumpy, chroma, pixie
import theme, xwin

type
  Ui* = ref object
    sk*: Silky
    window*: Window
    mouse*: Vec2
    size*: Vec2
    captured*: bool          ## A popup/modal owns the mouse this frame.
    clickConsumed*: bool     ## The left press/release was handled already.
    activeId*: string        ## Widget currently being dragged.
    pressId*: string         ## Widget the left press started on.
    scrollConsumed*: bool
    tooltip*: string
    tooltipAnchor*: Rect
    fakeMouse*: Vec2         ## debug scripting: overrides the pointer when x >= 0
    hitClip*: Rect           ## when w > 0, the mouse only hits widgets inside it
    focusId*: string         ## text field owning the keyboard
    caret*: int              ## byte offset of the caret in the focused field
    fieldScroll*: float32    ## horizontal scroll of the focused field's text
    editText*: string        ## numberField: text being typed
    typed*: string           ## text typed since the previous frame
    typedPending*: string    ## filled by the window's rune callback
    navId*: string           ## widget with keyboard focus (moved with Tab)
    navVisible*: bool        ## keyboard was used last: draw the focus ring
    focusFresh*: bool        ## focusId was just given by Tab, not by a click
    enterUsed*: bool         ## a focused button took Enter this frame
    tabStops*: seq[TabStop]  ## focusable widgets drawn this frame, in order

  TabStop* = object
    id*: string
    r*: Rect
    edit*: bool              ## a text input: focusing it starts editing

  EditEvent* = enum
    eeChanged, eeFocused, eeCommitted

proc newUi*(sk: Silky, window: Window): Ui =
  Ui(sk: sk, window: window, fakeMouse: vec2(-1, -1))

proc beginFrame*(ui: Ui) =
  ui.mouse = if ui.fakeMouse.x >= 0: ui.fakeMouse else: ui.window.mousePos.vec2
  # Windy only tracks the pointer from motion events, so a click without a
  # preceding motion (e.g. the first one after the window appears or gets
  # focus) would be tested against a stale position. Ask the server instead.
  if ui.fakeMouse.x < 0:
    for b in [MouseLeft, MouseRight, MouseMiddle]:
      if ui.window.buttonPressed[b] or ui.window.buttonReleased[b]:
        ui.mouse = ui.window.pointerPos.local.vec2
        break
  ui.size = ui.window.size.vec2
  ui.captured = false
  ui.clickConsumed = false
  ui.scrollConsumed = false
  ui.tooltip = ""
  ui.typed = ui.typedPending
  ui.typedPending = ""
  ui.enterUsed = false
  ui.tabStops.setLen 0
  for b in [MouseLeft, MouseRight, MouseMiddle]:
    if ui.window.buttonPressed[b]: ui.navVisible = false

proc endFrame*(ui: Ui) =
  if ui.window.buttonReleased[MouseLeft] or not ui.window.buttonDown[MouseLeft]:
    ui.activeId = ""
    ui.pressId = ""

proc inside*(p: Vec2, r: Rect): bool =
  p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and p.y < r.y + r.h

proc hover*(ui: Ui, r: Rect): bool =
  not ui.captured and ui.mouse.inside(r) and
    (ui.hitClip.w <= 0 or ui.mouse.inside(ui.hitClip))

proc pressed*(ui: Ui, b = MouseLeft): bool =
  ui.window.buttonPressed[b] and not (b == MouseLeft and ui.clickConsumed)

proc released*(ui: Ui, b = MouseLeft): bool =
  ui.window.buttonReleased[b] and not (b == MouseLeft and ui.clickConsumed)

proc down*(ui: Ui, b = MouseLeft): bool = ui.window.buttonDown[b]

proc consumeClick*(ui: Ui) = ui.clickConsumed = true

proc scroll*(ui: Ui): float32 =
  if ui.scrollConsumed: 0'f32 else: ui.window.scrollDelta.y

proc wheelNotches*(ui: Ui): float32 =
  ## Wheel notches this frame, + = down. Windy reports ±10 per notch on X11
  ## (added up when several arrive within one poll).
  ui.scroll() / 10

proc shiftDown(w: Window): bool = w.buttonDown[KeyLeftShift] or w.buttonDown[KeyRightShift]

# --- keyboard focus ----------------------------------------------------------

proc tabStop*(ui: Ui, id: string, r: Rect, edit = false): bool =
  ## Adds a widget to this frame's Tab order; true when it has keyboard focus.
  ui.tabStops.add TabStop(id: id, r: r, edit: edit)
  ui.navId == id

proc navKey*(ui: Ui, id: string, key: Button): bool =
  ## key was pressed while widget id has keyboard focus (and no text field does).
  ui.navId == id and ui.focusId.len == 0 and ui.window.buttonPressed[key]

proc tabNavigate*(ui: Ui): int =
  ## Moves keyboard focus on Tab / Shift+Tab through this frame's stops.
  ## Returns the index of the newly focused stop, or -1.
  let w = ui.window
  result = -1
  if not w.buttonPressed[KeyTab] or ui.tabStops.len == 0: return
  if w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl] or
     w.buttonDown[KeyLeftAlt] or w.buttonDown[KeyRightAlt]: return
  let n = ui.tabStops.len
  var i = -1
  for k, s in ui.tabStops:
    if s.id == ui.navId: i = k
  result =
    if i < 0: (if w.shiftDown: n - 1 else: 0)
    else: (i + (if w.shiftDown: n - 1 else: 1)) mod n
  let s = ui.tabStops[result]
  ui.navId = s.id
  ui.navVisible = true
  ui.focusId = if s.edit: s.id else: ""
  ui.focusFresh = s.edit

# --- drawing helpers -------------------------------------------------------

proc rect*(ui: Ui, r: Rect, color: ColorRGBX) =
  ui.sk.drawRect(r.xy, r.wh, color)

proc border*(ui: Ui, r: Rect, color: ColorRGBX, t = 1'f32) =
  ui.sk.drawRect(r.xy, vec2(r.w, t), color)
  ui.sk.drawRect(vec2(r.x, r.y + r.h - t), vec2(r.w, t), color)
  ui.sk.drawRect(vec2(r.x, r.y), vec2(t, r.h), color)
  ui.sk.drawRect(vec2(r.x + r.w - t, r.y), vec2(t, r.h), color)

proc textSize*(ui: Ui, s: string, font = FontMain): Vec2 =
  ui.sk.getTextSize(font, s)

proc text*(ui: Ui, s: string, pos: Vec2, color = colText, font = FontMain) =
  discard ui.sk.drawText(font, s, pos.floor, color, clip = false)

proc textIn*(ui: Ui, s: string, r: Rect, color = colText, font = FontMain,
             h = LeftAlign, v = MiddleAlign) =
  ## Draws text clipped and aligned inside a rect.
  discard ui.sk.drawText(font, s, r.xy.floor, color, r.w, r.h, clip = true,
    hAlign = h, vAlign = v)

proc ellipsize*(ui: Ui, s: string, maxW: float32, font = FontMain): string =
  if ui.textSize(s, font).x <= maxW: return s
  var lo = 0
  var hi = s.len
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if ui.textSize(s[0 ..< mid] & "…", font).x <= maxW: lo = mid
    else: hi = mid - 1
  # Avoid cutting a UTF-8 sequence in half.
  while lo > 0 and (s[lo].ord and 0xC0) == 0x80: dec lo
  s[0 ..< lo] & "…"

proc focusRing*(ui: Ui, r: Rect) =
  ## Keyboard focus marker around a widget, shown after Tab was used.
  if ui.navVisible: ui.border(rect(r.x - 3, r.y - 3, r.w + 6, r.h + 6), colAccent)

proc icon*(ui: Ui, name: string, center: Vec2, color = colText) =
  let sz = ui.sk.getImageSize(name)
  ui.sk.drawImage(name, (center - sz / 2).floor, color)

proc tip*(ui: Ui, r: Rect, s: string) =
  if ui.hover(r): ui.tooltip = s; ui.tooltipAnchor = r

proc drawTooltip*(ui: Ui) =
  if ui.tooltip.len == 0 or ui.sk.mouseIdleTime < 0.5: return
  let sz = ui.textSize(ui.tooltip, FontSmall) + vec2(14, 8)
  var p = vec2(ui.mouse.x + 12, ui.tooltipAnchor.y - sz.y - 6)
  p.x = clamp(p.x, 4, ui.size.x - sz.x - 4)
  if p.y < 4: p.y = ui.tooltipAnchor.y + ui.tooltipAnchor.h + 6
  ui.sk.pushLayer(PopupsLayer)
  ui.rect(rect(p, sz), colPopup)
  ui.border(rect(p, sz), colBorder)
  ui.text(ui.tooltip, p + vec2(7, 4), colText, FontSmall)
  ui.sk.popLayer()

# --- widgets ---------------------------------------------------------------

proc iconButton*(ui: Ui, id: string, r: Rect, iconName: string, tooltip = "",
                 enabled = true, toggled = false): bool =
  let hov = enabled and ui.hover(r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.consumeClick()
  let isDown = hov and ui.pressId == id and ui.down()
  if isDown: ui.rect(r, colPressed)
  elif hov: ui.rect(r, colHover)
  let col =
    if not enabled: colTextDisabled
    elif toggled: colAccent
    elif hov: colWhite
    else: colText
  ui.icon(iconName, r.xy + r.wh / 2, col)
  if tooltip.len > 0: ui.tip(r, tooltip)
  if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id:
    result = true

proc textButton*(ui: Ui, id: string, r: Rect, label: string, primary = false): bool =
  let hov = ui.hover(r)
  let focused = ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.navId = id
    ui.consumeClick()
  let base = if primary: colAccent else: colPanelRaised
  let col =
    if hov and ui.pressId == id and ui.down(): colPressed
    elif hov: (if primary: colAccentHover else: colHover)
    else: base
  ui.rect(r, col)
  if not primary: ui.border(r, colBorder)
  ui.textIn(label, r, if primary: colOnAccent else: colText, h = CenterAlign)
  if focused: ui.focusRing(r)
  if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id:
    result = true
  if ui.navKey(id, KeySpace) or ui.navKey(id, KeyEnter) or ui.navKey(id, NumpadEnter):
    ui.enterUsed = true
    result = true

proc checkbox*(ui: Ui, id: string, pos: Vec2, label: string, value: var bool): bool =
  let box = rect(pos.x, pos.y + 3, 16, 16)
  let r = rect(pos.x, pos.y, 22 + ui.textSize(label).x, 22)
  let hov = ui.hover(r)
  let focused = ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.navId = id
    ui.consumeClick()
  if focused: ui.focusRing(r)
  ui.rect(box, if value: colAccent else: colPanelRaised)
  ui.border(box, if hov: colAccent else: colBorder)
  if value: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
  ui.textIn(label, rect(pos.x + 24, pos.y, r.w, 22), colText)
  if (hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id) or
     ui.navKey(id, KeySpace):
    value = not value
    result = true

proc stepper*(ui: Ui, id: string, pos: Vec2, label: string, value: var float,
              step, lo, hi: float, unit = "", decimals = 0): bool =
  ## "label   [-] value [+]" row; returns true when value changed.
  ui.textIn(label, rect(pos.x, pos.y, 220, 24), colText)
  let minus = rect(pos.x + 230, pos.y, 24, 24)
  let valR = rect(pos.x + 256, pos.y, 84, 24)
  let plus = rect(pos.x + 342, pos.y, 24, 24)
  ui.rect(valR, colPanel)
  ui.border(valR, colBorder)
  let shown = if decimals == 0: $int(round(value)) else: formatFloat(value, ffDecimal, decimals)
  ui.textIn(shown & unit, valR, colText, h = CenterAlign)
  for (r, dir, sid) in [(minus, -1.0, "-"), (plus, 1.0, "+")]:
    let hov = ui.hover(r)
    if hov and ui.pressed():
      ui.pressId = id & sid
      ui.consumeClick()
    ui.rect(r, if hov: colHover else: colPanelRaised)
    ui.border(r, colBorder)
    ui.textIn(sid, r, colText, h = CenterAlign)
    if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id & sid:
      value = clamp(value + dir * step, lo, hi)
      result = true

proc radioButton*(ui: Ui, id: string, pos: Vec2, label: string, selected: bool,
                  enabled = true): bool =
  ## Returns true when clicked while not selected.
  let r = rect(pos.x, pos.y, 22 + ui.textSize(label).x, 22)
  let hov = enabled and ui.hover(r)
  let focused = enabled and ui.tabStop(id, r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.navId = id
    ui.consumeClick()
  if focused: ui.focusRing(r)
  let c = vec2(pos.x + 8, pos.y + 11)
  ui.icon("ring16", c, if hov or selected: colAccent else: colBorder)
  if selected: ui.icon("radio16", c, if enabled: colAccent else: colTextDisabled)
  ui.textIn(label, rect(pos.x + 24, pos.y, r.w, 22),
    if enabled: colText else: colTextDisabled)
  if (hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id) or
     (focused and ui.navKey(id, KeySpace)):
    result = not selected

proc groupHeader*(ui: Ui, pos: Vec2, w: float32, title: string) =
  ## Section title followed by a rule to the right edge.
  let tw = ui.textSize(title, FontSmall).x
  ui.textIn(title, rect(pos.x, pos.y, tw + 2, 20), colTextDim, FontSmall)
  ui.rect(rect(pos.x + tw + 10, pos.y + 10, max(0'f32, w - tw - 10), 1), colBorder)

proc prevRune(s: string, i: int): int =
  result = max(0, i - 1)
  while result > 0 and (s[result].ord and 0xC0) == 0x80: dec result

proc nextRune(s: string, i: int): int =
  result = min(s.len, i + 1)
  while result < s.len and (s[result].ord and 0xC0) == 0x80: inc result

proc textField*(ui: Ui, id: string, r: Rect, text: var string,
                placeholder = ""): set[EditEvent] =
  ## Single-line text input. Click to focus; Enter, Tab, Escape or a click
  ## elsewhere ends editing (eeCommitted).
  let w = ui.window
  let hov = ui.hover(r)
  let pad = 7'f32
  discard ui.tabStop(id, r, edit = true)
  if ui.focusId == id and ui.focusFresh:
    # Focused with Tab: edit from the end of the text.
    ui.focusFresh = false
    ui.fieldScroll = 0
    ui.caret = text.len
    result.incl eeFocused
  if ui.focusId == id and w.buttonPressed[MouseLeft] and not hov:
    ui.focusId = ""
    result.incl eeCommitted
  if hov and ui.pressed():
    ui.consumeClick()
    ui.navId = id
    if ui.focusId != id:
      ui.focusId = id
      ui.fieldScroll = 0
      result.incl eeFocused
    # Caret at the character boundary nearest to the click.
    let x = ui.mouse.x - r.x - pad + ui.fieldScroll
    var i = 0
    while i < text.len:
      let j = nextRune(text, i)
      let mid = (ui.textSize(text[0 ..< i]).x + ui.textSize(text[0 ..< j]).x) / 2
      if x < mid: break
      i = j
    ui.caret = i
  let focused = ui.focusId == id
  if focused:
    ui.caret = clamp(ui.caret, 0, text.len)
    let ctrl = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
    var ins = ""
    for ch in ui.typed:  # drop control characters such as Tab
      if ch.ord >= 0x20 and ch.ord != 0x7f: ins.add ch
    if ctrl and w.buttonPressed[KeyV]:
      ins.add getClipboardString().multiReplace(("\r", ""), ("\n", " "))
    if ins.len > 0:
      text.insert(ins, ui.caret)
      ui.caret += ins.len
      result.incl eeChanged
    if w.buttonPressed[KeyBackspace] and ui.caret > 0:
      let a = if ctrl: 0 else: prevRune(text, ui.caret)
      text.delete(a ..< ui.caret)
      ui.caret = a
      result.incl eeChanged
    if w.buttonPressed[KeyDelete] and ui.caret < text.len:
      text.delete(ui.caret ..< nextRune(text, ui.caret))
      result.incl eeChanged
    if w.buttonPressed[KeyLeft]: ui.caret = prevRune(text, ui.caret)
    if w.buttonPressed[KeyRight]: ui.caret = nextRune(text, ui.caret)
    if w.buttonPressed[KeyHome]: ui.caret = 0
    if w.buttonPressed[KeyEnd]: ui.caret = text.len
    if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or
       w.buttonPressed[KeyTab] or w.buttonPressed[KeyEscape]:
      ui.focusId = ""
      result.incl eeCommitted
  ui.rect(r, colBackground)
  ui.border(r, if focused: colAccent elif hov: colTextDim else: colBorder)
  let inner = rect(r.x + pad, r.y, r.w - pad * 2, r.h)
  ui.sk.pushClipRect(inner)
  if focused:
    let cx = ui.textSize(text[0 ..< ui.caret]).x
    if cx - ui.fieldScroll > inner.w - 2: ui.fieldScroll = cx - inner.w + 2
    if cx - ui.fieldScroll < 0: ui.fieldScroll = cx
    ui.textIn(text, rect(inner.x - ui.fieldScroll, r.y, inner.w + ui.fieldScroll + 4000, r.h), colText)
    ui.rect(rect(inner.x + cx - ui.fieldScroll, r.y + 5, 1, r.h - 10), colAccent)
  elif text.len > 0:
    ui.textIn(text, rect(inner.x, r.y, inner.w + 4000, r.h), colText)
  else:
    ui.textIn(placeholder, rect(inner.x, r.y, inner.w + 4000, r.h), colTextDisabled)
  ui.sk.popClipRect()

proc numberField*(ui: Ui, id: string, r: Rect, value: var float,
                  step, lo, hi: float, decimals = 0): bool =
  ## [-] value [+]: type a number, click the buttons or scroll over it.
  ## Returns true when value changed.
  let fid = id & "#field"
  proc fmt(v: float): string =
    if decimals == 0: $int(round(v)) else: formatFloat(v, ffDecimal, decimals)
  let minus = rect(r.x, r.y, 24, r.h)
  let plus = rect(r.x + r.w - 24, r.y, 24, r.h)
  let fr = rect(r.x + 26, r.y, r.w - 52, r.h)
  if ui.focusId == fid and ui.focusFresh: ui.editText = fmt(value)
  var buf = if ui.focusId == fid: ui.editText else: fmt(value)
  let ev = ui.textField(fid, fr, buf)
  if eeFocused in ev:
    buf = fmt(value)
    ui.caret = buf.len
  # Up/Down step the value while typing in it, keeping the field focused.
  var keyDelta = 0.0
  if ui.focusId == fid:
    if ui.window.buttonPressed[KeyUp]: keyDelta = step
    if ui.window.buttonPressed[KeyDown]: keyDelta = -step
    if keyDelta != 0:
      try:
        let v = clamp(parseFloat(buf.strip), lo, hi)
        if v != value:
          value = v
          result = true
      except ValueError: discard
  if ui.focusId == fid: ui.editText = buf
  if eeCommitted in ev:
    try:
      let v = clamp(parseFloat(buf.strip), lo, hi)
      if v != value:
        value = v
        result = true
    except ValueError: discard
  var delta = 0.0
  if ui.hover(fr) and ui.scroll() != 0 and ui.focusId != fid:
    delta = if ui.scroll() < 0: step else: -step
    ui.scrollConsumed = true
  for (b, dir, sid) in [(minus, -1.0, "-"), (plus, 1.0, "+")]:
    let hov = ui.hover(b)
    if hov and ui.pressed():
      ui.pressId = id & sid
      ui.consumeClick()
    ui.rect(b, if hov and ui.down() and ui.pressId == id & sid: colPressed
               elif hov: colHover else: colPanelRaised)
    ui.border(b, colBorder)
    ui.textIn(sid, b, colText, h = CenterAlign)
    if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id & sid:
      delta = dir * step
  if delta != 0 or keyDelta != 0:
    # Snap to the step grid so typed odd values rejoin it.
    let v = clamp(round((value + delta + keyDelta) / step) * step, lo, hi)
    if v != value:
      value = v
      result = true
    if keyDelta != 0:
      ui.editText = fmt(value)
      ui.caret = ui.editText.len
    elif ui.focusId == fid: ui.focusId = ""

proc fmtTime*(t: float, millis = false): string =
  ## HH:MM:SS, or HH:MM:SS.mmm with millis.
  let ms = max(0, int(t * 1000))
  let s = ms div 1000
  result = &"{s div 3600:02}:{(s mod 3600) div 60:02}:{s mod 60:02}"
  if millis: result.add &".{ms mod 1000:03}"
