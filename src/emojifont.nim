## Color emoji fonts, which pixie can't draw: their glyphs are pictures, not
## outlines. Two kinds are read:
## - CBDT/CBLC (Noto Color Emoji, Linux): a PNG per glyph at one or more
##   sizes (strikes); the biggest strike is scaled down.
## - COLR v0/CPAL (Segoe UI Emoji, Windows; Twemoji Mozilla): outline layers,
##   each filled with a palette color, drawn with pixie.
## glyphcache adds the pictures to the UI atlas as color glyphs. Sequences
## (ZWJ families, flags, skin tones) aren't joined: their parts draw one by one.

import std/[tables, unicode]
import pixie, pixie/fontformats/opentype {.all.}, flatty/binny, vmath

type
  EmojiKind = enum ekCbdt, ekColr

  EmojiFont* = ref object
    buf: string
    kind: EmojiKind
    cmap: Table[Rune, uint16]
    upem: float32
    # CBDT: the strike used
    cblc, cbdt: int          ## table offsets
    ppem: float32
    subtables: seq[tuple[first, last: int, offset: int]]  ## index subtables (absolute offsets)
    # COLR
    ot: OpenType             ## outlines and advances
    colr: int
    numBase, baseOffset, layerOffset: int
    palette: seq[ColorRGBA]

  EmojiGlyph* = object
    image*: Image            ## premultiplied RGBA, nil for an empty glyph
    x*, y*: float32          ## the picture's top left from the pen at the baseline, pixels
    advance*: float32

proc u8(b: string, i: int): int = b[i].ord
proc i8(b: string, i: int): int = cast[int8](b[i]).int
proc u16(b: string, i: int): int = b.readUint16(i).swap().int
proc u32(b: string, i: int): int = b.readUint32(i).swap().int

proc loadEmojiFont*(path: string, index = 0): EmojiFont =
  ## The color emoji font in path (face index of a collection), nil when it
  ## has no CBDT or COLR glyphs or can't be read.
  try:
    let buf = readFile(path)
    var start = 0
    if buf.len >= 12 and buf[0 ..< 4] == "ttcf":
      if index >= buf.u32(8): return nil
      start = buf.u32(12 + 4 * index)
    if buf.len < start + 12: return nil
    let n = buf.u16(start + 4)
    if buf.len < start + 12 + 16 * n: return nil
    var tables: Table[string, int]
    for t in 0 ..< n:
      let r = start + 12 + 16 * t
      tables[buf[r ..< r + 4]] = buf.u32(r + 8)
    if "cmap" notin tables or "head" notin tables: return nil
    let f = EmojiFont(buf: buf, upem: buf.u16(tables["head"] + 18).float32)
    if "CBLC" in tables and "CBDT" in tables:
      f.kind = ekCbdt
      f.cmap = parseCmapTable(buf, tables["cmap"]).runeToGlyphId
      f.cblc = tables["CBLC"]
      f.cbdt = tables["CBDT"]
      # The biggest strike: scaled down, it looks best.
      let sizes = buf.u32(f.cblc + 4)
      var best = -1
      for s in 0 ..< sizes:
        let r = f.cblc + 8 + 48 * s
        if best < 0 or buf.u8(r + 44) > buf.u8(f.cblc + 8 + 48 * best + 44): best = s
      if best < 0: return nil
      let r = f.cblc + 8 + 48 * best
      f.ppem = buf.u8(r + 44).float32
      let arr = f.cblc + buf.u32(r)
      for k in 0 ..< buf.u32(r + 8):
        let a = arr + 8 * k
        f.subtables.add (buf.u16(a), buf.u16(a + 2), arr + buf.u32(a + 4))
    elif "COLR" in tables and "CPAL" in tables:
      f.kind = ekColr
      f.ot = parseOpenType(buf, start)
      f.cmap = f.ot.cmap.runeToGlyphId
      f.colr = tables["COLR"]
      f.numBase = buf.u16(f.colr + 2)
      f.baseOffset = f.colr + buf.u32(f.colr + 4)
      f.layerOffset = f.colr + buf.u32(f.colr + 8)
      if f.numBase == 0: return nil
      let cpal = tables["CPAL"]
      let entries = buf.u16(cpal + 2)
      let records = cpal + buf.u32(cpal + 8)
      let first = buf.u16(cpal + 12)  # palette 0
      for e in 0 ..< entries:
        let c = records + 4 * (first + e)
        f.palette.add rgba(buf.u8(c + 2).uint8, buf.u8(c + 1).uint8, buf.u8(c).uint8,
                           buf.u8(c + 3).uint8)
    else:
      return nil
    result = f
  except CatchableError, IndexDefect, RangeDefect:  # a font pixie misreads (see glyphcache.loadFace)
    result = nil

