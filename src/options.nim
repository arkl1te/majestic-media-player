## Options window: a tree of pages on the left (drawn like a classic Windows
## tree view) and the selected page on the right. Edits apply to the config
## live; the caller snapshots it beforehand so Cancel can undo them.

import std/[strutils, strformat, math]
import silky, vmath, bumpy, chroma, pixie
import ui, theme, config, assoc

type
  OptionsPage* = enum
    opPlayer = "Player"
    opFormats = "Formats"
    opPlayback = "Playback"
    opSubtitles = "Subtitles"
    opMisc = "Miscellaneous"

  OptionsAction* = enum
    oaNone, oaOk, oaCancel

  OptionsDialog* = ref object
    page*: OptionsPage
    playerOpen: bool            ## Player node expanded (shows Formats)
    scroll: float32             ## page content scroll
    assoc: seq[AssocItem]
    assocLoaded: bool
    search: string
    listScroll: float32
    listCursor: int             ## Formats list row moved with the keyboard
    status: string              ## Formats page: outcome of the last Apply
    assocApplied*: bool         ## associations were written; the caller clears it

  Pane = object
    ## Layout cursor for a page.
    x, y, w: float32
    started: bool               ## a group header was placed already

const
  Tree = [(opPlayer, 0), (opFormats, 1), (opPlayback, 0), (opSubtitles, 0), (opMisc, 0)]
  TreeWidth = 180'f32
  TreeRow = 22'f32
  TreeIndent = 16'f32
  Row = 28'f32                  ## height of one option line
  LabelW = 210'f32              ## label column for numbers and text inputs

proc newOptionsDialog*(): OptionsDialog = OptionsDialog(playerOpen: true)

proc opened*(d: OptionsDialog, ui: Ui) =
  ## The window is being shown: re-read associations, start at the top.
  d.assocLoaded = false
  d.status = ""
  d.scroll = 0
  ui.navId = "o-tree"
  ui.navVisible = false

proc selectPage*(d: OptionsDialog, ui: Ui, p: OptionsPage) =
  if p == d.page: return
  d.page = p
  d.scroll = 0
  ui.focusId = ""
  if p == opFormats: d.playerOpen = true

# --- tree ---------------------------------------------------------------------

proc visibleRows(d: OptionsDialog): seq[(OptionsPage, int)] =
  for (p, level) in Tree:
    if level == 0 or d.playerOpen: result.add (p, level)

proc dotsH(ui: Ui, x1, x2, y: float32) =
  var x = x1.round
  while x < x2:
    ui.rect(rect(x, y.round, 1, 1), colTextDisabled)
    x += 2

proc dotsV(ui: Ui, x, y1, y2: float32) =
  var y = y1.round
  while y < y2:
    ui.rect(rect(x.round, y, 1, 1), colTextDisabled)
    y += 2

