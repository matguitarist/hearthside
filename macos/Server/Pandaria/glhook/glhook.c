// Fixes for the 5.4.8 client on Apple's OpenGL, loaded at launch: `mac-client-setup` points the
// client's dead libcrypto.0.9.8 import at it. The client calls OpenGL through each context's
// dispatch table (CGLMacro.h), so entries of that table are replaced as contexts are created or
// made current.
// GLHOOK_DUMP=<dir>: write every program and shader string the client compiles to <dir>.
// GLHOOK_LOG=<file>: surface parameters and frame timing, every two seconds.
// GLHOOK_FSR=0: keep the client's own linear stretch instead of FSR 1 (fsr.c);
// GLHOOK_SHARPNESS=<stops>: RCAS sharpening, 0 the most, each 1 halves it (default 0.2);
// GLHOOK_FSR_SCALE=<x>: output size as a multiple of the frame (default 1.5, 0 the whole surface).
// GLHOOK_SHOT=<dir>: captures on request, see shot().
// GLHOOK_AO=0: no ambient occlusion (ao.c); GLHOOK_AO=show: the occlusion alone.
// GLHOOK_ATMOS=0: no ground mist (atmos.c); GLHOOK_ATMOS=show: the mist alone.
// GLHOOK_FOG=<1-5>: the mist's level, Low to Ultra (default 4, High).
// GLHOOK_TRACE_FILES=1: log the AzerothPlus files the client opens (see requested).
// In the game, Control-Option-O and Control-Option-M cycle each: on, off, alone; Control-Option-F
// steps the fog level (see watch_keys). AzerothPlus's Graphics tab sets them too (see requested).
#include "post.h"
#include <OpenGL/CGLContext.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <dlfcn.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_time.h>
#include <CoreGraphics/CGGeometry.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <pthread.h>
#include <fcntl.h>
#include <stdarg.h>

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

// The colour and depth attachments of the bound draw framebuffer, kept while AO is on (glhook
// cannot tell the world's framebuffer by its name: the client re-attaches its framebuffers).
struct attachment { GLint type, name; };
static struct attachment draw_color, draw_depth;

static struct attachment attached(GLenum target, GLenum point) {
    struct attachment a = {0, 0};
    glGetFramebufferAttachmentParameterivEXT(target, point, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE_EXT, &a.type);
    if (a.type) glGetFramebufferAttachmentParameterivEXT(target, point, GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME_EXT, &a.name);
    return a;
}

// GLHOOK_AO and GLHOOK_ATMOS: 0 off, 1 on (the default), "show" the effect alone (2). With
// GLHOOK_SHOT, the files <GLHOOK_SHOT>/ao-mode and atmos-mode override them while the game runs,
// read every half second or so. GLHOOK_FOG and the file fog-level hold the mist's level, 1 to 5.
static int ao_mode = -1, atmos_mode = -1, fog_level = -1;
static const char *fog_names[] = {"", "low", "fair", "good", "high", "ultra"};

static int parse_mode(const char *v) { return !v ? 1 : !strcmp(v, "0") ? 0 : !strcmp(v, "show") ? 2 : 1; }

static int parse_level(const char *v) {
    int l = v ? atoi(v) : 4;
    return l < 1 || l > 5 ? 4 : l;
}

static void read_mode(int *mode, const char *var, const char *file) {
    int (*parse)(const char *) = mode == &fog_level ? parse_level : parse_mode;
    if (*mode < 0) *mode = parse(getenv(var));
    const char *dir = getenv("GLHOOK_SHOT");
    if (!dir || flushes % 30) return;
    char path[1024], v[16] = "";
    snprintf(path, sizeof path, "%s/%s", dir, file);
    FILE *f = fopen(path, "r");
    if (!f) return;
    if (fgets(v, sizeof v, f)) v[strcspn(v, "\n")] = 0, *mode = parse(v);
    fclose(f);
}

static void read_modes(void) {
    read_mode(&ao_mode, "GLHOOK_AO", "ao-mode");
    read_mode(&atmos_mode, "GLHOOK_ATMOS", "atmos-mode");
    read_mode(&fog_level, "GLHOOK_FOG", "fog-level");
}

// Control-Option-O (occlusion) and Control-Option-M (mist): on, then off, then the effect alone,
// then on again. Control-Option-F steps the fog level up, from Ultra back to Low, and turns the mist
// on if it was off. By the letter the layout types, so M is M on AZERTY too; the game never sees
// these presses. The client's GLApplication takes its keys in its own sendEvent:, before any
// AppKit event monitor, so that method is wrapped.
static int next_mode(int mode) { return mode == 1 ? 0 : mode == 0 ? 2 : 1; }

