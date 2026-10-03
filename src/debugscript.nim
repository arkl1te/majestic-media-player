## Debug automation for development: MMP_SCRIPT="1.5:open /f.mkv;3:shot /tmp/a.png;4:quit"
## Each step is "<seconds since start>:<command> [args]". Used to verify the UI
## without a human at the mouse; inert unless the env var is set.

import std/[os, strutils, times]

type
  ScriptStep* = object
    at*: float
    cmd*: string
    args*: seq[string]

  Script* = object
    steps*: seq[ScriptStep]
    start*: float
    next*: int

proc loadScript*(): Script =
  let src = getEnv("MMP_SCRIPT")
  result.start = epochTime()
  for part in src.split(';'):
    let p = part.strip
    if p.len == 0: continue
    let i = p.find(':')
    if i < 0: continue
    let words = p[i + 1 .. ^1].strip.splitWhitespace
    if words.len == 0: continue
    result.steps.add ScriptStep(at: parseFloat(p[0 ..< i]), cmd: words[0],
      args: words[1 .. ^1])

proc due*(s: var Script): seq[ScriptStep] =
  let t = epochTime() - s.start
  while s.next < s.steps.len and s.steps[s.next].at <= t:
    result.add s.steps[s.next]
    inc s.next
