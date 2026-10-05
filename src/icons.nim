## Vector icons rasterized into the Silky atlas at startup (white; tinted when drawn).

import std/math
import pixie, silky

const musicPath* = "M12 3v10.55c-.59-.34-1.27-.55-2-.55-2.21 0-4 1.79-4 4s1.79 4 4 4 4-1.79 4-4V7h4V3h-6z"
const crownPath* = "M5 16L3 5l5.5 5L12 4l3.5 6L21 5l-2 11H5zm14 3c0 .6-.4 1-1 1H6c-.6 0-1-.4-1-1v-1h14v1z"

const iconPaths = {
  "play": (24, "M8 5v14l11-7z"),
  "pause": (24, "M6 5h4v14H6zM14 5h4v14h-4z"),
  "stop": (24, "M6 6h12v12H6z"),
  "prev": (24, "M6 6h2v12H6zM9.5 12L18 18V6z"),
  "next": (24, "M16 6h2v12h-2zM6 18l8.5-6L6 6z"),
  "slower": (24, "M11 18V6l-8.5 6zM20.5 18V6L12 12z"),
  "faster": (24, "M3.5 18l8.5-6L3.5 6zM13 18l8.5-6L13 6z"),
  "check": (24, "M9 16.2L4.8 12l-1.4 1.4L9 19 21 7l-1.4-1.4z"),
  "radio": (24, "M12 7.5a4.5 4.5 0 1 1 0 9a4.5 4.5 0 1 1 0-9z"),
  "arrow": (24, "M9.5 7l5 5-5 5z"),
  "expand": (24, "M7 9.5l5 5 5-5z"),
  "film": (24, "M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4c-1.1 0-1.99.9-1.99 2L2 18c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V4h-4z"),
  "music": (24, musicPath),
  "nofile": (24, "M6 2c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6H6zm7 7V3.5L18.5 9H13z"),
  "mono": (24, "M3 9v6h4l5 5V4L7 9H3zm11-1v8c1.7-.8 3-2.3 3-4s-1.3-3.2-3-4z"),
  "nosound": (24, "M3 9v6h4l5 5V4L7 9H3zM14.5 9.5l1.4-1.4 2.1 2.1 2.1-2.1 1.4 1.4-2.1 2.1 2.1 2.1-1.4 1.4-2.1-2.1-2.1 2.1-1.4-1.4 2.1-2.1z"),
  "stereo": (32, "M14 9v6h-3l-4 5V4l4 5zM5 8v8c-1.7-.8-3-2.3-3-4s1.3-3.2 3-4zM18 9v6h3l4 5V4l-4 5zM27 8v8c1.7-.8 3-2.3 3-4s-1.3-3.2-3-4z"),
  "volume": (24, "M3 9v6h4l5 5V4L7 9H3zm13.5 3c0-1.77-1.02-3.29-2.5-4.03v8.05c1.48-.73 2.5-2.25 2.5-4.02zM14 3.23v2.06c2.89.86 5 3.54 5 6.71s-2.11 5.85-5 6.71v2.06c4.01-.91 7-4.49 7-8.77s-2.99-7.86-7-8.77z"),
  "playlist": (24, "M3 10h11v2H3zm0-4h11v2H3zm0 8h7v2H3zm13-1v8l6-4z"),
  "crown": (24, crownPath),
  "terminal": (24, "M20 4H4c-1.11 0-2 .9-2 2v12c0 1.1.89 2 2 2h16c1.1 0 2-.9 2-2V6c0-1.1-.89-2-2-2zm0 14H4V8h16v10zm-2-1h-6v-2h6v2zM7.5 17l-1.41-1.41L8.67 13l-2.59-2.59L7.5 9l4 4-4 4z"),
  "close": (24, "M19 6.41L17.59 5 12 10.59 6.41 5 5 6.41 10.59 12 5 17.59 6.41 19 12 13.41 17.59 19 19 17.59 13.41 12z"),
}

proc renderIcon*(path: string, viewBox, size: int, color = color(1, 1, 1, 1)): Image =
  ## viewBox is the square (or 32x24 for wide icons) design grid width.
  let wide = viewBox == 32
  let h = size
  let w = if wide: size * 4 div 3 else: size
  result = newImage(w, h)
  let s = size.float32 / 24
  result.fillPath(parsePath(path), color, scale(vec2(s, s)))

proc ringIcon(size: int): Image =
  ## Radio button outline.
  result = newImage(size, size)
  let ctx = newContext(result)
  ctx.strokeStyle = color(1, 1, 1, 1)
  let k = size / 16
  ctx.lineWidth = 1.5 * k
  ctx.strokeCircle(circle(vec2(size / 2, size / 2), size / 2 - 1.5 * k))

proc addIcons*(builder: AtlasBuilder, scale = 1'f32) =
  ## Names keep the nominal size; images are rasterized at size * scale.
  proc px(size: int): int = int(round(size.float32 * scale))
  for (name, spec) in iconPaths:
    for size in [16, 20]:
      let img = renderIcon(spec[1], spec[0], px(size))
      discard builder.addImage(name & $size, img)
  discard builder.addImage("ring16", ringIcon(px(16)))

proc appIcon*(): Image =
  ## Window icon: accent crown on a dark rounded tile.
  result = newImage(64, 64)
  let ctx = newContext(result)
  ctx.fillStyle = parseHtmlColor("#17181c")
  ctx.fillRoundedRect(rect(0, 0, 64, 64), 14)
  result.fillPath(parsePath(crownPath), parseHtmlColor("#9d8cff"),
    translate(vec2(8, 6)) * scale(vec2(2, 2)))
