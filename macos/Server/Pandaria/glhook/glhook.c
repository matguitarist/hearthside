// Fixes for the 5.4.8 client on Apple's OpenGL, loaded at launch: `mac-client-setup` points the
// client's dead libcrypto.0.9.8 import at it. The client calls OpenGL through each context's
// dispatch table (CGLMacro.h), so entries of that table are replaced as contexts are created or
// made current.
// GLHOOK_DUMP=<dir>: write every program and shader string the client compiles to <dir>.
// GLHOOK_LOG=<file>: surface parameters and frame timing, every two seconds.
// GLHOOK_FSR=0: keep the client's own linear stretch instead of FSR 1 (fsr.c);
// GLHOOK_SHARPNESS=<stops>: RCAS sharpening, 0 the most, each 1 halves it (default 0.2);
// GLHOOK_FSR_SCALE=<x>: output size as a multiple of the frame (default 1.5, 0 the whole surface).
#include "fsr.h"
#include <OpenGL/CGLContext.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>
#include <CoreGraphics/CGGeometry.h>
#include <objc/message.h>
#include <objc/runtime.h>

#define DYLD_INTERPOSE(_new, _old) \
    __attribute__((used)) static struct { const void *n, *o; } _interpose_##_old \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)_new, (const void *)_old };

static const char *dump_dir(void) { return getenv("GLHOOK_DUMP"); }

static void dump(const char *kind, int n, const char *const *parts, const GLint *lens, int count) {
    if (!dump_dir()) return;
    char p[1024];
    snprintf(p, sizeof p, "%s/%s-%04d.txt", dump_dir(), kind, n);
    FILE *f = fopen(p, "w");
    for (int i = 0; f && i < count; i++)
        fwrite(parts[i], 1, lens && lens[i] >= 0 ? (size_t)lens[i] : strlen(parts[i]), f);
    if (f) fclose(f);
}

// The skinning programs (NV_vertex_program3) load four bone indices at once, `ARL A0, R0;`, then
// read bones through A0.y, A0.z and A0.w; Apple's translator honours only A0.x, so blended
// vertices take the wrong bones. Rewritten: the indices go to a temporary, and each instruction
// that reads A0.c gets its own `ARL A0.x, AIDX.c;` and reads A0.x. Returns NULL if no change.
static char *fix_vector_arl(const char *text, size_t len) {
    const char *arl = strstr(text, "ARL   A0, ");
    if (!arl || arl >= text + len) return NULL;
    char *out = malloc(len * 3 + 64), *o = out;
    int vector = 0;
    for (const char *line = text, *end; line < text + len; line = end) {
        end = memchr(line, '\n', text + len - line);
        end = end ? end + 1 : text + len;
        size_t n = end - line;
        if (!strncmp(line, "ADDRESS A0;", 11)) {
            o += sprintf(o, "ADDRESS A0;\nTEMP AIDX;\n");
        } else if (!strncmp(line, "ARL   A0, ", 10)) {
            o += sprintf(o, "FLR   AIDX, ");
            memcpy(o, line + 10, n - 10), o += n - 10;
            vector = 1;
        } else if (!strncmp(line, "ARL", 3)) {
            memcpy(o, line, n), o += n;
            vector = 0;
        } else {
            const char *a = vector ? memmem(line, n, "A0.", 3) : NULL;
            if (a) o += sprintf(o, "ARL   A0.x, AIDX.%c;\n", a[3]);
            for (const char *p = line; p < end; p++) {
                *o++ = *p;
                if (vector && p + 3 < end && !strncmp(p, "A0.", 3)) memcpy(o, "0.x", 3), o += 3, p += 3;
            }
        }
    }
    *o = 0;
    return out;
}

typedef void (*ProgramString)(GLIContext, GLenum, GLenum, GLsizei, const GLvoid *);
static ProgramString real_program_string;
static int program_count;

static void hook_program_string(GLIContext ctx, GLenum target, GLenum format, GLsizei len, const GLvoid *text) {
    const char *part = text;
    GLint l = len;
    int n = program_count++;
    dump(target == GL_VERTEX_PROGRAM_ARB ? "vp" : "fp", n, &part, &l, 1);
    char *fixed = target == GL_VERTEX_PROGRAM_ARB ? fix_vector_arl(text, len) : NULL;
    if (fixed) {
        dump("vpfix", n, (const char *const *)&fixed, NULL, 1);
        real_program_string(ctx, target, format, strlen(fixed), fixed);
        free(fixed);
        return;
    }
    real_program_string(ctx, target, format, len, text);
}

