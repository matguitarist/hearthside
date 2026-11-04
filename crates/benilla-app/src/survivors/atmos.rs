//! Atmosphere for the survivors world: a low ground mist and the sun's shafts through it. The mist
//! is an exponential height fog around the hero's ground, broken into drifting patches by noise
//! and tinted with the zone's own fog colour (`Light.dbc`), so it pools in hollows and follows the
//! time of day. The shafts are the sunlight it scatters: samples of the air along each view ray,
//! each tested against the depth buffer toward the sun, so the air under a tree's canopy or in a
//! building's lee stays dark and the light between them shows as beams. The survivors camera
//! looks down, where the sun is never on screen, so the beams come from the occluders on screen,
//! not from a sun disc.
//!
//! Two passes after the transparent pass, like [`super::ao`]: `fs_atmos` at half resolution into
//! a premultiplied colour texture, then `fs_apply` upsamples it with depth-aware weights and
//! blends it over the camera's colour target (`over`: `src + dst·(1 − a)`).
//!
//! On by default in survivors; `V` toggles it in play, `WOW_ATMOS=0` starts it off, and
//! `WOW_ATMOS=show` draws the atmosphere alone, over black.

use std::collections::HashMap;

use bevy::core_pipeline::core_3d::graph::{Core3d, Node3d};
use bevy::core_pipeline::FullscreenShader;
use bevy::ecs::query::QueryItem;
use bevy::prelude::*;
use bevy::render::extract_component::{ExtractComponent, ExtractComponentPlugin};
use bevy::render::render_graph::{
    NodeRunError, RenderGraphContext, RenderGraphExt, RenderLabel, ViewNode, ViewNodeRunner,
};
use bevy::render::render_resource::binding_types::{
    texture_2d, texture_depth_2d, texture_depth_2d_multisampled, uniform_buffer_sized,
};
use bevy::render::render_resource::*;
use bevy::render::renderer::{RenderContext, RenderDevice, RenderQueue};
use bevy::render::texture::{CachedTexture, TextureCache};
use bevy::render::view::{ExtractedView, Msaa, ViewDepthTexture, ViewTarget};
use bevy::render::{Render, RenderApp, RenderStartup, RenderSystems};
use bevy::shader::ShaderDefVal;

use benilla_world::lighting::WowLighting;
use benilla_world::view::WorldCamera;

use super::hero::Hero;

const SHADER: &str = "embedded://benilla_app/shaders/survivors_atmos.wgsl";
/// The uniform: fourteen `vec4`s, written in [`prepare`], read as `Params` in the shader.
const PARAMS_BYTES: u64 = 14 * 16;

/// The atmosphere's settings and this frame's scene inputs, on the world camera. `amount` 0 skips
/// both passes, and the toggle eases it.
#[derive(Component, Clone, Copy, ExtractComponent)]
pub(super) struct Atmosphere {
    pub amount: f32,
    /// Mist extinction per yard at the reference height.
    pub density: f32,
    /// How fast the mist thins with height, in yards (its e-folding height).
    pub falloff: f32,
    /// How bright the sun's shafts are.
    pub shafts: f32,
    /// The mist's reference height: the hero's ground, eased so slopes do not make it jump.
    pub ground: f32,
    /// The zone's fog colour and sun colour, `Light.dbc`, and the direction toward the sun.
    pub fog: Vec3,
    pub sun: Vec3,
    pub to_sun: Vec3,
    /// Seconds, wrapped, for the drift.
    pub time: f32,
}

impl Default for Atmosphere {
    fn default() -> Self {
        Self {
            amount: 0.0,
            density: 0.025,
            falloff: 5.0,
            shafts: 0.3,
            ground: f32::NAN,
            fog: Vec3::splat(0.6),
            sun: Vec3::ONE,
            to_sun: Vec3::Y,
            time: 0.0,
        }
    }
}

/// Whether the atmosphere is wanted; the camera's `amount` eases toward it.
#[derive(Resource)]
struct AtmosOn(bool);

