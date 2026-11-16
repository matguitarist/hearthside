// What glhook's own passes share: programs, the full-screen quad, render targets, and post_world,
// which sets the client's state aside, copies the world's depth once and runs AO and the mist.
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <stdio.h>
#include <stdlib.h>

#include "post.h"

static const char *vertex_src =
    "#version 120\n"
    "void main() { gl_Position = gl_Vertex; }\n";

unsigned post_program(const char *name, const char *fragment_src) {
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
        fprintf(stderr, "glhook: %s shaders failed\n", name);
        return 0;
    }
    return p;
}

void post_quad(void) {
    glBegin(GL_TRIANGLE_STRIP);
    glVertex2f(-1, -1), glVertex2f(1, -1), glVertex2f(-1, 1), glVertex2f(1, 1);
    glEnd();
}

static void nearest(void) {
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
}

int post_target(unsigned *tex, unsigned *fbo, unsigned internal, int w, int h) {
    if (!*tex) glGenTextures(1, tex), glGenFramebuffersEXT(1, fbo);
    glBindTexture(GL_TEXTURE_2D, *tex);
    glTexImage2D(GL_TEXTURE_2D, 0, internal, w, h, 0, GL_RGBA, internal == GL_RGBA8 ? GL_UNSIGNED_BYTE : GL_FLOAT, NULL);
    nearest();
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, *fbo);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, *tex, 0);
    return glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT) == GL_FRAMEBUFFER_COMPLETE_EXT;
}

float post_env(const char *name, float fallback) {
    const char *v = getenv(name);
    return v ? strtof(v, NULL) : fallback;
}

// The world's depth as a texture: the client's renderbuffer may be multisampled and cannot be
// sampled, so it is blitted (one sample of each pixel) into a texture of the same format.
static GLuint copy_depth(const struct view *v) {
    static GLuint source_fbo, depth_fbo, depth_tex, source_rb;
    static int failed, tw, th;
    static CGLContextObj owner;
    if (CGLGetCurrentContext() != owner) {
        owner = CGLGetCurrentContext();
        source_fbo = depth_fbo = depth_tex = source_rb = 0;
        failed = tw = th = 0;
    }
    if (failed) return 0;
    if (v->w != tw || v->h != th) {
        if (!depth_tex) glGenTextures(1, &depth_tex), glGenFramebuffersEXT(1, &source_fbo), glGenFramebuffersEXT(1, &depth_fbo);
        glBindTexture(GL_TEXTURE_2D, depth_tex);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH24_STENCIL8_EXT, v->w, v->h, 0, GL_DEPTH_STENCIL_EXT, GL_UNSIGNED_INT_24_8_EXT, NULL);
        nearest();
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
        glTexParameteri(GL_TEXTURE_2D, GL_DEPTH_TEXTURE_MODE, GL_LUMINANCE);
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, depth_fbo);
        glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_TEXTURE_2D, depth_tex, 0);
        glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_STENCIL_ATTACHMENT_EXT, GL_TEXTURE_2D, depth_tex, 0);
        glDrawBuffer(GL_NONE), glReadBuffer(GL_NONE);
        GLenum status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
        fprintf(stderr, "glhook: world depth %dx%d, framebuffer %x, error %x\n", v->w, v->h, status, glGetError());
        if (status != GL_FRAMEBUFFER_COMPLETE_EXT) return failed = 1, 0;
        tw = v->w, th = v->h;
    }
    if (source_rb != v->depth_rb) {
        glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, source_fbo);
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_DEPTH_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, v->depth_rb);
        glFramebufferRenderbufferEXT(GL_FRAMEBUFFER_EXT, GL_STENCIL_ATTACHMENT_EXT, GL_RENDERBUFFER_EXT, v->depth_rb);
        glDrawBuffer(GL_NONE), glReadBuffer(GL_NONE);
        GLenum status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
        if (status != GL_FRAMEBUFFER_COMPLETE_EXT) {
            fprintf(stderr, "glhook: cannot read depth renderbuffer %u: %x\n", v->depth_rb, status);
            return failed = 1, 0;
        }
        source_rb = v->depth_rb;
    }
    glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, source_fbo);
    glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, depth_fbo);
    glBlitFramebufferEXT(0, 0, v->w, v->h, 0, 0, v->w, v->h, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
    return depth_tex;
}

int post_world(const struct view *v, int ao, int atmos, int fog) {
    if (v->w <= 0 || v->h <= 0 || (!ao && !atmos)) return 0;
    GLint read_fbo, draw_fbo, prog, active, unpack;
    glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING_EXT, &read_fbo);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING_EXT, &draw_fbo);
    glGetIntegerv(GL_CURRENT_PROGRAM, &prog);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &active);
    glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &unpack);
    glPushAttrib(GL_ALL_ATTRIB_BITS);
    glPushClientAttrib(GL_CLIENT_ALL_ATTRIB_BITS);
    // As in fsr.c: no pixel buffer and no client storage behind new textures.
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, 0);
    glPixelStorei(GL_UNPACK_CLIENT_STORAGE_APPLE, GL_FALSE);
    glActiveTexture(GL_TEXTURE0);

    int drawn = 0;
    GLuint depth = copy_depth(v);
    if (depth) {
        GLenum off[] = {GL_BLEND, GL_DEPTH_TEST, GL_SCISSOR_TEST, GL_CULL_FACE, GL_ALPHA_TEST, GL_STENCIL_TEST,
                        GL_VERTEX_PROGRAM_ARB, GL_FRAGMENT_PROGRAM_ARB, GL_FRAMEBUFFER_SRGB_EXT};
        for (unsigned i = 0; i < sizeof off / sizeof *off; i++) glDisable(off[i]);
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
        glDepthMask(GL_FALSE);
        // "show" draws one effect alone, so the other stays off.
        if (ao && atmos != 2) drawn |= ao_pass(v, depth, ao == 2);
        if (atmos && ao != 2 && v->oriented) drawn |= atmos_pass(v, depth, atmos == 2, fog);
    }

    glUseProgram(prog);
    glPopClientAttrib();
    glPopAttrib();
    glActiveTexture(active);
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER, unpack);
    glBindFramebufferEXT(GL_READ_FRAMEBUFFER_EXT, read_fbo);
    glBindFramebufferEXT(GL_DRAW_FRAMEBUFFER_EXT, draw_fbo);
    return drawn;
}