proc drawTree(d: OptionsDialog, ui: Ui, r: Rect, keys: bool) =
  ui.rect(r, colBackground)
  ui.border(r, colBorder)
  let rows = d.visibleRows
  let focused = ui.tabStop("o-tree", r)
  let top = r.y + 6
  let x0 = r.x + 14             # root connector column, expanders sit on it
  proc rowY(i: int): float32 = top + i.float32 * TreeRow
  proc mid(i: int): float32 = rowY(i) + TreeRow / 2

  # Connectors: roots share one column; children hang off their parent.
  var firstRoot, lastRoot = -1
  for i, (p, level) in rows:
    if level == 0:
      if firstRoot < 0: firstRoot = i
      lastRoot = i
  ui.dotsV(x0, mid(firstRoot), mid(lastRoot) + 1)
  for i, (p, level) in rows:
    let cy = mid(i)
    if level == 0:
      if p != opPlayer: ui.dotsH(x0, x0 + 10, cy)
    else:
      let xc = x0 + TreeIndent
      ui.dotsV(xc, mid(i - 1) + 6, cy + 1)
      ui.dotsH(xc, xc + 10, cy)

  for i, (p, level) in rows:
    let y = rowY(i)
    let cy = mid(i)
    if p == opPlayer:
      let ex = rect(x0 - 7, cy - 7, 15, 15)
      ui.rect(ex, colBackground)
      ui.icon(if d.playerOpen: "expand16" else: "arrow16", vec2(x0 + 0.5, cy),
        if ui.hover(ex): colText else: colTextDim)
      if ui.hover(ex) and ui.pressed():
        ui.consumeClick()
        d.playerOpen = not d.playerOpen
        if not d.playerOpen and d.page == opFormats: d.selectPage(ui, opPlayer)
    let lx = x0 + level.float32 * TreeIndent + 12
    let label = rect(lx, y + 2, ui.textSize($p).x + 10, TreeRow - 4)
    let rowR = rect(lx, y, r.x + r.w - lx - 4, TreeRow)
    let sel = d.page == p
    let hov = ui.hover(rowR)
    if sel: ui.rect(label, colAccent)
    elif hov: ui.rect(label, colHover)
    if sel and focused: ui.focusRing(rect(label.x + 2, label.y + 2, label.w - 4, label.h - 4))
    ui.textIn($p, rect(label.x + 5, label.y, label.w, label.h),
      if sel: colOnAccent else: colText)
    if hov and ui.pressed():
      ui.consumeClick()
      ui.navId = "o-tree"
      d.selectPage(ui, p)
    if hov and p == opPlayer and ui.window.buttonPressed[DoubleClick]:
      d.playerOpen = not d.playerOpen

  # Keyboard: Up/Down move, Left collapses (or goes to the parent), Right expands.
  if not keys or ui.navId notin ["", "o-tree"]: return
  let w = ui.window
  var cur = 0
  for i, (p, _) in rows:
    if p == d.page: cur = i
  if w.buttonPressed[KeyUp] and cur > 0: d.selectPage(ui, rows[cur - 1][0])
  elif w.buttonPressed[KeyDown] and cur < rows.high: d.selectPage(ui, rows[cur + 1][0])
  elif w.buttonPressed[KeyLeft]:
    if d.page == opFormats: d.selectPage(ui, opPlayer)
    elif d.page == opPlayer: d.playerOpen = false
  elif w.buttonPressed[KeyRight] and d.page == opPlayer:
    d.playerOpen = true

# --- page building blocks -----------------------------------------------------

proc group(ui: Ui, p: var Pane, title: string) =
  if p.started: p.y += 6
  p.started = true
  ui.groupHeader(vec2(p.x, p.y), p.w, title)
  p.y += 26

proc gap(p: var Pane) = p.y += 10

proc checkRow(ui: Ui, p: var Pane, id, label: string, value: var bool) =
  discard ui.checkbox(id, vec2(p.x + 8, p.y + 2), label, value)
  p.y += Row

proc radioRow[T](ui: Ui, p: var Pane, id, label: string, value: var T, option: T) =
  if ui.radioButton(id, vec2(p.x + 8, p.y + 2), label, value == option):
    value = option
  p.y += Row

proc numberRow(ui: Ui, p: var Pane, id, label: string, value: var float,
            step, lo, hi: float, decimals = 0) =
  ui.textIn(label, rect(p.x + 8, p.y, LabelW, 26), colText)
  discard ui.numberField(id, rect(p.x + 8 + LabelW, p.y, 150, 26), value,
    step, lo, hi, decimals)
  p.y += Row + 4

