// Survivors atmosphere (`survivors/atmos.rs`): ground mist and the sun's shafts through it.
// `fs_atmos`, at half resolution, rebuilds each pixel's world position from the depth buffer and
// integrates along the camera's ray: an exponential height fog over the hero's ground, broken into
// drifting patches, and the sunlight that fog scatters toward the camera, from samples of the air
// each tested against the depth buffer toward the sun (a screen-space shadow ray), so canopies and
// walls cut it into beams. Out: premultiplied colour, alpha the mist's coverage. `fs_apply`
// upsamples it with depth-aware weights for the `over` blend. Distances are in yards.

#import bevy_core_pipeline::fullscreen_vertex_shader::FullscreenVertexOutput

#ifdef MULTISAMPLED
@group(0) @binding(0) var depth_tex: texture_depth_multisampled_2d;
#else
@group(0) @binding(0) var depth_tex: texture_depth_2d;
#endif

struct Params {
    // x, y the focal terms, z the near plane, w the drift clock in seconds.
    proj: vec4<f32>,
    // xy the target size in pixels, zw its reciprocal.
    size: vec4<f32>,
    world_from_view: mat4x4<f32>,
    clip_from_world: mat4x4<f32>,
    // xyz toward the sun, w the shafts' strength (scaled by the toggle).
    sun: vec4<f32>,
    // rgb the sun's colour, w the mist's extinction per yard at the ground (scaled by the toggle).
    light: vec4<f32>,
    // rgb the zone's fog colour, w the ground height.
    mist: vec4<f32>,
    // x the mist's e-folding height, y the noise's frequency per yard, zw the wind in yards/s.
    shape: vec4<f32>,
}
@group(0) @binding(1) var<uniform> params: Params;
// `fs_apply` only: `fs_atmos`'s output.
@group(0) @binding(2) var atmos: texture_2d<f32>;

// The farthest the mist is integrated to: past it, the zone's own distance fog has the scene.
const FAR: f32 = 300.0;
// The air sampled for shafts: this many samples over the last `SHAFT_SPAN` yards before the
// surface, each tested over `SHADOW_SPAN` yards toward the sun in `SHADOW_STEPS` steps.
const SHAFT_SAMPLES: i32 = 8;
const SHAFT_SPAN: f32 = 30.0;
const SHADOW_STEPS: i32 = 6;
const SHADOW_SPAN: f32 = 24.0;
// How thick a surface in the depth buffer is taken to be: a sample farther behind it than this is
// beside it, not in its shadow.
const THICKNESS: f32 = 8.0;

fn clamp_px(p: vec2<i32>) -> vec2<i32> {
    return clamp(p, vec2<i32>(0), vec2<i32>(params.size.xy) - 1);
}

fn depth_at(p: vec2<i32>) -> f32 {
    return textureLoad(depth_tex, clamp_px(p), 0);
}

// The distance along the view axis, `near / depth` (reverse-Z); nothing drawn is far away.
fn distance_of(depth: f32) -> f32 {
    return select(1e5, params.proj.z / depth, depth > 0.0);
}

// The world position of pixel `p` at view-axis distance `z`.
fn world_pos(p: vec2<i32>, z: f32) -> vec3<f32> {
    let uv = (vec2<f32>(p) + 0.5) * params.size.zw;
    let ndc = vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    let view = vec3<f32>(ndc.x * z / params.proj.x, ndc.y * z / params.proj.y, -z);
    return (params.world_from_view * vec4<f32>(view, 1.0)).xyz;
}

fn ign(p: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(dot(p, vec2<f32>(0.06711056, 0.00583715))));
}

fn hash(p: vec2<f32>) -> f32 {
    let q = fract(p * vec2<f32>(123.34, 456.21));
    let r = q + dot(q, q + 45.32);
    return fract(r.x * r.y);
}

