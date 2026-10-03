## OpenGL plumbing for video: mpv renders into an offscreen texture, which is
## then drawn as an arbitrarily transformed quad (pan/rotate/scale).

import opengl, vmath
import mpv

proc glXGetProcAddressARB(name: cstring): pointer {.importc, dynlib: "libGL.so.1".}

proc mpvGetProcAddress(ctx: pointer, name: cstring): pointer {.cdecl.} =
  glXGetProcAddressARB(name)

type
  VideoTarget* = object
    fbo*, tex*: GLuint
    w*, h*: int

  QuadRenderer* = object
    program: GLuint
    vao, vbo: GLuint
    uViewport, uTex, uAlpha: GLint

proc createRenderContext*(h: MpvHandle, blockForTargetTime = true): MpvRenderContext =
  var
    initParams = MpvOpenGlInitParams(getProcAddress: mpvGetProcAddress)
    apiType = "opengl".cstring
    advanced: cint = 1
    blockFlag: cint = cint(blockForTargetTime)
    params = [
      MpvRenderParam(kind: rpApiType, data: apiType),
      MpvRenderParam(kind: rpOpenGlInitParams, data: initParams.addr),
      MpvRenderParam(kind: rpAdvancedControl, data: advanced.addr),
      MpvRenderParam(kind: rpBlockForTargetTime, data: blockFlag.addr),
      MpvRenderParam(kind: rpInvalid, data: nil)
    ]
  check mpv_render_context_create(result.addr, h, params[0].addr), "render context"

proc nextFrameTarget*(ctx: MpvRenderContext): int64 =
  ## Target display time (mpv_get_time_ns clock) of the queued frame, or 0
  ## when it should be shown right away.
  var info: MpvRenderFrameInfo
  if mpv_render_context_get_info(ctx, MpvRenderParam(kind: rpNextFrameInfo, data: info.addr)) < 0:
    return 0
  if (info.flags and MpvFrameInfoPresent) == 0: return 0
  info.targetTime

proc ensureSize*(t: var VideoTarget, w, h: int) =
  let w = max(w, 1)
  let h = max(h, 1)
  if t.fbo != 0 and t.w == w and t.h == h:
    return
  if t.fbo == 0:
    glGenFramebuffers(1, t.fbo.addr)
    glGenTextures(1, t.tex.addr)
  t.w = w
  t.h = h
  glBindTexture(GL_TEXTURE_2D, t.tex)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint, w.GLsizei, h.GLsizei, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE.GLint)
  glBindTexture(GL_TEXTURE_2D, 0)
  glBindFramebuffer(GL_FRAMEBUFFER, t.fbo)
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, t.tex, 0)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

proc render*(ctx: MpvRenderContext, t: VideoTarget) =
  ## Renders the current mpv frame into the target texture.
  var
    fbo = MpvOpenGlFbo(fbo: t.fbo.cint, w: t.w.cint, h: t.h.cint)
    flip: cint = 0
    params = [
      MpvRenderParam(kind: rpOpenGlFbo, data: fbo.addr),
      MpvRenderParam(kind: rpFlipY, data: flip.addr),
      MpvRenderParam(kind: rpInvalid, data: nil)
    ]
  discard mpv_render_context_render(ctx, params[0].addr)
  glBindFramebuffer(GL_FRAMEBUFFER, 0)

const
  vertSrc = """
#version 410 core
layout(location = 0) in vec2 pos;
layout(location = 1) in vec2 uv;
uniform vec2 viewport;
out vec2 vUv;
void main() {
  vUv = uv;
  gl_Position = vec4(pos.x / viewport.x * 2.0 - 1.0, 1.0 - pos.y / viewport.y * 2.0, 0.0, 1.0);
}
"""
  fragSrc = """
#version 410 core
in vec2 vUv;
uniform sampler2D tex;
uniform float alpha;
out vec4 color;
void main() {
  color = vec4(texture(tex, vUv).rgb, 1.0) * alpha;
}
"""

proc compile(kind: GLenum, src: string): GLuint =
  result = glCreateShader(kind)
  var s = src.cstring
  glShaderSource(result, 1, cast[cstringArray](s.addr), nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, ok.addr)
  if ok == 0:
    var log = newString(1024)
    var length: GLsizei
    glGetShaderInfoLog(result, 1024, length.addr, log.cstring)
    log.setLen(length)
    raise newException(ValueError, "shader compile failed: " & log)

proc newQuadRenderer*(): QuadRenderer =
  result.program = glCreateProgram()
  glAttachShader(result.program, compile(GL_VERTEX_SHADER, vertSrc))
  glAttachShader(result.program, compile(GL_FRAGMENT_SHADER, fragSrc))
  glLinkProgram(result.program)
  result.uViewport = glGetUniformLocation(result.program, "viewport")
  result.uTex = glGetUniformLocation(result.program, "tex")
  result.uAlpha = glGetUniformLocation(result.program, "alpha")
  glGenVertexArrays(1, result.vao.addr)
  glGenBuffers(1, result.vbo.addr)
  glBindVertexArray(result.vao)
  glBindBuffer(GL_ARRAY_BUFFER, result.vbo)
  glBufferData(GL_ARRAY_BUFFER, 24 * sizeof(float32), nil, GL_DYNAMIC_DRAW)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(0, 2, cGL_FLOAT, GL_FALSE, 4 * sizeof(float32), nil)
  glEnableVertexAttribArray(1)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 4 * sizeof(float32),
    cast[pointer](2 * sizeof(float32)))
  glBindVertexArray(0)

proc draw*(q: QuadRenderer, tex: GLuint, corners: array[4, Vec2], viewport: Vec2, alpha = 1.0'f32) =
  ## Draws a texture onto a quad given by its corners in window pixels:
  ## top-left, top-right, bottom-right, bottom-left (as the image should look).
  ## mpv renders into the FBO with flip_y=0, which stores the image top row
  ## first (v=0 is the top of the picture).
  let uvs = [vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 1)]
  var data: array[24, float32]
  var i = 0
  for idx in [0, 1, 2, 0, 2, 3]:
    data[i] = corners[idx].x; data[i+1] = corners[idx].y
    data[i+2] = uvs[idx].x; data[i+3] = uvs[idx].y
    i += 4
  glViewport(0, 0, viewport.x.GLsizei, viewport.y.GLsizei)
  glUseProgram(q.program)
  glUniform2f(q.uViewport, viewport.x, viewport.y)
  glUniform1i(q.uTex, 0)
  glUniform1f(q.uAlpha, alpha)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, tex)
  glBindVertexArray(q.vao)
  glBindBuffer(GL_ARRAY_BUFFER, q.vbo)
  glBufferSubData(GL_ARRAY_BUFFER, 0, sizeof(data), data[0].addr)
  glDrawArrays(GL_TRIANGLES, 0, 6)
  glBindVertexArray(0)
  glBindTexture(GL_TEXTURE_2D, 0)
  glUseProgram(0)

proc rectCorners*(pos, size: Vec2): array[4, Vec2] =
  [pos, pos + vec2(size.x, 0), pos + size, pos + vec2(0, size.y)]

proc transformedCorners*(center, size: Vec2, angleDeg: float32): array[4, Vec2] =
  let
    a = angleDeg * PI.float32 / 180
    c = cos(a)
    s = sin(a)
    hx = size.x / 2
    hy = size.y / 2
  for i, p in [vec2(-hx, -hy), vec2(hx, -hy), vec2(hx, hy), vec2(-hx, hy)]:
    result[i] = center + vec2(p.x * c - p.y * s, p.x * s + p.y * c)