pub(super) fn plugin(app: &mut App) {
    let on = crate::webenv::var("WOW_ATMOS").is_none_or(|v| v != "0");
    app.add_plugins(ExtractComponentPlugin::<Atmosphere>::default())
        .insert_resource(AtmosOn(on))
        .add_systems(Update, (attach, toggle, drive).chain());
    let Some(render_app) = app.get_sub_app_mut(RenderApp) else {
        return;
    };
    render_app
        .add_systems(RenderStartup, init_pipelines)
        .add_systems(Render, prepare.in_set(RenderSystems::PrepareResources))
        .add_render_graph_node::<ViewNodeRunner<AtmosNode>>(Core3d, AtmosLabel)
        .add_render_graph_edges(
            Core3d,
            (Node3d::MainTransparentPass, AtmosLabel, Node3d::EndMainPass),
        );
}

/// A world camera without the atmosphere yet.
type NewWorldCamera = (With<WorldCamera>, Without<Atmosphere>);

/// Also lets the passes sample the camera's depth: Bevy makes it an attachment only.
fn attach(mut commands: Commands, mut cams: Query<(Entity, &mut Camera3d), NewWorldCamera>) {
    for (e, mut cam) in &mut cams {
        let usages = TextureUsages::from(cam.depth_texture_usages);
        cam.depth_texture_usages = (usages | TextureUsages::TEXTURE_BINDING).into();
        let mut atmos = Atmosphere::default();
        // Tuning overrides: `WOW_ATMOS_DENSITY`, `WOW_ATMOS_SHAFTS`.
        let num = |key: &str| crate::webenv::var(key).and_then(|v| v.parse::<f32>().ok());
        atmos.density = num("WOW_ATMOS_DENSITY").unwrap_or(atmos.density);
        atmos.shafts = num("WOW_ATMOS_SHAFTS").unwrap_or(atmos.shafts);
        commands.entity(e).insert(atmos);
    }
}

fn toggle(keys: Res<ButtonInput<KeyCode>>, mut on: ResMut<AtmosOn>) {
    if keys.just_pressed(KeyCode::KeyV) {
        on.0 = !on.0;
    }
}

/// Eases `amount` over a quarter second, the ground over about a second, and copies the scene's
/// light. Without a hero (the pick screen) there is no ground to hold the mist, so it fades out.
fn drive(
    time: Res<Time<Real>>,
    on: Res<AtmosOn>,
    lighting: Option<Res<WowLighting>>,
    hero: Query<&GlobalTransform, With<Hero>>,
    mut atmos: Query<&mut Atmosphere>,
) {
    let feet = hero.single().ok().map(|t| t.translation().y);
    let target = if on.0 && feet.is_some() { 1.0 } else { 0.0 };
    let dt = time.delta_secs();
    let k = 1.0 - (-dt * 12.0).exp();
    for mut a in &mut atmos {
        a.amount += (target - a.amount) * k;
        if (a.amount - target).abs() < 1e-3 {
            a.amount = target;
        }
        if let Some(y) = feet {
            a.ground = if a.ground.is_finite() {
                a.ground + (y - a.ground) * (1.0 - (-dt * 1.5).exp())
            } else {
                y
            };
        }
        if let Some(l) = lighting.as_deref() {
            a.fog = Vec3::from(l.fog_color);
            a.sun = Vec3::from(l.diffuse);
            a.to_sun = (-l.sun_dir).normalize_or(Vec3::Y);
        }
        a.time = time.elapsed_secs_wrapped();
    }
}

#[derive(Debug, Hash, PartialEq, Eq, Clone, RenderLabel)]
struct AtmosLabel;

/// What a view's pair of pipelines depends on: its depth's sample count and its colour format.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct AtmosKey {
    samples: u32,
    format: TextureFormat,
}

#[derive(Resource)]
struct AtmosPipelines {
    shader: Handle<Shader>,
    fullscreen: FullscreenShader,
    /// `WOW_ATMOS=show`: the apply pass replaces the colour, so the screen is the atmosphere alone.
    show: bool,
    pairs: HashMap<AtmosKey, AtmosPair>,
}

#[derive(Clone)]
struct AtmosPair {
    layout_atmos: BindGroupLayoutDescriptor,
    layout_apply: BindGroupLayoutDescriptor,
    atmos: CachedRenderPipelineId,
    apply: CachedRenderPipelineId,
}

fn init_pipelines(
    mut commands: Commands,
    fullscreen_shader: Res<FullscreenShader>,
    asset_server: Res<AssetServer>,
) {
    commands.insert_resource(AtmosPipelines {
        shader: asset_server.load(SHADER),
        fullscreen: fullscreen_shader.clone(),
        show: crate::webenv::var("WOW_ATMOS").is_some_and(|v| v == "show"),
        pairs: HashMap::new(),
    });
}

