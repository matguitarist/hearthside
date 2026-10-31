// AMD FidelityFX Super Resolution 1 (EASU upscale, then RCAS sharpening) for the 5.4.8 client's
// last blit, the one that stretches its finished frame onto the window. GLSL 1.20 ports of
// FsrEasuF and FsrRcasF from ffx_fsr1.h (MIT, Copyright (c) 2021 Advanced Micro Devices, Inc.),
// without gather: the 12 EASU taps are single fetches from a nearest-filtered copy of the frame.
// The client's window surface is far larger than any screen shows (6720x3780 for a 2560x1440
// frame), so the output goes to a surface of its own size instead, GLHOOK_FSR_SCALE times the
// frame (1.5 by default, FSR's "quality" ratio; 0 keeps the client's surface), which macOS scales
// to the window.
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "fsr.h"

static const char *vertex_src =
    "#version 120\n"
    "void main() { gl_Position = gl_Vertex; }\n";

static const char *easu_src =
    "#version 120\n"
    "uniform sampler2D src;\n"
    "uniform vec2 in_size, scale, origin;\n"
    "vec3 tap(vec2 fp, float x, float y) { return texture2D(src, (fp + vec2(x, y) + 0.5) / in_size).rgb; }\n"
    "float luma(vec3 c) { return c.b * 0.5 + (c.r * 0.5 + c.g); }\n"
    "void set(inout vec2 dir, inout float len, float w, float a, float b, float c, float d, float e) {\n"
    "  float lx = clamp(abs(d - b) / max(max(abs(d - c), abs(c - b)), 1.0 / 65536.0), 0.0, 1.0);\n"
    "  float ly = clamp(abs(e - a) / max(max(abs(e - c), abs(c - a)), 1.0 / 65536.0), 0.0, 1.0);\n"
    "  dir += vec2(d - b, e - a) * w;\n"
    "  len += (lx * lx + ly * ly) * w;\n"
    "}\n"
    "void acc(inout vec3 ac, inout float aw, vec2 off, vec2 dir, vec2 len, float lob, float clp, vec3 c) {\n"
    "  vec2 v = vec2(off.x * dir.x + off.y * dir.y, off.x * -dir.y + off.y * dir.x) * len;\n"
    "  float d2 = min(dot(v, v), clp);\n"
    "  float wb = 2.0 / 5.0 * d2 - 1.0, wa = lob * d2 - 1.0;\n"
    "  float w = (25.0 / 16.0 * wb * wb - (25.0 / 16.0 - 1.0)) * wa * wa;\n"
    "  ac += c * w; aw += w;\n"
    "}\n"
    "void main() {\n"
    "  vec2 pp = (gl_FragCoord.xy - origin) * scale - 0.5;\n"
    "  vec2 fp = floor(pp); pp -= fp;\n"
    "  vec3 b = tap(fp, 0.0, -1.0), c = tap(fp, 1.0, -1.0);\n"
    "  vec3 e = tap(fp, -1.0, 0.0), f = tap(fp, 0.0, 0.0), g = tap(fp, 1.0, 0.0), h = tap(fp, 2.0, 0.0);\n"
    "  vec3 i = tap(fp, -1.0, 1.0), j = tap(fp, 0.0, 1.0), k = tap(fp, 1.0, 1.0), l = tap(fp, 2.0, 1.0);\n"
    "  vec3 n = tap(fp, 0.0, 2.0), o = tap(fp, 1.0, 2.0);\n"
    "  float bL = luma(b), cL = luma(c), eL = luma(e), fL = luma(f), gL = luma(g), hL = luma(h);\n"
    "  float iL = luma(i), jL = luma(j), kL = luma(k), lL = luma(l), nL = luma(n), oL = luma(o);\n"
    "  vec2 dir = vec2(0.0); float len = 0.0;\n"
    "  set(dir, len, (1.0 - pp.x) * (1.0 - pp.y), bL, eL, fL, gL, jL);\n"
    "  set(dir, len, pp.x * (1.0 - pp.y), cL, fL, gL, hL, kL);\n"
    "  set(dir, len, (1.0 - pp.x) * pp.y, fL, iL, jL, kL, nL);\n"
    "  set(dir, len, pp.x * pp.y, gL, jL, kL, lL, oL);\n"
    "  float dr = dot(dir, dir);\n"
    "  bool zro = dr < 1.0 / 32768.0;\n"
    "  dir = zro ? vec2(1.0, 0.0) : dir * inversesqrt(dr);\n"
    "  len = len * 0.5; len *= len;\n"
    "  float stretch = dot(dir, dir) / max(abs(dir.x), abs(dir.y));\n"
    "  vec2 len2 = vec2(1.0 + (stretch - 1.0) * len, 1.0 - 0.5 * len);\n"
    "  float lob = 0.5 + ((1.0 / 4.0 - 0.04) - 0.5) * len;\n"
    "  float clp = 1.0 / lob;\n"
    "  vec3 mn = min(min(f, g), min(j, k)), mx = max(max(f, g), max(j, k));\n"
    "  vec3 ac = vec3(0.0); float aw = 0.0;\n"
    "  acc(ac, aw, vec2(0.0, -1.0) - pp, dir, len2, lob, clp, b);\n"
    "  acc(ac, aw, vec2(1.0, -1.0) - pp, dir, len2, lob, clp, c);\n"
    "  acc(ac, aw, vec2(-1.0, 1.0) - pp, dir, len2, lob, clp, i);\n"
    "  acc(ac, aw, vec2(0.0, 1.0) - pp, dir, len2, lob, clp, j);\n"
    "  acc(ac, aw, vec2(0.0, 0.0) - pp, dir, len2, lob, clp, f);\n"
    "  acc(ac, aw, vec2(-1.0, 0.0) - pp, dir, len2, lob, clp, e);\n"
    "  acc(ac, aw, vec2(1.0, 1.0) - pp, dir, len2, lob, clp, k);\n"
    "  acc(ac, aw, vec2(2.0, 1.0) - pp, dir, len2, lob, clp, l);\n"
    "  acc(ac, aw, vec2(2.0, 0.0) - pp, dir, len2, lob, clp, h);\n"
    "  acc(ac, aw, vec2(1.0, 0.0) - pp, dir, len2, lob, clp, g);\n"
    "  acc(ac, aw, vec2(1.0, 2.0) - pp, dir, len2, lob, clp, o);\n"
    "  acc(ac, aw, vec2(0.0, 2.0) - pp, dir, len2, lob, clp, n);\n"
    "  gl_FragColor = vec4(min(mx, max(mn, ac / aw)), 1.0);\n"
    "}\n";

