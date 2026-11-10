## Options > Libraries > Custom...: the file types a library lists, checked in
## a list like Options > Formats' (searched the same way), or typed in.

import std/[strutils, sequtils, strformat, tables]
import silky, vmath, bumpy, pixie
import ui, theme, config

type
  TypesAction* = enum
    taNone, taOk, taCancel

  TypeItem = object
    ext: string
    kind: string            ## Video, Audio, Module...
    mimes: string
    checked: bool

  TypesDialog* = ref object
    library*: int           ## the library whose types these are
    name*: string           ## its name, for the title
    items: seq[TypeItem]
    search: string
    addText: string         ## a type to add that isn't listed
    note: string            ## why the typed one wasn't added
    scroll: float32
    cursor: int             ## the row moved with the keyboard

const RowH = 24'f32

proc kindOf(ext: string): string =
  if ext in VideoExtensions: "Video"
  elif ext in AudioExtensions: "Audio"
  elif ext in TrackerExtensions: "Module"
  elif ext in MidiExtensions: "MIDI"
  elif ext in ImageExtensions: "Picture"
  elif ext == "cue": "Cue sheet"
  else: "Other"

proc open*(d: TypesDialog, library: int, name: string, exts: seq[string],
           mimes: Table[string, seq[string]]) =
  ## Starts the list over: every type the player knows, and the library's
  ## own (checked); MIME types from the system where it knows them.
  d.library = library
  d.name = name
  d.items = @[]
  d.search = ""
  d.addText = ""
  d.note = ""
  d.scroll = 0
  d.cursor = 0
  var all: seq[string]
  for e in @VideoExtensions & @AudioExtensions & @TrackerExtensions & @MidiExtensions &
           @ImageExtensions & @["cue"]:
    if e notin all: all.add e
  for e in exts:
    if e notin all: all.add e
  for e in all:
    d.items.add TypeItem(ext: e, kind: kindOf(e), mimes: mimes.getOrDefault(e).join(", "),
      checked: e in exts)

proc chosen*(d: TypesDialog): seq[string] =
  for it in d.items:
    if it.checked: result.add it.ext

proc addType(d: TypesDialog) =
  ## The typed type, checked (and listed, when it wasn't).
  let e = d.addText.strip.toLowerAscii.strip(chars = {'.', '*', ' '})
  if e.len == 0: return
  if e.anyIt(it in {'/', '\\', ',', ' ', '.'}):
    d.note = "Type it as the part of a file name after the last dot, e.g. mkv"
    return
  d.note = ""
  d.addText = ""
  for it in d.items.mitems:
    if it.ext == e:
      it.checked = true
      d.search = e
      return
  d.items.add TypeItem(ext: e, kind: kindOf(e), checked: true)
  d.search = e

