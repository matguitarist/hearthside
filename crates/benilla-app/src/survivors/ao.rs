//! Ambient occlusion for the survivors world: creases, corners, the feet of trees and walls and
//! the ground under units darken a little, so the scene sits on its ground. Depth only, since the
//! WoW materials write no normals: positions and normals are rebuilt from the depth buffer, and
//! a ring of taps around each pixel measures how much of its hemisphere is closed.
//!
//! Two passes between the opaque and the transparent pass, so only solid geometry darkens: water,
//! particles, spell effects, the sky and the HUD all draw over the result untouched.
//! 1. `fs_ao`: at half resolution, into a single-channel visibility texture.
//! 2. `fs_apply`: a depth-aware upsample of it, multiplied into the camera's colour target (its MSAA
//!    texture when MSAA is on, so the edges stay antialiased).
//!
//! On by default in survivors; `O` toggles it in play, and `WOW_AO=0` starts it off; `WOW_AO=show` draws the
//! occlusion alone, in grey, for tuning. It fades out
//! with distance, where its taps would be smaller than a pixel.

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

use benilla_world::view::WorldCamera;

const SHADER: &str = "embedded://benilla_app/shaders/survivors_ao.wgsl";
/// The uniform: projection, tuning, then the target size, a `vec4` each.
const PARAMS_BYTES: u64 = 48;

/// The occlusion's settings, on the world camera. `amount` 0 skips both passes, and the toggle
/// eases it.
#[derive(Component, Clone, Copy, ExtractComponent)]
pub(super) struct AmbientOcclusion {
    pub amount: f32,
    /// How dark a fully closed crease gets, 0..1.
    pub strength: f32,
    /// How far, in yards, a surface can occlude another.
    pub radius: f32,
    /// The distance, in yards, where it starts to fade, and where it is gone.
    pub fade: (f32, f32),
}

impl Default for AmbientOcclusion {
    fn default() -> Self {
        Self {
            amount: 0.0,
            strength: 0.7,
            radius: 3.0,
            fade: (100.0, 220.0),
        }
    }
}

/// Whether the occlusion is wanted; the camera's `amount` eases toward it.
#[derive(Resource)]
struct AoOn(bool);

pub(super) fn plugin(app: &mut App) {
    let on = crate::webenv::var("WOW_AO").is_none_or(|v| v != "0");
    app.add_plugins(ExtractComponentPlugin::<AmbientOcclusion>::default())
        .insert_resource(AoOn(on))
        .add_systems(Update, (attach, toggle, drive).chain());
    let Some(render_app) = app.get_sub_app_mut(RenderApp) else {
        return;
    };
    render_app
        .add_systems(RenderStartup, init_pipelines)
        .add_systems(Render, prepare.in_set(RenderSystems::PrepareResources))
        .add_render_graph_node::<ViewNodeRunner<AoNode>>(Core3d, AoLabel)
        .add_render_graph_edges(
            Core3d,
            (
                Node3d::MainOpaquePass,
                AoLabel,
                Node3d::MainTransmissivePass,
            ),
        );
}

/// A world camera without the occlusion yet.
type NewWorldCamera = (With<WorldCamera>, Without<AmbientOcclusion>);

/// Also lets the passes sample the camera's depth: Bevy makes it an attachment only.
fn attach(mut commands: Commands, mut cams: Query<(Entity, &mut Camera3d), NewWorldCamera>) {
    for (e, mut cam) in &mut cams {
        let usages = TextureUsages::from(cam.depth_texture_usages);
        cam.depth_texture_usages = (usages | TextureUsages::TEXTURE_BINDING).into();
        commands.entity(e).insert(AmbientOcclusion::default());
    }
}

fn toggle(keys: Res<ButtonInput<KeyCode>>, mut on: ResMut<AoOn>) {
    if keys.just_pressed(KeyCode::KeyO) {
        on.0 = !on.0;
    }
}

/// Eases `amount` over a quarter second.
fn drive(time: Res<Time<Real>>, on: Res<AoOn>, mut aos: Query<&mut AmbientOcclusion>) {
    let target = if on.0 { 1.0 } else { 0.0 };
    let k = 1.0 - (-time.delta_secs() * 12.0).exp();
    for mut ao in &mut aos {
        ao.amount += (target - ao.amount) * k;
        if (ao.amount - target).abs() < 1e-3 {
            ao.amount = target;
        }
    }
}

