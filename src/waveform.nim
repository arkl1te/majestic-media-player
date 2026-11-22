## The seek bar's waveform (its menu's Waveform): the sound playing, decoded
## on a thread of its own into the highest sample and the RMS of each
## bucket, a 1/Buckets slice of its length (1 ms at least). The sound comes
## from ffmpeg as a float WAV on a pipe, as ReplayGain scanning's does
## (rgscan), or for a MIDI file from FluidSynth with the SoundFont it plays
## with. The main thread takes in what's done (poll), so the waveform fills
## from the left as it's decoded.
##
## A link's is made of the files its stream was saved in as it played
## (websave), a stretch at a time (more), each landing where it is on the seek
## bar (`at`): buckets not decoded stay below 0. The file still being written
## is followed as it grows (ffmpeg's -follow), until stopped or no more comes
## for FollowWait.
##
## One worker for every request, started with the first and never ended,
## for the reason rgscan gives: what it allocates goes back to its own heap.
## A new request makes the one running stale: its ffmpeg is killed, and a
## render stops at its next read.

import std/[osproc, streams, math, locks, strutils, sequtils, algorithm]
import midistream

const
  Buckets* = 32768
  FollowWait* = 20.0       ## seconds a followed file may stay as it is before decoding ends

type
  WaveSource* = object
    file*: string          ## decoded from; "" = nothing to decode
    stream*: int           ## its audio stream, counting audio streams only
    start*, length*: float ## the stretch of it, seconds (a cue track); length 0: to its end
    at*: float             ## where that stretch starts on the seek bar, seconds
    follow*: bool          ## still being written: read on as it grows
    font*: string          ## a MIDI file's SoundFont: rendered by FluidSynth, not ffmpeg
    duration*: float       ## the seek bar's length, which sets the buckets' length

  Wave* = ref object
    src*: WaveSource
    bucket*: float         ## seconds each bucket holds
    peak*, rms*: seq[float32]  ## per bucket from the start, 1.0 full scale;
                           ## below 0 where nothing is decoded
    filled*: int           ## buckets decoded
    top*: float32          ## the highest peak taken in
    covered*: seq[(float, float)]  ## the stretches decoded, seek bar seconds, in order
    reach*: float          ## how far src's stretch is decoded (from src.at)
    done*: bool            ## src decoded to the end, failed, or replaced
    parts*: bool           ## a link's: made of its saved files, a stretch at a time (more)
    error*: string         ## why it failed; "" when it didn't
    gen: int

  Shared = object
    lock: Lock
    cond: Cond
    job: WaveSource
    bucket: float
    gen: int               ## the latest request's
    pending: bool          ## the worker has yet to take it
    peak, rms: seq[float32]  ## decoded, for poll to take in; grown by the
                           ## worker only, emptied (never freed) by poll
    runs: seq[(int, int)]  ## where in them each run starts, and its first bucket
    reach: float           ## how far decoded, seek bar seconds
    done: bool
    error: string
    ffmpeg: Process        ## decoding the latest request, to kill when it goes stale

  Reader = object
    o: Stream              ## ffmpeg's stdout, when not a render
    render: pointer        ## midistream's, for a MIDI file

var
  sh: Shared
  worker: Thread[void]
  inited: bool

proc read(r: Reader, dst: pointer, n: int): int =
  {.cast(gcsafe).}:
    result = if r.render != nil: renderRead(r.render, dst, n) else: r.o.readData(dst, n)

proc readFull(r: Reader, dst: pointer, n: int): int =
  ## n bytes unless the sound ends first (a pipe hands them in pieces).
  while result < n:
    let got = r.read(cast[ptr UncheckedArray[byte]](dst)[result].addr, n - result)
    if got <= 0: break
    result += got

proc u16(s: openArray[byte], i: int): int = s[i].int or s[i + 1].int shl 8
proc u32(s: openArray[byte], i: int): int =
  s[i].int or s[i + 1].int shl 8 or s[i + 2].int shl 16 or s[i + 3].int shl 24
proc fourcc(s: openArray[byte], i: int): string =
  for k in 0 ..< 4: result.add char(s[i + k])

proc publish(gen, first: int, peak, rms: var seq[float32], reach: float): bool =
  ## Hands the buckets made so far over, peak[0] being bucket `first`; false
  ## once the request is stale.
  withLock sh.lock:
    if sh.gen != gen: return false
    if peak.len > 0:
      sh.runs.add (sh.peak.len, first)
      sh.peak.add peak
      sh.rms.add rms
    sh.reach = max(sh.reach, reach)
  peak.setLen 0
  rms.setLen 0
  true

