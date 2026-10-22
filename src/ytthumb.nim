## A YouTube video's thumbnail, shown in the video frame while no video track
## is (the right-click menu's "Show Thumbnail When Video Is Off"): fetched with curl into the
## cache folder once per video, then read from there.

import std/[os, osproc]
import pixie

const Sizes = ["maxresdefault", "hqdefault"]  ## tried in turn: not every video has the first

type
  ThumbJob* = ref object
    id*: string               ## the video's
    p: Process                ## nil once finished
    size: int                 ## index into Sizes being fetched
    image*: Image             ## once read; nil until then, or when it failed
    failed*: bool

proc thumbPath(id: string): string =
  getCacheDir("majestic-media-player") / "thumbnails" / id & ".jpg"

proc running*(j: ThumbJob): bool = j != nil and j.p != nil

proc read(j: ThumbJob): bool =
  try:
    j.image = readImage(thumbPath(j.id))
    true
  except CatchableError:
    false

proc fetch(j: ThumbJob) =
  let path = thumbPath(j.id)
  try:
    createDir(path.parentDir)
    j.p = startProcess("curl", args = ["-fsL", "--max-time", "15", "-o", path & ".part",
      "https://i.ytimg.com/vi/" & j.id & "/" & Sizes[j.size] & ".jpg"],
      options = {poUsePath, poStdErrToStdOut, poDaemon})
  except OSError:
    j.failed = true

proc fetchThumbnail*(id: string): ThumbJob =
  ## The thumbnail of the video with that id: read at once when fetched
  ## before, else being fetched (poll).
  result = ThumbJob(id: id)
  if fileExists(thumbPath(id)) and result.read: return
  result.fetch()

proc poll*(j: ThumbJob): bool =
  ## True when the fetch just finished, the image read or failed.
  if not j.running or j.p.running: return false
  let code = j.p.peekExitCode
  j.p.close()
  j.p = nil
  let path = thumbPath(j.id)
  if code == 0:
    try: moveFile(path & ".part", path)
    except OSError: discard
    if j.read: return true
  discard tryRemoveFile(path & ".part")
  inc j.size
  if j.size < Sizes.len: j.fetch()
  else: j.failed = true
  not j.running

proc cancel*(j: ThumbJob) =
  if not j.running: return
  try: j.p.terminate(); j.p.close()
  except OSError: discard
  j.p = nil
  discard tryRemoveFile(thumbPath(j.id) & ".part")