impl AtmosPipelines {
    fn pair(&mut self, cache: &PipelineCache, key: AtmosKey) -> AtmosPair {
        if let Some(pair) = self.pairs.get(&key) {
            return pair.clone();
        }
        let multisampled = key.samples > 1;
        let depth = if multisampled {
            texture_depth_2d_multisampled()
        } else {
            texture_depth_2d()
        };
        let params = uniform_buffer_sized(false, std::num::NonZero::new(PARAMS_BYTES));
        let layout_atmos = BindGroupLayoutDescriptor::new(
            "survivors_atmos_layout",
            &BindGroupLayoutEntries::sequential(ShaderStages::FRAGMENT, (depth, params)),
        );
        let layout_apply = BindGroupLayoutDescriptor::new(
            "survivors_atmos_apply_layout",
            &BindGroupLayoutEntries::sequential(
                ShaderStages::FRAGMENT,
                (
                    depth,
                    params,
                    texture_2d(TextureSampleType::Float { filterable: false }),
                ),
            ),
        );
        let defs: Vec<ShaderDefVal> = if multisampled {
            vec!["MULTISAMPLED".into()]
        } else {
            vec![]
        };
        let atmos = cache.queue_render_pipeline(RenderPipelineDescriptor {
            label: Some("survivors_atmos".into()),
            layout: vec![layout_atmos.clone()],
            vertex: self.fullscreen.to_vertex_state(),
            fragment: Some(FragmentState {
                shader: self.shader.clone(),
                shader_defs: defs.clone(),
                entry_point: Some("fs_atmos".into()),
                targets: vec![Some(ColorTargetState {
                    format: TextureFormat::Rgba16Float,
                    blend: None,
                    write_mask: ColorWrites::ALL,
                })],
            }),
            ..default()
        });
        // Premultiplied `over` on colour, alpha left alone.
        let over = BlendState {
            color: BlendComponent {
                src_factor: BlendFactor::One,
                dst_factor: BlendFactor::OneMinusSrcAlpha,
                operation: BlendOperation::Add,
            },
            alpha: BlendComponent {
                src_factor: BlendFactor::Zero,
                dst_factor: BlendFactor::One,
                operation: BlendOperation::Add,
            },
        };
        let apply = cache.queue_render_pipeline(RenderPipelineDescriptor {
            label: Some("survivors_atmos_apply".into()),
            layout: vec![layout_apply.clone()],
            vertex: self.fullscreen.to_vertex_state(),
            fragment: Some(FragmentState {
                shader: self.shader.clone(),
                shader_defs: defs,
                entry_point: Some("fs_apply".into()),
                targets: vec![Some(ColorTargetState {
                    format: key.format,
                    blend: (!self.show).then_some(over),
                    write_mask: ColorWrites::ALL,
                })],
            }),
            multisample: MultisampleState {
                count: key.samples,
                ..default()
            },
            ..default()
        });
        let pair = AtmosPair {
            layout_atmos,
            layout_apply,
            atmos,
            apply,
        };
        self.pairs.insert(key, pair.clone());
        pair
    }
}

/// A view's half-resolution atmosphere texture, uniform and pipelines, refreshed every frame.
#[derive(Component)]
struct AtmosView {
    texture: CachedTexture,
    params: Buffer,
    pair: AtmosPair,
}

/// A view to prepare: its settings, projection, target and MSAA, and last frame's objects.
type AtmosViewItem = (
    Entity,
    &'static Atmosphere,
    &'static ExtractedView,
    &'static ViewTarget,
    &'static Msaa,
    Option<&'static AtmosView>,
);

