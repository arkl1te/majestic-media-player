## Glyphs added to the UI atlas the first time some text needs them, so file
## names, titles and tags in any script draw (Japanese, Chinese, Korean,
## Cyrillic beyond the prebuilt set, ...). The atlas (majestic.buildAtlas)
## is prebuilt with Latin only; a missing character is rasterized at the
## font's size from IBM Plex when it has it, else from a system font
## (fallbackfonts), and the atlas grows when full.
##
## Every Silky context shares the one atlas. The GPU copy is refreshed by
## Silky's atlasSyncHook at the end of each frame drawn (patches/silky.patch),
## once however many glyphs the frame added.
##
## Han characters take the form of the text's language: Japanese when the
## text has kana, Korean when it has hangul, else the locale's CJK language
## (Simplified Chinese when it has none). A character keeps the form it was
## first drawn in.
##
## Emoji come from a color emoji font (emojifont) as color glyphs, which
## Silky draws untinted; without one, from an outline font when one has them.

import std/[os, sets, strutils, tables, unicode, importutils]
import silky, silky/allocator, pixie, pixie/fontformats/opentype, vmath, bumpy, flatty/binny
import fallbackfonts, emojifont

privateAccess(Typeface)

const MaxAtlasSize = 8192  ## the atlas doesn't grow past this; later glyphs draw as "?"

type
  GlyphCache = object
    builder: AtlasBuilder
    version: int                         ## bumped when the atlas image changes
    sans, mono: Typeface                 ## IBM Plex, the atlas's own fonts
    faces: Table[string, Typeface]       ## loaded system faces by path#index, nil: unusable
    order: seq[Typeface]                 ## loaded faces, tried in order for other scripts
    langFace: Table[string, Typeface]    ## the face chosen for a CJK language
    noFont: HashSet[Rune]                ## characters no font draws
    emojiFonts: Table[string, EmojiFont] ## by path#index, nil: no color glyphs
    emojiOrder: seq[EmojiFont]
    full: bool                           ## the atlas reached MaxAtlasSize

var cache: GlyphCache

proc syncAtlas(sk: Silky) {.nimcall.} =
  ## Uploads the atlas to sk's texture when glyphs were added since.
  if cache.builder == nil or sk.atlasVersion == cache.version or
     sk.atlas != cache.builder.atlas:
    return
  sk.image = cache.builder.atlasImage
  sk.uploadAtlas()
  sk.atlasVersion = cache.version

proc initGlyphCache*(builder: AtlasBuilder, sansPath, monoPath: string) =
  ## Adopts a freshly built atlas (at start and on each UI scaling change);
  ## glyphs added to the previous one are added again as text needs them.
  cache.builder = builder
  cache.full = false
  inc cache.version
  try:
    if cache.sans == nil: cache.sans = readTypeface(sansPath)
    if cache.mono == nil: cache.mono = readTypeface(monoPath)
  except PixieError:
    discard
  atlasSyncHook = syncAtlas

proc loadFace(f: FontFace): Typeface =
  ## One face of a font file (.ttc/.otc collections hold several), nil when
  ## it can't be read.
  try:
    if f.path.splitFile.ext.toLowerAscii in [".ttc", ".otc"]:
      let buf = readFile(f.path)
      if buf.len < 12 or buf[0 ..< 4] != "ttcf": return nil
      let n = buf.readUint32(8).swap().int
      if f.index >= n or buf.len < 12 + 4 * n: return nil
      let offset = buf.readUint32(12 + 4 * f.index).swap().int
      result = Typeface(opentype: parseOpenType(buf, offset), filePath: f.path)
    else:
      result = readTypeface(f.path)
  except CatchableError:
    result = nil

proc face(f: FontFace): Typeface =
  let key = f.path & "#" & $f.index
  if key notin cache.faces:
    let tf = loadFace(f)
    cache.faces[key] = tf
    if tf != nil: cache.order.add tf
  cache.faces[key]

proc draws(tf: Typeface, r: Rune): bool =
  ## tf has an outline for r (color emoji fonts have bitmaps only).
  if tf == nil or not tf.hasGlyph(r): return false
  if r.isWhiteSpace: return true
  try:
    let b = tf.getGlyphPath(r).computeBounds()
    b.w > 0 and b.h > 0 and b.w.classify == fcNormal and b.h.classify == fcNormal
  except PixieError:
    false

proc faceFor(r: Rune, lang: string, mono: bool): Typeface =
  let primary = if mono: cache.mono else: cache.sans
  if primary.draws(r): return primary
  if lang.len > 0:
    # The language's own family first, so its Han forms are used.
    let key = lang & (if mono: "/mono" else: "")
    if key notin cache.langFace:
      cache.langFace[key] = nil
      for c in candidates(r, lang, mono):
        let tf = face(c)
        if tf.draws(r):
          cache.langFace[key] = tf
          return tf
    let tf = cache.langFace[key]
    if tf.draws(r): return tf
  for tf in cache.order:
    if tf.draws(r): return tf
  for c in candidates(r, lang, mono):
    let tf = face(c)
    if tf.draws(r): return tf
  nil

