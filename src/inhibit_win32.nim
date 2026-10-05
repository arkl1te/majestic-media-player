## Keeps the display awake with SetThreadExecutionState, which acts for the
## calling thread: the main one, which lives as long as the app.

type
  Inhibitor* = object
    wanted: bool   ## last state asked for

const
  EsContinuous = 0x80000000'u32
  EsSystemRequired = 0x00000001'u32
  EsDisplayRequired = 0x00000002'u32

proc SetThreadExecutionState(flags: uint32): uint32 {.stdcall, dynlib: "kernel32", importc.}

proc set*(ih: var Inhibitor, on: bool) =
  ## Inhibits or releases; cheap to call every frame, as it only acts on change.
  if on == ih.wanted: return
  ih.wanted = on
  discard SetThreadExecutionState(
    if on: EsContinuous or EsSystemRequired or EsDisplayRequired else: EsContinuous)