static void (*client_send_event)(id, SEL, id);

static void send_event(id app, SEL sel, id event) {
    // NSEventTypeKeyDown; Control and Option, without Shift or Command (NSEventModifierFlag*).
    if (((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("type")) == 10 &&
        (((unsigned long (*)(id, SEL))objc_msgSend)(event, sel_registerName("modifierFlags")) & 0x1e0000) == 0xc0000) {
        id chars = ((id(*)(id, SEL))objc_msgSend)(event, sel_registerName("charactersIgnoringModifiers"));
        const char *c = chars ? ((const char *(*)(id, SEL))objc_msgSend)(chars, sel_registerName("UTF8String")) : NULL;
        int *mode = !c ? NULL : !strcasecmp(c, "o") ? &ao_mode : !strcasecmp(c, "m") ? &atmos_mode : NULL;
        if (c && !strcasecmp(c, "f")) {
            if (fog_level < 0) read_modes();
            fog_level = fog_level % 5 + 1;
            if (!atmos_mode) atmos_mode = 1;
            fprintf(stderr, "glhook: fog %s\n", fog_names[fog_level]);
            return;
        }
        if (mode) {
            if (*mode < 0) read_modes();
            *mode = next_mode(*mode);
            fprintf(stderr, "glhook: %s %s\n", mode == &ao_mode ? "ambient occlusion" : "ground mist",
                    *mode == 0 ? "off" : *mode == 2 ? "alone" : "on");
            return;
        }
    }
    client_send_event(app, sel, event);
}

// AzerothPlus's Graphics tab asks by showing one of its images, AzerothPlus/glhook/<ao|mist|fog>-
// <value>.blp, 1x1 and clear: the client opens the file to load it, and glhook sees the name. It
// opens a file again each time a texture changes to it, so the tab clears the texture first; it
// never opens a file missing from the list of the addon's files it makes at startup, so the images
// ship with the addon. GLHOOK_TRACE_FILES=1 logs every AzerothPlus file the client opens.
static void requested(const char *path) {
    if (path && getenv("GLHOOK_TRACE_FILES") && strcasestr(path, "azerothplus")) fprintf(stderr, "glhook: open %s\n", path);
    const char *at = path ? strcasestr(path, "azerothplus/glhook/") : NULL;
    if (!at) return;
    char what[8] = "";
    int value;
    if (sscanf(at + 19, "%7[a-zA-Z]-%d", what, &value) != 2) return;
    if (ao_mode < 0) read_modes();
    if (!strcasecmp(what, "ao") && value >= 0 && value <= 2) ao_mode = value;
    else if (!strcasecmp(what, "mist") && value >= 0 && value <= 2) atmos_mode = value;
    else if (!strcasecmp(what, "fog") && value >= 1 && value <= 5) fog_level = value;
    else return;
    fprintf(stderr, "glhook: AzerothPlus set %s to %d\n", what, value);
}

static int hook_open(const char *path, int flags, ...) {
    mode_t mode = 0;
    if (flags & O_CREAT) {
        va_list args;
        va_start(args, flags);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    requested(path);
    return open(path, flags, mode);
}

static FILE *hook_fopen(const char *path, const char *mode) {
    requested(path);
    return fopen(path, mode);
}

// The client's calls come here; glhook's own reach the real functions.
DYLD_INTERPOSE(hook_open, open)
DYLD_INTERPOSE(hook_fopen, fopen)

static void watch_keys(void *unused) {
    (void)unused;
    id app = ((id(*)(id, SEL))objc_msgSend)((id)objc_getClass("NSApplication"), sel_registerName("sharedApplication"));
    Method m = app ? class_getInstanceMethod(object_getClass(app), sel_registerName("sendEvent:")) : NULL;
    if (m && !client_send_event) client_send_event = (void (*)(id, SEL, id))method_setImplementation(m, (IMP)send_event);
}

// Whether the world's passes are wanted, and so the frame watched.
static int post_on(void) {
    if (ao_mode < 0) read_modes();
    return ao_mode > 0 || atmos_mode > 0;
}

typedef void (*BindFramebuffer)(GLIContext, GLenum, GLuint);
static BindFramebuffer real_bind_framebuffer;
static void hook_bind_framebuffer(GLIContext ctx, GLenum target, GLuint fbo) {
    real_bind_framebuffer(ctx, target, fbo);
    if (target == GL_READ_FRAMEBUFFER_EXT) return;
    draw_fbo = fbo;
    if (!post_on() && !tracing()) return;
    draw_color = draw_depth = (struct attachment){0, 0};
    if (fbo) {
        draw_color = attached(GL_DRAW_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT);
        draw_depth = attached(GL_DRAW_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT);
    }
    if (tracing()) {
        GLint fmt = 0, mode = 0, cmp = 0, tex = 0;
        if (draw_depth.type == GL_TEXTURE) {
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &tex);
            glBindTexture(GL_TEXTURE_2D, draw_depth.name);
            glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_INTERNAL_FORMAT, &fmt);
            glGetTexParameteriv(GL_TEXTURE_2D, GL_DEPTH_TEXTURE_MODE, &mode);
            glGetTexParameteriv(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, &cmp);
            glBindTexture(GL_TEXTURE_2D, tex);
        }
        fprintf(log_file(), "bind fbo %u: color %x/%d depth %x/%d (format %x mode %x compare %x)\n", fbo, draw_color.type,
                draw_color.name, draw_depth.type, draw_depth.name, fmt, mode, cmp);
    }
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

// The programs' environment as the client sets it. While the world is drawn, vertex env[0..3] is
// its projection, by rows (the view is in each batch's own matrices), except for the sky, whose
// env[0..3] is a view-projection by columns, the camera at the origin.
static GLfloat vp_env[256][4], fp_env[256][4];

// The frame's world as the client drew it (post.h). The projection is the last perspective set
// while a framebuffer with a depth renderbuffer was bound (the camera's; shadow maps are
// orthographic, reflections render to textures). The client draws the world in the depth range
// [0, 0.94] and its horizon and sky in slices above, so only a range from 0 counts; the login
// screen sets none. The light comes from its fragment programs' environment, as its terrain sets
// it first after the projection: env[2] the fog colour, env[3] the ambient and env[5] the sun's
// colour, env[4] the direction the sunlight travels in view axes (x right, y up, z ahead); env[27]
// is the camera's position.
static struct {
    int frame, done, range_frame, axes_frame, light_frame, cam_frame;
    int have_fog, have_sun, have_ambient, have_dir;
    struct attachment depth;
    float a, b, fx, fy, range;
    float right[3], up[3], forward[3], cam[3], fog[3], sun[3], ambient[3], dir[3];
} world = {-1, -1, -1, -1, -1, -1};

typedef void (*DepthRange)(GLIContext, GLclampd, GLclampd);
static DepthRange real_depth_range;
static void hook_depth_range(GLIContext ctx, GLclampd n, GLclampd f) {
    if (tracing()) fprintf(log_file(), "depth range fbo %u %g %g\n", draw_fbo, n, f);
    if (post_on() && n == 0 && f > 0 && draw_depth.type == GL_RENDERBUFFER_EXT) world.range = f, world.range_frame = flushes;
    real_depth_range(ctx, n, f);
}

static float norm3(float *v) {
    float l = sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l > 0) v[0] /= l, v[1] /= l, v[2] /= l;
    return l;
}