proc baseRecord(f: EmojiFont, gid: int): tuple[first, count: int] =
  ## COLR layers of gid (count 0: none); records are sorted by glyph id.
  var (lo, hi) = (0, f.numBase - 1)
  while lo <= hi:
    let mid = (lo + hi) div 2
    let r = f.baseOffset + 6 * mid
    let g = f.buf.u16(r)
    if g == gid: return (f.buf.u16(r + 2), f.buf.u16(r + 4))
    if g < gid: lo = mid + 1 else: hi = mid - 1

proc pngOf(f: EmojiFont, gid: int): tuple[png: string, w, h, bx, by, adv: int] =
  ## The CBDT picture of gid and its metrics at the strike's size.
  let b = f.buf
  for st in f.subtables:
    if gid < st.first or gid > st.last: continue
    let
      indexFormat = b.u16(st.offset)
      imageFormat = b.u16(st.offset + 2)
      dataOffset = f.cbdt + b.u32(st.offset + 4)
      i = gid - st.first
    var glyph = -1
    var big = -1  # bigGlyphMetrics shared by the subtable (formats 2 and 5)
    case indexFormat
    of 1: glyph = dataOffset + b.u32(st.offset + 8 + 4 * i)
    of 3: glyph = dataOffset + b.u16(st.offset + 8 + 2 * i)
    of 2:
      glyph = dataOffset + i * b.u32(st.offset + 8)
      big = st.offset + 12
    of 4:
      let n = b.u32(st.offset + 8)
      for j in 0 ..< n:
        let e = st.offset + 12 + 4 * j
        if b.u16(e) == gid:
          glyph = dataOffset + b.u16(e + 2)
          break
    of 5:
      let n = b.u32(st.offset + 20)
      for j in 0 ..< n:
        if b.u16(st.offset + 24 + 2 * j) == gid:
          glyph = dataOffset + j * b.u32(st.offset + 8)
          break
      big = st.offset + 12
    else: discard
    if glyph < 0: return
    case imageFormat
    of 17:  # smallGlyphMetrics, PNG
      let n = b.u32(glyph + 5)
      return (b[glyph + 9 ..< glyph + 9 + n], b.u8(glyph + 1), b.u8(glyph), b.i8(glyph + 2),
              b.i8(glyph + 3), b.u8(glyph + 4))
    of 18:  # bigGlyphMetrics, PNG
      let n = b.u32(glyph + 8)
      return (b[glyph + 12 ..< glyph + 12 + n], b.u8(glyph + 1), b.u8(glyph), b.i8(glyph + 2),
              b.i8(glyph + 3), b.u8(glyph + 4))
    of 19:  # PNG, metrics in the index subtable
      if big < 0: return
      let n = b.u32(glyph)
      return (b[glyph + 4 ..< glyph + 4 + n], b.u8(big + 1), b.u8(big), b.i8(big + 2),
              b.i8(big + 3), b.u8(big + 4))
    else: return

proc hasEmoji*(f: EmojiFont, r: Rune): bool =
  if f == nil or r notin f.cmap: return false
  let gid = f.cmap[r].int
  case f.kind
  of ekCbdt:
    for st in f.subtables:
      if gid >= st.first and gid <= st.last: return true
    false
  of ekColr: f.baseRecord(gid).count > 0

