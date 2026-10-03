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

proc endFrame*(ui: Ui) =
  if ui.window.buttonReleased[MouseLeft] or not ui.window.buttonDown[MouseLeft]:
    ui.activeId = ""
    ui.pressId = ""

proc inside*(p: Vec2, r: Rect): bool =
  p.x >= r.x and p.y >= r.y and p.x < r.x + r.w and p.y < r.y + r.h

proc hover*(ui: Ui, r: Rect): bool =
  not ui.captured and ui.mouse.inside(r)

proc pressed*(ui: Ui, b = MouseLeft): bool =
  ui.window.buttonPressed[b] and not (b == MouseLeft and ui.clickConsumed)

proc released*(ui: Ui, b = MouseLeft): bool =
  ui.window.buttonReleased[b] and not (b == MouseLeft and ui.clickConsumed)

proc down*(ui: Ui, b = MouseLeft): bool = ui.window.buttonDown[b]

proc consumeClick*(ui: Ui) = ui.clickConsumed = true

proc scroll*(ui: Ui): float32 =
  if ui.scrollConsumed: 0'f32 else: ui.window.scrollDelta.y

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
  if hov and ui.pressed():
    ui.pressId = id
    ui.consumeClick()
  let base = if primary: colAccent else: colPanelRaised
  let col =
    if hov and ui.pressId == id and ui.down(): colPressed
    elif hov: (if primary: colAccentHover else: colHover)
    else: base
  ui.rect(r, col)
  if not primary: ui.border(r, colBorder)
  ui.textIn(label, r, if primary: colOnAccent else: colText, h = CenterAlign)
  if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id:
    result = true

proc checkbox*(ui: Ui, id: string, pos: Vec2, label: string, value: var bool): bool =
  let box = rect(pos.x, pos.y + 3, 16, 16)
  let r = rect(pos.x, pos.y, 22 + ui.textSize(label).x, 22)
  let hov = ui.hover(r)
  if hov and ui.pressed():
    ui.pressId = id
    ui.consumeClick()
  ui.rect(box, if value: colAccent else: colPanelRaised)
  ui.border(box, if hov: colAccent else: colBorder)
  if value: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
  ui.textIn(label, rect(pos.x + 24, pos.y, r.w, 22), colText)
  if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == id:
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

proc fmtTime*(t: float): string =
  let s = max(0, int(t))
  &"{s div 3600:02}:{(s mod 3600) div 60:02}:{s mod 60:02}"
