## Command-line Manager: composes shell commands for the Run menu out of text
## and cards. A card is a bash variable drawn as a chip inside the command
## line; it holds a value, or refers to the current media file or to a
## bookmark of it. When the command runs, the Run window asks for the
## bookmarks and lets the values be changed.

import std/[strutils, sequtils, os, math, tables]
import silky, vmath, bumpy, pixie
import ui, theme, config

type
  CmdAction* = enum
    caNone, caApply, caDelete, caCancel

  CmdDialog* = ref object
    saved*: seq[CommandLine]  ## the saved command lines, for the title list
    origTitle*: string        ## saved entry being edited, "" for a new one
    title*: string
    toks: seq[CmdPart]        ## the command line; text one character per token
    caret: int                ## token index
    caretEol: bool            ## caret drawn after the token before it (line end)
    selected: int             ## card token whose properties are shown, else -1
    scroll: float32           ## command line field, vertical
    refScroll: float32        ## reference list
    listOpen: bool            ## title list dropped down
    listScroll: int           ## its first row shown
    error: string             ## why the last Apply was refused
    applyRequested*: bool     ## debug scripting: press Apply next frame

const
  LineH = 26'f32              ## command line row
  ChipPad = 7'f32
  FieldPad = 8'f32
  RowH = 24'f32               ## reference and title list rows
  NameStart = {'a'..'z', 'A'..'Z', '_'}
  NameChars = NameStart + {'0'..'9'}

proc validName*(s: string): bool =
  ## Bash variable names: letters, digits and underscores, no leading digit.
  s.len > 0 and s[0] in NameStart and s.allCharsInSet(NameChars)

proc chars(s: string): seq[string] =
  ## UTF-8 characters of s.
  var i = 0
  while i < s.len:
    var j = i + 1
    while j < s.len and (s[j].ord and 0xC0) == 0x80: inc j
    result.add s[i ..< j]
    i = j

proc toTokens(parts: seq[CmdPart]): seq[CmdPart] =
  for p in parts:
    if p.card:
      result.add p
      # Earlier versions referred to bookmarks by number.
      if p.content.startsWith("bookmark:"): result[^1].content = "bookmark"
    else:
      for ch in p.text.chars: result.add CmdPart(text: ch)

proc toParts(toks: seq[CmdPart]): seq[CmdPart] =
  for t in toks:
    if not t.card and result.len > 0 and not result[^1].card: result[^1].text.add t.text
    else: result.add t

# --- resolving cards ---------------------------------------------------------

proc isBookmark(p: CmdPart): bool =
  p.card and p.kind == ckReference and p.content.startsWith("bookmark")

proc runCards*(parts: seq[CmdPart]): seq[CmdPart] =
  ## The cards the Run window asks about (values and bookmarks), each name
  ## once, in order.
  for p in parts:
    if p.card and (p.kind == ckValue or p.isBookmark) and not result.anyIt(it.name == p.name):
      result.add p

proc resolve*(p: CmdPart, path: string, picks: Table[string, string]): tuple[value, err: string] =
  ## A card's value now, or why it has none. picks holds what the Run window
  ## gave each card: the chosen bookmark's time, or a value replacing the
  ## card's own.
  case p.kind
  of ckValue:
    let v = picks.getOrDefault(p.name, p.content)
    result.value = if v.startsWith("~"): v.expandTilde else: v
  of ckReference:
    if p.content == "file":
      if path.len > 0: result.value = path
      else: result.err = "No media file is open"
    elif p.isBookmark:
      if p.name in picks: result.value = picks[p.name]
      else: result.err = "No bookmark chosen for " & p.name
    else:
      result.err = "Card " & p.name & " doesn't refer to anything"

proc compose*(parts: seq[CmdPart], path: string, picks: Table[string, string]): tuple[script, err: string] =
  ## A bash script: one assignment per card, then the command line with each
  ## card expanded as "${name}" (quoted to fit the quotes typed around it).
  var assigned: seq[string]
  var body = ""
  var inSingle, inDouble, escaped = false
  for p in parts:
    if not p.card:
      for ch in p.text:
        if escaped: escaped = false
        elif ch == '\\' and not inSingle: escaped = true
        elif ch == '\'' and not inDouble: inSingle = not inSingle
        elif ch == '"' and not inSingle: inDouble = not inDouble
        body.add ch
      continue
    escaped = false
    let (value, err) = p.resolve(path, picks)
    if err.len > 0: return ("", err)
    if p.name notin assigned:
      assigned.add p.name
      result.script.add p.name & "=" & quoteShellPosix(value) & "\n"
    let v = "${" & p.name & "}"
    body.add(if inSingle: "'\"" & v & "\"'" elif inDouble: v else: "\"" & v & "\"")
  result.script.add body