proc shrink(img: Image, w, h: int): Image =
  ## img scaled to w×h, halved first so no source pixel is skipped.
  result = img
  while result.width >= w * 2 and result.height >= h * 2 and result.width > 1:
    result = result.minifyBy2()
  if result.width != w or result.height != h:
    result = result.resize(w, h)

proc renderEmoji*(f: EmojiFont, r: Rune, size: float32): EmojiGlyph =
  ## r drawn for a font of size pixels (em), its top left snapped to pixels.
  let gid = f.cmap.getOrDefault(r).int
  case f.kind
  of ekCbdt:
    let (png, w, h, bx, by, adv) = f.pngOf(gid)
    let s = size / f.ppem
    result.advance = adv.float32 * s
    if png.len == 0 or w <= 0 or h <= 0: return
    let
      x0 = floor(bx.float32 * s)
      y0 = floor(-by.float32 * s)
      x1 = ceil((bx + w).float32 * s)
      y1 = ceil((h - by).float32 * s)
    result.x = x0
    result.y = y0
    result.image = decodeImage(png).shrink(max(1, int(x1 - x0)), max(1, int(y1 - y0)))
  of ekColr:
    let s = size / f.upem
    let ot = f.ot
    if gid < ot.hmtx.hMetrics.len: result.advance = ot.hmtx.hMetrics[gid].advanceWidth.float32 * s
    elif ot.hmtx.hMetrics.len > 0: result.advance = ot.hmtx.hMetrics[^1].advanceWidth.float32 * s
    let (first, count) = f.baseRecord(gid)
    var layers: seq[(Path, ColorRGBA)]
    var bounds: Rect
    let m = scale(vec2(s, -s))  # font units (y up) to pixels (y down)
    for l in 0 ..< count:
      let rec = f.layerOffset + 4 * (first + l)
      let (lg, pi) = (f.buf.u16(rec), f.buf.u16(rec + 2))
      let path = if ot.glyf != nil: ot.parseGlyfGlyph(lg.uint16) else: ot.parseCffGlyph(lg.uint16)
      # 0xFFFF: the text's color; light, like the UI's text.
      let c = if pi < f.palette.len: f.palette[pi] else: rgba(230, 230, 230, 255)
      let b = path.computeBounds(m)
      if b.w <= 0 or b.h <= 0: continue
      bounds = if layers.len == 0: b else: bounds or b
      layers.add (path, c)
    if layers.len == 0: return
    let
      x0 = floor(bounds.x)
      y0 = floor(bounds.y)
      img = newImage(max(1, int(ceil(bounds.x + bounds.w) - x0)),
                     max(1, int(ceil(bounds.y + bounds.h) - y0)))
    for (path, c) in layers:
      img.fillPath(path, c, translate(vec2(-x0, -y0)) * m)
    result.x = x0
    result.y = y0
    result.image = img

proc isEmoji*(r: Rune): bool =
  ## Characters shown as color emoji by default (Unicode's Emoji_Presentation,
  ## plus the rest of the emoji planes); others, like ★ or ♪, stay text.
  let c = r.int
  if c in 0x1F000 .. 0x1FAFF: return true
  c in [0x231A, 0x231B, 0x23E9, 0x23EA, 0x23EB, 0x23EC, 0x23F0, 0x23F3, 0x25FD, 0x25FE,
        0x2614, 0x2615, 0x267F, 0x2693, 0x26A1, 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4,
        0x26C5, 0x26CE, 0x26D4, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26FA, 0x26FD, 0x2705,
        0x270A, 0x270B, 0x2728, 0x274C, 0x274E, 0x2753, 0x2754, 0x2755, 0x2757, 0x2795,
        0x2796, 0x2797, 0x27B0, 0x27BF, 0x2B1B, 0x2B1C, 0x2B50, 0x2B55] or
    c in 0x2648 .. 0x2653
