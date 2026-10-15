## Options window: a tree of pages on the left (drawn like a classic Windows
## tree view) and the selected page on the right. Edits apply to the config
## live; the caller snapshots it beforehand so Cancel can undo them.

import std/[os, strutils, strformat, math, tables, times]
import silky, vmath, bumpy, chroma, pixie
import ui, theme, config, assoc, keymap, websave, mediainfo

type
  OptionsPage* = enum
    opPlayer = "Player"
    opInterface = "Interface"
    opFormats = "Formats"
    opPaths = "Paths"
    opKeys = "Keys"
    opPlayback = "Playback"
    opWeb = "Media Cache"
    opSubtitles = "Subtitles"
    opMisc = "Miscellaneous"
    opSystem = "System"

  OptionsAction* = enum
    oaNone, oaOk, oaCancel

  PathRequest* = enum
    ## Paths page buttons the caller carries out (file dialogs, file manager).
    prNone, prBrowseScreenshots, prBrowseOpen, prShowSettings,
    prBrowseWeb, prOpenWebDir, prClearWeb, prDeleteWeb

  WebInfo* = object
    ## Playback > Media Cache: the cached links, filled in by the caller.
    dir*: string
    used*, free*, total*: int64  ## bytes the folder takes, left on its disk, the disk's size (-1: unknown)
    items*: seq[WebItem]

  OptionsDialog* = ref object
    page*: OptionsPage
    expanded: set[OptionsPage]  ## tree nodes showing their children
    scroll: float32             ## page content scroll
    assoc: seq[AssocItem]
    assocLoaded: bool
    search: string
    listScroll: float32
    listCursor: int             ## Formats list row moved with the keyboard
    status: string              ## Formats page: outcome of the last Apply
    assocApplied*: bool         ## associations were written; the caller clears it
    request*: PathRequest       ## Paths page button pressed; the caller clears it
    keySearch: string
    keyScroll: float32
    keySel: KeyAction           ## Keys page: selected command
    capturing: bool             ## Keys page: waiting for the selected command's new key
    keyTaken: bool              ## a key went to the capture this frame
    keyNote: string             ## Keys page: outcome of the last change
    keyReveal: bool             ## scroll the selected command into view
    web*: WebInfo               ## Media Cache page; the caller refreshes it
    webPicked*: seq[string]     ## Media Cache page: links checked in the list
    webScroll: float32
    confirmClear: bool          ## Media Cache page: Clear pressed once, asking again

  Pane = object
    ## Layout cursor for a page.
    x, y, w: float32
    started: bool               ## a group header was placed already

const
  Tree = [(opPlayer, 0), (opInterface, 1), (opFormats, 1), (opPaths, 1), (opKeys, 1), (opPlayback, 0),
          (opWeb, 1), (opSubtitles, 0), (opMisc, 0), (opSystem, 0)]
  Parents = {opPlayer, opPlayback}
  TreeWidth = 180'f32
  TreeRow = 22'f32
  TreeIndent = 16'f32
  Row = 28'f32                  ## height of one option line
  LabelW = 210'f32              ## label column for numbers and text inputs

proc newOptionsDialog*(): OptionsDialog = OptionsDialog(expanded: Parents)

proc parentOf(p: OptionsPage): OptionsPage =
  ## The tree node p hangs off; p itself for a top-level node.
  result = p
  for (q, level) in Tree:
    if q == p: return
    if level == 0: result = q

proc opened*(d: OptionsDialog, ui: Ui) =
  ## The window is being shown: re-read associations, start at the top.
  d.assocLoaded = false
  d.status = ""
  d.keyNote = ""
  d.capturing = false
  d.confirmClear = false
  d.scroll = 0
  ui.navId = "o-tree"
  ui.navVisible = false

proc selectPage*(d: OptionsDialog, ui: Ui, p: OptionsPage) =
  if p == d.page: return
  d.page = p
  d.scroll = 0
  d.capturing = false
  d.confirmClear = false
  ui.focusId = ""
  d.expanded.incl p.parentOf

# --- tree ---------------------------------------------------------------------