typedef void (*ShaderSource)(GLIContext, GLhandleARB, GLsizei, const GLcharARB *const *, const GLint *);
static ShaderSource real_shader_source;
static int shader_count;

static void hook_shader_source(GLIContext ctx, GLhandleARB obj, GLsizei n, const GLcharARB *const *src, const GLint *lens) {
    dump("glsl", shader_count++, src, lens, n);
    real_shader_source(ctx, obj, n, src, lens);
}

// Framebuffer traffic, logged with GLHOOK_LOG: which framebuffer is drawn to, its viewports and
// every blit. The client draws its frame at its resolution and stretches it onto the window with
// one linear color blit to framebuffer 0: that one becomes FSR.
static FILE *log_file(void);
static GLuint draw_fbo;
static int flushes;
static int tracing(void) { return log_file() && flushes % 1000 < 2; }

typedef void (*BindFramebuffer)(GLIContext, GLenum, GLuint);
static BindFramebuffer real_bind_framebuffer;
static void hook_bind_framebuffer(GLIContext ctx, GLenum target, GLuint fbo) {
    if (target != GL_READ_FRAMEBUFFER_EXT) draw_fbo = fbo;
    real_bind_framebuffer(ctx, target, fbo);
}

typedef void (*Viewport)(GLIContext, GLint, GLint, GLsizei, GLsizei);
static Viewport real_viewport;
static void hook_viewport(GLIContext ctx, GLint x, GLint y, GLsizei w, GLsizei h) {
    static GLsizei lw, lh;
    static GLuint lf = ~0u;
    if (tracing() && (w != lw || h != lh || draw_fbo != lf)) {
        fprintf(log_file(), "viewport fbo %u %d,%d %dx%d\n", draw_fbo, x, y, w, h);
        lw = w, lh = h, lf = draw_fbo;
    }
    real_viewport(ctx, x, y, w, h);
}