proc preview(toks: seq[CmdPart], path: string): string =
  ## The command line as it would run now, values in place of the cards;
  ## bookmarks are only known once chosen in the Run window.
  for t in toks:
    if not t.card: result.add t.text
    elif t.isBookmark: result.add "[" & t.name & ": bookmark]"
    else:
      let (value, err) = t.resolve(path, initTable[string, string]())
      result.add(if err.len > 0: "[" & t.name & "?]" else: quoteShellPosix(value))

# --- dialog state ------------------------------------------------------------

proc newCmdDialog*(): CmdDialog = CmdDialog(selected: -1)

proc load*(d: CmdDialog, c: CommandLine) =
  ## Edits a saved command line, or starts a new one when c has no title.
  d.origTitle = c.title
  d.title = c.title
  d.toks = c.parts.toTokens
  d.caret = d.toks.len
  d.caretEol = true
  d.selected = -1
  d.scroll = 0
  d.listOpen = false
  d.error = ""

proc commandLine*(d: CmdDialog): CommandLine =
  CommandLine(title: d.title.strip, parts: d.toks.toParts)

proc validate(d: CmdDialog): string =
  let title = d.title.strip
  if title.len == 0: return "Give the command line a title."
  for c in d.saved:
    if c.title == title and c.title != d.origTitle:
      return "Another command line is already called “" & title & "”."
  if not d.toks.anyIt(it.card or it.text.strip.len > 0): return "The command line is empty."
  for i, t in d.toks:
    if not t.card: continue
    if not validName(t.name): return "“" & t.name & "” is not a valid variable name."
    if t.kind == ckReference and t.content.len == 0:
      return "Choose what card " & t.name & " refers to."
    for u in d.toks[0 ..< i]:
      if u.card and u.name == t.name and (u.kind != t.kind or u.content != t.content):
        return "Two different cards are named " & t.name & "."

proc insertTok(d: CmdDialog, t: CmdPart, at: int) =
  d.toks.insert(t, at)
  if d.selected >= at: inc d.selected

proc deleteTok(d: CmdDialog, at: int) =
  d.toks.delete(at)
  if d.selected == at: d.selected = -1
  elif d.selected > at: dec d.selected

proc isSpace(t: CmdPart): bool = not t.card and t.text == " "

proc addCard*(d: CmdDialog, name: string, kind = ckValue, content = "") =
  ## Inserts a card at the caret, spaced from its neighbours, and selects it;
  ## the caret goes after the space that follows it.
  var at = clamp(d.caret, 0, d.toks.len)
  if at > 0 and not d.toks[at - 1].isSpace:
    d.insertTok(CmdPart(text: " "), at)
    inc at
  d.insertTok(CmdPart(card: true, name: name, kind: kind, content: content), at)
  # Typing carries on after a space.
  if at + 1 == d.toks.len or not d.toks[at + 1].isSpace:
    d.insertTok(CmdPart(text: " "), at + 1)
  d.selected = at
  d.caret = at + 2
  d.caretEol = false
  d.error = ""

proc newCard(d: CmdDialog, ui: Ui) =
  ## New card button: a card named var1, var2, ... ready to be renamed.
  var n = 1
  while d.toks.anyIt(it.card and it.name == "var" & $n): inc n
  d.addCard("var" & $n)
  ui.focusId = "cl-name"
  ui.navId = "cl-name"
  ui.focusFresh = true

# --- command line field --------------------------------------------------------

proc chipLabel(t: CmdPart): string = (if t.name.len > 0: t.name else: "?")

proc layout(ui: Ui, toks: seq[CmdPart], width: float32): seq[Rect] =
  ## Token rects relative to the text origin. Words wrap as a whole; a word
  ## wider than the field breaks between characters. Positions within a word
  ## come from measuring its prefixes, so kerning is kept.
  result = newSeq[Rect](toks.len)
  var x, y = 0'f32
  var i = 0
  while i < toks.len:
    let t = toks[i]
    if t.card or t.isSpace:
      let w = if t.card: ui.textSize(t.chipLabel).x + ChipPad * 2 else: ui.textSize(" ").x
      if t.card and x > 0 and x + w > width:
        x = 0
        y += LineH
      result[i] = rect(x, y, w, LineH)
      x += w
      inc i
      continue
    var j = i
    var word = ""
    while j < toks.len and not toks[j].card and not toks[j].isSpace:
      word.add toks[j].text
      inc j
    if x > 0 and x + ui.textSize(word).x > width:
      x = 0
      y += LineH
    var prefix = ""
    var a = 0'f32               # prefix width at token k
    var lineStart = x           # where the word's current line piece begins
    var cut = 0'f32             # prefix width at that piece's start
    for k in i ..< j:
      prefix.add toks[k].text
      let b = ui.textSize(prefix).x
      var px = lineStart + a - cut
      if px > 0 and px + b - a > width:
        y += LineH
        lineStart = 0
        cut = a
        px = 0
      result[k] = rect(px, y, b - a, LineH)
      a = b
    x = result[j - 1].x + result[j - 1].w
    i = j

