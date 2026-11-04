// Ground mist lit by the sun for the 5.4.8 client, the Survivors pass (crates/benilla-app/src/
// shaders/survivors_atmos.wgsl) in GLSL 1.20, in the client's world: z is up. Run by post.c after
// the ambient occlusion. `ground_src` estimates the height of the ground the camera looks at, from
// the depth below the screen's middle, eased over about a second in a 1x1 target, where Survivors
// has the hero's feet. `atmos_src`, at half resolution, integrates an exponential height fog over
// that ground along each view ray, broken into drifting patches, and the sunlight it scatters
// toward the camera from samples of the air each tested toward the sun against the depth (a
// screen-space shadow ray), so canopies and walls cut it into beams. `apply_src` upsamples it with
// depth-aware weights and lays it over the colour. The fog colour, the sun and its colour are the
// client's own (glhook.c).
// GLHOOK_ATMOS=show draws the mist alone (glhook.c); GLHOOK_ATMOS_DENSITY (extinction per yard at
// the ground, default 0.025) and GLHOOK_ATMOS_SHAFTS (default 0.3) tune it.
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>

#include "post.h"

// The camera's axes and position in the world, to place a pixel: `rel_pos` is its offset from the
// camera at view distance t.
#define VIEW_GLSL \
    "uniform vec3 right, up, forward, cam;\n" \
    "vec3 rel_pos(vec2 p, float t) {\n" \
    "  vec2 ndc = (p + 0.5) / size * 2.0 - 1.0;\n" \
    "  return right * (ndc.x * t / proj.z) + up * (ndc.y * t / proj.w) + forward * t;\n" \
    "}\n"

static const char *ground_src =
    POST_DEPTH_GLSL VIEW_GLSL
    // 1 the first time: no easing from nothing.
    "uniform float first;\n"
    "void main() {\n"
    // The ground between the camera and the character, who stands near the screen's middle.
    "  float sum = 0.0, n = 0.0;\n"
    "  for (int i = 0; i < 5; i++) {\n"
    "    vec2 p = size * vec2(0.4 + 0.05 * float(i), 0.22 + 0.03 * float(i - 2) * float(i - 2));\n"
    "    float t = distance_of(depth_at(p));\n"
    "    if (t < 60.0) { sum += cam.z + rel_pos(p, t).z; n += 1.0; }\n"
    "  }\n"
    "  if (n == 0.0) gl_FragColor = first > 0.0 ? vec4(cam.z - 2.0, 0.0, 0.0, 1.0) : vec4(0.0);\n"
    "  else gl_FragColor = vec4(sum / n, 0.0, 0.0, first > 0.0 ? 1.0 : 0.05);\n"
    "}\n";

