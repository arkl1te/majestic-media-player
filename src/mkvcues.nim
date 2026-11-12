## Seek entries for the sound of Matroska files saved from streams (websave,
## written by FFmpeg through mpv's dump-cache). FFmpeg's Cues list a file's
## video keyframes only. With the video track off (a quick cover or the
## visualizer showing, Video Track None), mpv seeks by the sound's entries,
## and finding none but the one it keeps for the file's start, it goes back
## to the start at every seek and decodes all the sound from there: the
## further in, the longer each seek takes (10 minutes in: half a second, an
## hour: seconds). indexAudio adds an entry for each cluster for every audio
## track the Cues leave out. Only the Cues change: FFmpeg writes them last,
## so the new ones take their place and the Segment's size grows to match.

import std/[algorithm, tables]

type
  CueFix* = enum
    cfLeft     ## left as it is: unfinished (mpv still writing it), not laid
               ## out as FFmpeg does it, or unreadable
    cfFine     ## its sound had entries already
    cfIndexed  ## entries for its sound added now

  Head = object
    id: uint32
    size: int64               ## -1: unknown
    at, data: int64           ## where the element starts, and its data
    sizeLen: int

  Src = object
    f: File
    size: int64
    buf: string
    bufAt: int64

  Track = object
    number: uint64
    kind: uint64              ## TrackType: 1 video, 2 audio

const
  IdSegment = 0x18538067'u32
  IdSeekHead = 0x114D9B74'u32
  IdSeek = 0x4DBB'u32
  IdSeekId = 0x53AB'u32
  IdSeekPosition = 0x53AC'u32
  IdTracks = 0x1654AE6B'u32
  IdTrackEntry = 0xAE'u32
  IdTrackNumber = 0xD7'u32
  IdTrackType = 0x83'u32
  IdCluster = 0x1F43B675'u32
  IdTimestamp = 0xE7'u32
  IdSimpleBlock = 0xA3'u32
  IdBlockGroup = 0xA0'u32
  IdBlock = 0xA1'u32
  IdCues = 0x1C53BB6B'u32
  IdCuePoint = 0xBB'u32
  IdCueTime = 0xB3'u32
  IdCueTrackPositions = 0xB7'u32
  IdCueTrack = 0xF7'u32
  IdCueClusterPosition = 0xF1'u32
  IdEbml = 0x1A45DFA3'u32
  IdVoid = 0xEC'u32
  TrackAudio = 2'u64
  Window = 4096

# --- reading -----------------------------------------------------------------

proc byteAt(s: var Src, p: int64): int =
  ## The byte at p, -1 past the end.
  if p < 0 or p >= s.size: return -1
  if p < s.bufAt or p >= s.bufAt + s.buf.len:
    s.buf.setLen Window
    s.f.setFilePos(p)
    s.buf.setLen s.f.readBuffer(s.buf[0].addr, Window)
    s.bufAt = p
    if s.buf.len == 0: return -1
  s.buf[int(p - s.bufAt)].int

