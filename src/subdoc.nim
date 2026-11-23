## Subtitle documents for the subtitle editor: SubRip (.srt), Advanced
## SubStation Alpha (.ass, and the older .ssa) and WebVTT (.vtt) files read
## into lines with times and text, edited, and written back.
##
## A line's text is kept as edited: its line breaks are newlines (ASS's \N).
## ASS keeps everything around the events as it was (script info, styles,
## fonts), and each event's other fields (layer, style, margins...) in the
## order the file's Format line gives them. WebVTT keeps its header and the
## blocks before the first cue, and each cue's identifier and settings.

import std/[strutils, unicode, math, algorithm]

type
  SubFormat* = enum
    sfSrt = "srt", sfAss = "ass", sfVtt = "vtt"

  SubLine* = object
    start*, stop*: float      ## seconds
    text*: string             ## line breaks as '\n'
    comment*: bool            ## ASS: a Comment line (never shown)
    vals*: seq[string]        ## ASS: every field the Format line names, as
                              ## read (Start, End and Text are set from the
                              ## fields above when written)
    cueId*, cueSettings*: string  ## WebVTT: the line before the times, and
                              ## what follows them ("align:start")

  SubDoc* = object
    format*: SubFormat
    head*: string             ## ASS: what comes before [Events]; WebVTT: the
                              ## WEBVTT line and the blocks before the first cue
    tail*: string             ## ASS: the sections after [Events]
    fields*: seq[string]      ## ASS: the Format line's fields, as written
    lines*: seq[SubLine]
    bom*: bool                ## the file started with a UTF-8 byte order mark
    crlf*: bool               ## its lines ended in CR LF

const
  DefaultAssFields* = ["Layer", "Start", "End", "Style", "Name", "MarginL",
                       "MarginR", "MarginV", "Effect", "Text"]
  DefaultAssHead* = """[Script Info]
; Script made by Majestic Media Player
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
WrapStyle: 0
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,72,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,3,1.5,2,60,60,50,1

"""

# --- text encodings ----------------------------------------------------------

const Cp1252High: array[0x80 .. 0x9F, int] = [
  0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030,
  0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C,
  0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D,
  0x017E, 0x0178]

proc fromUtf16(s: string, big: bool): string =
  var i = 0
  proc unit(i: int): int =
    if big: s[i].ord shl 8 or s[i + 1].ord else: s[i + 1].ord shl 8 or s[i].ord
  while i + 1 < s.len:
    var c = unit(i)
    i += 2
    if c in 0xD800 .. 0xDBFF and i + 1 < s.len:
      let lo = unit(i)
      if lo in 0xDC00 .. 0xDFFF:
        c = 0x10000 + (c - 0xD800) shl 10 + (lo - 0xDC00)
        i += 2
    result.add Rune(c).toUTF8

proc decodeText*(raw: string): tuple[text: string, bom: bool] =
  ## The text of a subtitle file, as UTF-8: UTF-8 (with or without a byte
  ## order mark), UTF-16 with one, else Windows-1252 (Latin-1's superset).
  if raw.startsWith("\xEF\xBB\xBF"): return (raw[3 .. ^1], true)
  if raw.startsWith("\xFF\xFE"): return (fromUtf16(raw[2 .. ^1], false), false)
  if raw.startsWith("\xFE\xFF"): return (fromUtf16(raw[2 .. ^1], true), false)
  if validateUtf8(raw) < 0: return (raw, false)
  var s = newStringOfCap(raw.len + raw.len div 8)
  for ch in raw:
    let b = ch.ord
    if b < 0x80: s.add ch
    elif b <= 0x9F: s.add Rune(Cp1252High[b]).toUTF8
    else: s.add Rune(b).toUTF8
  (s, false)

# --- times -------------------------------------------------------------------

proc parseClock*(s: string): float =
  ## "H:MM:SS.cc", "HH:MM:SS,mmm", "MM:SS.mmm" and the like, to seconds.
  ## Raises ValueError on anything else.
  let parts = s.strip.replace(',', '.').split(':')
  if parts.len notin 2 .. 3: raise newException(ValueError, "not a time: " & s)
  for i, f in parts:
    let v = parseFloat(f.strip)
    if v < 0 or v.isNaN: raise newException(ValueError, "not a time: " & s)
    result = result * 60 + v

