// Ambient occlusion for the 5.4.8 client, the Survivors pass (crates/benilla-app/src/shaders/
// survivors_ao.wgsl) in GLSL 1.20. glhook.c calls it at the first copy out of the buffer the
// window shows, once the terrain, buildings and foliage are drawn and before the characters, the
// bloom and the interface (post.c copies the depth): `ao_src` rebuilds positions and normals from
// the depth at half resolution and asks a spiral of taps how much of each pixel's upper hemisphere
// they close, and `apply_src` upsamples that with depth-aware weights and multiplies it into the
// colour.
// Unlike Survivors' it lands after the fog, so it fades out well before the fog thickens (from
// 40% of GLHOOK_AO_FADE to all of it), or distant hills turn into dark shapes in the haze.
// GLHOOK_AO=show draws the occlusion alone (glhook.c); GLHOOK_AO_STRENGTH (default 0.7),
// GLHOOK_AO_RADIUS (yards, default 3) and GLHOOK_AO_FADE (yards, default 100) tune it.
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <stdio.h>

#include "post.h"

#define COMMON POST_DEPTH_GLSL "uniform vec4 tune;\n"

static const char *ao_src =
    COMMON
    "vec3 view_pos(vec2 p) {\n"
    "  p = clamp(p, vec2(0.0), size - 1.0);\n"
    "  float z = distance_of(depth_at(p));\n"
    "  vec2 ndc = (p + 0.5) / size * 2.0 - 1.0;\n"
    "  return vec3(ndc.x * z / proj.z, ndc.y * z / proj.w, z);\n"
    "}\n"
    // Jimenez's interleaved gradient noise: a different spiral rotation per pixel that the
    // upsample's blur averages out.
    "float ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }\n"
    "void main() {\n"
    // Half resolution: this pixel stands for the 2x2 block at `p`.
    "  vec2 p = floor(gl_FragCoord.xy) * 2.0;\n"
    "  if (depth_at(p) >= 1.0) { gl_FragColor = vec4(1.0); return; }\n"
    "  vec3 pos = view_pos(p);\n"
    "  float fade = 1.0 - smoothstep(tune.z, tune.w, pos.z);\n"
    "  float radius = tune.x;\n"
    "  float reach = radius * proj.w * 0.5 * size.y / pos.z;\n"
    "  if (fade <= 0.0 || reach < 1.5) { gl_FragColor = vec4(1.0); return; }\n"
    // The normal from the neighbours on the nearer side of each axis, so a silhouette edge does
    // not tilt it toward the background.
    "  vec3 l = view_pos(p - vec2(1.0, 0.0)), r = view_pos(p + vec2(1.0, 0.0));\n"
    "  vec3 d = view_pos(p - vec2(0.0, 1.0)), u = view_pos(p + vec2(0.0, 1.0));\n"
    "  vec3 dx = abs(l.z - pos.z) < abs(r.z - pos.z) ? pos - l : r - pos;\n"
    "  vec3 dy = abs(d.z - pos.z) < abs(u.z - pos.z) ? pos - d : u - pos;\n"
    "  vec3 n = normalize(cross(dx, dy));\n"
    "  if (dot(n, pos) > 0.0) n = -n;\n"
    // At most this many pixels: near the camera the radius would cover half the screen.
    "  float reach_px = min(reach, 160.0);\n"
    "  float noise = ign(gl_FragCoord.xy);\n"
    "  float spin = noise * 6.2831853;\n"
    "  float closed = 0.0;\n"
    "  for (int i = 0; i < 16; i++) {\n"
    "    float t = (float(i) + fract(noise + 0.5)) / 16.0;\n"
    "    float angle = spin + float(i) * 2.39996323;\n"
    // Denser near the pixel, where occluders matter most.
    "    vec2 offset = vec2(cos(angle), sin(angle)) * reach_px * (0.1 + 0.9 * t * t);\n"
    "    vec3 v = view_pos(p + floor(offset + 0.5)) - pos;\n"
    "    float len2 = dot(v, v);\n"
    "    float cosine = dot(v, n) * inversesqrt(max(len2, 1e-6));\n"
    // The cosine to the tap above which it counts, so a flat ground's own depth error does not;
    // past the radius a tap stops counting.
    "    closed += max(0.0, cosine - 0.12) * max(0.0, 1.0 - len2 / (radius * radius));\n"
    "  }\n"
    // A tap at most closes a quarter of the hemisphere on its own; the gain makes a right-angled
    // crease read as fully closed.
    "  float occlusion = min(1.0, closed * 8.0 / 16.0);\n"
    "  gl_FragColor = vec4(1.0 - occlusion * tune.y * fade, 0.0, 0.0, 1.0);\n"
    "}\n";