static void world_projection(void) {
    const GLfloat(*m)[4] = vp_env;
    if (draw_depth.type != GL_RENDERBUFFER_EXT) return;
    float s = m[3][2];
    // The sky's view-projection: columns x, y, z of the camera-relative world, then (0, 0, b, 0).
    if (world.frame == flushes && !m[3][0] && !m[3][1] && !m[3][3] && s == world.b) {
        for (int i = 0; i < 3; i++) world.right[i] = m[i][0], world.up[i] = m[i][1], world.forward[i] = m[i][3];
        if (norm3(world.right) > 0 && norm3(world.up) > 0 && norm3(world.forward) > 0) world.axes_frame = flushes;
        return;
    }
    if ((s != 1 && s != -1) || m[3][0] || m[3][1] || m[3][3] || m[0][1] || m[0][2] || m[1][0] || m[1][2] ||
        m[2][0] || m[2][1] || m[0][0] <= 0 || m[1][1] <= 0)
        return;
    if (world.frame != flushes) world.light_frame = flushes, world.have_fog = world.have_sun = world.have_ambient = world.have_dir = 0;
    world.frame = flushes;
    world.depth = draw_depth;
    // clip z = A zv + B with w = s zv, so for the distance t = s zv: ndc = s A + B / t.
    world.a = s * m[2][2], world.b = m[2][3];
    world.fx = m[0][0], world.fy = m[1][1];
}