proc clockText*(t: float, f: SubFormat): string =
  ## t as f writes times: SubRip 00:00:01,500, WebVTT 00:00:01.500, ASS
  ## 0:00:01.50 (centiseconds).
  if f == sfAss:
    let cs = max(0, int(round(t * 100)))
    let s = cs div 100
    return $(s div 3600) & ":" & align($((s div 60) mod 60), 2, '0') & ":" &
      align($(s mod 60), 2, '0') & "." & align($(cs mod 100), 2, '0')
  let ms = max(0, int(round(t * 1000)))
  let s = ms div 1000
  result = align($(s div 3600), 2, '0') & ":" & align($((s div 60) mod 60), 2, '0') & ":" &
    align($(s mod 60), 2, '0') & (if f == sfSrt: "," else: ".") & align($(ms mod 1000), 3, '0')

proc editTime*(t: float): string =
  ## A time as the editor shows and takes it: H:MM:SS.mmm.
  let ms = max(0, int(round(t * 1000)))
  let s = ms div 1000
  $(s div 3600) & ":" & align($((s div 60) mod 60), 2, '0') & ":" &
    align($(s mod 60), 2, '0') & "." & align($(ms mod 1000), 3, '0')

# --- ASS fields --------------------------------------------------------------

proc fieldIndex*(d: SubDoc, name: string): int =
  ## Where the Format line has the field name (case aside), -1 for nowhere.
  for i, f in d.fields:
    if cmpIgnoreCase(f, name) == 0: return i
  -1

proc field*(d: SubDoc, l: SubLine, name: string): string =
  let i = d.fieldIndex(name)
  if i >= 0 and i < l.vals.len: l.vals[i] else: ""

proc setField*(d: SubDoc, l: var SubLine, name, value: string) =
  let i = d.fieldIndex(name)
  if i < 0: return
  if l.vals.len < d.fields.len: l.vals.setLen d.fields.len
  l.vals[i] = value

proc style*(d: SubDoc, l: SubLine): string = d.field(l, "Style")

proc actor*(d: SubDoc, l: SubLine): string =
  ## ASS calls it Name; some files Actor.
  result = d.field(l, "Name")
  if result.len == 0: result = d.field(l, "Actor")

proc styles*(d: SubDoc): seq[string] =
  ## The style names the script defines, in its order.
  if d.format != sfAss: return
  var inStyles = false
  for raw in d.head.splitLines:
    let line = raw.strip
    if line.startsWith("["):
      inStyles = line.toLowerAscii.contains("styles")
    elif inStyles and line.toLowerAscii.startsWith("style:"):
      let name = line[6 .. ^1].split(',')[0].strip
      if name.len > 0 and name notin result: result.add name

proc newLine*(d: SubDoc, start, stop: float, like: SubLine = SubLine()): SubLine =
  ## An empty line from start to stop, with the fields of like (its style,
  ## layer...) when the document has any; else Default.
  result = SubLine(start: start, stop: stop, vals: like.vals)
  if d.format == sfAss and result.vals.len == 0:
    result.vals.setLen d.fields.len
    for i, f in d.fields:
      result.vals[i] =
        case f.toLowerAscii
        of "layer", "marginl", "marginr", "marginv", "marked": "0"
        of "style": "Default"
        else: ""
    let st = d.styles
    if st.len > 0 and "Default" notin st: d.setField(result, "Style", st[0])

# --- reading -----------------------------------------------------------------

proc mapItStrip(s: seq[string]): seq[string] =
  for x in s: result.add x.strip

proc parseSrt(text: string): SubDoc =
  result.format = sfSrt
  var lines = text.splitLines
  var i = 0
  while i < lines.len:
    let l = lines[i].strip
    if "-->" notin l:
      inc i
      continue
    let arrow = l.find("-->")
    var line = SubLine()
    try:
      line.start = parseClock(l[0 ..< arrow])
      let rest = l[arrow + 3 .. ^1].strip
      line.stop = parseClock(strutils.splitWhitespace(rest)[0])
    except ValueError, IndexDefect:
      inc i
      continue
    inc i
    var body: seq[string]
    while i < lines.len and lines[i].strip.len > 0:
      # A cue's number right after a blank: the next cue (missing blank line).
      if i + 1 < lines.len and "-->" in lines[i + 1] and lines[i].strip.allCharsInSet(Digits):
        break
      body.add lines[i].strip(leading = false)
      inc i
    line.text = body.join("\n")
    result.lines.add line

