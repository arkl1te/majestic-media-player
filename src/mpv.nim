## Minimal libmpv bindings (client.h, render.h, render_gl.h) plus helpers.

import std/json

{.passL: "-lmpv".}

type
  MpvHandle* = ptr object
  MpvRenderContext* = ptr object

  MpvFormat* {.size: sizeof(cint).} = enum
    fmtNone = 0, fmtString = 1, fmtOsdString = 2, fmtFlag = 3, fmtInt64 = 4,
    fmtDouble = 5, fmtNode = 6, fmtNodeArray = 7, fmtNodeMap = 8,
    fmtByteArray = 9

  MpvEventId* {.size: sizeof(cint).} = enum
    evNone = 0, evShutdown = 1, evLogMessage = 2, evGetPropertyReply = 3,
    evSetPropertyReply = 4, evCommandReply = 5, evStartFile = 6,
    evEndFile = 7, evFileLoaded = 8, evIdle = 11, evTick = 14,
    evClientMessage = 16, evVideoReconfig = 17, evAudioReconfig = 18,
    evSeek = 20, evPlaybackRestart = 21, evPropertyChange = 22,
    evQueueOverflow = 24, evHook = 25

  MpvEndFileReason* {.size: sizeof(cint).} = enum
    efEof = 0, efStop = 2, efQuit = 3, efError = 4, efRedirect = 5

  MpvEvent* = object
    eventId*: MpvEventId
    error*: cint
    replyUserdata*: uint64
    data*: pointer

  MpvEventProperty* = object
    name*: cstring
    format*: MpvFormat
    data*: pointer

  MpvEventEndFile* = object
    reason*: MpvEndFileReason
    error*: cint
    playlistEntryId*: int64
    playlistInsertId*: int64
    playlistInsertNumEntries*: cint

  MpvNodeList* = object
    num*: cint
    values*: ptr UncheckedArray[MpvNode]
    keys*: ptr UncheckedArray[cstring]

  MpvNodeUnion* {.union.} = object
    str*: cstring
    flag*: cint
    int64*: int64
    double*: cdouble
    list*: ptr MpvNodeList
    ba*: pointer

  MpvNode* = object
    u*: MpvNodeUnion
    format*: MpvFormat

  MpvRenderParamType* {.size: sizeof(cint).} = enum
    rpInvalid = 0, rpApiType = 1, rpOpenGlInitParams = 2, rpOpenGlFbo = 3,
    rpFlipY = 4, rpDepth = 5, rpIccProfile = 6, rpAmbientLight = 7,
    rpX11Display = 8, rpWlDisplay = 9, rpAdvancedControl = 10,
    rpNextFrameInfo = 11, rpBlockForTargetTime = 12, rpSkipRendering = 13

  MpvRenderParam* = object
    kind*: MpvRenderParamType
    data*: pointer

  MpvOpenGlInitParams* = object
    getProcAddress*: proc (ctx: pointer, name: cstring): pointer {.cdecl.}
    getProcAddressCtx*: pointer

  MpvOpenGlFbo* = object
    fbo*: cint
    w*, h*: cint
    internalFormat*: cint

  MpvRenderFrameInfo* = object
    flags*: uint64
    targetTime*: int64

const
  MpvRenderUpdateFrame* = 1'u64
  MpvFrameInfoPresent* = 1'u64
  MpvFrameInfoRedraw* = 2'u64

{.push importc, cdecl.}
proc mpv_create*(): MpvHandle
proc mpv_initialize*(ctx: MpvHandle): cint
proc mpv_terminate_destroy*(ctx: MpvHandle)
proc mpv_error_string*(error: cint): cstring
proc mpv_free*(data: pointer)
proc mpv_free_node_contents*(node: ptr MpvNode)
proc mpv_set_option_string*(ctx: MpvHandle, name, data: cstring): cint
proc mpv_command*(ctx: MpvHandle, args: ptr cstring): cint
proc mpv_command_string*(ctx: MpvHandle, args: cstring): cint
proc mpv_command_async*(ctx: MpvHandle, replyUserdata: uint64, args: ptr cstring): cint
proc mpv_set_property*(ctx: MpvHandle, name: cstring, format: MpvFormat, data: pointer): cint
proc mpv_set_property_string*(ctx: MpvHandle, name, data: cstring): cint
proc mpv_get_property*(ctx: MpvHandle, name: cstring, format: MpvFormat, data: pointer): cint
proc mpv_get_property_string*(ctx: MpvHandle, name: cstring): cstring
proc mpv_observe_property*(ctx: MpvHandle, replyUserdata: uint64, name: cstring, format: MpvFormat): cint
proc mpv_wait_event*(ctx: MpvHandle, timeout: cdouble): ptr MpvEvent
proc mpv_set_wakeup_callback*(ctx: MpvHandle, cb: proc (d: pointer) {.cdecl.}, d: pointer)
proc mpv_request_log_messages*(ctx: MpvHandle, minLevel: cstring): cint