static const char *atmos_src =
    POST_DEPTH_GLSL VIEW_GLSL
    "uniform sampler2D ground_tex;\n"
    // xyz toward the sun, w the shafts' strength.
    "uniform vec4 sun;\n"
    // rgb the sun's colour, w the mist's extinction per yard at the ground.
    "uniform vec4 light;\n"
    // rgb the fog colour; x the e-folding height, y the noise's frequency per yard, zw the wind in
    // yards per second; the drift clock in seconds.
    "uniform vec3 mist;\n"
    "uniform vec4 shape;\n"
    "uniform float time;\n"
    // The farthest the mist is integrated to: past it, the zone's own fog has the scene.
    "const float FAR = 300.0;\n"
    // The air sampled for shafts: this many samples over the last SHAFT_SPAN yards before the
    // surface, each tested over SHADOW_SPAN yards toward the sun in SHADOW_STEPS steps; a surface is
    // taken to be THICKNESS yards thick.
    "const int SHAFT_SAMPLES = 8;\n"
    "const float SHAFT_SPAN = 30.0;\n"
    "const int SHADOW_STEPS = 6;\n"
    "const float SHADOW_SPAN = 24.0;\n"
    "const float THICKNESS = 8.0;\n"
    "float ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }\n"
    "float hash(vec2 p) {\n"
    "  vec2 q = fract(p * vec2(123.34, 456.21));\n"
    "  q += dot(q, q + 45.32);\n"
    "  return fract(q.x * q.y);\n"
    "}\n"
    "float value_noise(vec2 p) {\n"
    "  vec2 i = floor(p), f = fract(p);\n"
    "  vec2 u = f * f * (3.0 - 2.0 * f);\n"
    "  float a = hash(i), b = hash(i + vec2(1.0, 0.0)), c = hash(i + vec2(0.0, 1.0)), d = hash(i + vec2(1.0, 1.0));\n"
    "  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);\n"
    "}\n"
    // Three octaves, each drifting a little faster than the last, so the patches change shape as
    // they move instead of sliding as one sheet.
    "float mist_noise(vec2 xy) {\n"
    "  vec2 p = xy * shape.y;\n"
    "  float sum = 0.0, amp = 0.55;\n"
    "  for (int i = 0; i < 3; i++) {\n"
    "    sum += value_noise(p + shape.zw * time * shape.y * (1.0 + 0.6 * float(i))) * amp;\n"
    "    p = p * 2.03 + vec2(17.1, 9.7);\n"
    "    amp *= 0.5;\n"
    "  }\n"
    "  return sum / 0.9625;\n"
    "}\n"
    // The optical depth of the height fog from a to b: the integral of exp(-(z - ground) / k).
    "float height_fog(vec3 a, vec3 b, float ground) {\n"
    "  float k = shape.x;\n"
    // Hollows below the ground fill, but only so deep.
    "  float za = max(a.z - ground, -3.0 * k), zb = max(b.z - ground, -3.0 * k);\n"
    "  float len = distance(a, b), dz = zb - za;\n"
    "  if (abs(dz) < 1e-3) return len * exp(-za / k);\n"
    "  return len * k * (exp(-za / k) - exp(-zb / k)) / dz;\n"
    "}\n"
    // Whether the depth shows something between x (from the camera) and the sun, within SHADOW_SPAN.
    "float sunlit(vec3 x, float jitter) {\n"
    "  for (int j = 0; j < SHADOW_STEPS; j++) {\n"
    "    vec3 y = x + sun.xyz * (SHADOW_SPAN * (float(j) + jitter) / float(SHADOW_STEPS));\n"
    "    float vz = dot(y, forward);\n"
    "    if (vz <= 0.0) return 1.0;\n"
    "    vec2 uv = vec2(proj.z * dot(y, right), proj.w * dot(y, up)) / vz * 0.5 + 0.5;\n"
    // Off screen nothing is known: lit.
    "    if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) return 1.0;\n"
    "    float behind = vz - distance_of(depth_at(floor(uv * size)));\n"
    "    if (behind > 0.3 && behind < THICKNESS) return 0.0;\n"
    "  }\n"
    "  return 1.0;\n"
    "}\n"
    "void main() {\n"
    "  vec2 p = floor(gl_FragCoord.xy) * 2.0;\n"
    "  float ground = texture2D(ground_tex, vec2(0.5)).r;\n"
    "  float t = min(distance_of(depth_at(p)), FAR);\n"
    "  vec3 rel = rel_pos(p, t), pos = cam + rel;\n"
    "  float dist = length(rel);\n"
    "  vec3 dir = rel / max(dist, 1e-4);\n"
    "  float noise = ign(gl_FragCoord.xy);\n"
    // The mist, in patches: almost clear between them, a little thicker than the base inside.
    "  float patches = mix(0.05, 1.6, smoothstep(0.4, 0.8, mist_noise(pos.xy)));\n"
    "  float coverage = 1.0 - exp(-light.w * height_fog(cam, pos, ground) * patches);\n"
    // The shafts: how much of the mist along the last stretch before the surface the sun reaches,
    // weighted toward the ground where the mist is. They light the mist and add nothing where
    // there is none.
    "  float lit = 1.0;\n"
    "  float day = smoothstep(0.0, 0.15, sun.z);\n"
    "  if (sun.w > 0.0 && day > 0.0) {\n"
    "    float stride = min(dist, SHAFT_SPAN) / float(SHAFT_SAMPLES);\n"
    "    float k = shape.x * 2.0, reached = 0.0, total = 0.0;\n"
    "    for (int i = 0; i < SHAFT_SAMPLES; i++) {\n"
    "      vec3 x = rel - dir * (stride * (float(i) + noise));\n"
    "      float haze = exp(-max(cam.z + x.z - ground, 0.0) / k);\n"
    "      reached += sunlit(x, fract(noise + float(i) * 0.618)) * haze;\n"
    "      total += haze;\n"
    "    }\n"
    "    lit = reached / max(total, 1e-4);\n"
    "  }\n"
    // Forward scattering: brighter looking toward the sun.
    "  float toward = max(dot(dir, sun.xyz), 0.0);\n"
    "  float phase = 0.5 + 1.5 * toward * toward * toward * toward;\n"
    "  vec3 color = mist * mix(0.55, 1.0, lit * day) + light.rgb * sun.w * day * phase * lit;\n"
    "  gl_FragColor = vec4(color * coverage, coverage);\n"
    "}\n";

static const char *apply_src =
    POST_DEPTH_GLSL
    "uniform sampler2D atmos;\n"
    "uniform vec2 half_size;\n"
    "void main() {\n"
    "  vec2 p = floor(gl_FragCoord.xy);\n"
    "  float z = distance_of(depth_at(p));\n"
    "  vec2 h0 = floor(p * 0.5);\n"
    "  vec4 sum = vec4(0.0);\n"
    "  float weight = 0.0;\n"
    "  for (int y = -1; y <= 1; y++) {\n"
    "    for (int x = -1; x <= 1; x++) {\n"
    "      vec2 h = clamp(h0 + vec2(float(x), float(y)), vec2(0.0), half_size - 1.0);\n"
    "      float dz = abs(distance_of(depth_at(h * 2.0)) - z) / (z * 0.03);\n"
    "      float w = exp(-dz * dz) + 1e-4;\n"
    "      sum += texture2D(atmos, (h + 0.5) / half_size) * w;\n"
    "      weight += w;\n"
    "    }\n"
    "  }\n"
    "  gl_FragColor = sum / weight;\n"
    "}\n";