proc parseVtt(text: string): SubDoc =
  result.format = sfVtt
  let lines = text.splitLines
  var i = 0
  var head: seq[string]
  # The header: WEBVTT and the blocks (NOTE, STYLE, REGION) before a cue.
  while i < lines.len:
    if "-->" in lines[i] or (i + 1 < lines.len and "-->" in lines[i + 1] and
       lines[i].strip.len > 0 and (i == 0 or lines[i - 1].strip.len == 0)):
      break
    head.add lines[i]
    inc i
  while head.len > 0 and head[^1].strip.len == 0: head.setLen(head.len - 1)
  result.head = if head.len > 0: head.join("\n") else: "WEBVTT"
  while i < lines.len:
    var id = ""
    if "-->" notin lines[i]:
      if lines[i].strip.len == 0 or lines[i].startsWith("NOTE"):
        # Skips a blank line or a NOTE block.
        if lines[i].startsWith("NOTE"):
          while i < lines.len and lines[i].strip.len > 0: inc i
        inc i
        continue
      id = lines[i].strip
      inc i
      if i >= lines.len or "-->" notin lines[i]: continue
    let l = lines[i].strip
    let arrow = l.find("-->")
    var line = SubLine(cueId: id)
    try:
      line.start = parseClock(l[0 ..< arrow])
      let rest = strutils.splitWhitespace(l[arrow + 3 .. ^1])
      line.stop = parseClock(rest[0])
      line.cueSettings = rest[1 .. ^1].join(" ")
    except ValueError, IndexDefect:
      inc i
      continue
    inc i
    var body: seq[string]
    while i < lines.len and lines[i].strip.len > 0:
      body.add lines[i]
      inc i
    line.text = body.join("\n")
    result.lines.add line

proc parseAss(text: string): SubDoc =
  result.format = sfAss
  let lines = text.splitLines
  var i = 0
  var head, tail: seq[string]
  while i < lines.len and lines[i].strip.toLowerAscii != "[events]":
    head.add lines[i]
    inc i
  result.head = head.join("\n")
  if result.head.len > 0 and not result.head.endsWith("\n"): result.head.add "\n"
  inc i  # [Events]
  while i < lines.len:
    let l = lines[i]
    let s = l.strip
    inc i
    if s.startsWith("[") and s.endsWith("]"):
      # Another section (Fonts, Graphics): kept from here on as it is.
      tail = lines[i - 1 .. ^1]
      break
    let colon = s.find(':')
    if colon < 0: continue
    let kind = s[0 ..< colon].strip.toLowerAscii
    let rest = s[colon + 1 .. ^1].strip(trailing = false)
    if kind == "format":
      result.fields = rest.split(',').mapItStrip
    elif kind in ["dialogue", "comment"]:
      if result.fields.len == 0: result.fields = @DefaultAssFields
      var vals = rest.split(',', result.fields.len - 1)
      for v in vals.mitems: v = v.strip
      if vals.len < result.fields.len: vals.setLen result.fields.len
      var line = SubLine(comment: kind == "comment")
      let ti = result.fieldIndex("Text")
      # The text keeps its spaces (only the one after the comma goes).
      if ti >= 0:
        let raw = rest.split(',', result.fields.len - 1)
        line.text = (if ti < raw.len: raw[ti] else: "").replace("\\N", "\n")
        vals[ti] = ""
      try:
        line.start = parseClock(vals[result.fieldIndex("Start")])
        line.stop = parseClock(vals[result.fieldIndex("End")])
      except ValueError, IndexDefect: discard
      line.vals = vals
      result.lines.add line
  if result.fields.len == 0: result.fields = @DefaultAssFields
  while tail.len > 0 and tail[^1].strip.len == 0: tail.setLen(tail.len - 1)
  result.tail = tail.join("\n")

proc formatOf*(path: string): SubFormat =
  ## The format a file's extension names (SubRip for unknown ones).
  let ext = path.toLowerAscii
  if ext.endsWith(".ass") or ext.endsWith(".ssa"): sfAss
  elif ext.endsWith(".vtt"): sfVtt
  else: sfSrt