#[derive(Debug, Hash, PartialEq, Eq, Clone, RenderLabel)]
struct AoLabel;

/// What a view's pair of pipelines depends on: its depth's sample count and its colour format.
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
struct AoKey {
    samples: u32,
    format: TextureFormat,
}

#[derive(Resource)]
struct AoPipelines {
    shader: Handle<Shader>,
    fullscreen: FullscreenShader,
    /// `WOW_AO=show`: the apply pass replaces the colour, so the screen is the occlusion alone.
    show: bool,
    /// Per [`AoKey`]: the bind group layouts and the queued pipelines, `(ao, apply)`.
    pairs: HashMap<AoKey, AoPair>,
}

#[derive(Clone)]
struct AoPair {
    layout_ao: BindGroupLayoutDescriptor,
    layout_apply: BindGroupLayoutDescriptor,
    ao: CachedRenderPipelineId,
    apply: CachedRenderPipelineId,
}

fn init_pipelines(
    mut commands: Commands,
    fullscreen_shader: Res<FullscreenShader>,
    asset_server: Res<AssetServer>,
) {
    commands.insert_resource(AoPipelines {
        shader: asset_server.load(SHADER),
        fullscreen: fullscreen_shader.clone(),
        show: crate::webenv::var("WOW_AO").is_some_and(|v| v == "show"),
        pairs: HashMap::new(),
    });
}