proc head(s: var Src, p: int64, h: var Head): bool =
  ## The element header at p.
  let b0 = s.byteAt(p)
  if b0 <= 0: return false
  var idLen = 1
  while idLen <= 4 and (b0 and (0x80 shr (idLen - 1))) == 0: inc idLen
  if idLen > 4: return false
  var id = uint32(b0)
  for k in 1 ..< idLen:
    let b = s.byteAt(p + k)
    if b < 0: return false
    id = id shl 8 or uint32(b)
  let q = p + idLen
  let c0 = s.byteAt(q)
  if c0 <= 0: return false
  var n = 1
  while (c0 and (0x80 shr (n - 1))) == 0: inc n
  var v = uint64(c0 and (0xFF shr n))
  var ones = v == uint64(0xFF shr n)
  for k in 1 ..< n:
    let b = s.byteAt(q + k)
    if b < 0: return false
    v = v shl 8 or uint64(b)
    if b != 0xFF: ones = false
  h = Head(id: id, size: (if ones: -1'i64 else: int64(v)), at: p, data: q + n, sizeLen: n)
  true

proc ends(h: Head): int64 = h.data + h.size

proc uintAt(s: var Src, h: Head): uint64 =
  for k in 0'i64 ..< min(h.size, 8'i64):
    result = result shl 8 or uint64(max(s.byteAt(h.data + k), 0))

proc rawAt(s: var Src, p, n: int64): string =
  for k in 0 ..< n: result.add char(max(s.byteAt(p + k), 0))

iterator children(s: var Src, parent: Head, ok: var bool): Head =
  ## The elements in parent; ok turns false at one that can't be read or
  ## runs past it.
  var p = parent.data
  while ok and p < parent.ends:
    var h: Head
    if not s.head(p, h) or h.size < 0 or h.ends > parent.ends:
      ok = false
      break
    yield h
    p = h.ends

# --- writing -----------------------------------------------------------------

proc vint(v: uint64, len = 0): string =
  ## v as an element size, in `len` bytes (0: as few as it takes).
  var n = 1
  while n < 8 and v >= (1'u64 shl (7 * n)) - 1: inc n
  n = max(n, len)
  let x = v or (1'u64 shl (7 * n))
  for k in countdown(n - 1, 0): result.add char((x shr (8 * k)) and 0xFF)

proc idBytes(id: uint32): string =
  var started = false
  for k in countdown(3, 0):
    let b = (id shr (8 * k)) and 0xFF
    if b != 0 or started:
      result.add char(b)
      started = true

proc uintBytes(v: uint64): string =
  var n = 1
  while n < 8 and v shr (8 * n) != 0: inc n
  for k in countdown(n - 1, 0): result.add char((v shr (8 * k)) and 0xFF)

proc element(id: uint32, data: string, sizeLen = 0): string =
  idBytes(id) & vint(data.len.uint64, sizeLen) & data

proc voidOf(n: int): string =
  ## A Void element n bytes long (n >= 2).
  for len in 1 .. 8:
    let data = n - 1 - len
    if data >= 0 and data.uint64 < (1'u64 shl (7 * len)) - 1:
      return idBytes(IdVoid) & vint(data.uint64, len) & newString(data)

# --- the file ------------------------------------------------------------------

proc indexAudio*(file: string): CueFix =
  ## Adds seek entries to the Cues of the Matroska file for every audio track
  ## they leave out (see the module's doc). Only a file finished and laid out
  ## as FFmpeg writes it (Cues last, found from the SeekHead) is changed.
  var s: Src
  if not s.f.open(file, fmRead): return cfLeft
  var segSizeAt, segData, cuesAt, cuesEnd: int64
  var segSizeLen: int
  var points: seq[tuple[time: uint64, parts: seq[string]]]
  var missing: seq[uint64]
  var clusters: seq[Head]
  try:
    s.size = s.f.getFileSize
    var h: Head
    if not s.head(0, h) or h.id != IdEbml or h.size < 0: return cfLeft
    var seg: Head
    # A size still unknown: mpv is writing it (FFmpeg sets it last).
    if not s.head(h.ends, seg) or seg.id != IdSegment or seg.size < 0 or
       seg.ends > s.size: return cfLeft
    (segSizeAt, segSizeLen, segData) = (seg.data - seg.sizeLen, seg.sizeLen, seg.data)
    # The SeekHead comes first: where the Cues and Tracks are.
    var sh: Head
    if not s.head(seg.data, sh) or sh.id != IdSeekHead or sh.size < 0: return cfLeft
    var ok = true
    var tracksAt = -1'i64
    cuesAt = -1
    for e in s.children(sh, ok):
      if e.id != IdSeek: continue
      var id = 0'u32
      var pos = -1'i64
      for f in s.children(e, ok):
        if f.id == IdSeekId and f.size in 1'i64 .. 4'i64: id = uint32(s.uintAt(f))
        elif f.id == IdSeekPosition: pos = int64(s.uintAt(f))
      if id == IdCues: cuesAt = seg.data + pos
      elif id == IdTracks: tracksAt = seg.data + pos
    if not ok or cuesAt < 0 or tracksAt < 0: return cfLeft
    var tracks: seq[Track]
    var th: Head
    if not s.head(tracksAt, th) or th.id != IdTracks or th.size < 0: return cfLeft
    for e in s.children(th, ok):
      if e.id != IdTrackEntry: continue
      var t: Track
      for f in s.children(e, ok):
        if f.id == IdTrackNumber: t.number = s.uintAt(f)
        elif f.id == IdTrackType: t.kind = s.uintAt(f)
      tracks.add t
    var ch: Head
    if not ok or not s.head(cuesAt, ch) or ch.id != IdCues or ch.size < 0 or
       ch.ends > s.size: return cfLeft
    cuesEnd = ch.ends
    var cued: seq[uint64]
    for e in s.children(ch, ok):
      if e.id != IdCuePoint: continue  # its CRC-32 (no longer right) and Voids go
      var time = 0'u64
      var parts: seq[string]
      for f in s.children(e, ok):
        if f.id == IdCueTime: time = s.uintAt(f)
        else:
          parts.add s.rawAt(f.at, f.ends - f.at)
          if f.id == IdCueTrackPositions:
            for g in s.children(f, ok):
              if g.id == IdCueTrack: cued.add s.uintAt(g)
      points.add (time, parts)
    if not ok: return cfLeft
    for t in tracks:
      if t.kind == TrackAudio and t.number notin cued: missing.add t.number
    if missing.len == 0: return cfFine
    # Cues last: they can grow there. The clusters, from the start up to them.
    if cuesEnd != s.size or seg.ends != s.size: return cfLeft
    var p = seg.data
    while p < cuesAt:
      var e: Head
      if not s.head(p, e) or e.size < 0 or e.ends > cuesAt: return cfLeft
      if e.id == IdCluster: clusters.add e
      p = e.ends
    if p != cuesAt: return cfLeft
    # Each cluster's first block of each such track: an entry at its time.
    var at: Table[uint64, int]
    for i, pt in points: at[pt.time] = i
    for c in clusters:
      var tc = 0'u64
      var found: seq[uint64]
      for e in s.children(c, ok):
        var blocks: seq[Head]
        if e.id == IdTimestamp: tc = s.uintAt(e)
        elif e.id == IdSimpleBlock: blocks.add e
        elif e.id == IdBlockGroup:
          for f in s.children(e, ok):
            if f.id == IdBlock: blocks.add f
        for b in blocks:
          # The block's track number (a size-like number), then its time
          # from the cluster's, signed 16 bits.
          let b0 = s.byteAt(b.data)
          if b0 <= 0: continue
          var n = 1
          while (b0 and (0x80 shr (n - 1))) == 0: inc n
          var track = uint64(b0 and (0xFF shr n))
          for k in 1 ..< n: track = track shl 8 or uint64(max(s.byteAt(b.data + k), 0))
          if track notin missing or track in found: continue
          found.add track
          let rel = cast[int16](uint16(max(s.byteAt(b.data + n), 0)) shl 8 or
                               uint16(max(s.byteAt(b.data + n + 1), 0)))
          let time = uint64(max(int64(tc) + rel, 0))
          let part = element(IdCueTrackPositions,
            element(IdCueTrack, uintBytes(track)) &
            element(IdCueClusterPosition, uintBytes(uint64(c.at - seg.data))))
          if time notin at:
            at[time] = points.len
            points.add (time, newSeq[string]())
          points[at[time]].parts.add part
        if found.len == missing.len: break
      if not ok: return cfLeft
  except IOError, OSError: return cfLeft
  finally: s.f.close()
  points.sort(proc (a, b: typeof(points[0])): int = cmp(a.time, b.time))
  var data = ""
  for pt in points:
    var body = element(IdCueTime, uintBytes(pt.time))
    for part in pt.parts: body.add part
    data.add element(IdCuePoint, body)
  var cues = element(IdCues, data)
  # Fewer bytes than before (it held Voids): a Void fills up to the old end.
  var fill = cuesEnd - (cuesAt + cues.len)
  if fill == 1:
    cues = element(IdCues, data, vint(data.len.uint64).len + 1)
    fill = 0
  if fill > 0: cues.add voidOf(fill.int)
  let segSize = uint64(cuesAt + cues.len - segData)
  if segSize >= (1'u64 shl (7 * segSizeLen)) - 1: return cfLeft
  var f: File
  if not f.open(file, fmReadWriteExisting): return cfLeft
  try:
    f.setFilePos(cuesAt)
    f.write cues
    f.setFilePos(segSizeAt)
    f.write vint(segSize, segSizeLen)
    f.flushFile()
    result = cfIndexed
  except IOError, OSError: result = cfLeft
  finally: f.close()