// The terrain's light, the first of the frame after the projection (later batches set their own).
// The camera's position is set before the projection, in another pass, and kept: the last one counts.
static void world_light(GLuint index, const GLfloat *v) {
    if (index == 27 && v[3] == 1 && fabsf(v[0]) < 1e6f) memcpy(world.cam, v, sizeof world.cam), world.cam_frame = flushes;
    if (world.light_frame != flushes || draw_depth.type != GL_RENDERBUFFER_EXT) return;
    // The first values of env[3..5] are placeholders with w 1.
    if (index == 2 && !world.have_fog) memcpy(world.fog, v, sizeof world.fog), world.have_fog = 1;
    if (index == 3 && !world.have_ambient && v[3] == 0) memcpy(world.ambient, v, sizeof world.ambient), world.have_ambient = 1;
    if (index == 4 && !world.have_dir && v[3] == 0) memcpy(world.dir, v, sizeof world.dir), world.have_dir = 1;
    if (index == 5 && !world.have_sun && v[3] == 0) memcpy(world.sun, v, sizeof world.sun), world.have_sun = 1;
}

// The colour buffer the window shows: the FSR blit's source, followed back through the frame's
// copies into it (the client draws into one renderbuffer and copies it out). The first copy out of
// it in a frame comes after the world and before the bloom and the interface: AO and the mist go
// there. The client's other targets with the same depth, such as its normal prepass for SSAO, are
// left alone.
static struct attachment display;
static struct { struct attachment from, to; } copies[32];
static int copy_count, copy_frame = -1;

static int same(struct attachment a, struct attachment b) { return a.type == b.type && a.name == b.name; }

static void world_blit(GLint read_fbo) {
    struct attachment from = attached(GL_READ_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT);
    if (copy_frame != flushes) copy_count = 0, copy_frame = flushes;
    if (draw_fbo == 0) {
        display = from;
        for (int i = copy_count - 1; i >= 0; i--)
            if (same(copies[i].to, display)) display = copies[i].from;
        return;
    }
    if (copy_count < 32) copies[copy_count].from = from, copies[copy_count++].to = draw_color;
    if (!display.type || !same(from, display) || world.frame != flushes || world.done == flushes) return;
    world.done = flushes;

    struct view v = {.color_fbo = read_fbo, .depth_rb = world.depth.name, .a = world.a, .b = world.b,
                     .fx = world.fx, .fy = world.fy, .range = world.range_frame == flushes ? world.range : 1};
    GLint rb;
    glGetIntegerv(GL_RENDERBUFFER_BINDING_EXT, &rb);
    glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, world.depth.name);
    glGetRenderbufferParameterivEXT(GL_RENDERBUFFER_EXT, GL_RENDERBUFFER_WIDTH_EXT, &v.w);
    glGetRenderbufferParameterivEXT(GL_RENDERBUFFER_EXT, GL_RENDERBUFFER_HEIGHT_EXT, &v.h);
    glBindRenderbufferEXT(GL_RENDERBUFFER_EXT, rb);
    v.oriented = world.axes_frame == flushes && world.cam_frame >= 0 && world.have_fog;
    if (v.oriented) {
        memcpy(v.right, world.right, sizeof v.right), memcpy(v.up, world.up, sizeof v.up);
        memcpy(v.forward, world.forward, sizeof v.forward), memcpy(v.cam, world.cam, sizeof v.cam);
        memcpy(v.fog, world.fog, sizeof v.fog);
    }
    v.lit = v.oriented && world.have_dir && world.have_sun;
    if (v.lit) {
        // Toward the sun, in the world: the light's view direction turned back by the camera's axes.
        for (int i = 0; i < 3; i++)
            v.to_sun[i] = -(world.right[i] * world.dir[0] + world.up[i] * world.dir[1] + world.forward[i] * world.dir[2]);
        norm3(v.to_sun);
        memcpy(v.sun, world.sun, sizeof v.sun);
        memcpy(v.ambient, world.ambient, sizeof v.ambient);
    }
    if (tracing())
        fprintf(log_file(), "world into fbo %d (color %x/%d, depth %d, %dx%d) a %g b %g fx %g fy %g range %g "
                "oriented %d forward %g %g %g cam %g %g %g fog %g %g %g lit %d to sun %g %g %g sun %g %g %g\n",
                read_fbo, from.type, from.name, v.depth_rb, v.w, v.h, v.a, v.b, v.fx, v.fy, v.range, v.oriented,
                v.forward[0], v.forward[1], v.forward[2], v.cam[0], v.cam[1], v.cam[2], v.fog[0], v.fog[1], v.fog[2],
                v.lit, v.to_sun[0], v.to_sun[1], v.to_sun[2], v.sun[0], v.sun[1], v.sun[2]);
    GLuint saved_draw = draw_fbo;
    post_world(&v, ao_mode, atmos_mode, fog_level);
    draw_fbo = saved_draw;
}