typedef void (*Blit)(GLIContext, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
static Blit real_blit;
static void hook_blit(GLIContext ctx, GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0, GLint dy0,
                      GLint dx1, GLint dy1, GLbitfield mask, GLenum filter) {
    if (tracing()) {
        fprintf(log_file(), "blit to fbo %u %d,%d-%d,%d from %d,%d-%d,%d mask %x filter %x\n", draw_fbo,
                dx0, dy0, dx1, dy1, sx0, sy0, sx1, sy1, mask, filter);
    }
    static int inside;
    const char *fsr = getenv("GLHOOK_FSR");
    if (!inside && draw_fbo == 0 && mask == GL_COLOR_BUFFER_BIT && filter == GL_LINEAR && !(fsr && !strcmp(fsr, "0"))) {
        inside = 1;
        int done = fsr_blit(sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1);
        inside = 0;
        if (done) return;
    }
    real_blit(ctx, sx0, sy0, sx1, sy1, dx0, dy0, dx1, dy1, mask, filter);
}

static void patch(CGLContextObj ctx) {
    if (!ctx) return;
    if (ctx->disp.bind_framebuffer_EXT != hook_bind_framebuffer) {
        real_bind_framebuffer = ctx->disp.bind_framebuffer_EXT;
        ctx->disp.bind_framebuffer_EXT = hook_bind_framebuffer;
    }
    if (ctx->disp.viewport != hook_viewport) {
        real_viewport = ctx->disp.viewport;
        ctx->disp.viewport = hook_viewport;
    }
    if (ctx->disp.blit_framebuffer_EXT != hook_blit) {
        real_blit = ctx->disp.blit_framebuffer_EXT;
        ctx->disp.blit_framebuffer_EXT = hook_blit;
    }
    if (ctx->disp.program_string_ARB != hook_program_string) {
        real_program_string = ctx->disp.program_string_ARB;
        ctx->disp.program_string_ARB = hook_program_string;
    }
    if (ctx->disp.shader_source_ARB != hook_shader_source) {
        real_shader_source = ctx->disp.shader_source_ARB;
        ctx->disp.shader_source_ARB = hook_shader_source;
    }
}

static CGLError hook_create_context(CGLPixelFormatObj pix, CGLContextObj share, CGLContextObj *ctx) {
    CGLError e = CGLCreateContext(pix, share, ctx);
    if (e == kCGLNoError) patch(*ctx);
    return e;
}
DYLD_INTERPOSE(hook_create_context, CGLCreateContext)

static CGLError hook_set_current(CGLContextObj ctx) {
    patch(ctx);
    return CGLSetCurrentContext(ctx);
}
DYLD_INTERPOSE(hook_set_current, CGLSetCurrentContext)

static FILE *log_file(void) {
    static FILE *f;
    if (!f && getenv("GLHOOK_LOG")) f = fopen(getenv("GLHOOK_LOG"), "a");
    return f;
}

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static CGLError hook_set_parameter(CGLContextObj ctx, CGLContextParameter p, const GLint *v) {
    if (log_file()) {
        fprintf(log_file(), "%.0f CGLSetParameter %d = %d %d\n", now_ms(), p, v ? v[0] : 0,
                v && p == kCGLCPSurfaceBackingSize ? v[1] : 0);
        fflush(log_file());
    }
    return CGLSetParameter(ctx, p, v);
}
DYLD_INTERPOSE(hook_set_parameter, CGLSetParameter)

// The view's frame and bounds in points, the window's scale, and the GL surface's real size in
// pixels (private CGLGetSurface + CGSGetSurfaceBounds, looked up so a missing one is harmless).
static void surface_info(CGLContextObj ctx, char *out, size_t n) {
    id (*msg)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
    CGRect (*rect)(id, SEL) = (CGRect(*)(id, SEL))objc_msgSend_stret;
    id gl = msg((id)objc_getClass("NSOpenGLContext"), sel_registerName("currentContext"));
    id view = gl ? msg(gl, sel_registerName("view")) : nil;
    CGRect f = {0}, b = {0}, sb = {0};
    double scale = 0;
    int best = -1;
    if (view) {
        f = rect(view, sel_registerName("frame"));
        b = rect(view, sel_registerName("bounds"));
        best = ((BOOL(*)(id, SEL))objc_msgSend)(view, sel_registerName("wantsBestResolutionOpenGLSurface"));
        id win = msg(view, sel_registerName("window"));
        if (win) scale = ((double(*)(id, SEL))objc_msgSend)(win, sel_registerName("backingScaleFactor"));
    }
    int (*get_surface)(CGLContextObj, int *, int *, int *) = dlsym(RTLD_DEFAULT, "CGLGetSurface");
    int (*surface_bounds)(int, int, int, CGRect *) = dlsym(RTLD_DEFAULT, "CGSGetSurfaceBounds");
    int cid = 0, wid = 0, sid = 0;
    if (get_surface && surface_bounds && !get_surface(ctx, &cid, &wid, &sid) && sid) surface_bounds(cid, wid, sid, &sb);
    snprintf(out, n, "frame %.0fx%.0f bounds %.0fx%.0f scale %.1f best %d surface %.0fx%.0f",
             f.size.width, f.size.height, b.size.width, b.size.height, scale, best, sb.size.width, sb.size.height);
}

static CGLError hook_flush(CGLContextObj ctx) {
    static double last, window, worst, in_flush;
    static int frames;
    double t0 = now_ms();
    CGLError e = CGLFlushDrawable(ctx);
    double t1 = now_ms();
    if (!log_file()) return e;
    if (last) {
        worst = t1 - last > worst ? t1 - last : worst;
        in_flush += t1 - t0;
        frames++;
    }
    if (!window) window = t1;
    if (tracing()) fprintf(log_file(), "flush %d\n", flushes);
    flushes++;
    if (t1 - window >= 2000) {
        GLint swap = -1, size[2] = {0}, sized = -1, vp[4] = {0};
        CGLGetParameter(ctx, kCGLCPSwapInterval, &swap);
        CGLIsEnabled(ctx, kCGLCESurfaceBackingSize, &sized);
        CGLGetParameter(ctx, kCGLCPSurfaceBackingSize, size);
        char info[256];
        ctx->disp.get_integerv(ctx->rend, GL_VIEWPORT, vp);
        surface_info(ctx, info, sizeof info);
        fprintf(log_file(), "%.0f fps %.1f worst %.1fms in-flush %.1fms swap %d backing %s %dx%d viewport %dx%d %s\n",
                t1, frames * 1000 / (t1 - window), worst, in_flush / (frames ? frames : 1), swap,
                sized ? "on" : "off", size[0], size[1], vp[2], vp[3], info);
        fflush(log_file());
        window = t1, worst = 0, in_flush = 0, frames = 0;
    }
    last = t1;
    return e;
}
DYLD_INTERPOSE(hook_flush, CGLFlushDrawable)

