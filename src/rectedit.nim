## Drawing a rectangle over the video for the Run window's rectangle cards:
## drag out a new one, drag its sides to resize it, drag it or use the arrow
## keys to move it. Numbers are the video's own pixels, anchored top-left,
## as ffmpeg's crop filter takes them.

import std/[math, strformat]
import silky, vmath, bumpy, pixie
import ui, theme

type
  RectGrab = enum
    rgLeft, rgRight, rgTop, rgBottom

  RectCursor* = enum
    rcCross, rcMove, rcMoving, rcResizeH, rcResizeV

  VideoMap* = object
    ## Where the video's pixels land in the window: the frame's center and
    ## size (UI units), its rotation (degrees, a multiple of 90) and the
    ## video's own size.
    center*, size*: Vec2
    rotation*: float32
    video*: IVec2

  RectEdit* = ref object
    rect*: int                ## the rectangle being drawn
    has*: bool                ## one is drawn; until then a drag draws one
    x0*, y0*, x1*, y1*: int   ## video pixels, x0 <= x1 and y0 <= y1
    dragging: bool
    moving: bool
    grab: set[RectGrab]       ## sides being dragged
    pressAt: Vec2             ## video pixels where the drag began
    start: array[4, int]      ## x0, y0, x1, y1 then

const
  Near = 6'f32                ## UI units from a side that grab it

proc rot(v: Vec2, deg: float32): Vec2 =
  let r = deg * PI.float32 / 180
  vec2(v.x * cos(r) - v.y * sin(r), v.x * sin(r) + v.y * cos(r))

proc toScreen*(m: VideoMap, p: Vec2): Vec2 =
  m.center + rot((p / m.video.vec2 - 0.5) * m.size, m.rotation)

proc toVideo*(m: VideoMap, s: Vec2): Vec2 =
  (rot(s - m.center, -m.rotation) / m.size + 0.5) * m.video.vec2

proc spanRect(a, b: Vec2): Rect =
  rect(min(a.x, b.x), min(a.y, b.y), abs(a.x - b.x), abs(a.y - b.y))

proc clip(r, c: Rect): Rect =
  let x0 = max(r.x, c.x)
  let y0 = max(r.y, c.y)
  rect(x0, y0, max(0'f32, min(r.x + r.w, c.x + c.w) - x0), max(0'f32, min(r.y + r.h, c.y + c.h) - y0))

proc screenRect*(e: RectEdit, m: VideoMap): Rect =
  spanRect(m.toScreen(vec2(e.x0.float32, e.y0.float32)), m.toScreen(vec2(e.x1.float32, e.y1.float32)))

proc videoBounds(m: VideoMap): Rect =
  spanRect(m.toScreen(vec2(0, 0)), m.toScreen(m.video.vec2))

proc seed*(e: RectEdit, x, y, w, h: int, m: VideoMap) =
  ## Starts from a rectangle (the cards' numbers), kept inside the video.
  e.x0 = clamp(x, 0, m.video.x)
  e.y0 = clamp(y, 0, m.video.y)
  e.x1 = clamp(x + w, e.x0, m.video.x)
  e.y1 = clamp(y + h, e.y0, m.video.y)
  e.has = e.x1 > e.x0 and e.y1 > e.y0

proc value*(e: RectEdit, dim: string): int =
  case dim
  of "width": e.x1 - e.x0
  of "height": e.y1 - e.y0
  of "x": e.x0
  else: e.y0

proc segDist(p, a, b: Vec2): float32 =
  let ab = b - a
  let t = if ab.lengthSq > 0: clamp(dot(p - a, ab) / ab.lengthSq, 0, 1) else: 0'f32
  (a + ab * t - p).length