proc visibleRows(d: OptionsDialog): seq[(OptionsPage, int)] =
  for (p, level) in Tree:
    if level == 0 or p.parentOf in d.expanded: result.add (p, level)

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
      if p notin Parents: ui.dotsH(x0, x0 + 10, cy)
    else:
      let xc = x0 + TreeIndent
      # The first child hangs below its parent's label, the next ones off the
      # sibling above.
      ui.dotsV(xc, mid(i - 1) + (if rows[i - 1][1] == level: 0'f32 else: 6), cy + 1)
      ui.dotsH(xc, xc + 10, cy)

  for i, (p, level) in rows:
    let y = rowY(i)
    let cy = mid(i)
    proc toggle(d: OptionsDialog) =
      if p in d.expanded:
        d.expanded.excl p
        if d.page.parentOf == p: d.selectPage(ui, p)
      else: d.expanded.incl p
    if p in Parents:
      let ex = rect(x0 - 7, cy - 7, 15, 15)
      ui.rect(ex, colBackground)
      ui.icon(if p in d.expanded: "expand16" else: "arrow16", vec2(x0 + 0.5, cy),
        if ui.hover(ex): colText else: colTextDim)
      if ui.hover(ex) and ui.pressed():
        ui.consumeClick()
        d.toggle()
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
    if hov and p in Parents and ui.window.buttonPressed[DoubleClick]: d.toggle()

  # Keyboard: Up/Down move, Left collapses (or goes to the parent), Right expands.
  if not keys or ui.navId notin ["", "o-tree"]: return
  let w = ui.window
  var cur = 0
  for i, (p, _) in rows:
    if p == d.page: cur = i
  if w.buttonPressed[KeyUp] and cur > 0: d.selectPage(ui, rows[cur - 1][0])
  elif w.buttonPressed[KeyDown] and cur < rows.high: d.selectPage(ui, rows[cur + 1][0])
  elif w.buttonPressed[KeyLeft]:
    if d.page.parentOf != d.page: d.selectPage(ui, d.page.parentOf)
    elif d.page in Parents: d.expanded.excl d.page
  elif w.buttonPressed[KeyRight] and d.page in Parents:
    d.expanded.incl d.page

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

proc button(ui: Ui, id, label: string, r: Rect, enabled: bool): bool =
  ## A text button, greyed out and inert when not enabled.
  if enabled: return ui.textButton(id, r, label)
  ui.rect(r, colPanelRaised)
  ui.border(r, colBorder)
  ui.textIn(label, r, colTextDisabled, h = CenterAlign)

proc toggleNumberRow(ui: Ui, p: var Pane, id, label: string, on: var bool,
                     value: var int, step, lo, hi: int) =
  ## A checkbox turning a limit on, its number beside it.
  discard ui.checkbox(id, vec2(p.x + 8, p.y + 2), label, on)
  var v = value.float
  discard ui.numberField(id & "-n", rect(p.x + 8 + LabelW, p.y, 150, 26), v,
    step.float, lo.float, hi.float)
  value = clamp(int(round(v)), lo, hi)
  p.y += Row + 4

proc hint(ui: Ui, p: var Pane, s: string) =
  ui.textIn(s, rect(p.x + 8, p.y - 2, p.w - 8, 18), colTextDim, FontSmall)
  p.y += 20

proc folderRow(ui: Ui, p: var Pane, id, label: string, value: var string,
               placeholder: string): bool =
  ## A folder text input with a Browse... button; true when it was pressed.
  const bw = 96'f32
  ui.textIn(label, rect(p.x + 8, p.y, LabelW, 26), colText)
  let fw = max(120'f32, p.w - LabelW - 8 - bw - 8)
  discard ui.textField(id, rect(p.x + 8 + LabelW, p.y, fw, 26), value, placeholder)
  result = ui.textButton(id & "-browse", rect(p.x + 16 + LabelW + fw, p.y, bw, 26),
    "Browse...")
  p.y += Row + 4

proc folderNote(ui: Ui, p: var Pane, value: string) =
  ## Warns when a typed folder does not exist.
  let d = value.expandPath
  if d.len > 0 and not dirExists(d):
    ui.textIn("This folder does not exist.", rect(p.x + 8 + LabelW, p.y - 2, p.w - LabelW - 8, 18),
      colAccent, FontSmall)
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
  ui.checkRow(p, "o-rxf", "Remember last pan, rotation and zoom", c.rememberTransform)
  ui.checkRow(p, "o-rpl", "Remember playlist", c.rememberPlaylist)

proc interfacePage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Interface")
  ui.numberRow(p, "o-scale", "UI scaling (percent)", c.uiScale, 25, 50, 300)
  ui.hint(p, "Size of text, menus and controls in every window.")
  ui.group(p, "OSD")
  ui.textIn("OSD scaling", rect(p.x + 8, p.y, LabelW, 26), colText)
  let sw = clamp(p.w - LabelW - 8 - 70, 120'f32, 300'f32)
  discard ui.slider("o-osdscale", rect(p.x + 8 + LabelW, p.y, sw, 26), c.osdScale,
    OsdScaleMin, OsdScaleMax, 0.05)
  ui.textIn("x" & formatFloat(c.osdScale, ffDecimal, 2),
    rect(p.x + 8 + LabelW + sw + 14, p.y, 60, 26), colText)
  p.y += Row + 4
  ui.checkRow(p, "o-osdwin", "Scale with window size", c.osdScaleByWindow)
  ui.hint(p, if c.osdScaleByWindow: "OSD text grows and shrinks with the video frame."
             else: "OSD text keeps the same size whatever the window's size.")
  ui.group(p, "Timestamps")
  ui.checkRow(p, "o-osdtime", "Show timestamp in OSD", c.osdTimestamp)
  ui.checkRow(p, "o-millis", "Show milliseconds", c.showMillis)
  ui.checkRow(p, "o-remain", "Show remaining time", c.showRemaining)
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
      let kept = d.assoc.userOverrides()
      d.status =
        if err.len > 0: "Could not save associations: " & err
        elif kept.len > 0:
          "Applied. Windows keeps your own default app for ." & kept.join(", .") &
            "; change it in Settings > Default apps."
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

proc pathsPage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Screenshots")
  if ui.folderRow(p, "o-shotdir", "Folder", c.screenshotDir, defaultScreenshotDir()):
    d.request = prBrowseScreenshots
  ui.folderNote(p, c.screenshotDir)
  ui.checkRow(p, "o-shotask", "Save without asking for a file name", c.screenshotNoAsk)
  ui.hint(p, "Alt+I saves a PNG named after the file and the time straight into the folder.")
  ui.group(p, "Open dialogs")
  if ui.folderRow(p, "o-opendir", "Start in", c.openDir,
      "Folder of the playing file"):
    d.request = prBrowseOpen
  ui.folderNote(p, c.openDir)
  ui.hint(p, "Empty: the playing file's folder, else the last folder a file was opened from.")
  ui.group(p, "Settings")
  ui.textIn("Settings folder", rect(p.x + 8, p.y, LabelW, 26), colText)
  const bw = 96'f32
  let tw = max(120'f32, p.w - LabelW - 8 - bw - 8)
  ui.textIn(ui.ellipsize(configDir(), tw), rect(p.x + 8 + LabelW, p.y, tw, 26), colTextDim)
  if ui.textButton("o-cfgdir", rect(p.x + 16 + LabelW + tw, p.y, bw, 26), "Open"):
    d.request = prShowSettings
  p.y += Row + 4
  ui.hint(p, "Settings, remembered positions, bookmarks and Run commands are kept here.")

const KeyCapture = "o-keycap"     ## focusId while waiting for a key

proc startCapture*(d: OptionsDialog, ui: Ui, act: KeyAction) =
  d.keySel = act
  d.capturing = true
  d.keyReveal = true
  ui.focusId = KeyCapture       # the window's own keys (Esc, Enter, Tab) stand back
  ui.navId = "o-keys-list"

proc stopCapture(d: OptionsDialog, ui: Ui) =
  d.capturing = false
  if ui.focusId == KeyCapture: ui.focusId = ""

proc assignKeys*(d: OptionsDialog, c: var Config, act: KeyAction, ks: seq[KeyCombo]) =
  ## Gives act the keys ks, taking each from any command that had it.
  var taken: seq[string]
  for k in ks:
    for other in c.actionsUsing(k):
      if other != act:
        c.removeCombo(other, k)
        let name = "\"" & Actions[other].label & "\""
        if name notin taken: taken.add name
  c.setCombos(act, ks)
  d.keyNote =
    if ks.len == 0: Actions[act].label & ": no key"
    else: Actions[act].label & ": " & c.keysText(act)
  if taken.len > 0: d.keyNote.add " (taken from " & taken.join(", ") & ")"

proc keysPage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane, bottom: float32) =
  let w = ui.window
  d.keyTaken = false
  if d.capturing:
    # The next key pressed, with the modifiers held, becomes the command's
    # key. Escape or a click cancels.
    let key = w.pressedKey
    if w.buttonPressed[KeyEscape] or w.buttonPressed[MouseLeft] or
       w.buttonPressed[MouseRight] or ui.focusId != KeyCapture:
      d.stopCapture(ui)
      d.keyTaken = w.buttonPressed[KeyEscape]
    elif key != ButtonUnknown:
      d.assignKeys(c, d.keySel, @[KeyCombo(mods: w.heldMods, key: key)])
      d.stopCapture(ui)
      d.keyTaken = true

  ui.group(p, "Keyboard shortcuts")
  discard ui.textField("o-keysearch", rect(p.x + 8, p.y, p.w - 8, 26), d.keySearch,
    "Search commands or keys")
  p.y += 34

  # Rows: a header per group, then its commands matching the search.
  type KeyRow = tuple[header: bool, group: KeyGroup, act: KeyAction]
  var rows: seq[KeyRow]
  var acts: seq[int]            # indexes of the command rows
  for g in KeyGroup:
    var first = true
    for act in KeyAction:
      let info = Actions[act]
      if info.group != g: continue
      if not c.matchesSearch(act, d.keySearch): continue
      if first:
        rows.add (true, g, act)
        first = false
      acts.add rows.len
      rows.add (false, g, act)

  let footer = 8'f32 + 34 + 18  # buttons and the status line below the list
  let list = rect(p.x + 8, p.y, p.w - 8, max(120'f32, bottom - p.y - footer))
  ui.rect(list, colBackground)
  ui.border(list, colBorder)
  const rowH = 24'f32
  const keyW = 190'f32
  let inner = rect(list.x + 1, list.y + 1, list.w - 2, list.h - 2)
  let maxScroll = max(0'f32, rows.len.float32 * rowH - inner.h)
  let listFocused = ui.tabStop("o-keys-list", list)
  var cur = -1                  # position of the selected command in acts
  for n, i in acts:
    if rows[i].act == d.keySel: cur = n
  proc reveal(d: OptionsDialog, i: int) =
    let top = i.float32 * rowH
    if top < d.keyScroll: d.keyScroll = top
    if top + rowH > d.keyScroll + inner.h: d.keyScroll = top + rowH - inner.h
  if d.keyReveal and cur >= 0:
    d.keyReveal = false
    d.reveal(acts[cur])
  if listFocused and ui.focusId.len == 0 and acts.len > 0:
    # Up/Down/PageUp/PageDown/Home/End move the selection, Enter or Space
    # asks for a new key, Delete or Backspace removes the key.
    let page = max(1, int(inner.h / rowH) - 1)
    var n = max(cur, 0)
    if w.buttonPressed[KeyUp]: dec n
    if w.buttonPressed[KeyDown]: inc n
    if w.buttonPressed[KeyPageUp]: n -= page
    if w.buttonPressed[KeyPageDown]: n += page
    if w.buttonPressed[KeyHome]: n = 0
    if w.buttonPressed[KeyEnd]: n = acts.high
    n = clamp(n, 0, acts.high)
    if n != cur:
      cur = n
      d.keySel = rows[acts[n]].act
      ui.navVisible = true
      # Bring the group header into view with the first command.
      d.reveal(if n == 0: 0 else: acts[n])
    if cur >= 0:
      if w.buttonPressed[KeyEnter] or w.buttonPressed[NumpadEnter] or w.buttonPressed[KeySpace]:
        ui.enterUsed = true
        d.startCapture(ui, d.keySel)
      elif w.buttonPressed[KeyDelete] or w.buttonPressed[KeyBackspace]:
        d.assignKeys(c, d.keySel, @[])
  if ui.hover(inner) and ui.scroll() != 0:
    d.keyScroll += ui.scroll() * rowH / 3
    ui.scrollConsumed = true
  d.keyScroll = clamp(d.keyScroll, 0, maxScroll)

  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for i, row in rows:
    let r = rect(inner.x, inner.y + i.float32 * rowH - d.keyScroll, inner.w, rowH)
    if r.y + rowH < inner.y or r.y > inner.y + inner.h: continue
    if row.header:
      ui.textIn($row.group, rect(r.x + 8, r.y, r.w - 16, rowH), colAccent, FontSmall)
      ui.rect(rect(r.x + 8, r.y + rowH - 3, r.w - 16, 1), colBorder)
      continue
    let act = row.act
    let sel = act == d.keySel and cur >= 0
    let capturing = sel and d.capturing
    let hov = ui.hover(r)
    if sel: ui.rect(r, if listFocused or capturing: colAccent else: colPanelRaised)
    elif hov: ui.rect(r, colHover)
    let fg = if sel and (listFocused or capturing): colOnAccent else: colText
    let changed = not c.isDefault(act)
    ui.textIn(ui.ellipsize(Actions[act].label, r.w - keyW - 40),
      rect(r.x + 20, r.y, r.w - keyW - 28, rowH), fg)
    let kr = rect(r.x + r.w - keyW - 6, r.y + 2, keyW, rowH - 4)
    let key = c.keysText(act)
    if capturing:
      ui.rect(kr, colBackground)
      ui.border(kr, colAccent)
      ui.textIn("Press a key...", rect(kr.x + 8, kr.y, kr.w - 16, kr.h), colTextDim, FontSmall)
    else:
      let kcol =
        if sel and (listFocused or capturing): colOnAccent
        elif key.len == 0: colTextDisabled
        elif changed: colAccent
        else: colTextDim
      ui.textIn((if changed: "• " else: "") & (if key.len > 0: key else: "None"),
        rect(kr.x + 8, kr.y, kr.w - 16, kr.h), kcol, FontSmall)
      if ui.hover(kr): ui.tip(kr, "Click to change")
    if hov and ui.pressed():
      ui.consumeClick()
      ui.navId = "o-keys-list"
      ui.focusId = ""
      # Clicking the key, or double-clicking the row, asks for a new key.
      if ui.hover(kr) or (sel and w.buttonPressed[DoubleClick]): d.startCapture(ui, act)
      else: d.keySel = act
  if rows.len == 0:
    ui.textIn("No matching commands", inner, colTextDim, FontSmall, h = CenterAlign)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  p.y = list.y + list.h + 8

  let has = cur >= 0
  const bw = 110'f32
  let by = p.y
  proc at(i: int): Rect = rect(list.x + i.float32 * (bw + 8), by, bw, 28)
  if ui.button("o-keyset", "Change...", at(0), has): d.startCapture(ui, d.keySel)
  if ui.button("o-keyclear", "Clear", at(1), has and c.combos(d.keySel).len > 0):
    d.assignKeys(c, d.keySel, @[])
  if ui.button("o-keyreset", "Default", at(2), has and not c.isDefault(d.keySel)):
    d.assignKeys(c, d.keySel, d.keySel.defaults)
  let allR = rect(p.x + p.w - 150, p.y, 150, 28)
  if c.keys.len > 0:
    if ui.textButton("o-keyresetall", allR, "Reset all keys"):
      c.keys.clear()
      d.keyNote = "All keys are back to their defaults."
  else:
    ui.rect(allR, colPanelRaised)
    ui.border(allR, colBorder)
    ui.textIn("Reset all keys", allR, colTextDisabled, h = CenterAlign)
  p.y += 34
  let note =
    if d.capturing: "Press a key for \"" & Actions[d.keySel].label & "\"; Esc cancels."
    elif d.keyNote.len > 0: d.keyNote
    else: "Click a key to change it. A key given to another command is taken from it."
  ui.textIn(ui.ellipsize(note, p.w - 8, FontSmall), rect(p.x + 8, p.y, p.w - 8, 18),
    if d.capturing: colAccent else: colTextDim, FontSmall)
  p.y += 18

proc playbackPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Display")
  ui.checkRow(p, "o-awake", "Keep the monitor on while playing video", c.keepDisplayOn)
  ui.hint(p, "Stops the system from blanking or turning off the screen during video playback.")
  ui.group(p, "Track preference")
  ui.textRow(p, "o-slang", "Subtitles", c.subLangs, "e.g. eng, jpn")
  ui.textRow(p, "o-alang", "Audio", c.audioLangs, "e.g. jpn, eng")
  ui.hint(p, "Language codes in order of preference; the first matching track is picked on open.")
  ui.group(p, "Online media")
  ui.textRow(p, "o-cookies", "Sign in with", c.signInCookies, "auto")
  ui.hint(p, "Browser whose cookies yt-dlp uses when a video asks to sign in (age-restricted).")
  ui.hint(p, "auto tries each installed browser; none turns it off; or brave, chrome, firefox...")
  ui.group(p, "Seek bar")
  ui.checkRow(p, "o-prev", "Show thumbnail preview on hover", c.seekPreview)
  ui.checkRow(p, "o-snap", "Hold Shift to snap to chapters", c.snapWithShift)
  ui.hint(p, if c.snapWithShift: "Seeking snaps to chapters only while Shift is held."
             else: "Seeking snaps to chapters; hold Shift to seek freely.")
  ui.checkRow(p, "o-bmch", "Bookmarks as chapters", c.bookmarksAsChapters)
  ui.hint(p, "Next/previous chapter also stops at bookmarks.")
  ui.group(p, "Steps")
  ui.numberRow(p, "o-rate", "Playback rate", c.rateStep, 0.05, 0.05, 2, 2)
  ui.numberRow(p, "o-jump", "Jump (seconds)", c.seekStep, 1, 1, 600)
  ui.numberRow(p, "o-vol", "Volume", c.volumeStep, 0.5, 0.5, 50, 1)

proc webPage(d: OptionsDialog, ui: Ui, c: var Config, p: var Pane, bottom: float32) =
  let web = d.web
  ui.group(p, "Cache folder")
  const bw = 96'f32
  const lw = 110'f32            # narrower labels: the folder field has two buttons
  ui.textIn("Space taken", rect(p.x + 8, p.y, lw, 26), colText)
  proc pct(part, whole: float): string =
    let v = 100 * part / whole
    if v < 10: formatFloat(v, ffDecimal, 1) & "%" else: $int(round(v)) & "%"
  var usage = fmtBytes(web.used.float)
  if c.webSizeOn: usage.add "  (" & pct(web.used.float, float(c.webSizeGB.int64 shl 30)) &
    &" of {c.webSizeGB} GiB)"
  elif web.total > 0: usage.add "  (" & pct(web.used.float, web.total.float) & " of the disk)"
  if web.free >= 0: usage.add "  " & fmtBytes(web.free.float) & " free"
  let uw = p.w - lw - 8 - 128
  ui.textIn(ui.ellipsize(usage, uw), rect(p.x + 8 + lw, p.y, uw, 26), colTextDim)
  let clearR = rect(p.x + p.w - 120, p.y, 120, 26)
  if d.confirmClear:
    if ui.textButton("o-webclear-yes", clearR, "Really clear?", primary = true):
      d.confirmClear = false
      d.request = prClearWeb
    elif ui.pressed() and not ui.hover(clearR): d.confirmClear = false
  elif ui.button("o-webclear", "Clear cache", clearR, web.items.len > 0 or web.used > 0):
    d.confirmClear = true
  p.y += Row + 4
  ui.textIn("Folder", rect(p.x + 8, p.y, lw, 26), colText)
  let fw = max(120'f32, p.w - lw - 8 - 2 * (bw + 8))
  discard ui.textField("o-webdir", rect(p.x + 8 + lw, p.y, fw, 26), c.webDir,
    defaultSaveDir())
  if ui.textButton("o-webdir-browse", rect(p.x + 16 + lw + fw, p.y, bw, 26), "Browse..."):
    d.request = prBrowseWeb
  if ui.textButton("o-webdir-open", rect(p.x + 24 + lw + fw + bw, p.y, bw, 26), "Open"):
    d.request = prOpenWebDir
  p.y += Row + 4
  ui.hint(p, "Online media is cached here as it streams, and plays from disk when opened again.")
  if c.webDir.expandPath notin ["", web.dir]:
    ui.textIn("Applied on OK; what's cached in the current folder stays there.",
      rect(p.x + 8, p.y - 2, p.w - 8, 18), colAccent, FontSmall)
    p.y += 20

  ui.group(p, "Cached media")
  # Checked items still cached; the list may have changed since.
  var picked: seq[string]
  for it in web.items:
    if it.url in d.webPicked: picked.add it.url
  d.webPicked = picked
  if ui.button("o-webdel", "Delete selected", rect(p.x + 8, p.y, 140, 28), picked.len > 0):
    d.request = prDeleteWeb
  if ui.textButton("o-webshow", rect(p.x + 156, p.y, 190, 28), "Open containing folder"):
    d.request = prOpenWebDir
  let count = &"{web.items.len} item(s)" & (if picked.len > 0: &", {picked.len} selected" else: "")
  ui.textIn(count, rect(p.x + 354, p.y, p.w - 354, 28), colTextDim, FontSmall, h = RightAlign)
  p.y += 36

  const rowH = 24'f32
  const sizeW = 76'f32
  const savedW = 140'f32
  const dateW = 120'f32
  const autoH = 32'f32 + 3 * (Row + 4) + 20  # Delete automatically, below the list
  let list = rect(p.x + 8, p.y, p.w - 8, max(160'f32, bottom - p.y - 8 - autoH))
  ui.rect(list, colBackground)
  ui.border(list, colBorder)
  # Header: a box checking every item, and the columns' names.
  let head = rect(list.x + 1, list.y + 1, list.w - 2, rowH)
  let titleW = head.w - 32 - savedW - sizeW - dateW
  var all = web.items.len > 0 and picked.len == web.items.len
  if ui.checkbox("o-weball", vec2(head.x + 8, head.y + 1), "", all):
    d.webPicked = @[]
    if all:
      for it in web.items: d.webPicked.add it.url
  var x = head.x + 32
  for (name, cw) in [("Title", titleW), ("Saved", savedW), ("Size", sizeW), ("Last opened", dateW)]:
    ui.textIn(name, rect(x, head.y, cw - 8, rowH), colTextDim, FontSmall)
    x += cw
  ui.rect(rect(head.x, head.y + rowH, head.w, 1), colBorder)

  let inner = rect(list.x + 1, head.y + rowH + 1, list.w - 2, list.h - rowH - 3)
  let maxScroll = max(0'f32, web.items.len.float32 * rowH - inner.h)
  if ui.hover(inner) and ui.scroll() != 0:
    d.webScroll += ui.scroll() * rowH / 3
    ui.scrollConsumed = true
  d.webScroll = clamp(d.webScroll, 0, maxScroll)
  let outerClip = ui.hitClip
  ui.hitClip = inner
  ui.sk.pushClipRect(inner)
  for n, it in web.items:
    let row = rect(inner.x, inner.y + n.float32 * rowH - d.webScroll, inner.w, rowH)
    if row.y + rowH < inner.y or row.y > inner.y + inner.h: continue
    let on = it.url in d.webPicked
    let hov = ui.hover(row)
    if hov: ui.rect(row, colHover)
    let box = rect(row.x + 8, row.y + 4, 16, 16)
    ui.rect(box, if on: colAccent else: colPanelRaised)
    ui.border(box, if hov: colAccent else: colBorder)
    if on: ui.icon("check16", box.xy + box.wh / 2, colOnAccent)
    var x = row.x + 32
    let title = if it.title.len > 0: it.title else: it.url
    let tr = rect(x, row.y, titleW - 8, rowH)
    ui.textIn(ui.ellipsize(title, tr.w), tr, colText)
    if ui.hover(tr): ui.tip(tr, it.url)
    x += titleW
    let saved =
      if it.duration > 0 and it.saved >= it.duration - 1: "Complete"
      elif it.duration > 0: fmtTime(it.saved, dur = it.duration) & " / " & fmtTime(it.duration)
      else: fmtTime(it.saved)
    ui.textIn(saved, rect(x, row.y, savedW - 8, rowH), colTextDim, FontSmall)
    x += savedW
    ui.textIn(fmtBytes(it.bytes.float), rect(x, row.y, sizeW - 8, rowH), colTextDim, FontSmall)
    x += sizeW
    let date = if it.used > 0: fromUnix(int64(it.used)).local.format("yyyy-MM-dd HH:mm") else: ""
    ui.textIn(date, rect(x, row.y, dateW - 8, rowH), colTextDim, FontSmall)
    if hov and ui.pressed():
      ui.pressId = "o-web" & $n
      ui.consumeClick()
    if hov and ui.window.buttonReleased[MouseLeft] and ui.pressId == "o-web" & $n:
      if on: d.webPicked.delete(d.webPicked.find(it.url))
      else: d.webPicked.add it.url
  if web.items.len == 0:
    ui.textIn("Nothing cached", inner, colTextDim, FontSmall, h = CenterAlign)
  ui.sk.popClipRect()
  ui.hitClip = outerClip
  p.y = list.y + list.h + 8

  ui.group(p, "Delete automatically")
  ui.toggleNumberRow(p, "o-webkeep", "Delete after (hours)", c.webKeepOn, c.webKeepHours, 1, 1, 87600)
  ui.toggleNumberRow(p, "o-webcount", "Keep at most (items)", c.webCountOn, c.webCount, 1, 1, 10000)
  ui.toggleNumberRow(p, "o-websize", "Max. disk space (GiB)", c.webSizeOn, c.webSizeGB, 1, 1, 100000)
  ui.hint(p, "Checked on OK, at start and as media is cached; the least recently opened go first.")

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

proc systemPage(ui: Ui, c: var Config, p: var Pane) =
  ui.group(p, "Memory")
  var mb = c.loopFramesMB.float
  ui.numberRow(p, "o-lfmem", "Loop frames (MB)", mb, 64, 64, LoopFramesMaxMB.float)
  c.loopFramesMB = clamp(int(round(mb)), 64, LoopFramesMaxMB)
  ui.hint(p, "Video memory for short A-B loops' frames, which keep them moving.")
  ui.hint(p, &"Loops needing more play the plain way, often frozen. At most {LoopFramesMaxMB} MB.")

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
  of opInterface: interfacePage(ui, c, p)
  of opFormats: d.formatsPage(ui, p, pageR.y + pageR.h)
  of opPaths: d.pathsPage(ui, c, p)
  of opKeys: d.keysPage(ui, c, p, pageR.y + pageR.h)
  of opPlayback: playbackPage(ui, c, p)
  of opWeb: d.webPage(ui, c, p, pageR.y + pageR.h)
  of opSubtitles: subtitlesPage(ui, c, p)
  of opMisc: miscPage(ui, c, p)
  of opSystem: systemPage(ui, c, p)
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
  # A Tab that was just bound to a command doesn't move the focus too.
  let i = if d.keyTaken: -1 else: ui.tabNavigate()
  if i >= pageStops and i < pageStopsEnd:
    let sr = ui.tabStops[i].r
    if sr.y < pageR.y: d.scroll -= pageR.y - sr.y + 4
    elif sr.y + sr.h > pageR.y + pageR.h: d.scroll += sr.y + sr.h - pageR.y - pageR.h + 4
    d.scroll = clamp(d.scroll, 0, maxScroll)