proc textRow(ui: Ui, p: var Pane, id, label: string, value: var string, placeholder: string) =
  ui.textIn(label, rect(p.x + 8, p.y, LabelW, 26), colText)
  discard ui.textField(id, rect(p.x + 8 + LabelW, p.y, max(120'f32, p.w - LabelW - 8), 26),
    value, placeholder)
  p.y += Row + 4

proc hint(ui: Ui, p: var Pane, s: string) =
  ui.textIn(s, rect(p.x + 8, p.y - 2, p.w - 8, 18), colTextDim, FontSmall)
  p.y += 20

# --- pages ----------------------------------------------------------------------

proc playerPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Open options")
  ui.radioRow(p, "o-same", "Same player for each media file", c.openMode, omSamePlayer)
  ui.radioRow(p, "o-new", "New player for each media file", c.openMode, omNewPlayer)
  p.gap
  ui.checkRow(p, "o-fit", "Resize window to fit video on open", c.autoFitWindow)
  ui.checkRow(p, "o-rtime", "Remember time (continue where the file was left off)", c.rememberTime)
  ui.checkRow(p, "o-rpos", "Remember window position", c.rememberWindowPos)
  ui.checkRow(p, "o-rsize", "Remember window size", c.rememberWindowSize)
  ui.checkRow(p, "o-rxf", "Remember last grab, rotation and scale", c.rememberTransform)
  ui.checkRow(p, "o-rpl", "Remember playlist", c.rememberPlaylist)
  ui.group(p, "Timestamps")
  ui.checkRow(p, "o-osdtime", "Show timestamp in OSD", c.osdTimestamp)
  ui.checkRow(p, "o-millis", "Show milliseconds", c.showMillis)
  ui.checkRow(p, "o-remain", "Show remaining time", c.showRemaining)
  ui.group(p, "Seekbar")
  ui.checkRow(p, "o-bmch", "Bookmarks as chapters", c.bookmarksAsChapters)
  ui.hint(p, "Next/previous chapter also stops at bookmarks.")
  ui.group(p, "Title bar")
  ui.radioRow(p, "o-tname", "File name only", c.titleFullPath, false)
  ui.radioRow(p, "o-tpath", "Display full path", c.titleFullPath, true)
  ui.checkRow(p, "o-ttitle", "Replace file name with title", c.titleUseMediaTitle)

proc formatsPage(d: OptionsDialog, ui: Ui, p: var Pane, bottom: float32) =
  if not d.assocLoaded:
    d.assoc = loadAssocItems()
    d.assocLoaded = true
    d.listScroll = 0
  ui.group(p, "File association")
  discard ui.textField("o-search", rect(p.x + 8, p.y, p.w - 8, 26), d.search,
    "Search extensions or MIME types")
  p.y += 34

  let footer = 8'f32 + 34 + 18  # buttons and the status line below the list
  let list = rect(p.x + 8, p.y, p.w - 8, max(120'f32, bottom - p.y - footer))
  ui.rect(list, colBackground)
  ui.border(list, colBorder)
  let needle = d.search.strip.toLowerAscii.strip(chars = {'.', '*'})
  var shown: seq[int]
  for i, it in d.assoc:
    if needle.len == 0 or needle in it.ext or needle in it.mimes.join(" "):
      shown.add i
  const rowH = 24'f32
  let inner = rect(list.x + 1, list.y + 1, list.w - 2, list.h - 2)
  let maxScroll = max(0'f32, shown.len.float32 * rowH - inner.h)
  let listFocused = ui.tabStop("o-assoc-list", list)
  d.listCursor = clamp(d.listCursor, 0, max(0, shown.high))
  if listFocused and ui.focusId.len == 0 and shown.len > 0:
    # Up/Down/PageUp/PageDown/Home/End move the cursor row, Space toggles it.
    let w = ui.window
    let page = max(1, int(inner.h / rowH) - 1)
    var c = d.listCursor
    if w.buttonPressed[KeyUp]: dec c
    if w.buttonPressed[KeyDown]: inc c
    if w.buttonPressed[KeyPageUp]: c -= page
    if w.buttonPressed[KeyPageDown]: c += page
    if w.buttonPressed[KeyHome]: c = 0
    if w.buttonPressed[KeyEnd]: c = shown.high
    c = clamp(c, 0, shown.high)
    if c != d.listCursor:
      d.listCursor = c
      ui.navVisible = true
      let top = c.float32 * rowH
      if top < d.listScroll: d.listScroll = top
      if top + rowH > d.listScroll + inner.h: d.listScroll = top + rowH - inner.h
    if w.buttonPressed[KeySpace] and d.assoc[shown[c]].mimes.len > 0:
      d.assoc.setChecked(shown[c], not d.assoc[shown[c]].checked)
      ui.navVisible = true
  if ui.hover(inner) and ui.scroll() != 0:
    d.listScroll += ui.scroll() * rowH / 3
    ui.scrollConsumed = true
  d.listScroll = clamp(d.listScroll, 0, maxScroll)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for n, i in shown:
    let it = d.assoc[i]
    let row = rect(inner.x, inner.y + n.float32 * rowH - d.listScroll, inner.w, rowH)
    if row.y + rowH < inner.y or row.y > inner.y + inner.h: continue
    let ok = it.mimes.len > 0
    let hov = ok and ui.hover(row)
    if hov: ui.rect(row, colHover)
    if listFocused and ui.navVisible and n == d.listCursor: ui.border(row, colAccent)
    let box = rect(row.x + 8, row.y + 4, 16, 16)
    ui.rect(box, if it.checked: colAccent else: colPanelRaised)
    ui.border(box, if hov: colAccent else: colBorder)
    if it.checked: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
    let changed = it.checked != it.current
    ui.textIn((if changed: "• " else: "") & "." & it.ext,
      rect(row.x + 32, row.y, 80, rowH), if not ok: colTextDisabled
                                           elif changed: colAccent else: colText)
    ui.textIn(if it.video: "Video" else: "Audio", rect(row.x + 112, row.y, 60, rowH),
      colTextDim, FontSmall)
    let mimes = if ok: it.mimes.join(", ") else: "not in the MIME database"
    ui.textIn(ui.ellipsize(mimes, row.w - 186, FontSmall),
      rect(row.x + 176, row.y, row.w - 180, rowH),
      if ok: colTextDim else: colTextDisabled, FontSmall)
    if hov and ui.pressed():
      ui.pressId = "o-assoc" & $i
      ui.navId = "o-assoc-list"
      d.listCursor = n
      ui.consumeClick()
    if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == "o-assoc" & $i:
      d.assoc.setChecked(i, not it.checked)
  if shown.len == 0:
    ui.textIn("No matching formats", inner, colTextDim, FontSmall, h = CenterAlign)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  p.y = list.y + list.h + 8

  let bw = 140'f32
  if ui.textButton("o-allvideo", rect(p.x + 8, p.y, bw, 28), "Select all video"):
    for i, it in d.assoc:
      if it.video and it.mimes.len > 0: d.assoc.setChecked(i, true)
  if ui.textButton("o-allaudio", rect(p.x + 16 + bw, p.y, bw, 28), "Select all audio"):
    for i, it in d.assoc:
      if not it.video and it.mimes.len > 0: d.assoc.setChecked(i, true)
  var waiting = 0
  for it in d.assoc:
    if it.checked != it.current: inc waiting
  let applyR = rect(p.x + p.w - 160, p.y, 160, 28)
  if waiting > 0:
    if ui.textButton("o-apply", applyR, "Apply associations", primary = true):
      let err = d.assoc.applyAssociations()
      d.status = if err.len > 0: "Could not write mimeapps.list: " & err
                 else: "Associations applied."
      if err.len == 0: d.assocApplied = true
  else:
    ui.rect(applyR, colPanelRaised)
    ui.border(applyR, colBorder)
    ui.textIn("Apply associations", applyR, colTextDisabled, h = CenterAlign)
  p.y += 34
  let note =
    if waiting > 0: &"{waiting} format(s) changed, not applied yet"
    else: d.status
  ui.textIn(ui.ellipsize(note, p.w - 8, FontSmall), rect(p.x + 8, p.y, p.w - 8, 18),
    if waiting > 0: colAccent else: colTextDim, FontSmall)
  p.y += 18

proc playbackPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Steps")
  ui.numberRow(p, "o-rate", "Playback rate", c.rateStep, 0.05, 0.05, 2, 2)
  ui.numberRow(p, "o-jump", "Jump (seconds)", c.seekStep, 1, 1, 600)
  ui.numberRow(p, "o-vol", "Volume", c.volumeStep, 0.5, 0.5, 50, 1)
  ui.group(p, "Seek bar")
  ui.checkRow(p, "o-prev", "Show thumbnail preview on hover", c.seekPreview)
  ui.checkRow(p, "o-snap", "Hold Shift to snap to chapters", c.snapWithShift)
  ui.hint(p, if c.snapWithShift: "Seeking snaps to chapters only while Shift is held."
             else: "Seeking snaps to chapters; hold Shift to seek freely.")
  ui.group(p, "Track preference")
  ui.textRow(p, "o-slang", "Subtitles", c.subLangs, "e.g. eng, jpn")
  ui.textRow(p, "o-alang", "Audio", c.audioLangs, "e.g. jpn, eng")
  ui.hint(p, "Language codes in order of preference; the first matching track is picked on open.")

proc subtitlesPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Subtitles")
  ui.numberRow(p, "o-sdelay", "Delay (milliseconds)", c.subDelay, 50, -600_000, 600_000)
  ui.textRow(p, "o-spaths", "Autoload paths", c.subPaths, "e.g. Subs;Subtitles;~/subs")
  ui.hint(p, "Folders searched for subtitles matching the file's name, separated by ';'.")
  ui.hint(p, "Relative paths start at the media file's folder.")

proc miscPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Steps")
  ui.numberRow(p, "o-move", "Move (pixels)", c.panStep, 1, 1, 500)
  ui.numberRow(p, "o-rot", "Rotate (degrees)", c.rotateStep, 1, 1, 90)
  ui.numberRow(p, "o-size", "Resize (percent)", c.sizeStep, 1, 1, 50)

# --- window -----------------------------------------------------------------------

proc draw*(d: OptionsDialog, ui: Ui, c: var Config, r: Rect): OptionsAction =
  ## Draws the window's contents filling r (the Options window's client area).
  let w = ui.window
  # Keys that belong to the window, not to a text field being edited.
  let keys = ui.focusId.len == 0
  let enter = keys and (w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter])

  let body = rect(r.x + 16, r.y + 16, r.w - 32, r.h - 16 - 58)
  let treeR = rect(body.x, body.y, TreeWidth, body.h)
  d.drawTree(ui, treeR, keys)

  let pageR = rect(treeR.x + treeR.w + 16, body.y, body.w - treeR.w - 16, body.h)
  ui.sk.pushClipRect(pageR)
  let outerClip = ui.hitClip
  ui.hitClip = pageR
  let origin = pageR.y - d.scroll
  var p = Pane(x: pageR.x, y: origin, w: pageR.w - 12)
  let pageStops = ui.tabStops.len
  case d.page
  of opPlayer: playerPage(ui, c, p)
  of opFormats: d.formatsPage(ui, p, pageR.y + pageR.h)
  of opPlayback: playbackPage(ui, c, p)
  of opSubtitles: subtitlesPage(ui, c, p)
  of opMisc: miscPage(ui, c, p)
  ui.hitClip = outerClip
  ui.sk.popClipRect()
  let pageStopsEnd = ui.tabStops.len

  # Long pages scroll when the window is small.
  let contentH = p.y - origin
  let maxScroll = max(0'f32, contentH - pageR.h)
  if ui.hover(pageR) and ui.scroll() != 0:
    d.scroll += ui.scroll() * 3
    ui.scrollConsumed = true
  d.scroll = clamp(d.scroll, 0, maxScroll)
  if maxScroll > 0:
    let th = max(24'f32, pageR.h * pageR.h / contentH)
    let ty = pageR.y + (pageR.h - th) * (d.scroll / maxScroll)
    ui.rect(rect(pageR.x + pageR.w - 4, ty, 3, th), colTrack)

  ui.rect(rect(r.x + 1, r.y + r.h - 50, r.w - 2, 1), colBorder)
  let by = r.y + r.h - 40
  if ui.textButton("o-ok", rect(r.x + r.w - 212, by, 92, 30), "OK", primary = true):
    result = oaOk
  if ui.textButton("o-cancel", rect(r.x + r.w - 112, by, 92, 30), "Cancel"):
    result = oaCancel
  # Enter means OK unless a focused button took it.
  if result == oaNone and enter and not ui.enterUsed: result = oaOk
  if result != oaNone:
    ui.focusId = ""
    return

  # Tab / Shift+Tab: tree, page controls, OK, Cancel. Scroll the page so a
  # newly focused control is visible.
  let i = ui.tabNavigate()
  if i >= pageStops and i < pageStopsEnd:
    let sr = ui.tabStops[i].r
    if sr.y < pageR.y: d.scroll -= pageR.y - sr.y + 4
    elif sr.y + sr.h > pageR.y + pageR.h: d.scroll += sr.y + sr.h - pageR.y - pageR.h + 4
    d.scroll = clamp(d.scroll, 0, maxScroll)