// The read framebuffer's rectangle as <GLHOOK_SHOT>/<kind>.ppm, when <GLHOOK_SHOT>/<kind> exists
// (it is removed): "world" is the frame before the interface, "screen" the window as shown.
static void shot(const char *kind, int x, int y, int w, int h) {
    const char *dir = getenv("GLHOOK_SHOT");
    char path[1024];
    snprintf(path, sizeof path, "%s/%s", dir ? dir : "", kind);
    if (!dir || w <= 0 || h <= 0 || unlink(path)) return;
    unsigned char *px = malloc((size_t)w * h * 3);
    GLint pack;
    glGetIntegerv(GL_PIXEL_PACK_BUFFER_BINDING, &pack);
    glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
    glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(x, y, w, h, GL_RGB, GL_UNSIGNED_BYTE, px);
    glPopClientAttrib();
    glBindBuffer(GL_PIXEL_PACK_BUFFER, pack);
    strlcat(path, ".ppm", sizeof path);
    FILE *f = fopen(path, "wb");
    if (f) {
        fprintf(f, "P6 %d %d 255\n", w, h);
        for (int row = h - 1; row >= 0; row--) fwrite(px + (size_t)row * w * 3, 1, (size_t)w * 3, f);
        fclose(f);
    }
    free(px);
}

typedef void (*Blit)(GLIContext, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLint, GLbitfield, GLenum);
static Blit real_blit;
static void hook_blit(GLIContext ctx, GLint sx0, GLint sy0, GLint sx1, GLint sy1, GLint dx0, GLint dy0,
                      GLint dx1, GLint dy1, GLbitfield mask, GLenum filter) {
    GLint read_fbo = 0;
    if (tracing() || post_on()) glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read_fbo);
    if (tracing()) {
        fprintf(log_file(), "blit to fbo %u %d,%d-%d,%d from fbo %d %d,%d-%d,%d mask %x filter %x\n", draw_fbo,
                dx0, dy0, dx1, dy1, read_fbo, sx0, sy0, sx1, sy1, mask, filter);
    }
    if (post_on() && (mask & GL_COLOR_BUFFER_BIT) && read_fbo) world_blit(read_fbo);
    if (draw_fbo == 0 && mask == GL_COLOR_BUFFER_BIT && getenv("GLHOOK_SHOT")) shot("world", sx0, sy0, sx1 - sx0, sy1 - sy0);
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


static void env_set(GLenum target, GLuint index, GLsizei count, const GLfloat *v) {
    GLfloat (*env)[4] = target == GL_VERTEX_PROGRAM_ARB ? vp_env : fp_env;
    if (index + count > 256) return;
    memcpy(env[index], v, count * 4 * sizeof(GLfloat));
    if (post_on() && target == GL_VERTEX_PROGRAM_ARB && index <= 3 && index + count > 3) world_projection();
    if (post_on() && target == GL_FRAGMENT_PROGRAM_ARB)
        for (GLsizei i = 0; i < count; i++) world_light(index + i, v + i * 4);
    if (tracing())
        for (GLsizei i = 0; i < count; i++)
            fprintf(log_file(), "env %s[%u] fbo %u = %g %g %g %g\n", target == GL_VERTEX_PROGRAM_ARB ? "vp" : "fp",
                    index + i, draw_fbo, v[i * 4], v[i * 4 + 1], v[i * 4 + 2], v[i * 4 + 3]);
}

typedef void (*EnvParameter4fv)(GLIContext, GLenum, GLuint, const GLfloat *);
static EnvParameter4fv real_env4fv;
static void hook_env4fv(GLIContext ctx, GLenum target, GLuint index, const GLfloat *v) {
    env_set(target, index, 1, v);
    real_env4fv(ctx, target, index, v);
}

typedef void (*EnvParameter4f)(GLIContext, GLenum, GLuint, GLfloat, GLfloat, GLfloat, GLfloat);
static EnvParameter4f real_env4f;
static void hook_env4f(GLIContext ctx, GLenum target, GLuint index, GLfloat x, GLfloat y, GLfloat z, GLfloat w) {
    GLfloat v[4] = {x, y, z, w};
    env_set(target, index, 1, v);
    real_env4f(ctx, target, index, x, y, z, w);
}