proc finite(b: Rect): Rect =
  const Finite = {fcNormal, fcSubnormal, fcZero, fcNegZero}
  if b.x.classify in Finite and b.y.classify in Finite and b.w.classify in Finite and
     b.h.classify in Finite: b
  else: rect(0, 0, 0, 0)

proc place(img: Image): tuple[ok: bool, x, y: int] =
  ## Packs img into the atlas, growing it when full.
  let b = cache.builder
  var a = b.allocator.allocate(img.width, img.height)
  while not a.success:
    if b.size >= MaxAtlasSize:
      cache.full = true
      return
    b.growAtlas(b.size * 2)
    a = b.allocator.allocate(img.width, img.height)
  b.atlasImage.draw(img, translate(vec2(a.x.float32, a.y.float32)), OverwriteBlend)
  (true, a.x, a.y)

proc setEntry(fa: FontAtlas, r: Rune, entry: LetterEntry) =
  fa.entries[$r] = @[entry]
  fa.lookup.entries[r] = GlyphEntries(entries: @[entry])

proc emojiFor(r: Rune): EmojiFont =
  ## A color emoji font with r, nil when none has it.
  for f in cache.emojiOrder:
    if f.hasEmoji(r): return f
  for c in candidates(r, "", emoji = true):
    let key = c.path & "#" & $c.index
    if key in cache.emojiFonts: continue
    let f = loadEmojiFont(c.path, c.index)
    cache.emojiFonts[key] = f
    if f != nil:
      cache.emojiOrder.add f
      if f.hasEmoji(r): return f
  nil

proc addEmoji(fa: FontAtlas, r: Rune, f: EmojiFont): bool =
  let g = f.renderEmoji(r, fa.size)
  var entry = LetterEntry(boundsX: g.x, boundsY: g.y, advance: g.advance, colored: true)
  if g.image != nil:
    let (ok, x, y) = place(g.image)
    if not ok: return false
    entry.x = x
    entry.y = y
    entry.boundsWidth = g.image.width.float32
    entry.boundsHeight = g.image.height.float32
  fa.setEntry(r, entry)
  true

proc addGlyph(fa: FontAtlas, r: Rune, tf: Typeface): bool =
  ## Rasterizes r like Silky's addFont (no subpixel variants) into the atlas.
  var font = newFont(tf)
  font.size = fa.size
  let
    s = font.scale
    scaleMat = scale(vec2(s))
    path = tf.getGlyphPath(r)
    bounds = path.computeBounds(scaleMat).snapToPixels().finite()
    w = bounds.w.ceil.int
    h = bounds.h.ceil.int
  var entry = LetterEntry(boundsX: bounds.x, boundsY: bounds.y, boundsWidth: bounds.w,
    boundsHeight: bounds.h, advance: tf.getAdvance(r) * s)
  if w > 0 and h > 0:
    let img = newImage(w, h)
    img.fillPath(path, color(1, 1, 1, 1), translate(vec2(-bounds.x, -bounds.y)) * scaleMat)
    let (ok, x, y) = place(img)
    if not ok: return false
    entry.x = x
    entry.y = y
    entry.boundsWidth = w.float32
    entry.boundsHeight = h.float32
  fa.setEntry(r, entry)
  true

proc isIgnorable(r: Rune): bool =
  ## Format characters drawn as nothing: zero-width spaces and joiners,
  ## direction marks, variation selectors (as after many emoji), BOM.
  let c = r.int
  c in 0x200B .. 0x200F or c in 0x202A .. 0x202E or c in 0x2060 .. 0x206F or
    c in 0xFE00 .. 0xFE0F or c == 0xFEFF or c in 0xE0000 .. 0xE0FFF

proc textLang(s: string): string =
  ## The CJK language Han characters in s are drawn in.
  for r in s.runes:
    if r.isKana: return "ja"
    if r.isHangul: return "ko"
  result = localeCjkLang()
  if result.len == 0: result = "zh-cn"

proc ensureGlyphs*(sk: Silky, font, s: string) =
  ## Adds the characters of s that font lacks to the atlas, before s is
  ## measured or drawn with it.
  if cache.builder == nil or cache.full: return
  block ascii:
    for c in s:
      if c.ord >= 0x80: break ascii
    return  # the atlas has all of ASCII
  if sk.atlas != cache.builder.atlas: return
  let fa = sk.atlas.fonts.getOrDefault(font)
  if fa == nil: return
  let mono = font.startsWith("Mono")
  var cjkLang = ""
  var added = false
  for r in s.runes:
    if r.int < 0x20 or r in fa.lookup.entries or r in cache.noFont: continue
    if r.isIgnorable:
      fa.setEntry(r, LetterEntry())
      continue
    if r.isEmoji:
      let ef = emojiFor(r)
      if ef != nil:
        if not fa.addEmoji(r, ef): break
        added = true
        continue
    let lang =
      if r.isKana: "ja"
      elif r.isHangul: "ko"
      elif r.isCjk:
        if cjkLang.len == 0: cjkLang = textLang(s)
        cjkLang
      else: ""
    let tf = faceFor(r, lang, mono)
    if tf == nil:
      cache.noFont.incl r
      continue
    if not fa.addGlyph(r, tf): break
    added = true
  if added: inc cache.version