proc caretPos(d: CmdDialog, rs: seq[Rect]): Vec2 =
  let c = clamp(d.caret, 0, rs.len)
  if rs.len == 0: vec2(0, 0)
  elif c == rs.len or (d.caretEol and c > 0): vec2(rs[c - 1].x + rs[c - 1].w, rs[c - 1].y)
  else: rs[c].xy

proc hitCaret(rs: seq[Rect], p: Vec2): tuple[caret: int, eol: bool] =
  ## Caret index nearest to p (text coordinates).
  if rs.len == 0: return (0, false)
  let lastLine = int(rs[^1].y / LineH)
  let line = clamp(int(floor(p.y / LineH)), 0, lastLine)
  var last = -1
  for k, r in rs:
    if int(r.y / LineH) != line: continue
    if p.x < r.x + r.w / 2: return (k, false)
    last = k
  if last < 0: (rs.len, false) else: (last + 1, true)

proc commandField(d: CmdDialog, ui: Ui, r: Rect) =
  ## The command line: wrapping text with cards as chips. Click a chip to
  ## show its properties.
  const id = "cl-line"
  let w = ui.window
  let hov = ui.hover(r)
  let inner = rect(r.x + FieldPad, r.y + 4, r.w - FieldPad * 2, r.h - 8)
  discard ui.tabStop(id, r, edit = true)
  if ui.focusId == id and ui.focusFresh:
    ui.focusFresh = false
    d.caret = d.toks.len
    d.caretEol = true
  if ui.focusId == id and w.buttonPressed[MouseLeft] and not hov:
    ui.focusId = ""
  var rs = layout(ui, d.toks, inner.w)
  let origin = vec2(inner.x, inner.y - d.scroll)
  if hov and ui.pressed():
    ui.consumeClick()
    ui.navId = id
    ui.focusId = id
    let p = ui.mouse - origin
    var chip = -1
    for k, t in d.toks:
      if t.card and p.inside(rs[k]): chip = k
    if chip >= 0:
      d.selected = chip
      d.caret = chip + 1
      d.caretEol = true
    else:
      (d.caret, d.caretEol) = hitCaret(rs, p)

  let focused = ui.focusId == id
  var moved = false
  if focused:
    d.caret = clamp(d.caret, 0, d.toks.len)
    let ctrl = w.buttonDown[KeyLeftControl] or w.buttonDown[KeyRightControl]
    var ins = ""
    for ch in ui.typed:
      if ch.ord >= 0x20 and ch.ord != 0x7f: ins.add ch
    if ctrl and w.buttonPressed[KeyV]:
      ins.add getClipboardString().multiReplace(("\r", ""), ("\n", " "), ("\t", " "))
    for ch in ins.chars:
      d.insertTok(CmdPart(text: ch), d.caret)
      inc d.caret
      d.caretEol = false
      moved = true
    if w.buttonPressed[KeyBackspace] and d.caret > 0:
      dec d.caret
      d.deleteTok(d.caret)
      d.caretEol = false
      moved = true
    if w.buttonPressed[KeyDelete] and d.caret < d.toks.len:
      d.deleteTok(d.caret)
      d.caretEol = false
      moved = true
    if moved: rs = layout(ui, d.toks, inner.w)
    let cp = d.caretPos(rs)
    if w.buttonPressed[KeyLeft] and d.caret > 0:
      dec d.caret
      d.caretEol = false
      moved = true
    if w.buttonPressed[KeyRight] and d.caret < d.toks.len:
      inc d.caret
      # Stepping past a line's last token: stay at that line's end.
      d.caretEol = d.caret < rs.len and rs[d.caret].y > rs[d.caret - 1].y
      moved = true
    if w.buttonPressed[KeyHome]:
      (d.caret, d.caretEol) = hitCaret(rs, vec2(-1, cp.y + 1))
      moved = true
    if w.buttonPressed[KeyEnd]:
      (d.caret, d.caretEol) = hitCaret(rs, vec2(1e9, cp.y + 1))
      moved = true
    if w.buttonPressed[KeyUp] and cp.y > 0:
      (d.caret, d.caretEol) = hitCaret(rs, vec2(cp.x, cp.y - LineH + 1))
      moved = true
    if w.buttonPressed[KeyDown]:
      (d.caret, d.caretEol) = hitCaret(rs, vec2(cp.x, cp.y + LineH + 1))
      moved = true
    if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or
       w.buttonPressed[KeyTab] or w.buttonPressed[KeyEscape]:
      ui.focusId = ""

  # Scrolling: the wheel, and following the caret.
  let contentH = (if rs.len > 0: rs[^1].y + LineH else: LineH)
  let maxScroll = max(0'f32, contentH - inner.h)
  if hov and ui.scroll() != 0:
    d.scroll += ui.scroll() * LineH
    ui.scrollConsumed = true
  if focused and moved:
    let cy = d.caretPos(rs).y
    if cy < d.scroll: d.scroll = cy
    if cy + LineH > d.scroll + inner.h: d.scroll = cy + LineH - inner.h
  d.scroll = clamp(d.scroll, 0, maxScroll)
  let o = vec2(inner.x, inner.y - d.scroll)

  ui.rect(r, colBackground)
  ui.border(r, if ui.focusId == id: colAccent elif hov: colTextDim else: colBorder)
  ui.sk.pushClipRect(inner)
  if d.toks.len == 0 and ui.focusId != id:
    ui.textIn("Type a command; New card adds a variable at the caret",
      rect(o.x, o.y, inner.w, LineH), colTextDisabled)
  for k, t in d.toks:
    let tr = rect(rs[k].xy + o, rs[k].wh)
    if tr.y + tr.h < inner.y or tr.y > inner.y + inner.h: continue
    if not t.card:
      ui.textIn(t.text, rect(tr.x, tr.y, tr.w + 20, tr.h), colText)
      continue
    let chip = rect(tr.x + 1, tr.y + 3, tr.w - 2, tr.h - 6)
    ui.rect(chip, if t.kind == ckReference: colCardRef else: colCardValue)
    let bad = not validName(t.name) or t.kind == ckReference and t.content.len == 0
    if k == d.selected: ui.border(chip, colAccent)
    elif bad: ui.border(chip, colError)
    elif ui.hover(chip): ui.border(chip, colTextDim)
    ui.textIn(t.chipLabel, chip, colText, h = CenterAlign)
  if ui.focusId == id:
    let cp = d.caretPos(rs) + o
    ui.rect(rect(cp.x, cp.y + 4, 1, LineH - 8), colAccent)
  ui.sk.popClipRect()
  if maxScroll > 0:
    let th = max(20'f32, inner.h * inner.h / contentH)
    let ty = inner.y + (inner.h - th) * (d.scroll / maxScroll)
    ui.rect(rect(r.x + r.w - 4, ty, 3, th), colTrack)

# --- properties ----------------------------------------------------------------

proc referenceList(d: CmdDialog, ui: Ui, r: Rect, card: var CmdPart, path: string) =
  ## Flat list of what a card can refer to: the media file's path, or a
  ## bookmark picked when the command runs.
  let rows: array[2, tuple[key, label, detail: string]] = [
    ("file", (if path.len > 0: path else: "Media file (none open)"), ""),
    ("bookmark", "Bookmark", "chosen on run")]
  ui.rect(r, colBackground)
  ui.border(r, colBorder)
  let inner = rect(r.x + 1, r.y + 1, r.w - 2, r.h - 2)
  let focused = ui.tabStop("cl-ref", r)
  if focused: ui.focusRing(r)
  var cur = -1
  for i, row in rows:
    if row.key == card.content: cur = i
  if focused and ui.focusId.len == 0:
    let w = ui.window
    var c = cur
    if w.buttonPressed[KeyUp]: c = max(0, c - 1)
    if w.buttonPressed[KeyDown]: c = min(rows.high, c + 1)
    if c != cur and c >= 0:
      card.content = rows[c].key
      cur = c
      let top = c.float32 * RowH
      if top < d.refScroll: d.refScroll = top
      if top + RowH > d.refScroll + inner.h: d.refScroll = top + RowH - inner.h
  let maxScroll = max(0'f32, rows.len.float32 * RowH - inner.h)
  if ui.hover(inner) and ui.scroll() != 0:
    d.refScroll += ui.scroll() * RowH
    ui.scrollConsumed = true
  d.refScroll = clamp(d.refScroll, 0, maxScroll)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for i, row in rows:
    let rr = rect(inner.x, inner.y + i.float32 * RowH - d.refScroll, inner.w, RowH)
    if rr.y + RowH < inner.y or rr.y > inner.y + inner.h: continue
    let sel = i == cur
    let hov = ui.hover(rr)
    if sel: ui.rect(rr, colAccent)
    elif hov: ui.rect(rr, colHover)
    let dw = if row.detail.len > 0: ui.textSize(row.detail, FontSmall).x + 12 else: 0'f32
    ui.textIn(ui.ellipsize(row.label, rr.w - dw - 16), rect(rr.x + 8, rr.y, rr.w - dw - 16, RowH),
      if sel: colOnAccent elif row.key == "file" and path.len == 0: colTextDim else: colText)
    if dw > 0:
      ui.textIn(row.detail, rect(rr.x + rr.w - dw, rr.y, dw - 8, RowH),
        if sel: colOnAccent else: colTextDim, FontSmall, h = RightAlign)
    if row.key == "file" and path.len > 0: ui.tip(rr, path)
    if hov and ui.pressed():
      ui.consumeClick()
      ui.navId = "cl-ref"
      card.content = row.key
  ui.sk.popClipRect()
  ui.hitClip = outerClip

proc properties(d: CmdDialog, ui: Ui, r: Rect, path: string) =
  ui.groupHeader(r.xy, r.w, "Properties")
  var y = r.y + 30
  let s = d.selected
  if s < 0 or s >= d.toks.len or not d.toks[s].card:
    d.selected = -1
    ui.textIn("Click a card in the command line to edit it,", rect(r.x, y, r.w, 20),
      colTextDim, FontSmall)
    ui.textIn("or add one with New card.", rect(r.x, y + 18, r.w, 20), colTextDim, FontSmall)
    return
  const labelW = 70'f32
  ui.textIn("Name", rect(r.x, y, labelW, 26), colText)
  discard ui.textField("cl-name", rect(r.x + labelW, y, r.w - labelW, 26), d.toks[s].name,
    "variable name")
  y += 28
  let name = d.toks[s].name
  if validName(name):
    ui.textIn("Runs as the bash variable $" & name, rect(r.x + labelW, y, r.w - labelW, 18),
      colTextDim, FontSmall)
  else:
    ui.textIn(if name.len == 0: "Required"
              else: "Letters, digits and _; no leading digit",
      rect(r.x + labelW, y, r.w - labelW, 18), colError, FontSmall)
  y += 26
  ui.textIn("Type", rect(r.x, y, labelW, 22), colText)
  if ui.radioButton("cl-value", vec2(r.x + labelW, y), "Value", d.toks[s].kind == ckValue):
    d.toks[s].kind = ckValue
    d.toks[s].content = ""
  if ui.radioButton("cl-refer", vec2(r.x + labelW + 90, y), "Reference",
                    d.toks[s].kind == ckReference):
    d.toks[s].kind = ckReference
    d.toks[s].content = "file"
    d.refScroll = 0
  y += 34
  ui.textIn("Content", rect(r.x, y, labelW, 26), colText)
  if d.toks[s].kind == ckValue:
    discard ui.textField("cl-content", rect(r.x + labelW, y, r.w - labelW, 26),
      d.toks[s].content, "text")
    ui.textIn("The default; it can be changed on run.",
      rect(r.x + labelW, y + 28, r.w - labelW, 18), colTextDim, FontSmall)
    ui.textIn("A leading ~ means your home folder.",
      rect(r.x + labelW, y + 46, r.w - labelW, 18), colTextDim, FontSmall)
  else:
    let h = RowH * 2 + 2
    d.referenceList(ui, rect(r.x + labelW, y, r.w - labelW, h), d.toks[s], path)

# --- window ---------------------------------------------------------------------

proc wrapText(ui: Ui, s: string, width: float32, maxLines: int, font: string): seq[string] =
  ## Greedy word wrap; the last line is ellipsized when text remains.
  var line = ""
  let words = s.split(' ')
  for i, word in words:
    let next = if line.len == 0: word else: line & " " & word
    if line.len > 0 and ui.textSize(next, font).x > width:
      if result.len == maxLines - 1:
        result.add ui.ellipsize(line & " " & words[i .. ^1].join(" "), width, font)
        return
      result.add ui.ellipsize(line, width, font)
      line = word
    else:
      line = next
  if line.len > 0: result.add ui.ellipsize(line, width, font)

proc draw*(d: CmdDialog, ui: Ui, r: Rect, path: string): CmdAction =
  ## Draws the window's contents filling r. path is the current media file,
  ## offered as a reference.
  let w = ui.window
  let keys = ui.focusId.len == 0  # keys for the window, not a field being edited
  let W = r.w
  let H = r.h

  # Title, with the saved command lines dropped down from the arrow.
  ui.textIn("Title", rect(r.x + 16, r.y + 10, 200, 20), colTextDim, FontSmall)
  let titleR = rect(r.x + 16, r.y + 32, W - 32 - 34 - 88 * 2, 28)
  let arrowR = rect(titleR.x + titleR.w + 4, titleR.y, 30, 28)
  let newR = rect(arrowR.x + arrowR.w + 8, titleR.y, 80, 28)
  let delR = rect(newR.x + newR.w + 8, titleR.y, 80, 28)
  const ListMax = 10
  let listRows = d.saved.len
  let listR = rect(titleR.x, titleR.y + titleR.h + 2, titleR.w + 34,
    min(listRows, ListMax).float32 * RowH + 2)
  let overList = d.listOpen and ui.mouse.inside(listR)
  var escUsed = false
  if d.listOpen:
    if w.buttonPressed[KeyEscape]:
      d.listOpen = false
      escUsed = true
    if ui.pressed() and not overList:
      d.listOpen = false
      ui.consumeClick()
  if overList:
    if ui.scroll() != 0:
      d.listScroll += int(sgn(ui.scroll()))
      ui.scrollConsumed = true
    ui.captured = true
  d.listScroll = clamp(d.listScroll, 0, max(0, listRows - ListMax))

  discard ui.textField("cl-title", titleR, d.title, "Untitled")
  ui.rect(arrowR, colPanelRaised)
  ui.border(arrowR, colBorder)
  if ui.iconButton("cl-list", arrowR, "expand16", "Saved command lines",
                   enabled = listRows > 0):
    d.listOpen = not d.listOpen
    d.listScroll = 0
  if ui.textButton("cl-new", newR, "New"):
    d.load(CommandLine())
    ui.focusId = "cl-title"
    ui.navId = "cl-title"
    ui.focusFresh = true
  let canDelete = d.origTitle.len > 0
  if canDelete:
    if ui.textButton("cl-delete", delR, "Delete"): result = caDelete
  else:
    ui.rect(delR, colPanelRaised)
    ui.border(delR, colBorder)
    ui.textIn("Delete", delR, colTextDisabled, h = CenterAlign)

  # Left column: New card, then the selected card's properties.
  let top = r.y + 76
  let bottom = r.y + H - 58
  let leftR = rect(r.x + 16, top, 300, bottom - top)
  if ui.textButton("cl-newcard", rect(leftR.x, leftR.y, 120, 28), "New card"):
    d.newCard(ui)
  d.properties(ui, rect(leftR.x, leftR.y + 44, leftR.w, leftR.h - 44), path)

  # Right column: the command line and what it would run.
  let rx = leftR.x + leftR.w + 20
  let rightR = rect(rx, top, r.x + W - 16 - rx, bottom - top)
  ui.groupHeader(rightR.xy, rightR.w, "Command line")
  const previewH = 4 * 18'f32 + 26
  let fieldR = rect(rightR.x, rightR.y + 26, rightR.w, rightR.h - 26 - previewH)
  d.commandField(ui, fieldR)
  var py = fieldR.y + fieldR.h + 10
  ui.textIn("Runs as", rect(rightR.x, py, rightR.w, 18), colTextDim, FontSmall)
  py += 20
  let shown = d.toks.preview(path)
  for line in ui.wrapText(shown, rightR.w, 4, FontSmall):
    ui.textIn(line, rect(rightR.x, py, rightR.w, 18), colText, FontSmall)
    py += 18

  # Buttons; the reason for a refused Apply on their left.
  ui.rect(rect(r.x + 1, r.y + H - 50, W - 2, 1), colBorder)
  let by = r.y + H - 40
  if d.error.len > 0:
    ui.textIn(ui.ellipsize(d.error, W - 260), rect(r.x + 16, by, W - 260, 30), colError)
  let cancel = ui.textButton("cl-cancel", rect(r.x + W - 212, by, 92, 30), "Cancel")
  var apply = ui.textButton("cl-apply", rect(r.x + W - 112, by, 92, 30), "Apply",
    primary = true)
  if d.applyRequested:
    d.applyRequested = false
    apply = true
  # Enter applies unless a focused button took it.
  if keys and not ui.enterUsed and
     (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]):
    apply = true
  if cancel or keys and not escUsed and w.buttonPressed[KeyEscape]: result = caCancel
  elif apply:
    d.error = d.validate
    if d.error.len == 0: result = caApply

  # The dropped-down title list, over everything.
  if d.listOpen:
    ui.captured = false
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(listR.xy + vec2(3, 4), listR.wh), colShadow)
    ui.rect(listR, colPopup)
    ui.border(listR, colBorder)
    for n in 0 ..< min(listRows, ListMax):
      let i = n + d.listScroll
      let rr = rect(listR.x + 1, listR.y + 1 + n.float32 * RowH, listR.w - 2, RowH)
      let hov = ui.hover(rr)
      if hov: ui.rect(rr, colHover)
      let label = d.saved[i].title
      let current = label == d.origTitle
      ui.textIn(ui.ellipsize(label, rr.w - 20), rect(rr.x + 10, rr.y, rr.w - 20, RowH),
        if current: colAccent else: colText)
      if hov and ui.pressed():
        ui.consumeClick()
        ui.focusId = ""
        d.load(d.saved[i])
    ui.sk.popLayer()

  if result != caNone:
    ui.focusId = ""
    return
  discard ui.tabNavigate()

# --- Run window: bookmarks and values for one run ---------------------------------

type
  PickAction* = enum
    paNone, paRun, paCancel

  PickDialog* = ref object
    ## Shown when a command line with value or bookmark cards runs: one row
    ## per card, its name and a dropdown of the media file's bookmarks or a
    ## field holding the card's value.
    cmd*: CommandLine
    rows*: seq[CmdPart]       ## the cards asked about
    picks*: seq[int]          ## bookmark rows: the bookmark index chosen
    texts*: seq[string]       ## value rows: the value to run with
    openRow*: int             ## row whose dropdown is open, else -1
    listScroll: int
    runRequested*: bool       ## debug scripting: press Run next frame

const
  PickTop = 44'f32
  PickRowH = 36'f32
  PickLabelW = 150'f32

proc newPickDialog*(): PickDialog = PickDialog(openRow: -1)

proc start*(d: PickDialog, c: CommandLine, count: int) =
  ## Prepares the window for c. Values start at the card's own; the n-th
  ## bookmark card starts at bookmark n, so a command using bookmarks in
  ## order needs no changes for a file marked in order.
  d.cmd = c
  d.rows = c.parts.runCards
  d.picks = newSeq[int](d.rows.len)
  d.texts = newSeq[string](d.rows.len)
  var n = 0
  for i, row in d.rows:
    if row.isBookmark:
      d.picks[i] = max(0, min(n, count - 1))
      inc n
    else:
      d.texts[i] = row.content
  d.openRow = -1
  d.listScroll = 0

proc size*(d: PickDialog): tuple[w, h: int32] =
  (480'i32, int32(max(200'f32, PickTop + d.rows.len.float32 * PickRowH + 70)))