proc grabAt(e: RectEdit, m: VideoMap, p: Vec2): set[RectGrab] =
  ## The sides within reach of p (two near a corner).
  if not e.has: return
  proc s(x, y: int): Vec2 = m.toScreen(vec2(x.float32, y.float32))
  let dl = segDist(p, s(e.x0, e.y0), s(e.x0, e.y1))
  let dr = segDist(p, s(e.x1, e.y0), s(e.x1, e.y1))
  let dt = segDist(p, s(e.x0, e.y0), s(e.x1, e.y0))
  let db = segDist(p, s(e.x0, e.y1), s(e.x1, e.y1))
  if min(dl, dr) <= Near: result.incl(if dl <= dr: rgLeft else: rgRight)
  if min(dt, db) <= Near: result.incl(if dt <= db: rgTop else: rgBottom)

proc cursorAt*(e: RectEdit, m: VideoMap, p: Vec2): RectCursor =
  if e.dragging and e.moving: return rcMoving
  let g = if e.dragging: e.grab else: e.grabAt(m, p)
  if g.len == 1:
    # Which way the side runs on screen: the frame may be turned.
    let side = if g * {rgLeft, rgRight} != {}: vec2(0, 1) else: vec2(1, 0)
    return if abs(rot(side, m.rotation).x) < 0.5: rcResizeH else: rcResizeV
  if g.len == 0 and e.has and not e.dragging and p.inside(e.screenRect(m)): return rcMove
  rcCross

proc update*(e: RectEdit, m: VideoMap, mouse: Vec2, press, down: bool): bool =
  ## Mouse handling over the video; press is a left press there. True when
  ## the rectangle changed.
  let before = [e.x0, e.y0, e.x1, e.y1, ord(e.has)]
  let (vw, vh) = (m.video.x.int, m.video.y.int)
  let p = m.toVideo(mouse)
  let q = (x: clamp(int(round(p.x)), 0, vw), y: clamp(int(round(p.y)), 0, vh))
  if press:
    e.dragging = true
    e.pressAt = p
    e.start = [e.x0, e.y0, e.x1, e.y1]
    e.grab = e.grabAt(m, mouse)
    e.moving = e.grab.len == 0 and e.has and mouse.inside(e.screenRect(m))
    if e.grab.len == 0 and not e.moving:
      # A new one, dragged out from its corner here.
      (e.x0, e.y0, e.x1, e.y1) = (q.x, q.y, q.x, q.y)
      e.has = true
      e.grab = {rgRight, rgBottom}
  elif e.dragging and not down:
    e.dragging = false
  elif e.dragging and e.moving:
    let (w, h) = (e.start[2] - e.start[0], e.start[3] - e.start[1])
    e.x0 = clamp(e.start[0] + int(round(p.x - e.pressAt.x)), 0, max(0, vw - w))
    e.y0 = clamp(e.start[1] + int(round(p.y - e.pressAt.y)), 0, max(0, vh - h))
    e.x1 = e.x0 + w
    e.y1 = e.y0 + h
  elif e.dragging:
    if rgLeft in e.grab: e.x0 = q.x
    if rgRight in e.grab: e.x1 = q.x
    if rgTop in e.grab: e.y0 = q.y
    if rgBottom in e.grab: e.y1 = q.y
    # Dragged past the opposite side: that side is now the one dragged.
    if e.x0 > e.x1:
      swap(e.x0, e.x1)
      if rgLeft in e.grab: e.grab = e.grab - {rgLeft} + {rgRight}
      else: e.grab = e.grab - {rgRight} + {rgLeft}
    if e.y0 > e.y1:
      swap(e.y0, e.y1)
      if rgTop in e.grab: e.grab = e.grab - {rgTop} + {rgBottom}
      else: e.grab = e.grab - {rgBottom} + {rgTop}
  [e.x0, e.y0, e.x1, e.y1, ord(e.has)] != before

proc nudge*(e: RectEdit, m: VideoMap, d: IVec2): bool =
  ## Arrow keys: one video pixel in the direction pressed on screen.
  if not e.has or e.dragging or d == ivec2(0, 0): return
  let v = rot(d.vec2, -m.rotation)
  let (w, h) = (e.x1 - e.x0, e.y1 - e.y0)
  let x = clamp(e.x0 + int(round(v.x)), 0, max(0, m.video.x.int - w))
  let y = clamp(e.y0 + int(round(v.y)), 0, max(0, m.video.y.int - h))
  result = x != e.x0 or y != e.y0
  (e.x0, e.y0, e.x1, e.y1) = (x, y, x + w, y + h)