proc parseSubs*(raw: string, hint = sfSrt): SubDoc =
  ## A subtitle file's contents read into a document: its format from what's
  ## in it, else hint.
  let (text, bom) = decodeText(raw)
  let crlf = "\r\n" in text
  let t = text.replace("\r\n", "\n").replace('\r', '\n')
  let lead = t.strip(trailing = false)
  result =
    if lead.startsWith("WEBVTT"): parseVtt(t)
    elif lead.toLowerAscii.startsWith("[script info]") or "\n[events]" in t.toLowerAscii: parseAss(t)
    elif hint == sfAss: parseAss(t)
    elif hint == sfVtt: parseVtt(t)
    else: parseSrt(t)
  result.bom = bom
  result.crlf = crlf

proc newDoc*(f: SubFormat): SubDoc =
  result.format = f
  case f
  of sfAss:
    result.head = DefaultAssHead
    result.fields = @DefaultAssFields
  of sfVtt: result.head = "WEBVTT"
  of sfSrt: discard

# --- writing -----------------------------------------------------------------

proc stripTags*(text: string): string =
  ## The text without ASS override blocks ({\i1}) and HTML-like tags (<i>).
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '{':
      let e = text.find('}', i + 1)
      if e < 0: (result.add text[i .. ^1]; break)
      i = e + 1
    elif c == '<':
      let e = text.find('>', i + 1)
      if e < 0 or e - i > 40 or text[i + 1 .. e - 1].contains('<'):
        result.add c
        inc i
      else: i = e + 1
    else:
      result.add c
      inc i

proc assToHtml(text: string): string =
  ## ASS text for SubRip or WebVTT: italics, bold and underline as tags,
  ## the other override blocks dropped, \h as a space.
  var i = 0
  var open: seq[string]
  while i < text.len:
    if text[i] == '{':
      let e = text.find('}', i + 1)
      if e < 0: (result.add text[i .. ^1]; break)
      for tag in text[i + 1 ..< e].split('\\'):
        for (t, h) in [("i", "i"), ("b", "b"), ("u", "u")]:
          if tag == t & "1" and h notin open:
            result.add "<" & h & ">"
            open.add h
          elif tag == t & "0" and h in open:
            result.add "</" & h & ">"
            open.delete open.find(h)
      i = e + 1
    elif text[i] == '\\' and i + 1 < text.len and text[i + 1] in {'h', 'n'}:
      result.add (if text[i + 1] == 'h': " " else: "\n")
      i += 2
    else:
      result.add text[i]
      inc i
  for h in open.reversed: result.add "</" & h & ">"

proc htmlToAss(text: string): string =
  ## SubRip text for ASS: <i>, <b> and <u> as override tags, others dropped.
  result = text
  for (h, t) in [("i", "i"), ("b", "b"), ("u", "u")]:
    for cs in [h, h.toUpperAscii]:
      result = result.replace("<" & cs & ">", "{\\" & t & "1}").replace("</" & cs & ">", "{\\" & t & "0}")
  result = stripTags(result.replace("{\\", "\x01")).replace("\x01", "{\\")

proc convertTo*(d: SubDoc, f: SubFormat): SubDoc =
  ## d in format f, for saving it as such: tags translated where they can be.
  if d.format == f: return d
  result = newDoc(f)
  result.bom = d.bom
  result.crlf = d.crlf
  for l in d.lines:
    var n = result.newLine(l.start, l.stop)
    n.comment = l.comment
    n.text =
      if d.format == sfAss: assToHtml(l.text)
      elif f == sfAss: htmlToAss(l.text)
      else: l.text
    if d.format == sfAss and l.comment: continue  # only ASS has them
    result.lines.add n