proc markText(marks: seq[Bookmark], i: int): (string, string) =
  if i >= 0 and i < marks.len: (marks[i].label(i), fmtTime(marks[i].time, millis = true))
  else: ("", "")

proc dropRect(r: Rect, i: int): Rect =
  rect(r.x + 16 + PickLabelW, r.y + PickTop + i.float32 * PickRowH, r.w - 32 - PickLabelW, 28)

proc listRect(r: Rect, i, count: int): tuple[r: Rect, rows: int] =
  ## The open dropdown's list: below its field, or above when there is more
  ## room there; it scrolls when the window is too short for all rows.
  let dr = dropRect(r, i)
  let below = r.y + r.h - (dr.y + dr.h) - 6
  let above = dr.y - r.y - 6
  let space = max(below, above)
  let rows = max(1, min(count, int((space - 2) / RowH)))
  let h = rows.float32 * RowH + 2
  let y = if below >= h or below >= above: dr.y + dr.h + 2 else: dr.y - 2 - h
  (rect(dr.x, y, dr.w, h), rows)

proc draw*(d: PickDialog, ui: Ui, r: Rect, marks: seq[Bookmark]): PickAction =
  let w = ui.window
  let noField = ui.focusId.len == 0  # else Escape belongs to the value field
  let count = marks.len
  var escUsed = false

  # An open list takes the pointer; a press elsewhere closes it.
  var lr: tuple[r: Rect, rows: int]
  if d.openRow >= 0:
    lr = listRect(r, d.openRow, count)
    let over = ui.mouse.inside(lr.r)
    if w.buttonPressed[KeyEscape]:
      d.openRow = -1
      escUsed = true
    elif ui.pressed() and not over:
      d.openRow = -1
      ui.consumeClick()
    elif over:
      if ui.scroll() != 0:
        d.listScroll += int(sgn(ui.scroll()))
        ui.scrollConsumed = true
      ui.captured = true
    d.listScroll = clamp(d.listScroll, 0, max(0, count - lr.rows))
  let open = d.openRow

  ui.textIn(ui.ellipsize("Variables of " & d.cmd.title & " for this run.", r.w - 32, FontSmall),
    rect(r.x + 16, r.y + 12, r.w - 32, 20), colTextDim, FontSmall)
  for i, row in d.rows:
    let dr = dropRect(r, i)
    ui.textIn(ui.ellipsize(row.name, PickLabelW - 12),
      rect(r.x + 16, dr.y, PickLabelW - 12, dr.h), colText)
    let id = "pk-" & $i
    if not row.isBookmark:
      discard ui.textField(id, dr, d.texts[i], "empty")
      continue
    let hov = ui.hover(dr)
    let focused = ui.tabStop(id, dr)
    if hov and ui.pressed():
      ui.consumeClick()
      ui.navId = id
      d.openRow = if open == i: -1 else: i
      if d.openRow >= 0:
        # Start with the chosen bookmark in view.
        d.listScroll = d.picks[i] - listRect(r, i, count).rows div 2
    if focused and ui.focusId.len == 0 and d.openRow < 0:
      if w.buttonPressed[KeyUp]: d.picks[i] = max(0, d.picks[i] - 1)
      if w.buttonPressed[KeyDown]: d.picks[i] = min(count - 1, d.picks[i] + 1)
      if w.buttonPressed[KeySpace]:
        d.openRow = i
        d.listScroll = d.picks[i] - listRect(r, i, count).rows div 2
    d.picks[i] = clamp(d.picks[i], 0, count - 1)
    ui.rect(dr, colBackground)
    ui.border(dr, if open == i: colAccent elif hov: colTextDim else: colBorder)
    if focused: ui.focusRing(dr)
    let (label, time) = markText(marks, d.picks[i])
    let tw = ui.textSize(time, FontSmall).x
    ui.textIn(ui.ellipsize(label, dr.w - tw - 52), rect(dr.x + 8, dr.y, dr.w - tw - 52, dr.h),
      colText)
    ui.textIn(time, rect(dr.x + dr.w - tw - 34, dr.y, tw, dr.h), colTextDim, FontSmall)
    ui.icon("expand16", vec2(dr.x + dr.w - 15, dr.y + dr.h / 2),
      if hov: colText else: colTextDim)

  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  let keys = noField and d.openRow < 0
  let cancel = ui.textButton("pk-cancel", rect(r.x + r.w - 212, by, 92, 30), "Cancel")
  var run = ui.textButton("pk-run", rect(r.x + r.w - 112, by, 92, 30), "Run", primary = true)
  if d.runRequested:
    d.runRequested = false
    run = true
  # Enter runs, also from a value field.
  if d.openRow < 0 and open < 0 and not ui.enterUsed and
     (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]):
    run = true
  if cancel or keys and not escUsed and w.buttonPressed[KeyEscape]: result = paCancel
  elif run: result = paRun

  # The open list, over everything.
  if d.openRow >= 0 and d.openRow == open:
    ui.captured = false
    ui.sk.pushLayer(PopupsLayer)
    ui.rect(rect(lr.r.xy + vec2(3, 4), lr.r.wh), colShadow)
    ui.rect(lr.r, colPopup)
    ui.border(lr.r, colAccent)
    for n in 0 ..< lr.rows:
      let k = n + d.listScroll
      if k >= count: break
      let rr = rect(lr.r.x + 1, lr.r.y + 1 + n.float32 * RowH, lr.r.w - 2, RowH)
      let hov = ui.hover(rr)
      let sel = k == d.picks[open]
      if sel: ui.rect(rr, colAccent)
      elif hov: ui.rect(rr, colHover)
      let (label, time) = markText(marks, k)
      let tw = ui.textSize(time, FontSmall).x
      ui.textIn(ui.ellipsize(label, rr.w - tw - 30), rect(rr.x + 8, rr.y, rr.w - tw - 30, RowH),
        if sel: colOnAccent else: colText)
      ui.textIn(time, rect(rr.x + rr.w - tw - 10, rr.y, tw, RowH),
        if sel: colOnAccent else: colTextDim, FontSmall)
      if hov and ui.pressed():
        ui.consumeClick()
        d.picks[open] = k
        d.openRow = -1
    if count > lr.rows:
      let th = max(16'f32, lr.r.h * lr.rows.float32 / count.float32)
      let ty = lr.r.y + (lr.r.h - th) * (d.listScroll / max(1, count - lr.rows))
      ui.rect(rect(lr.r.x + lr.r.w - 4, ty, 3, th), colTrack)
    ui.sk.popLayer()

  if result == paNone: discard ui.tabNavigate()
