// The passes glhook adds to the client's frame, and what they share.

// FSR 1 in place of the client's final stretch blit; fsr.c.
// Upscales the read framebuffer's source rectangle into the draw framebuffer's destination one and
// returns 1, or returns 0 (nothing drawn) when it does not apply or its shaders failed.
int fsr_blit(int sx0, int sy0, int sx1, int sy1, int dx0, int dy0, int dx1, int dy1);

// The world as glhook.c saw the client draw it this frame. Distances are in yards, directions in
// the world's axes (z up).
struct view {
    // The framebuffer holding the finished world, and its depth-stencil renderbuffer, w x h.
    unsigned color_fbo, depth_rb;
    int w, h;
    // A view distance t is at clip depth `ndc = a + b / t`; fx, fy are the focal terms; the world's
    // window depths span [0, range], the horizon and the sky lie beyond.
    float a, b, fx, fy, range;
    // Known (1) or not: the camera's axes and position, then the light.
    int oriented, lit;
    float right[3], up[3], forward[3], cam[3];
    // The zone's fog colour, the sun's and the ambient light's colours, the direction toward the sun.
    float fog[3], sun[3], ambient[3], to_sun[3];
};

// Ambient occlusion (ao.c) then ground mist (atmos.c) into the world's colour, each 0 off, 1 on,
// 2 alone ("show"), over one copy of its depth (post.c); the mist at fog level `fog`, 1 Low to 5
// Ultra. Returns 0 when nothing could be drawn.
int post_world(const struct view *v, int ao, int atmos, int fog);

// The passes themselves, inside post_world: the state is set aside, depth-tested drawing is off,
// and `depth_tex` holds the world's depth. Each returns 0 and stays off after a failure.
int ao_pass(const struct view *v, unsigned depth_tex, int show);
int atmos_pass(const struct view *v, unsigned depth_tex, int show, int level);

// GLSL 1.20 for the passes: the world's depth (`depth`, `size` in pixels) as distances. `proj` is
// a, b, fx, fy and `range` the world's depth range (struct view); `depth_at` gives the window depth
// over `range`, 1 or more for the horizon and the sky, and `distance_of` the view distance in yards.
#define POST_DEPTH_GLSL \
    "#version 120\n" \
    "uniform sampler2D depth;\n" \
    "uniform vec2 size;\n" \
    "uniform vec4 proj;\n" \
    "uniform float range;\n" \
    "float depth_at(vec2 p) { return texture2D(depth, (clamp(p, vec2(0.0), size - 1.0) + 0.5) / size).r / range; }\n" \
    "float distance_of(float d) { return proj.y / (min(d, 1.0) * 2.0 - 1.0 - proj.x); }\n"

// A program of the shared full-screen vertex shader and `fragment_src`, or 0 (reported under `name`).
unsigned post_program(const char *name, const char *fragment_src);
// A quad over the whole viewport.
void post_quad(void);
// An RGBA texture of `internal` format with a framebuffer around it, (re)made at w x h; 0 if it is
// not complete. Nearest filtering, clamped.
int post_target(unsigned *tex, unsigned *fbo, unsigned internal, int w, int h);
// A tuning value from the environment.
float post_env(const char *name, float fallback);