proc render*(d: SubDoc): string =
  ## The document as its format's file text (UTF-8, as it was read: with its
  ## byte order mark and line ends).
  var o: seq[string]
  case d.format
  of sfSrt:
    var n = 0
    for l in d.lines:
      inc n
      o.add $n
      o.add clockText(l.start, sfSrt) & " --> " & clockText(l.stop, sfSrt)
      # A blank line would end the cue early.
      for t in l.text.split('\n'):
        o.add (if t.strip.len == 0: " " else: t)
      o.add ""
  of sfVtt:
    o.add d.head
    o.add ""
    for l in d.lines:
      if l.cueId.len > 0: o.add l.cueId
      o.add clockText(l.start, sfVtt) & " --> " & clockText(l.stop, sfVtt) &
        (if l.cueSettings.len > 0: " " & l.cueSettings else: "")
      # A blank line would end the cue early.
      for t in l.text.split('\n'):
        o.add (if t.strip.len == 0: " " else: t)
      o.add ""
  of sfAss:
    var head = d.head
    while head.endsWith("\n\n"): head.setLen(head.len - 1)
    if head.len > 0 and not head.endsWith("\n"): head.add "\n"
    if head.len > 0: head.add "\n"
    o.add head & "[Events]"
    o.add "Format: " & d.fields.join(", ")
    let (si, ei, ti) = (d.fieldIndex("Start"), d.fieldIndex("End"), d.fieldIndex("Text"))
    for l in d.lines:
      var vals = l.vals
      if vals.len < d.fields.len: vals.setLen d.fields.len
      if si >= 0: vals[si] = clockText(l.start, sfAss)
      if ei >= 0: vals[ei] = clockText(l.stop, sfAss)
      if ti >= 0: vals[ti] = l.text.replace("\n", "\\N")
      for k, v in vals.mpairs:
        if k != ti: v = v.replace(",", ";")  # a comma would shift the fields after it
      o.add (if l.comment: "Comment: " else: "Dialogue: ") & vals.join(",")
    if d.tail.len > 0:
      o.add ""
      o.add d.tail
  result = o.join("\n")
  if not result.endsWith("\n"): result.add "\n"
  if d.crlf: result = result.replace("\n", "\r\n")
  if d.bom: result = "\xEF\xBB\xBF" & result

# --- edits ------------------------------------------------------------------

proc plain*(d: SubDoc, text: string): string =
  ## A line's text as the editor's grid shows it: tags left out, ASS's hard
  ## spaces as spaces.
  result = stripTags(text)
  if d.format == sfAss: result = result.replace("\\h", " ").replace("\\n", " ")

proc cps*(d: SubDoc, l: SubLine): float =
  ## Characters per second, as Aegisub counts them: the letters and digits
  ## of the shown text (no spaces or punctuation) over the line's duration.
  let dur = l.stop - l.start
  if dur <= 0: return 0
  var n = 0
  for r in d.plain(l.text).runes:
    if r.isWhiteSpace: continue
    if r.int < 0x80 and char(r.int) in PunctuationChars: continue
    inc n
  n.float / dur

proc sortByTime*(d: var SubDoc): seq[int] =
  ## Puts the lines in order of start (stable). Returns, for each new place,
  ## the old index.
  var idx = newSeq[int](d.lines.len)
  for i in 0 ..< idx.len: idx[i] = i
  let ls = d.lines
  idx.sort(proc (a, b: int): int =
    result = cmp(ls[a].start, ls[b].start)
    if result == 0: result = cmp(a, b))
  for i, k in idx: d.lines[i] = ls[k]
  idx

proc lowerRunes(s: string): string =
  for r in s.runes: result.add r.toLower.toUTF8

proc findText*(hay, needle: string, start = 0, matchCase = false): int =
  ## Where needle next appears in hay from byte start, -1 for nowhere; case
  ## aside unless matchCase.
  if needle.len == 0: return -1
  if matchCase: return hay.find(needle, start)
  let h = lowerRunes(hay)
  let n = lowerRunes(needle)
  if h.len == hay.len: return h.find(n, start)
  # Lowering changed the length (rare letters): match each rune.
  var i = start
  while i < hay.len:
    var j = i
    var k = 0
    var ok = true
    while k < needle.len:
      if j >= hay.len: (ok = false; break)
      let a = hay.runeAt(j)
      let b = needle.runeAt(k)
      if a.toLower != b.toLower: (ok = false; break)
      j += a.size
      k += b.size
    if ok: return i
    i += hay.runeLenAt(i)
  -1

proc matchEnd*(hay, needle: string, at: int, matchCase = false): int =
  ## Where the match of needle found at byte at ends in hay.
  if matchCase: return at + needle.len
  var j = at
  for r in needle.runes:
    if j >= hay.len: break
    j += hay.runeLenAt(j)
  j

proc replaceText*(hay, needle, by: string, matchCase = false): tuple[text: string, count: int] =
  ## Every match of needle in hay replaced with by.
  var i = 0
  while true:
    let at = findText(hay, needle, i, matchCase)
    if at < 0: break
    result.text.add hay[i ..< at]
    result.text.add by
    i = matchEnd(hay, needle, at, matchCase)
    inc result.count
  result.text.add hay[i .. ^1]
