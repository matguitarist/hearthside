// Survivors ambient occlusion, from depth alone (`survivors/ao.rs`). `fs_ao`, at half resolution,
// rebuilds each pixel's view-space position and normal from the depth buffer and asks a spiral of
// taps around it how much of its upper hemisphere they close; `fs_apply` upsamples that with
// depth-aware weights, so the spiral's noise goes and edges stay sharp, and multiplies it into the
// colour target.
// Distances are in yards, the world's unit; positions use +z forward, `near / depth` (reverse-Z).

#import bevy_core_pipeline::fullscreen_vertex_shader::FullscreenVertexOutput

#ifdef MULTISAMPLED
@group(0) @binding(0) var depth_tex: texture_depth_multisampled_2d;
#else
@group(0) @binding(0) var depth_tex: texture_depth_2d;
#endif

struct Params {
    // x, y the focal terms (clip_from_view[0][0], [1][1]), z the near plane.
    proj: vec4<f32>,
    // x radius, y strength (already scaled by the toggle), z fade start, w fade end.
    tune: vec4<f32>,
    // xy the target size in pixels, zw its reciprocal.
    size: vec4<f32>,
}
@group(0) @binding(1) var<uniform> params: Params;
// `fs_apply` only: `fs_ao`'s output.
@group(0) @binding(2) var visibility: texture_2d<f32>;

const TAPS: i32 = 16;
const GOLDEN_ANGLE: f32 = 2.39996323;
// The most pixels a tap reaches: near the camera the radius would cover half the screen.
const MAX_REACH: f32 = 160.0;

fn clamp_px(p: vec2<i32>) -> vec2<i32> {
    return clamp(p, vec2<i32>(0), vec2<i32>(params.size.xy) - 1);
}

fn depth_at(p: vec2<i32>) -> f32 {
    return textureLoad(depth_tex, clamp_px(p), 0);
}

fn distance_of(depth: f32) -> f32 {
    return params.proj.z / max(depth, 1e-7);
}

fn view_pos(p: vec2<i32>) -> vec3<f32> {
    let z = distance_of(depth_at(p));
    let uv = (vec2<f32>(clamp_px(p)) + 0.5) * params.size.zw;
    let ndc = vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    return vec3<f32>(ndc.x * z / params.proj.x, ndc.y * z / params.proj.y, z);
}

// Jimenez's interleaved gradient noise: a different spiral rotation per pixel that a small blur
// averages out.
fn ign(p: vec2<f32>) -> f32 {
    return fract(52.9829189 * fract(dot(p, vec2<f32>(0.06711056, 0.00583715))));
}

@fragment
fn fs_ao(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    // Half resolution: this pixel stands for the 2×2 block at `p`.
    let p = vec2<i32>(in.position.xy) * 2;
    // Reverse-Z clears to 0: nothing drawn here, the sky.
    if (depth_at(p) <= 0.0) {
        return vec4<f32>(1.0);
    }
    let pos = view_pos(p);
    let fade = 1.0 - smoothstep(params.tune.z, params.tune.w, pos.z);
    let radius = params.tune.x;
    let reach = radius * params.proj.y * 0.5 * params.size.y / pos.z;
    if (fade <= 0.0 || reach < 1.5) {
        return vec4<f32>(1.0);
    }

    // The normal from the neighbours on the nearer side of each axis, so a silhouette edge does
    // not tilt it toward the background.
    let l = view_pos(p - vec2<i32>(1, 0));
    let r = view_pos(p + vec2<i32>(1, 0));
    let u = view_pos(p - vec2<i32>(0, 1));
    let d = view_pos(p + vec2<i32>(0, 1));
    let dx = select(r - pos, pos - l, abs(l.z - pos.z) < abs(r.z - pos.z));
    let dy = select(d - pos, pos - u, abs(u.z - pos.z) < abs(d.z - pos.z));
    var n = normalize(cross(dx, dy));
    if (dot(n, pos) > 0.0) {
        n = -n;
    }

    let reach_px = min(reach, MAX_REACH);
    let noise = ign(in.position.xy);
    let spin = noise * 6.2831853;
    // The cosine to the tap above which it counts, so a flat ground's own depth error does not.
    let bias = 0.12;
    var closed = 0.0;
    for (var i = 0; i < TAPS; i++) {
        let t = (f32(i) + fract(noise + 0.5)) / f32(TAPS);
        let angle = spin + f32(i) * GOLDEN_ANGLE;
        // Denser near the pixel, where occluders matter most.
        let offset = vec2<f32>(cos(angle), sin(angle)) * reach_px * (0.1 + 0.9 * t * t);
        let tap = view_pos(p + vec2<i32>(round(offset)));
        let v = tap - pos;
        let len2 = dot(v, v);
        let cosine = dot(v, n) * inverseSqrt(max(len2, 1e-6));
        // Anything past the radius stops counting: a tree trunk in front does not shade the ground
        // far behind it.
        let falloff = max(0.0, 1.0 - len2 / (radius * radius));
        closed += max(0.0, cosine - bias) * falloff;
    }
    // A tap at most closes a quarter of the hemisphere on its own; the gain makes a right-angled
    // crease read as fully closed.
    let occlusion = min(1.0, closed * 8.0 / f32(TAPS));
    let vis = 1.0 - occlusion * params.tune.y * fade;
    return vec4<f32>(vis, 0.0, 0.0, 1.0);
}

@fragment
fn fs_apply(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    let p = vec2<i32>(in.position.xy);
    let depth = depth_at(p);
    if (depth <= 0.0) {
        return vec4<f32>(1.0);
    }
    let z = distance_of(depth);
    // The half-resolution texels around this pixel, each read at the depth it was computed at.
    let half = p / 2;
    let half_max = vec2<i32>(textureDimensions(visibility)) - 1;
    var sum = 0.0;
    var weight = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let h = clamp(half + vec2<i32>(x, y), vec2<i32>(0), half_max);
            let q = h * 2;
            // Taps on another surface (more than ~3% further or nearer) barely count.
            let dz = abs(distance_of(depth_at(q)) - z) / (z * 0.03);
            let w = exp(-dz * dz);
            sum += textureLoad(visibility, h, 0).r * w;
            weight += w;
        }
    }
    let vis = sum / max(weight, 1e-4);
    return vec4<f32>(vec3<f32>(vis), 1.0);
}