static const char *rcas_src =
    "#version 120\n"
    "uniform sampler2D src;\n"
    "uniform vec2 size, origin;\n"
    "uniform float sharpness;\n"
    "vec3 at(vec2 p, float x, float y) { return texture2D(src, (p + vec2(x, y)) / size).rgb; }\n"
    "void main() {\n"
    "  vec2 p = gl_FragCoord.xy - origin;\n"
    "  vec3 b = at(p, 0.0, -1.0), d = at(p, -1.0, 0.0), e = at(p, 0.0, 0.0), f = at(p, 1.0, 0.0), h = at(p, 0.0, 1.0);\n"
    "  vec3 mn4 = min(min(b, d), min(f, h)), mx4 = max(max(b, d), max(f, h));\n"
    "  vec3 hit_min = min(mn4, e) / (4.0 * mx4);\n"
    "  vec3 hit_max = (1.0 - max(mx4, e)) / (4.0 * mn4 - 4.0);\n"
    "  vec3 lobes = max(-hit_min, hit_max);\n"
    "  float lobe = max(-(0.25 - 1.0 / 16.0), min(max(lobes.r, max(lobes.g, lobes.b)), 0.0)) * sharpness;\n"
    "  gl_FragColor = vec4((lobe * (b + d + f + h) + e) / (4.0 * lobe + 1.0), 1.0);\n"
    "}\n";

static GLuint program(const char *fragment_src) {
    GLuint p = glCreateProgram(), shaders[2] = {glCreateShader(GL_VERTEX_SHADER), glCreateShader(GL_FRAGMENT_SHADER)};
    const char *srcs[2] = {vertex_src, fragment_src};
    for (int i = 0; i < 2; i++) {
        glShaderSource(shaders[i], 1, &srcs[i], NULL);
        glCompileShader(shaders[i]);
        glAttachShader(p, shaders[i]);
    }
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[2048] = "";
        for (int i = 0; i < 2; i++) glGetShaderInfoLog(shaders[i], sizeof log, NULL, log), fputs(log, stderr);
        fprintf(stderr, "glhook: FSR shaders failed, falling back to the client's blit\n");
        return 0;
    }
    return p;
}

// A texture and a framebuffer around it, (re)sized to w x h.
struct target { GLuint tex, fbo; int w, h; };

static void size_target(struct target *t, int w, int h) {
    if (t->w == w && t->h == h) return;
    if (!t->tex) glGenTextures(1, &t->tex), glGenFramebuffersEXT(1, &t->fbo);
    glBindTexture(GL_TEXTURE_2D, t->tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, t->fbo);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, t->tex, 0);
    t->w = w, t->h = h;
}

static void quad(void) {
    glBegin(GL_TRIANGLE_STRIP);
    glVertex2f(-1, -1), glVertex2f(1, -1), glVertex2f(-1, 1), glVertex2f(1, 1);
    glEnd();
}