static void set_view(GLuint p, const struct view *v) {
    glUniform1i(glGetUniformLocation(p, "depth"), 0);
    glUniform2f(glGetUniformLocation(p, "size"), v->w, v->h);
    glUniform4f(glGetUniformLocation(p, "proj"), v->a, v->b, v->fx, v->fy);
    glUniform1f(glGetUniformLocation(p, "range"), v->range);
    glUniform3fv(glGetUniformLocation(p, "right"), 1, v->right);
    glUniform3fv(glGetUniformLocation(p, "up"), 1, v->up);
    glUniform3fv(glGetUniformLocation(p, "forward"), 1, v->forward);
    glUniform3fv(glGetUniformLocation(p, "cam"), 1, v->cam);
}

int atmos_pass(const struct view *v, unsigned depth_tex, int show) {
    static GLuint ground, atmos, apply, ground_fbo, ground_tex, half_fbo, half_tex;
    static int failed, tw, th, tuned, first;
    static float density, shafts;
    static CGLContextObj owner;
    if (CGLGetCurrentContext() != owner) {
        owner = CGLGetCurrentContext();
        ground = atmos = apply = ground_fbo = ground_tex = half_fbo = half_tex = 0;
        failed = tw = th = 0;
    }
    if (!tuned) {
        tuned = 1;
        density = post_env("GLHOOK_ATMOS_DENSITY", 0.025f);
        shafts = post_env("GLHOOK_ATMOS_SHAFTS", 0.3f);
    }
    if (failed) return 0;
    if (!ground && !(ground = post_program("mist", ground_src))) return failed = 1, 0;
    if (!atmos && !(atmos = post_program("mist", atmos_src))) return failed = 1, 0;
    if (!apply && !(apply = post_program("mist", apply_src))) return failed = 1, 0;
    int w = v->w, h = v->h, hw = (w + 1) / 2, hh = (h + 1) / 2;
    if (w != tw || h != th) {
        // The ground's height needs a float: it is in world units, hundreds of yards up.
        if (!ground_tex && !post_target(&ground_tex, &ground_fbo, GL_RGBA32F_ARB, 1, 1)) {
            fprintf(stderr, "glhook: mist has no float target\n");
            return failed = 1, 0;
        }
        if (!post_target(&half_tex, &half_fbo, GL_RGBA8, hw, hh)) {
            fprintf(stderr, "glhook: mist cannot draw at %dx%d\n", hw, hh);
            return failed = 1, 0;
        }
        tw = w, th = h, first = 1;
    }
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    float seconds = fmod((double)mach_absolute_time() * tb.numer / tb.denom / 1e9, 3600.0);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, depth_tex);

    // The ground, eased: each frame moves it 5% of the way.
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, ground_fbo);
    glViewport(0, 0, 1, 1);
    glUseProgram(ground);
    set_view(ground, v);
    glUniform1f(glGetUniformLocation(ground, "first"), first);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    post_quad();
    glDisable(GL_BLEND);
    first = 0;

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, ground_tex);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, half_fbo);
    glViewport(0, 0, hw, hh);
    glUseProgram(atmos);
    set_view(atmos, v);
    glUniform1i(glGetUniformLocation(atmos, "ground_tex"), 1);
    glUniform4f(glGetUniformLocation(atmos, "sun"), v->to_sun[0], v->to_sun[1], v->to_sun[2], v->lit ? shafts : 0);
    glUniform4f(glGetUniformLocation(atmos, "light"), v->sun[0], v->sun[1], v->sun[2], density);
    glUniform3fv(glGetUniformLocation(atmos, "mist"), 1, v->fog);
    // The mist's e-folding height, its noise (patches about 40 yards across) and its wind.
    glUniform4f(glGetUniformLocation(atmos, "shape"), 5.0f, 1.0f / 40.0f, 0.9f, 0.35f);
    glUniform1f(glGetUniformLocation(atmos, "time"), seconds);
    post_quad();

    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, half_tex);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, v->color_fbo);
    glViewport(0, 0, w, h);
    if (!show) {
        // Premultiplied, over the scene; the alpha stays.
        glEnable(GL_BLEND);
        glBlendFuncSeparate(GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ZERO, GL_ONE);
    }
    glUseProgram(apply);
    glUniform1i(glGetUniformLocation(apply, "depth"), 0);
    glUniform2f(glGetUniformLocation(apply, "size"), w, h);
    glUniform4f(glGetUniformLocation(apply, "proj"), v->a, v->b, v->fx, v->fy);
    glUniform1f(glGetUniformLocation(apply, "range"), v->range);
    glUniform1i(glGetUniformLocation(apply, "atmos"), 1);
    glUniform2f(glGetUniformLocation(apply, "half_size"), hw, hh);
    post_quad();
    glDisable(GL_BLEND);
    glActiveTexture(GL_TEXTURE0);
    return 1;
}