typedef void (*EnvParameters4fv)(GLIContext, GLenum, GLuint, GLsizei, const GLfloat *);
static EnvParameters4fv real_envs4fv;
static void hook_envs4fv(GLIContext ctx, GLenum target, GLuint index, GLsizei count, const GLfloat *v) {
    env_set(target, index, count, v);
    real_envs4fv(ctx, target, index, count, v);
}

static void patch(CGLContextObj ctx) {
    if (!ctx) return;
    if (ctx->disp.depth_range != hook_depth_range) {
        real_depth_range = ctx->disp.depth_range;
        ctx->disp.depth_range = hook_depth_range;
    }
    if (ctx->disp.depth_range != hook_depth_range) {
        real_depth_range = ctx->disp.depth_range;
        ctx->disp.depth_range = hook_depth_range;
    }
    if (ctx->disp.program_env_parameter4fv_ARB != hook_env4fv) {
        real_env4fv = ctx->disp.program_env_parameter4fv_ARB;
        ctx->disp.program_env_parameter4fv_ARB = hook_env4fv;
    }
    if (ctx->disp.program_env_parameter4f_ARB != hook_env4f) {
        real_env4f = ctx->disp.program_env_parameter4f_ARB;
        ctx->disp.program_env_parameter4f_ARB = hook_env4f;
    }
    if (ctx->disp.program_env_parameters4fv_EXT != hook_envs4fv) {
        real_envs4fv = ctx->disp.program_env_parameters4fv_EXT;
        ctx->disp.program_env_parameters4fv_EXT = hook_envs4fv;
    }
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

// A window larger than its screen, shrunk to the screen's visible area. Started from the launcher,
// which hides as the client opens, the client maximizes to the largest size it knows (6016x3384)
// instead of the screen's, and the screen shows only a corner of the game. A fullscreen window
// is the screen's size, never larger, so it is left alone. On the main thread, as AppKit wants.
static void fit_window(void *win) {
    id (*msg)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
    CGRect (*rect)(id, SEL) = (CGRect(*)(id, SEL))objc_msgSend_stret;
    id screen = msg((id)win, sel_registerName("screen"));
    if (!screen) screen = msg((id)objc_getClass("NSScreen"), sel_registerName("mainScreen"));
    if (!screen) return;
    CGRect f = rect((id)win, sel_registerName("frame")), s = rect(screen, sel_registerName("frame"));
    if (f.size.width <= s.size.width + 1 && f.size.height <= s.size.height + 1) return;
    CGRect fit = rect(screen, sel_registerName("visibleFrame"));
    ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)((id)win, sel_registerName("setFrame:display:"), fit, YES);
    fprintf(stderr, "glhook: window %.0fx%.0f fitted to the screen, %.0fx%.0f\n", f.size.width, f.size.height,
            fit.size.width, fit.size.height);
}

// Twice a second, the window of the context being drawn, checked by fit_window.
static void check_window(void) {
    static double next;
    if (now_ms() < next) return;
    next = now_ms() + 500;
    id (*msg)(id, SEL) = (id(*)(id, SEL))objc_msgSend;
    id gl = msg((id)objc_getClass("NSOpenGLContext"), sel_registerName("currentContext"));
    id view = gl ? msg(gl, sel_registerName("view")) : nil;
    id win = view ? msg(view, sel_registerName("window")) : nil;
    if (!win) return;
    if (pthread_main_np()) fit_window(win);
    else dispatch_async_f(dispatch_get_main_queue(), win, fit_window);
}

static CGLError hook_flush(CGLContextObj ctx) {
    static int keys;
    if (!keys) keys = 1, dispatch_async_f(dispatch_get_main_queue(), NULL, watch_keys);
    read_modes();
    check_window();
    static double last, window, worst, in_flush;
    static int frames;
    if (getenv("GLHOOK_SHOT")) {
        GLint vp[4], fbo;
        glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &fbo);
        glGetIntegerv(GL_VIEWPORT, vp);
        if (!fbo) {
            glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, 0);
            shot("screen", vp[0], vp[1], vp[2], vp[3]);
        }
    }
    double t0 = now_ms();
    CGLError e = CGLFlushDrawable(ctx);
    double t1 = now_ms();
    if (!log_file()) {
        flushes++;
        return e;
    }
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

