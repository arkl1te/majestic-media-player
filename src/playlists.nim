## Playlist files: M3U/M3U8 and PLS, read and written.

import std/[os, strutils, uri]

const PlaylistExtensions* = ["m3u", "m3u8", "pls"]

type PlaylistEntry* = object
  path*: string
  title*: string
  duration*: float  ## seconds, < 0 when unknown

proc isPls(path: string): bool = path.splitFile.ext.toLowerAscii == ".pls"

proc resolve(entry, base: string): string =
  ## Entry as written in a playlist: an URL, a file:// URI, or an absolute
  ## path or one relative to the playlist's folder.
  let e = entry.strip
  if e.len == 0: return
  if e.toLowerAscii.startsWith("file://"): return decodeUrl(e.parseUri.path, false)
  if e.contains("://"): return e
  let p = e.replace('\\', '/')
  if p.isAbsolute: p else: normalizedPath(base / p)

proc readPlaylist*(path: string): seq[string] =
  ## The entries of an M3U or PLS file, in order; raises IOError when unreadable.
  let base = path.absolutePath.parentDir
  var text = readFile(path)
  if text.startsWith("\xEF\xBB\xBF"): text = text[3 .. ^1]
  if path.isPls:
    # FileN= lines, ordered by N (they are usually in order already)
    var files: seq[(int, string)]
    for line in text.splitLines:
      let l = line.strip
      if l.toLowerAscii.startsWith("file"):
        let eq = l.find('=')
        if eq < 0: continue
        try: files.add (parseInt(l[4 ..< eq].strip), l[eq + 1 .. ^1])
        except ValueError: discard
    for i in 1 ..< files.len:  # stable insertion sort keeps duplicates' order
      var j = i
      while j > 0 and files[j - 1][0] > files[j][0]:
        swap(files[j - 1], files[j])
        dec j
    for (_, f) in files:
      let r = resolve(f, base)
      if r.len > 0: result.add r
  else:
    for line in text.splitLines:
      let l = line.strip
      if l.len == 0 or l.startsWith("#"): continue
      let r = resolve(l, base)
      if r.len > 0: result.add r

proc writePlaylist*(path: string, entries: seq[PlaylistEntry]) =
  ## Writes PLS for a .pls path, extended M3U otherwise (UTF-8, absolute
  ## paths); raises IOError on failure.
  var s: string
  if path.isPls:
    s.add "[playlist]\n"
    for i, e in entries:
      let n = i + 1
      s.add "File" & $n & "=" & e.path & "\n"
      s.add "Title" & $n & "=" & e.title & "\n"
      s.add "Length" & $n & "=" & $(if e.duration < 0: -1 else: int(e.duration + 0.5)) & "\n"
    s.add "NumberOfEntries=" & $entries.len & "\n"
    s.add "Version=2\n"
  else:
    s.add "#EXTM3U\n"
    for e in entries:
      let d = if e.duration < 0: -1 else: int(e.duration + 0.5)
      s.add "#EXTINF:" & $d & "," & e.title & "\n"
      s.add e.path & "\n"
  writeFile(path, s)