fn value_noise(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash(i);
    let b = hash(i + vec2<f32>(1.0, 0.0));
    let c = hash(i + vec2<f32>(0.0, 1.0));
    let d = hash(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Three octaves, each drifting a little faster than the last, so the patches change shape as they
// move instead of sliding as one sheet.
fn mist_noise(xz: vec2<f32>) -> f32 {
    let t = params.proj.w;
    let wind = params.shape.zw;
    var p = xz * params.shape.y;
    var sum = 0.0;
    var amp = 0.55;
    for (var i = 0; i < 3; i++) {
        sum += value_noise(p + wind * t * params.shape.y * (1.0 + 0.6 * f32(i))) * amp;
        p = p * 2.03 + vec2<f32>(17.1, 9.7);
        amp *= 0.5;
    }
    return sum / 0.9625;
}

// The optical depth of the height fog along the ray from `a` to `b`: `∫ exp(-(y - ground) / k)`.
fn height_fog(a: vec3<f32>, b: vec3<f32>) -> f32 {
    let k = params.shape.x;
    let ground = params.mist.w;
    // Hollows below the ground fill, but only so deep.
    let ya = max(a.y - ground, -3.0 * k);
    let yb = max(b.y - ground, -3.0 * k);
    let len = distance(a, b);
    let dy = yb - ya;
    if (abs(dy) < 1e-3) {
        return len * exp(-ya / k);
    }
    return len * k * (exp(-ya / k) - exp(-yb / k)) / dy;
}

// Whether the depth buffer shows something between `x` and the sun, within `SHADOW_SPAN`.
fn sunlit(x: vec3<f32>, jitter: f32) -> f32 {
    let to_sun = params.sun.xyz;
    for (var j = 0; j < SHADOW_STEPS; j++) {
        let y = x + to_sun * (SHADOW_SPAN * (f32(j) + jitter) / f32(SHADOW_STEPS));
        let clip = params.clip_from_world * vec4<f32>(y, 1.0);
        if (clip.w <= 0.0) {
            return 1.0;
        }
        let ndc = clip.xy / clip.w;
        let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
        // Off screen nothing is known: lit.
        if (any(uv < vec2<f32>(0.0)) || any(uv > vec2<f32>(1.0))) {
            return 1.0;
        }
        let scene = distance_of(depth_at(vec2<i32>(uv * params.size.xy)));
        let behind = clip.w - scene;
        if (behind > 0.3 && behind < THICKNESS) {
            return 0.0;
        }
    }
    return 1.0;
}

@fragment
fn fs_atmos(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    let p = vec2<i32>(in.position.xy) * 2;
    let z = min(distance_of(depth_at(p)), FAR);
    let pos = world_pos(p, z);
    let cam = params.world_from_view[3].xyz;
    let ray = pos - cam;
    let dist = length(ray);
    let dir = ray / max(dist, 1e-4);
    let noise = ign(in.position.xy);

    // The mist, in patches: almost clear between them, a little thicker than the base inside.
    let patches = mix(0.05, 1.6, smoothstep(0.4, 0.8, mist_noise(pos.xz)));
    let coverage = 1.0 - exp(-params.light.w * height_fog(cam, pos) * patches);

    // The shafts: how much of the mist along the last stretch before the surface the sun reaches,
    // weighted toward the ground where the mist is. They light the mist, adding nothing where
    // there is none, so open ground under a high camera is not washed over.
    var lit = 1.0;
    let day = smoothstep(0.0, 0.15, params.sun.y);
    if (params.sun.w > 0.0 && day > 0.0) {
        let step = min(dist, SHAFT_SPAN) / f32(SHAFT_SAMPLES);
        let k = params.shape.x * 2.0;
        var reached = 0.0;
        var total = 0.0;
        for (var i = 0; i < SHAFT_SAMPLES; i++) {
            let x = pos - dir * (step * (f32(i) + noise));
            let haze = exp(-max(x.y - params.mist.w, 0.0) / k);
            reached += sunlit(x, fract(noise + f32(i) * 0.618)) * haze;
            total += haze;
        }
        lit = reached / max(total, 1e-4);
    }
    // Forward scattering: brighter looking toward the sun.
    let toward = max(dot(dir, params.sun.xyz), 0.0);
    let phase = 0.5 + 1.5 * toward * toward * toward * toward;
    let sunlight = params.light.rgb * params.sun.w * day * phase * lit;
    let color = params.mist.rgb * mix(0.55, 1.0, lit * day) + sunlight;

    return vec4<f32>(color * coverage, coverage);
}

@fragment
fn fs_apply(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    let p = vec2<i32>(in.position.xy);
    let z = distance_of(depth_at(p));
    let half = p / 2;
    let half_max = vec2<i32>(textureDimensions(atmos)) - 1;
    var sum = vec4<f32>(0.0);
    var weight = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let h = clamp(half + vec2<i32>(x, y), vec2<i32>(0), half_max);
            let dz = abs(distance_of(depth_at(h * 2)) - z) / (z * 0.03);
            let w = exp(-dz * dz) + 1e-4;
            sum += textureLoad(atmos, h, 0) * w;
            weight += w;
        }
    }
    return sum / weight;
}
