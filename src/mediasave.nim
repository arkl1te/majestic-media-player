## File > Save: the media playing, saved whole to a file the user picks. A
## file on disk (or a link the media cache holds all of) is copied a piece at
## a time, playing going on meanwhile; any other link is downloaded with
## yt-dlp, as its hook streams it (best video and audio, in an .mkv or .mp4
## with its subtitles and chapters).

import std/[os, strutils, times]
import ytdlp

type
  SaveJob* = ref object
    dest*: string             ## the file it makes
    error*: string            ## why it failed; "" while it hasn't
    done*: bool               ## finished, well or not
    src, part: string         ## copying: from where, and the file being written
    fin, fout: File
    size, copied: int64
    dl: YtJob                 ## downloading
    started: Time

const
  Chunk = 1 shl 20
  PollBudget = 0.008          ## seconds a poll may spend copying

proc safeName*(title: string): string =
  ## title as a file name: characters no file system takes go.
  for c in title:
    result.add(if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|'} or c < ' ': '_' else: c)
  result = result.strip(chars = {' ', '.'})
  if result.len == 0: result = "media"

proc fail(j: SaveJob, msg: string) =
  if j.fin != nil: j.fin.close()
  if j.fout != nil: j.fout.close()
  j.fin = nil
  j.fout = nil
  if j.part.len > 0:
    try: removeFile(j.part)
    except OSError: discard
  j.error = msg
  j.done = true

proc copying*(src, dest: string): SaveJob =
  ## Copies src to dest, written as dest.part until all of it is.
  result = SaveJob(src: src, dest: dest, part: dest & ".part")
  if src.absolutePath == dest.absolutePath or
     fileExists(dest) and (try: sameFile(src, dest) except OSError: false):
    result.fail("it's the file itself")
    return
  try:
    result.size = getFileSize(src)
    createDir(dest.parentDir)
  except OSError as e:
    result.fail(e.msg)
    return
  if not open(result.fin, src, fmRead):
    result.fail("cannot read " & src.extractFilename)
  elif not open(result.fout, result.part, fmWrite):
    result.fail("cannot write " & dest.extractFilename)

proc downloading*(exe, url, dest: string, cookies = ""): SaveJob =
  ## Downloads url with yt-dlp; dest's extension (.mp4, else .mkv) picks the
  ## container, and dest becomes the file it makes.
  let ext = if dest.splitFile.ext.toLowerAscii == ".mp4": "mp4" else: "mkv"
  let (dir, name, _) = dest.splitFile
  result = SaveJob(dest: dir / name & "." & ext, started: getTime())
  try: createDir(dir)
  except OSError as e:
    result.fail(e.msg)
    return
  result.dl = download(exe, url, dir, name.replace("%", "%%") & ".%(ext)s", ext, cookies)

proc running*(j: SaveJob): bool = j != nil and not j.done

proc progress*(j: SaveJob): float =
  ## Percent done; -1 while unknown.
  if j.dl != nil: j.dl.progress
  elif j.size > 0: j.copied.float * 100 / j.size.float
  else: -1

proc bytes*(j: SaveJob): tuple[done, total: int64] =
  ## Bytes saved, of how many (0: unknown).
  if j.dl != nil: (j.dl.bytes, j.dl.total) else: (j.copied, j.size)

proc stage*(j: SaveJob): tuple[step, steps: int] =
  ## Downloading video and audio apart, then merging them: which of those
  ## it's on; steps 0 otherwise.
  if j.dl != nil and j.dl.steps > 0: (clamp(j.dl.step, 1, j.dl.steps), j.dl.steps)
  else: (0, 0)

proc poll*(j: SaveJob): bool =
  ## Copies on or reads yt-dlp's progress. True when anything changed.
  if not j.running: return
  if j.dl != nil:
    result = j.dl.poll()
    if not j.dl.running:
      if j.dl.code == 0 and fileExists(j.dest): j.done = true
      elif j.dl.code == 0: j.fail("yt-dlp made no " & j.dest.extractFilename)
      else: j.fail(j.dl.errorText)
    return
  var buf = newSeq[byte](Chunk)
  let start = epochTime()
  while epochTime() - start < PollBudget:
    let n = try: j.fin.readBuffer(buf[0].addr, Chunk) except IOError: -1
    if n < 0:
      j.fail("cannot read " & j.src.extractFilename)
      return true
    if n > 0 and (try: j.fout.writeBuffer(buf[0].addr, n) != n except IOError: true):
      j.fail("cannot write " & j.dest.extractFilename & " (disk full?)")
      return true
    j.copied += n
    result = true
    if n < Chunk:  # the end
      j.fin.close()
      j.fout.close()
      j.fin = nil
      j.fout = nil
      try: moveFile(j.part, j.dest)
      except OSError as e:
        j.fail(e.msg)
        return
      j.done = true
      return

proc cancel*(j: SaveJob) =
  if not j.running: return
  if j.dl != nil:
    j.dl.stop()
    # What it left: the streams it downloads apart (name.f<format>.<ext>,
    # .part while downloading) and the merge (name.temp.<ext>).
    let (dir, name, _) = j.dest.splitFile
    try:
      for kind, f in walkDir(dir):
        let n = f.extractFilename
        if kind != pcFile or not n.startsWith(name & "."): continue
        let rest = n[name.len + 1 .. ^1]
        if (rest.startsWith("f") or rest.startsWith("temp.")) and
           getLastModificationTime(f) >= j.started: removeFile(f)
    except OSError: discard
  j.fail("cancelled")