proc mpv_render_context_create*(res: ptr MpvRenderContext, mpv: MpvHandle, params: ptr MpvRenderParam): cint
proc mpv_render_context_set_update_callback*(ctx: MpvRenderContext, cb: proc (d: pointer) {.cdecl.}, d: pointer)
proc mpv_render_context_update*(ctx: MpvRenderContext): uint64
proc mpv_render_context_get_info*(ctx: MpvRenderContext, param: MpvRenderParam): cint
proc mpv_get_time_ns*(ctx: MpvHandle): int64
proc mpv_render_context_render*(ctx: MpvRenderContext, params: ptr MpvRenderParam): cint
proc mpv_render_context_report_swap*(ctx: MpvRenderContext)
proc mpv_render_context_free*(ctx: MpvRenderContext)
{.pop.}

type MpvError* = object of CatchableError

proc check*(code: cint, what: string) =
  if code < 0:
    raise newException(MpvError, what & ": " & $mpv_error_string(code))

proc command*(h: MpvHandle, args: varargs[string]): cint {.discardable.} =
  ## Runs an mpv command synchronously. Returns the mpv error code.
  var cargs = newSeq[cstring](args.len + 1)
  for i, a in args: cargs[i] = a.cstring
  cargs[^1] = nil
  mpv_command(h, cargs[0].addr)

proc commandStr*(h: MpvHandle, cmd: string): cint {.discardable.} =
  ## Runs a command in input.conf syntax (supports prefixes like osd-msg).
  mpv_command_string(h, cmd)

proc commandAsync*(h: MpvHandle, args: varargs[string]) =
  var cargs = newSeq[cstring](args.len + 1)
  for i, a in args: cargs[i] = a.cstring
  cargs[^1] = nil
  discard mpv_command_async(h, 0, cargs[0].addr)

proc setOpt*(h: MpvHandle, name, value: string) =
  check mpv_set_option_string(h, name, value), "option " & name

proc setProp*(h: MpvHandle, name, value: string): cint {.discardable.} =
  mpv_set_property_string(h, name, value)

proc setProp*(h: MpvHandle, name: string, value: float): cint {.discardable.} =
  var v = value.cdouble
  mpv_set_property(h, name, fmtDouble, v.addr)

proc setProp*(h: MpvHandle, name: string, value: bool): cint {.discardable.} =
  var v = cint(value)
  mpv_set_property(h, name, fmtFlag, v.addr)

proc getStr*(h: MpvHandle, name: string): string =
  let s = mpv_get_property_string(h, name)
  if s != nil:
    result = $s
    mpv_free(s)

proc getFloat*(h: MpvHandle, name: string, default = 0.0): float =
  var v: cdouble
  if mpv_get_property(h, name, fmtDouble, v.addr) >= 0: v.float else: default

proc getInt*(h: MpvHandle, name: string, default = 0): int =
  var v: int64
  if mpv_get_property(h, name, fmtInt64, v.addr) >= 0: v.int else: default

proc getFlag*(h: MpvHandle, name: string): bool =
  var v: cint
  mpv_get_property(h, name, fmtFlag, v.addr) >= 0 and v != 0

proc toJson*(node: MpvNode): JsonNode =
  case node.format
  of fmtString, fmtOsdString: %($node.u.str)
  of fmtFlag: %(node.u.flag != 0)
  of fmtInt64: %node.u.int64
  of fmtDouble: %node.u.double.float
  of fmtNodeArray:
    var arr = newJArray()
    let l = node.u.list
    for i in 0 ..< l.num: arr.add l.values[i].toJson
    arr
  of fmtNodeMap:
    var obj = newJObject()
    let l = node.u.list
    for i in 0 ..< l.num: obj[$l.keys[i]] = l.values[i].toJson
    obj
  else: newJNull()

proc getNode*(h: MpvHandle, name: string): JsonNode =
  var node: MpvNode
  if mpv_get_property(h, name, fmtNode, node.addr) < 0:
    return newJNull()
  result = node.toJson
  mpv_free_node_contents(node.addr)