proc draw*(d: TypesDialog, ui: Ui, r: Rect): TypesAction =
  ## Draws the window's contents filling r.
  let w = ui.window
  let keys = ui.focusId.len == 0
  let x = r.x + 16
  let width = r.w - 32
  var y = r.y + 14
  ui.textIn(ui.ellipsize(&"File types \"{d.name}\" lists", width), rect(x, y, width, 24), colText)
  y += 30
  discard ui.textField("lt-search", rect(x, y, width, 26), d.search, "Search types or MIME types")
  y += 34

  let footer = 34'f32 + 22 + 58  # buttons, the count, the bottom bar
  let list = rect(x, y, width, max(120'f32, r.y + r.h - y - footer))
  ui.rect(list, colBackground)
  ui.border(list, colBorder)
  let needle = d.search.strip.toLowerAscii.strip(chars = {'.', '*'})
  var shown: seq[int]
  for i, it in d.items:
    if needle.len == 0 or needle in it.ext or needle in it.mimes.toLowerAscii or
       needle in it.kind.toLowerAscii:
      shown.add i
  let inner = rect(list.x + 1, list.y + 1, list.w - 2, list.h - 2)
  let maxScroll = max(0'f32, shown.len.float32 * RowH - inner.h)
  let listFocused = ui.tabStop("lt-list", list)
  d.cursor = clamp(d.cursor, 0, max(0, shown.high))
  if listFocused and keys and shown.len > 0:
    # Up/Down/PageUp/PageDown/Home/End move the cursor row, Space checks it.
    let page = max(1, int(inner.h / RowH) - 1)
    var c = d.cursor
    if w.buttonPressed[KeyUp]: dec c
    if w.buttonPressed[KeyDown]: inc c
    if w.buttonPressed[KeyPageUp]: c -= page
    if w.buttonPressed[KeyPageDown]: c += page
    if w.buttonPressed[KeyHome]: c = 0
    if w.buttonPressed[KeyEnd]: c = shown.high
    c = clamp(c, 0, shown.high)
    if c != d.cursor:
      d.cursor = c
      ui.navVisible = true
      let top = c.float32 * RowH
      if top < d.scroll: d.scroll = top
      if top + RowH > d.scroll + inner.h: d.scroll = top + RowH - inner.h
    if w.buttonPressed[KeySpace]:
      d.items[shown[c]].checked = not d.items[shown[c]].checked
      ui.navVisible = true
  if ui.hover(inner) and ui.scroll() != 0:
    d.scroll += ui.scroll() * RowH / 3
    ui.scrollConsumed = true
  d.scroll = clamp(d.scroll, 0, maxScroll)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for n, i in shown:
    let it = d.items[i]
    let row = rect(inner.x, inner.y + n.float32 * RowH - d.scroll, inner.w, RowH)
    if row.y + RowH < inner.y or row.y > inner.y + inner.h: continue
    let hov = ui.hover(row)
    if hov: ui.rect(row, colHover)
    if listFocused and ui.navVisible and n == d.cursor: ui.border(row, colAccent)
    let box = rect(row.x + 8, row.y + 4, 16, 16)
    ui.rect(box, if it.checked: colAccent else: colPanelRaised)
    ui.border(box, if hov: colAccent else: colBorder)
    if it.checked: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
    ui.textIn("." & it.ext, rect(row.x + 32, row.y, 80, RowH), colText)
    ui.textIn(it.kind, rect(row.x + 112, row.y, 76, RowH), colTextDim, FontSmall)
    ui.textIn(ui.ellipsize(it.mimes, row.w - 200, FontSmall), rect(row.x + 192, row.y, row.w - 196, RowH),
      colTextDim, FontSmall)
    if hov and ui.pressed():
      ui.pressId = "lt-item" & $i
      ui.navId = "lt-list"
      d.cursor = n
      ui.consumeClick()
    if hov and w.buttonReleased[MouseLeft] and ui.pressId == "lt-item" & $i:
      d.items[i].checked = not it.checked
  if shown.len == 0:
    ui.textIn("No matching types: add it below", inner, colTextDim, FontSmall, h = CenterAlign)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  y = list.y + list.h + 8

  # Whole groups, and a type of one's own.
  let bw = 110'f32
  proc setAll(d: TypesDialog, kinds: openArray[string], on: bool) =
    for it in d.items.mitems:
      if it.kind in kinds: it.checked = on
  if ui.textButton("lt-video", rect(x, y, bw, 28), "All video"): d.setAll(["Video"], true)
  if ui.textButton("lt-audio", rect(x + bw + 6, y, bw, 28), "All audio"):
    d.setAll(["Audio", "Module", "MIDI"], true)
  if ui.textButton("lt-clear", rect(x + 2 * (bw + 6), y, 70, 28), "None"):
    for it in d.items.mitems: it.checked = false
  let ax = x + 2 * (bw + 6) + 76 + 14
  let addW = 70'f32
  let fieldW = max(60'f32, x + width - ax - addW - 6)
  let ev = ui.textField("lt-add", rect(ax, y + 1, fieldW, 26), d.addText, "Another type, e.g. mts")
  if eeCommitted in ev and (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter]):
    d.addType()
    ui.enterUsed = true  # not OK
  if ui.textButton("lt-addbtn", rect(ax + fieldW + 6, y, addW, 28), "Add"): d.addType()
  y += 34
  let count = d.chosen.len
  let note = if d.note.len > 0: d.note
             elif count == 0: "No types checked"
             else: &"{count} type(s) checked"
  ui.textIn(ui.ellipsize(note, width, FontSmall), rect(x, y, width, 18),
    if d.note.len > 0: colError elif count == 0: colWarning else: colTextDim, FontSmall)

  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  let okR = rect(r.x + r.w - 212, by, 92, 30)
  if count == 0:
    ui.rect(okR, colPanelRaised)
    ui.border(okR, colBorder)
    ui.textIn("OK", okR, colTextDisabled, h = CenterAlign)
    ui.tip(okR, "Check at least one type")
  elif ui.textButton("lt-ok", okR, "OK", primary = true):
    result = taOk
  if ui.textButton("lt-cancel", rect(r.x + r.w - 112, by, 92, 30), "Cancel"):
    result = taCancel
  let enter = keys and (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter])
  if result == taNone and enter and not ui.enterUsed and count > 0: result = taOk
  if result == taNone and keys and w.buttonPressed[KeyEscape]: result = taCancel
  if result == taNone: discard ui.tabNavigate()
  else: ui.focusId = ""