int fsr_blit(int sx0, int sy0, int sx1, int sy1, int dx0, int dy0, int dx1, int dy1) {
    static GLuint easu, rcas;
    static int failed, reported;
    static struct target input, upscaled;
    static float sharpness = -1;
    static CGLContextObj owner;
    static int backing_w, backing_h;
    // Textures, framebuffers and programs belong to the context they were made in.
    if (CGLGetCurrentContext() != owner) {
        owner = CGLGetCurrentContext();
        easu = rcas = 0, failed = reported = 0;
        input = upscaled = (struct target){0};
        backing_w = backing_h = 0;
    }
    int sw = sx1 - sx0, sh = sy1 - sy0, dw = dx1 - dx0, dh = dy1 - dy0;
    if (failed || sw <= 0 || sh <= 0 || dw <= sw || dh <= sh) return 0;
    static float scale = -1;
    if (scale < 0) {
        const char *s = getenv("GLHOOK_FSR_SCALE");
        scale = s ? strtof(s, NULL) : 1.5f;
    }
    int tw = sw * scale + 0.5f, th = sh * scale + 0.5f;
    if (scale > 1 && tw < dw && th < dh) {
        if (tw != backing_w || th != backing_h) {
            GLint size[2] = {tw, th};
            CGLSetParameter(owner, kCGLCPSurfaceBackingSize, size);
            CGLEnable(owner, kCGLCESurfaceBackingSize);
            backing_w = tw, backing_h = th;
        }
        dx0 = dy0 = 0, dx1 = dw = tw, dy1 = dh = th;
    }

    GLint read_fbo, draw_fbo, prog, active;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read_fbo);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw_fbo);
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glPushAttrib(GL_ALL_ATTRIB_BITS);
    glPushClientAttrib(GL_CLIENT_ALL_ATTRIB_BITS);
    glActiveTexture(GL_TEXTURE0);

    if (!easu && !(easu = program(easu_src))) failed = 1;
    if (!failed && !rcas && !(rcas = program(rcas_src))) failed = 1;
    if (sharpness < 0) {
        // In stops: 0 is the most, each 1 halves it; AMD's default is 0.2.
        const char *s = getenv("GLHOOK_SHARPNESS");
        sharpness = exp2f(-(s ? strtof(s, NULL) : 0.2f));
    }
    if (!failed) {
        // The frame, copied as is: EASU reads exact texels, and the client's source may be multisampled.
        // A pixel buffer the client left bound would turn the textures' NULL data into an offset in
        // it, and its client storage (APPLE_client_storage) would leave them with no memory at all.
        // The pixel store comes back with glPopClientAttrib.
        GLint unpack;
        glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
        glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_FALSE);
        size_target(&input, sw, sh);
        size_target(&upscaled, dw, dh);
        glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack);
        if (!reported) {
            reported = 1;
            glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, input.fbo);
            GLenum in_status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
            glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, upscaled.fbo);
            GLenum up_status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
            if (in_status != GL_FRAMEBUFFER_COMPLETE_EXT || up_status != GL_FRAMEBUFFER_COMPLETE_EXT) failed = 1;
            fprintf(stderr, "glhook: FSR %dx%d -> %dx%d in context %p, read fbo %d, draw fbo %d, "
                    "framebuffers %x %x, error %x\n", sw, sh, dw, dh, (void *)owner, read_fbo, draw_fbo,
                    in_status, up_status, glGetError());
        }
        glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, read_fbo);
        glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, input.fbo);
        glBlitFramebufferEXT(sx0, sy0, sx1, sy1, 0, 0, sw, sh, GL_COLOR_BUFFER_BIT, GL_NEAREST);
    }
    if (!failed) {
        GLenum off[] = {GL_BLEND, GL_DEPTH_TEST, GL_SCISSOR_TEST, GL_CULL_FACE, GL_ALPHA_TEST, GL_STENCIL_TEST,
                        GL_VERTEX_PROGRAM_ARB, GL_FRAGMENT_PROGRAM_ARB, GL_FRAMEBUFFER_SRGB_EXT};
        for (unsigned i = 0; i < sizeof off / sizeof *off; i++) glDisable(off[i]);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glDepthMask(GL_FALSE);

        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, upscaled.fbo);
        glViewport(0, 0, dw, dh);
        glUseProgram(easu);
        glBindTexture(GL_TEXTURE_2D, input.tex);
        glUniform1i(glGetUniformLocation(easu, "src"), 0);
        glUniform2f(glGetUniformLocation(easu, "in_size"), sw, sh);
        glUniform2f(glGetUniformLocation(easu, "scale"), (float)sw / dw, (float)sh / dh);
        glUniform2f(glGetUniformLocation(easu, "origin"), 0, 0);
        quad();

        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, draw_fbo);
        glViewport(dx0, dy0, dw, dh);
        glUseProgram(rcas);
        glBindTexture(GL_TEXTURE_2D, upscaled.tex);
        glUniform1i(glGetUniformLocation(rcas, "src"), 0);
        glUniform2f(glGetUniformLocation(rcas, "size"), dw, dh);
        glUniform2f(glGetUniformLocation(rcas, "origin"), dx0, dy0);
        glUniform1f(glGetUniformLocation(rcas, "sharpness"), sharpness);
        quad();
    }

    glUseProgram(prog);
    glPopClientAttrib();
    glPopAttrib();
    glActiveTexture(active);
    glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, read_fbo);
    glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, draw_fbo);
    return !failed;
}