proc scan(r: Reader, bucket, at: float, gen: int): string =
  ## Reads the float WAV r gives into buckets, its start at `at` seconds;
  ## why it couldn't, else "".
  var head: array[12, byte]
  if r.readFull(head[0].addr, 12) != 12 or fourcc(head, 0) != "RIFF":
    return "no sound decoded"
  var (rate, chans) = (0, 0)
  while true:
    var ch: array[8, byte]
    if r.readFull(ch[0].addr, 8) != 8: return "the decoded sound ended early"
    let (id, size) = (fourcc(ch, 0), u32(ch, 4))
    if id == "data": break
    var body = newSeq[byte](size + (size and 1))
    if body.len > 0 and r.readFull(body[0].addr, body.len) != body.len:
      return "the decoded sound ended early"
    if id == "fmt " and size >= 16: (chans, rate) = (u16(body, 2), u32(body, 4))
  if rate <= 0 or chans <= 0: return "no audio format in the decoded sound"
  # The bucket filling, and the frame that ends it.
  var idx = int(at / bucket)
  var edge = (float(idx + 1) * bucket - at) * rate.float
  var first = idx                        # the bucket peak[0] is
  var buf = newSeq[float32](4096 * chans)
  var leftover = 0                       # bytes of a partial frame held in buf
  var (pk, sq, inBucket) = (0'f32, 0.0, 0)
  var frames = 0
  var peak, rms: seq[float32]
  while true:
    let got = r.read(cast[ptr UncheckedArray[byte]](buf[0].addr)[leftover].addr,
                     buf.len * 4 - leftover)
    if got <= 0: break
    let bytes = leftover + got
    let n = bytes div (4 * chans)
    for i in 0 ..< n:
      for c in 0 ..< chans:
        let x = abs(buf[i * chans + c])
        if x > pk: pk = x
        sq += float(x) * float(x)
      inc inBucket
      inc frames
      if frames.float >= edge:
        peak.add pk
        rms.add float32(sqrt(sq / float(inBucket * chans)))
        inc idx
        edge = (float(idx + 1) * bucket - at) * rate.float
        (pk, sq, inBucket) = (0'f32, 0.0, 0)
    leftover = bytes - n * 4 * chans
    if leftover > 0:
      moveMem(buf[0].addr, cast[ptr UncheckedArray[byte]](buf[0].addr)[n * 4 * chans].addr, leftover)
    if peak.len > 0:
      if not publish(gen, first, peak, rms, at + frames / rate): return "replaced"
      first = idx
  if inBucket > 0:
    peak.add pk
    rms.add float32(sqrt(sq / float(inBucket * chans)))
  if not publish(gen, first, peak, rms, at + frames / rate): return "replaced"
  if frames == 0: return "no sound decoded"

proc work(job: WaveSource, bucket: float, gen: int) =
  var err = ""
  if job.font.len > 0:
    var rd: pointer
    {.cast(gcsafe).}: rd = renderOpen(job.file, job.font)
    if rd == nil: err = "FluidSynth can't play it"
    else:
      err = scan(Reader(render: rd), bucket, job.at, gen)
      {.cast(gcsafe).}: renderClose(rd)
  else:
    var args = @["-v", "fatal", "-nostdin"]
    if job.follow:  # at its end, waits for more: rw_timeout ends that
      args.add ["-follow", "1", "-rw_timeout", $int(FollowWait * 1e6)]
    if job.start > 0: args.add ["-ss", formatFloat(job.start, ffDecimal, 6)]
    args.add ["-i", job.file]
    if job.length > 0: args.add ["-t", formatFloat(job.length, ffDecimal, 6)]
    args.add ["-map", "0:a:" & $job.stream, "-vn", "-sn", "-dn",
              "-c:a", "pcm_f32le", "-f", "wav", "-"]
    var p: Process
    try: p = startProcess("ffmpeg", args = args, options = {poUsePath, poDaemon})  # poDaemon: no console window on Windows
    except OSError: err = "ffmpeg can't be run"
    if p != nil:
      var stale = false
      withLock sh.lock:
        if sh.gen == gen: sh.ffmpeg = p
        else: stale = true
      if not stale: err = scan(Reader(o: p.outputStream), bucket, job.at, gen)
      withLock sh.lock:
        if sh.ffmpeg == p: sh.ffmpeg = nil
      if stale or err == "replaced":
        try: p.kill() except OSError: discard
      discard p.waitForExit()
      if err == "no sound decoded":
        let msg = p.errorStream.readAll.strip
        err = if "matches no streams" in msg: "no audio"
              elif msg.len > 0: msg.splitLines[^1]
              else: "ffmpeg can't decode it"
      p.close()
  withLock sh.lock:
    if sh.gen == gen:
      sh.done = true
      sh.error = err

proc workLoop() {.thread.} =
  ## Decodes each request, the latest one only, for as long as the program runs.
  {.cast(gcsafe).}:
    while true:
      var job: WaveSource
      var (bucket, gen) = (0.0, 0)
      withLock sh.lock:
        while not sh.pending: wait(sh.cond, sh.lock)
        sh.pending = false
        (job, bucket, gen) = (sh.job, sh.bucket, sh.gen)
      work(job, bucket, gen)

proc stale() =
  ## Ends the request running (sh.lock held). sh.ffmpeg is left for the
  ## worker to clear: Nim's reference counts aren't thread-safe, so only the
  ## thread that started the Process assigns it. Clearing it here counted it
  ## down on the main thread, whose cycle collector then traced it after the
  ## worker freed it (a crash). It stays a live, unreaped process until the
  ## worker clears it, so killing it twice is harmless.
  inc sh.gen
  sh.pending = false
  if sh.ffmpeg != nil:
    try: sh.ffmpeg.kill() except OSError: discard

proc start(w: Wave, src: WaveSource) =
  ## Has the worker decode src into w, in place of whatever it decodes.
  if not inited:
    initLock sh.lock
    initCond sh.cond
    createThread(worker, workLoop)
    inited = true
  if src.font.len > 0: discard midistream.available()  # FluidSynth's globals, set before the thread uses them
  (w.src, w.reach, w.done, w.error) = (src, src.at, false, "")
  withLock sh.lock:
    stale()
    sh.job = src
    sh.bucket = w.bucket
    sh.peak.setLen 0
    sh.rms.setLen 0
    sh.runs.setLen 0
    sh.reach = src.at
    sh.done = false
    sh.error = ""
    sh.pending = true
    w.gen = sh.gen
    signal(sh.cond)

proc empty*(duration: float): Wave =
  ## A link's waveform as seek bar `duration` seconds long, nothing decoded
  ## yet: more fills it.
  result = Wave(bucket: max(0.001, duration / Buckets), done: true, parts: true)
  result.src.duration = duration
  let n = max(1, int(ceil(duration / result.bucket)))
  result.peak = newSeqWith(n, -1'f32)
  result.rms = newSeqWith(n, -1'f32)

proc request*(src: WaveSource): Wave =
  ## Starts decoding src, in place of whatever was being decoded.
  result = empty(src.duration)
  result.parts = false
  result.start(src)

proc more*(w: Wave, src: WaveSource) =
  ## Decodes another stretch into w (src.at placing it), in place of
  ## whatever was being decoded.
  var src = src
  src.duration = w.src.duration
  w.start(src)

proc cancel*() =
  ## Stops decoding, whatever was asked last.
  if not inited: return
  withLock sh.lock: stale()

proc stop*(w: Wave) =
  ## Stops decoding w, keeping what it has.
  if w == nil or w.done: return
  cancel()
  (w.done, w.error) = (true, "stopped")

proc cover(w: Wave, a, b: float) =
  ## Notes a..b as decoded, joining the stretches it touches.
  if b <= a: return
  var (a, b) = (a, b)
  var keep: seq[(float, float)]
  for s in w.covered:
    if s[1] < a or s[0] > b: keep.add s
    else: (a, b) = (min(a, s[0]), max(b, s[1]))
  keep.add (a, b)
  keep.sort(proc (x, y: (float, float)): int = cmp(x[0], y[0]))
  w.covered = keep

proc poll*(w: Wave): bool =
  ## Takes in the buckets decoded since; true when there were any, or when it
  ## just ended.
  if w == nil or w.done: return
  withLock sh.lock:
    if sh.gen != w.gen:
      w.done = true
      w.error = "replaced"
      return true
    for r, (at, first) in sh.runs:
      let upTo = if r + 1 < sh.runs.len: sh.runs[r + 1][0] else: sh.peak.len
      for k in at ..< upTo:
        let i = first + k - at
        if i < 0 or i >= w.peak.len: continue
        # A bucket two stretches share gets the most of either.
        if w.peak[i] < 0: inc w.filled
        w.peak[i] = max(w.peak[i], sh.peak[k])
        w.rms[i] = max(w.rms[i], sh.rms[k])
        if sh.peak[k] > w.top: w.top = sh.peak[k]
      result = true
    sh.peak.setLen 0
    sh.rms.setLen 0
    sh.runs.setLen 0
    if sh.reach > w.reach:
      w.reach = sh.reach
      w.cover(w.src.at, w.reach)
    if sh.done:
      w.done = true
      w.error = sh.error
      result = true