fn prepare(
    mut commands: Commands,
    mut texture_cache: ResMut<TextureCache>,
    mut pipelines: ResMut<AtmosPipelines>,
    cache: Res<PipelineCache>,
    device: Res<RenderDevice>,
    queue: Res<RenderQueue>,
    views: Query<AtmosViewItem>,
) {
    for (entity, atmos, view, target, msaa, existing) in &views {
        if atmos.amount <= 0.0 || !atmos.ground.is_finite() {
            commands.entity(entity).remove::<AtmosView>();
            continue;
        }
        let size = target.main_texture().size();
        let texture = texture_cache.get(
            &device,
            TextureDescriptor {
                label: Some("survivors_atmos"),
                size: Extent3d {
                    width: size.width.div_ceil(2),
                    height: size.height.div_ceil(2),
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: TextureDimension::D2,
                format: TextureFormat::Rgba16Float,
                usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            },
        );
        let pair = pipelines.pair(
            &cache,
            AtmosKey {
                samples: msaa.samples(),
                format: target.main_texture_format(),
            },
        );
        let clip = view.clip_from_view;
        let world_from_view = view.world_from_view.to_matrix();
        let clip_from_world = view
            .clip_from_world
            .unwrap_or(clip * world_from_view.inverse());
        let mut uniform = Vec::with_capacity(56);
        // proj: the focal terms, near, and the drift clock.
        uniform.extend([clip.x_axis.x, clip.y_axis.y, clip.w_axis.z, atmos.time]);
        uniform.extend([
            size.width as f32,
            size.height as f32,
            1.0 / size.width as f32,
            1.0 / size.height as f32,
        ]);
        uniform.extend(world_from_view.to_cols_array());
        uniform.extend(clip_from_world.to_cols_array());
        uniform.extend(atmos.to_sun.extend(atmos.shafts * atmos.amount).to_array());
        uniform.extend(atmos.sun.extend(atmos.density * atmos.amount).to_array());
        uniform.extend(atmos.fog.extend(atmos.ground).to_array());
        // The mist's falloff, its noise scale (patches about 40 yards across), and its wind.
        uniform.extend([atmos.falloff, 1.0 / 40.0, 0.9, 0.35]);
        let params = match existing {
            Some(view) => view.params.clone(),
            None => device.create_buffer(&BufferDescriptor {
                label: Some("survivors_atmos_params"),
                size: PARAMS_BYTES,
                usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }),
        };
        queue.write_buffer(&params, 0, bytemuck::cast_slice(&uniform));
        commands.entity(entity).insert(AtmosView {
            texture,
            params,
            pair,
        });
    }
}

#[derive(Default)]
struct AtmosNode;

impl ViewNode for AtmosNode {
    type ViewQuery = (
        &'static ViewTarget,
        &'static ViewDepthTexture,
        &'static AtmosView,
    );

    fn run<'w>(
        &self,
        _graph: &mut RenderGraphContext,
        render_context: &mut RenderContext<'w>,
        (target, depth, atmos): QueryItem<'w, '_, Self::ViewQuery>,
        world: &'w World,
    ) -> Result<(), NodeRunError> {
        let cache = world.resource::<PipelineCache>();
        // Still compiling: this frame goes without.
        let (Some(pipeline_atmos), Some(pipeline_apply)) = (
            cache.get_render_pipeline(atmos.pair.atmos),
            cache.get_render_pipeline(atmos.pair.apply),
        ) else {
            return Ok(());
        };
        let device = render_context.render_device();
        let bind_atmos = device.create_bind_group(
            "survivors_atmos",
            &cache.get_bind_group_layout(&atmos.pair.layout_atmos),
            &BindGroupEntries::sequential((depth.view(), atmos.params.as_entire_binding())),
        );
        let bind_apply = device.create_bind_group(
            "survivors_atmos_apply",
            &cache.get_bind_group_layout(&atmos.pair.layout_apply),
            &BindGroupEntries::sequential((
                depth.view(),
                atmos.params.as_entire_binding(),
                &atmos.texture.default_view,
            )),
        );

        let mut pass = render_context.begin_tracked_render_pass(RenderPassDescriptor {
            label: Some("survivors_atmos"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: &atmos.texture.default_view,
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Clear(LinearRgba::NONE.into()),
                    store: StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        pass.set_render_pipeline(pipeline_atmos);
        pass.set_bind_group(0, &bind_atmos, &[]);
        pass.draw(0..3, 0..1);
        drop(pass);

        let mut pass = render_context.begin_tracked_render_pass(RenderPassDescriptor {
            label: Some("survivors_atmos_apply"),
            color_attachments: &[Some(target.get_color_attachment())],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        pass.set_render_pipeline(pipeline_apply);
        pass.set_bind_group(0, &bind_apply, &[]);
        pass.draw(0..3, 0..1);
        Ok(())
    }
}