proc dashedLine(ui: Ui, a, b: Vec2, color: ColorRGBX) =
  ## Horizontal or vertical.
  const dash = 5'f32
  const gap = 4'f32
  if abs(b.x - a.x) >= abs(b.y - a.y):
    let (lo, hi) = (min(a.x, b.x), max(a.x, b.x))
    var x = lo
    while x < hi:
      ui.rect(rect(x, a.y, min(dash, hi - x), 1), color)
      x += dash + gap
  else:
    let (lo, hi) = (min(a.y, b.y), max(a.y, b.y))
    var y = lo
    while y < hi:
      ui.rect(rect(a.x, y, 1, min(dash, hi - y)), color)
      y += dash + gap

proc draw*(e: RectEdit, ui: Ui, m: VideoMap, area: Rect, number: int) =
  ## The rectangle with the video outside it dimmed, dashed lines from the
  ## video's top and left edges to its anchored corner, its position by that
  ## corner and its size by the opposite one.
  let bounds = m.videoBounds.clip(area)
  # How to draw, at the top; the rectangle's numbers go over it.
  let hint = &"Rectangle {number}: drag to draw, drag a side to resize, drag inside or " &
    "use the arrow keys to move · Enter confirms · Esc cancels"
  let hs = ui.textSize(hint, FontSmall) + vec2(16, 8)
  let hr = rect(area.x + max(0'f32, (area.w - hs.x) / 2), area.y + 8, min(hs.x, area.w), hs.y)
  ui.rect(hr, colOverlayBg)
  ui.textIn(ui.ellipsize(hint, hr.w - 16, FontSmall), hr, colText, FontSmall, h = CenterAlign)
  if e.has:
    let sr = e.screenRect(m)
    let inner = sr.clip(bounds)
    if inner.w > 0 and inner.h > 0:
      ui.rect(rect(bounds.x, bounds.y, bounds.w, inner.y - bounds.y), colShadow)
      ui.rect(rect(bounds.x, inner.y + inner.h, bounds.w, bounds.y + bounds.h - inner.y - inner.h), colShadow)
      ui.rect(rect(bounds.x, inner.y, inner.x - bounds.x, inner.h), colShadow)
      ui.rect(rect(inner.x + inner.w, inner.y, bounds.x + bounds.w - inner.x - inner.w, inner.h), colShadow)
    proc s(x, y: int): Vec2 = m.toScreen(vec2(x.float32, y.float32))
    let anchor = s(e.x0, e.y0)
    ui.dashedLine(s(0, e.y0), anchor, colRect)
    ui.dashedLine(s(e.x0, 0), anchor, colRect)
    ui.border(rect(sr.x, sr.y, max(1'f32, sr.w), max(1'f32, sr.h)), colRect)
    let center = sr.xy + sr.wh / 2
    for (corner, label) in [(anchor, &"({e.x0}, {e.y0})"),
                            (s(e.x1, e.y1), &"({e.x1 - e.x0}, {e.y1 - e.y0})")]:
      # Outside the rectangle at its corner, or inside when that leaves
      # the video.
      let sz = ui.textSize(label, FontSmall) + vec2(10, 4)
      let left = corner.x <= center.x
      let up = corner.y <= center.y
      let x = if left: corner.x else: corner.x - sz.x
      var box = rect(x, (if up: corner.y - sz.y - 3 else: corner.y + 3), sz.x, sz.y)
      if box.x < bounds.x or box.y < bounds.y or box.x + box.w > bounds.x + bounds.w or
         box.y + box.h > bounds.y + bounds.h:
        box.y = if up: corner.y + 3 else: corner.y - sz.y - 3
      box.x = clamp(box.x, bounds.x, max(bounds.x, bounds.x + bounds.w - sz.x))
      box.y = clamp(box.y, bounds.y, max(bounds.y, bounds.y + bounds.h - sz.y))
      ui.rect(box, colShadow)
      ui.textIn(label, box, colWhite, FontSmall, h = CenterAlign)