impl AoPipelines {
    fn pair(&mut self, cache: &PipelineCache, key: AoKey) -> AoPair {
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
        let layout_ao = BindGroupLayoutDescriptor::new(
            "survivors_ao_layout",
            &BindGroupLayoutEntries::sequential(ShaderStages::FRAGMENT, (depth, params)),
        );
        let layout_apply = BindGroupLayoutDescriptor::new(
            "survivors_ao_apply_layout",
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
        let ao = cache.queue_render_pipeline(RenderPipelineDescriptor {
            label: Some("survivors_ao".into()),
            layout: vec![layout_ao.clone()],
            vertex: self.fullscreen.to_vertex_state(),
            fragment: Some(FragmentState {
                shader: self.shader.clone(),
                shader_defs: defs.clone(),
                entry_point: Some("fs_ao".into()),
                targets: vec![Some(ColorTargetState {
                    format: TextureFormat::R8Unorm,
                    blend: None,
                    write_mask: ColorWrites::RED,
                })],
            }),
            ..default()
        });
        // `dst · src` on colour, alpha left alone: the pass only ever darkens what is there.
        let multiply = BlendState {
            color: BlendComponent {
                src_factor: BlendFactor::Dst,
                dst_factor: BlendFactor::Zero,
                operation: BlendOperation::Add,
            },
            alpha: BlendComponent {
                src_factor: BlendFactor::Zero,
                dst_factor: BlendFactor::One,
                operation: BlendOperation::Add,
            },
        };
        let apply = cache.queue_render_pipeline(RenderPipelineDescriptor {
            label: Some("survivors_ao_apply".into()),
            layout: vec![layout_apply.clone()],
            vertex: self.fullscreen.to_vertex_state(),
            fragment: Some(FragmentState {
                shader: self.shader.clone(),
                shader_defs: defs,
                entry_point: Some("fs_apply".into()),
                targets: vec![Some(ColorTargetState {
                    format: key.format,
                    blend: (!self.show).then_some(multiply),
                    write_mask: ColorWrites::ALL,
                })],
            }),
            multisample: MultisampleState {
                count: key.samples,
                ..default()
            },
            ..default()
        });
        let pair = AoPair {
            layout_ao,
            layout_apply,
            ao,
            apply,
        };
        self.pairs.insert(key, pair.clone());
        pair
    }
}

/// A view's visibility texture, uniform and pipelines, refreshed every frame.
#[derive(Component)]
struct AoView {
    visibility: CachedTexture,
    params: Buffer,
    pair: AoPair,
}

/// A view to prepare: its settings, projection, target and MSAA, and last frame's objects.
type AoViewItem = (
    Entity,
    &'static AmbientOcclusion,
    &'static ExtractedView,
    &'static ViewTarget,
    &'static Msaa,
    Option<&'static AoView>,
);

fn prepare(
    mut commands: Commands,
    mut texture_cache: ResMut<TextureCache>,
    mut pipelines: ResMut<AoPipelines>,
    cache: Res<PipelineCache>,
    device: Res<RenderDevice>,
    queue: Res<RenderQueue>,
    views: Query<AoViewItem>,
) {
    for (entity, ao, view, target, msaa, existing) in &views {
        if ao.amount <= 0.0 {
            commands.entity(entity).remove::<AoView>();
            continue;
        }
        let size = target.main_texture().size();
        let visibility = texture_cache.get(
            &device,
            TextureDescriptor {
                label: Some("survivors_ao_visibility"),
                size: Extent3d {
                    width: size.width.div_ceil(2),
                    height: size.height.div_ceil(2),
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: TextureDimension::D2,
                format: TextureFormat::R8Unorm,
                usage: TextureUsages::RENDER_ATTACHMENT | TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            },
        );
        let pair = pipelines.pair(
            &cache,
            AoKey {
                samples: msaa.samples(),
                format: target.main_texture_format(),
            },
        );
        // Bevy's infinite reverse-Z perspective: `ndc_z = near / view_distance`, so the shader
        // gets the distance back as `near / depth`, and x, y from the two focal terms.
        let clip = view.clip_from_view;
        let uniform: [f32; 12] = [
            clip.x_axis.x,
            clip.y_axis.y,
            clip.w_axis.z,
            0.0,
            ao.radius,
            ao.strength * ao.amount,
            ao.fade.0,
            ao.fade.1,
            size.width as f32,
            size.height as f32,
            1.0 / size.width as f32,
            1.0 / size.height as f32,
        ];
        let params = match existing {
            Some(view) => view.params.clone(),
            None => device.create_buffer(&BufferDescriptor {
                label: Some("survivors_ao_params"),
                size: PARAMS_BYTES,
                usage: BufferUsages::UNIFORM | BufferUsages::COPY_DST,
                mapped_at_creation: false,
            }),
        };
        queue.write_buffer(&params, 0, bytemuck::cast_slice(&uniform));
        commands.entity(entity).insert(AoView {
            visibility,
            params,
            pair,
        });
    }
}

#[derive(Default)]
struct AoNode;

impl ViewNode for AoNode {
    type ViewQuery = (
        &'static ViewTarget,
        &'static ViewDepthTexture,
        &'static AoView,
    );

    fn run<'w>(
        &self,
        _graph: &mut RenderGraphContext,
        render_context: &mut RenderContext<'w>,
        (target, depth, ao): QueryItem<'w, '_, Self::ViewQuery>,
        world: &'w World,
    ) -> Result<(), NodeRunError> {
        let cache = world.resource::<PipelineCache>();
        // Still compiling: this frame goes without.
        let (Some(pipeline_ao), Some(pipeline_apply)) = (
            cache.get_render_pipeline(ao.pair.ao),
            cache.get_render_pipeline(ao.pair.apply),
        ) else {
            return Ok(());
        };
        let device = render_context.render_device();
        let bind_ao = device.create_bind_group(
            "survivors_ao",
            &cache.get_bind_group_layout(&ao.pair.layout_ao),
            &BindGroupEntries::sequential((depth.view(), ao.params.as_entire_binding())),
        );
        let bind_apply = device.create_bind_group(
            "survivors_ao_apply",
            &cache.get_bind_group_layout(&ao.pair.layout_apply),
            &BindGroupEntries::sequential((
                depth.view(),
                ao.params.as_entire_binding(),
                &ao.visibility.default_view,
            )),
        );

        let mut pass = render_context.begin_tracked_render_pass(RenderPassDescriptor {
            label: Some("survivors_ao"),
            color_attachments: &[Some(RenderPassColorAttachment {
                view: &ao.visibility.default_view,
                depth_slice: None,
                resolve_target: None,
                ops: Operations {
                    load: LoadOp::Clear(LinearRgba::WHITE.into()),
                    store: StoreOp::Store,
                },
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
        });
        pass.set_render_pipeline(pipeline_ao);
        pass.set_bind_group(0, &bind_ao, &[]);
        pass.draw(0..3, 0..1);
        drop(pass);

        let mut pass = render_context.begin_tracked_render_pass(RenderPassDescriptor {
            label: Some("survivors_ao_apply"),
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