static const char *apply_src =
    COMMON
    "uniform sampler2D visibility;\n"
    "uniform vec2 half_size;\n"
    "void main() {\n"
    "  vec2 p = floor(gl_FragCoord.xy);\n"
    "  float d = depth_at(p);\n"
    "  if (d >= 1.0) { gl_FragColor = vec4(1.0); return; }\n"
    "  float z = distance_of(d);\n"
    // The half-resolution texels around this pixel, each read at the depth it was computed at.
    "  vec2 h0 = floor(p * 0.5);\n"
    "  float sum = 0.0, weight = 0.0;\n"
    "  for (int y = -1; y <= 1; y++) {\n"
    "    for (int x = -1; x <= 1; x++) {\n"
    "      vec2 h = clamp(h0 + vec2(float(x), float(y)), vec2(0.0), half_size - 1.0);\n"
    // Taps on another surface (more than ~3% further or nearer) barely count.
    "      float dz = abs(distance_of(depth_at(h * 2.0)) - z) / (z * 0.03);\n"
    "      float w = exp(-dz * dz);\n"
    "      sum += texture2D(visibility, (h + 0.5) / half_size).r * w;\n"
    "      weight += w;\n"
    "    }\n"
    "  }\n"
    "  gl_FragColor = vec4(vec3(sum / max(weight, 1e-4)), 1.0);\n"
    "}\n";

int ao_pass(const struct view *v, unsigned depth_tex, int show) {
    static GLuint ao, apply, half_fbo, half_tex;
    static int failed, tw, th, tuned;
    static float radius, strength, fade;
    static CGLContextObj owner;
    if (CGLGetCurrentContext() != owner) {
        owner = CGLGetCurrentContext();
        ao = apply = half_fbo = half_tex = 0;
        failed = tw = th = 0;
    }
    if (!tuned) {
        tuned = 1;
        radius = post_env("GLHOOK_AO_RADIUS", 3.0f);
        strength = post_env("GLHOOK_AO_STRENGTH", 0.7f);
        fade = post_env("GLHOOK_AO_FADE", 100.0f);
    }
    if (failed) return 0;
    if (!ao && !(ao = post_program("AO", ao_src))) return failed = 1, 0;
    if (!apply && !(apply = post_program("AO", apply_src))) return failed = 1, 0;
    int w = v->w, h = v->h, hw = (w + 1) / 2, hh = (h + 1) / 2;
    if (w != tw || h != th) {
        if (!post_target(&half_tex, &half_fbo, GL_RGBA8, hw, hh)) {
            fprintf(stderr, "glhook: AO cannot draw at %dx%d\n", hw, hh);
            return failed = 1, 0;
        }
        tw = w, th = h;
    }

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, half_tex);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, depth_tex);

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, half_fbo);
    glViewport(0, 0, hw, hh);
    glUseProgram(ao);
    glUniform1i(glGetUniformLocation(ao, "depth"), 0);
    glUniform2f(glGetUniformLocation(ao, "size"), w, h);
    glUniform4f(glGetUniformLocation(ao, "proj"), v->a, v->b, v->fx, v->fy);
    glUniform4f(glGetUniformLocation(ao, "tune"), radius, strength, fade * 0.4f, fade);
    glUniform1f(glGetUniformLocation(ao, "range"), v->range);
    post_quad();

    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, v->color_fbo);
    glViewport(0, 0, w, h);
    if (!show) {
        // colour × visibility; the alpha stays.
        glEnable(GL_BLEND);
        glBlendFuncSeparate(GL_ZERO, GL_SRC_COLOR, GL_ZERO, GL_ONE);
    }
    glUseProgram(apply);
    glUniform1i(glGetUniformLocation(apply, "depth"), 0);
    glUniform1i(glGetUniformLocation(apply, "visibility"), 1);
    glUniform2f(glGetUniformLocation(apply, "size"), w, h);
    glUniform2f(glGetUniformLocation(apply, "half_size"), hw, hh);
    glUniform4f(glGetUniformLocation(apply, "proj"), v->a, v->b, v->fx, v->fy);
    glUniform1f(glGetUniformLocation(apply, "range"), v->range);
    post_quad();
    glDisable(GL_BLEND);
    return 1;
}
