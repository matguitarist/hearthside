//! The mode's screens, in bevy_ui since FrameXML is off: the class and hero pick, the in-run HUD,
//! the level-up cards, pause, and the results.

use std::collections::HashMap;

use benilla_ui::script::nameplate;
use benilla_world::view::WorldCamera;
use bevy::prelude::*;
use bevy::render::render_resource::AsBindGroup;
use bevy::shader::ShaderRef;
use bevy::ui_render::ui_material::{MaterialNode, UiMaterial};
use bevy::window::PrimaryWindow;

use super::data::{self, AbilityDef, Effect, Kind, PassiveDef, Stat};
use super::hero::{self, Hero};
use super::minimap::{self, MiniMap};
use super::{Owned, Phase, Rng, Run, Selection, Stats};

mod bar;
mod offer;
mod tooltip;
pub(super) use bar::*;
use bar::{action_bar, quickslot_frame, spell_name, SLOT};
pub(super) use offer::*;
pub(super) use tooltip::*;
use tooltip::{ability_body, cast_at, compact, num, passive_text, pct, stat_label};

const GOLD: Color = Color::srgb(1.0, 0.82, 0.0);
/// The mobility button's edge, an action button's 36 units.
const DIM: Color = Color::srgb(0.6, 0.6, 0.6);
pub(super) const DIM_GREY: Color = DIM;
pub(super) const GOLD_TONE: Color = GOLD;

#[derive(Component)]
pub(super) struct MenuRoot;
#[derive(Component)]
pub(super) struct HudRoot;
#[derive(Component)]
pub(super) struct LevelUpRoot;
#[derive(Component)]
pub(super) struct PauseRoot;
#[derive(Component)]
pub(super) struct OverRoot;
#[derive(Component)]
pub(super) struct XpBar;
#[derive(Component)]
pub(super) struct XpFill;
#[derive(Component)]
pub(super) struct XpText;
#[derive(Component)]
pub(super) struct LevelText;
#[derive(Component)]
pub(super) struct TimerText;
#[derive(Component)]
pub(super) struct KillText;
#[derive(Component)]
pub(super) struct HpFrame;
#[derive(Component)]
pub(super) struct HpBar;
#[derive(Component)]
pub(super) struct HpLevelSeat;
#[derive(Component)]
pub(super) struct HpLevel;
#[derive(Component)]
pub(super) struct HpFill;
#[derive(Component)]
pub(super) struct ShieldFill;
#[derive(Component)]
pub(super) struct BannerText;
#[derive(Component)]
pub(super) struct ActionBar;
/// One of `MainMenuBar`'s twelve action slots: abilities in 0..6, passives in 6..12.
#[derive(Component)]
pub(super) struct BarSlot(usize);
/// A line in the micro-menu buttons' recess: 0 the next boss, 1 the pace.
#[derive(Component)]
pub(super) struct BarInfo(u8);
/// A bag socket, holding the run's `n`th armor drop.
#[derive(Component)]
pub(super) struct LootSlot(usize);
#[derive(Component)]
pub(super) struct OfferRow;
/// The line under LEVEL UP: which level this is.
#[derive(Component)]
pub(super) struct LevelUpSub;

/// A radial cooldown sweep over one ability icon: `sweep` is the remaining fraction
/// (1.0 = just cast, 0.0 = ready), drawn by `ui_sweep.wgsl`.
#[derive(Asset, TypePath, AsBindGroup, Clone)]
pub(super) struct SweepUiMaterial {
    #[uniform(0)]
    pub(super) sweep: f32,
}

impl UiMaterial for SweepUiMaterial {
    fn fragment_shader() -> ShaderRef {
        "embedded://benilla_app/shaders/ui_sweep.wgsl".into()
    }
}

/// The cooldown overlay on one ability slot, driven every frame.
#[derive(Component)]
pub(super) struct AbilitySweep {
    handle: Handle<SweepUiMaterial>,
    index: usize,
}

/// The class mobility's action button, bottom centre over the XP bar; shown once it is learned.
#[derive(Component)]
pub(super) struct MobilitySlot;

/// The item bar's `n`th socket, over the action bar's left end, and its cooldown sweep.
#[derive(Component)]
pub(super) struct QuickSlot(usize);
#[derive(Component)]
pub(super) struct QuickSweep(usize, Handle<SweepUiMaterial>);

/// The backpack button, in the bar's backpack socket.
#[derive(Component)]
pub(super) struct BackpackButton;

/// The money frame over the bar's right end: the gold, silver and copper counts, each with its
/// coin.
#[derive(Component)]
pub(super) struct MoneyCoin(u8);
#[derive(Component)]
pub(super) struct MoneyText(u8);
#[derive(Component)]
pub(super) struct MobilityIcon;
#[derive(Component)]
pub(super) struct MobilitySweep(Handle<SweepUiMaterial>);
#[derive(Component)]
pub(super) struct OverTitle;
#[derive(Component)]
pub(super) struct OverStats;
#[derive(Component)]
pub(super) struct OverLine;
#[derive(Component)]
pub(super) struct OverStat(pub(super) usize);

/// An icon slot filled from the spell's `SpellIcon` once the client data is up.
#[derive(Component)]
pub(super) struct SpellIcon(pub(super) u32);
#[derive(Component)]
pub(super) struct IconDone;

/// A FrameXML `Texture` region: a client art file, its `TexCoords` (left, right, top, bottom) and
/// vertex colour, drawn once the archives are readable.
#[derive(Component)]
pub(super) struct UiArt {
    path: &'static str,
    coords: [f32; 4],
    tint: Color,
}

impl UiArt {
    pub(super) fn crop(path: &'static str, coords: [f32; 4]) -> Self {
        Self {
            path,
            coords,
            tint: Color::WHITE,
        }
    }

    fn tinted(path: &'static str, tint: Color) -> Self {
        Self {
            path,
            coords: [0.0, 1.0, 0.0, 1.0],
            tint,
        }
    }
}

#[derive(Component)]
pub(super) struct ArtDone;

/// What an icon slot's tooltip describes: an index into the run's abilities or passives.
#[derive(Component, Clone, Copy, PartialEq, Eq, Debug)]
pub(super) enum TipFor {
    Ability(usize),
    Passive(usize),
    Mobility,
    /// The run's `n`th armor drop.
    Loot(usize),
    /// The item bar's `n`th socket.
    Quick(usize),
    /// A backpack cell.
    Bag(super::panels::BagCell),
    Backpack,
}

/// The one `GameTooltip`, and the column its lines go in.
#[derive(Component)]
pub(super) struct GameTooltip;
#[derive(Component)]
pub(super) struct TipBody;

#[derive(Component, Clone, Copy, PartialEq)]
pub(super) enum UiAction {
    Resume,
    MainMenu,
    Quit,
    Settings,
    /// Settings back to the pause menu.
    Done,
    /// One of Settings' tabs.
    Tab(u8),
    /// The backpack's Close.
    CloseBag,
    /// The results' Play Again: the same hero in the same zone, straight back in.
    PlayAgain,
}

/// A Play Again waiting for the pick screen to reset the run and stand the hero up again.
#[derive(Resource, Default)]
pub(super) struct Replay(pub(super) bool);

#[derive(Clone, Copy)]
pub(super) enum Choice {
    NewAbility(&'static AbilityDef),
    Upgrade(usize),
    NewPassive(&'static PassiveDef),
    UpPassive(usize),
    Heal,
}

/// The level-up cards on offer.
#[derive(Resource, Default)]
pub(super) struct Offer {
    choices: Vec<Choice>,
}

impl Offer {
    pub(super) fn len(&self) -> usize {
        self.choices.len()
    }

    pub(super) fn choices(&self) -> &[Choice] {
        &self.choices
    }
}

#[derive(Resource)]
pub(super) struct HudFont(pub(super) Handle<Font>);

pub(super) fn rgb(hex: u32) -> Color {
    Color::srgb_u8((hex >> 16) as u8, (hex >> 8) as u8, hex as u8)
}

fn text(font: &Handle<Font>, s: impl Into<String>, size: f32, color: Color) -> impl Bundle {
    (
        Text::new(s),
        TextFont {
            font: font.clone(),
            font_size: size,
            ..default()
        },
        TextColor(color),
        TextShadow {
            offset: Vec2::splat(1.5),
            color: Color::BLACK,
        },
    )
}

pub(super) fn text_bundle(
    font: &Handle<Font>,
    s: impl Into<String>,
    size: f32,
    color: Color,
) -> impl Bundle {
    text(font, s, size, color)
}

pub(super) fn centered_bundle(
    font: &Handle<Font>,
    s: impl Into<String>,
    size: f32,
    color: Color,
) -> impl Bundle {
    centered(font, s, size, color)
}

fn centered(font: &Handle<Font>, s: impl Into<String>, size: f32, color: Color) -> impl Bundle {
    (
        text(font, s, size, color),
        TextLayout::new_with_justify(Justify::Center),
    )
}

pub(super) fn icon_bundle(spell: u32, size: f32) -> impl Bundle {
    icon(spell, size)
}

fn icon(spell: u32, size: f32) -> impl Bundle {
    (
        Node {
            width: Val::Px(size),
            height: Val::Px(size),
            ..default()
        },
        ImageNode {
            color: Color::srgba(0.0, 0.0, 0.0, 0.6),
            ..default()
        },
        SpellIcon(spell),
    )
}

pub(super) fn setup_hud(
    mut commands: Commands,
    asset_server: Res<AssetServer>,
    mut images: ResMut<Assets<Image>>,
    mut sweeps_init: ResMut<Assets<SweepUiMaterial>>,
    mut fills: ResMut<Assets<super::fill::FillMaterial>>,
) {
    let font = crate::char_select::wow_font(&asset_server);
    let number_font: Handle<Font> = asset_server.load("mpq://Fonts/ARIALN.ttf");
    commands.insert_resource(HudFont(font.clone()));
    let f = &font;
    let map = MiniMap::new(&mut images);

    // --- The in-run HUD. ---
    commands
        .spawn((
            HudRoot,
            Node {
                position_type: PositionType::Absolute,
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                flex_direction: FlexDirection::Column,
                ..default()
            },
            GlobalZIndex(400),
            Visibility::Hidden,
        ))
        .with_children(|root| {
            action_bar(root, f, &mut sweeps_init);
            // `MainMenuExpBar`, 1024×13 at the bottom centre, stacked on the 40-unit action bar.
            root.spawn((
                XpBar,
                Interaction::default(),
                Node {
                    position_type: PositionType::Absolute,
                    left: Val::Percent(50.0),
                    bottom: Val::Px(40.0),
                    margin: UiRect::left(Val::Px(-512.0)),
                    width: Val::Px(1024.0),
                    height: Val::Px(13.0),
                    ..default()
                },
                BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.5)),
            ))
            .with_children(|bar| {
                bar.spawn((
                    XpFill,
                    Node {
                        width: Val::Percent(0.0),
                        height: Val::Percent(100.0),
                        ..default()
                    },
                    ImageNode {
                        color: Color::NONE,
                        ..default()
                    },
                    UiArt::tinted(
                        "Interface\\TargetingFrame\\UI-StatusBar",
                        Color::srgb(0.58, 0.0, 0.55),
                    ),
                ));
                // `MainMenuXPBarTexture0`..`3`: the segment rules, 256×10 on the bar's top.
                for (i, top) in [0.792_968_75, 0.542_968_75, 0.292_968_75, 0.042_968_75]
                    .into_iter()
                    .enumerate()
                {
                    bar.spawn((
                        Node {
                            position_type: PositionType::Absolute,
                            left: Val::Px(256.0 * i as f32),
                            top: Val::Px(0.0),
                            width: Val::Px(256.0),
                            height: Val::Px(10.0),
                            ..default()
                        },
                        ImageNode {
                            color: Color::NONE,
                            ..default()
                        },
                        UiArt::crop(
                            "Interface\\MainMenuBar\\UI-MainMenuBar-Dwarf",
                            [0.0, 1.0, top, top + 0.039_062_5],
                        ),
                    ));
                }
                // `MainMenuBarExpText`, `TextStatusBarText` centred one unit up, shown on hover.
                bar.spawn(Node {
                    position_type: PositionType::Absolute,
                    width: Val::Percent(100.0),
                    height: Val::Percent(100.0),
                    top: Val::Px(-1.0),
                    justify_content: JustifyContent::Center,
                    align_items: AlignItems::Center,
                    ..default()
                })
                .with_children(|n| {
                    n.spawn((
                        XpText,
                        Text::new(""),
                        TextFont {
                            font: number_font.clone(),
                            font_size: 14.0,
                            ..default()
                        },
                        TextColor(Color::WHITE),
                        TextShadow {
                            offset: Vec2::new(1.0, 1.0),
                            color: Color::BLACK,
                        },
                        TextLayout::new(Justify::Center, LineBreak::NoWrap),
                        Visibility::Hidden,
                    ));
                });
            });
            minimap::spawn_cluster(root, f, &map);
            root.spawn(Node {
                width: Val::Percent(100.0),
                padding: UiRect::all(Val::Px(10.0)),
                justify_content: JustifyContent::SpaceBetween,
                align_items: AlignItems::FlexStart,
                ..default()
            })
            .with_children(|row| {
                // The minimap cluster's width, so the clock stays centred.
                row.spawn(Node {
                    width: Val::Px(300.0),
                    ..default()
                });
                // The clock, with the level and the kill count on one line under it.
                row.spawn(Node {
                    flex_direction: FlexDirection::Column,
                    align_items: AlignItems::Center,
                    row_gap: Val::Px(0.0),
                    ..default()
                })
                .with_children(|col| {
                    col.spawn((TimerText, centered(f, "00:00", 34.0, Color::WHITE)));
                    col.spawn(Node {
                        column_gap: Val::Px(14.0),
                        ..default()
                    })
                    .with_children(|line| {
                        line.spawn((LevelText, text(f, "Level 1", 14.0, GOLD)));
                        line.spawn((KillText, text(f, "Kills 0", 14.0, Color::WHITE)));
                    });
                    col.spawn((
                        super::difficulty::AffixText,
                        text(f, "", 13.0, Color::srgb(1.0, 0.5, 0.25)),
                        Visibility::Hidden,
                    ));
                });
                // The minimap cluster's column.
                row.spawn(Node {
                    width: Val::Px(300.0),
                    ..default()
                });
            });
            root.spawn(Node {
                position_type: PositionType::Absolute,
                top: Val::Percent(22.0),
                width: Val::Percent(100.0),
                justify_content: JustifyContent::Center,
                ..default()
            })
            .with_children(|n| {
                n.spawn((BannerText, centered(f, "", 30.0, GOLD)));
            });
            // The hero's health as a nameplate (`CGNamePlateFrame`): the bar under the border that
            // caps it, the level in the border's seat; [`hero_plate`] sizes and seats it.
            let absolute = || Node {
                position_type: PositionType::Absolute,
                ..default()
            };
            let unpainted = || ImageNode {
                color: Color::NONE,
                ..default()
            };
            let [r, g, b, _] = crate::vplates::PLATE_FRIENDLY;
            root.spawn((HpFrame, absolute(), Visibility::Hidden))
                .with_children(|plate| {
                    plate.spawn((HpBar, absolute())).with_children(|bar| {
                        bar.spawn((
                            HpFill,
                            Node {
                                width: Val::Percent(100.0),
                                height: Val::Percent(100.0),
                                ..default()
                            },
                            unpainted(),
                            UiArt::tinted(nameplate::BAR_FILL_TEXTURE, Color::srgb(r, g, b)),
                        ));
                        bar.spawn((
                            ShieldFill,
                            Node {
                                width: Val::Percent(0.0),
                                height: Val::Percent(100.0),
                                ..absolute()
                            },
                            unpainted(),
                            UiArt::tinted(
                                nameplate::BAR_FILL_TEXTURE,
                                Color::srgba(0.85, 0.9, 1.0, 0.75),
                            ),
                        ));
                    });
                    plate.spawn((
                        Node {
                            width: Val::Percent(100.0),
                            height: Val::Percent(100.0),
                            ..absolute()
                        },
                        unpainted(),
                        UiArt::crop(nameplate::BORDER_TEXTURE, [0.0, 1.0, 0.0, 1.0]),
                    ));
                    let [r, g, b, _] = crate::vplates::CON_YELLOW;
                    plate
                        .spawn((
                            HpLevelSeat,
                            Node {
                                width: Val::Px(0.0),
                                height: Val::Px(0.0),
                                justify_content: JustifyContent::Center,
                                align_items: AlignItems::Center,
                                overflow: Overflow::visible(),
                                ..absolute()
                            },
                        ))
                        .with_children(|seat| {
                            seat.spawn((
                                HpLevel,
                                Text::new("1"),
                                TextFont {
                                    font: f.clone(),
                                    font_size: 11.0,
                                    ..default()
                                },
                                TextColor(Color::srgb(r, g, b)),
                                TextShadow {
                                    offset: Vec2::new(1.0, 1.0),
                                    color: Color::BLACK,
                                },
                                TextLayout::new(Justify::Center, LineBreak::NoWrap),
                            ));
                        });
                });
        });
    commands.insert_resource(map);

    // --- The run's pick screen; [`super::menu`] builds into it once the glue art is in. ---
    commands.spawn((
        MenuRoot,
        Node {
            position_type: PositionType::Absolute,
            width: Val::Percent(100.0),
            height: Val::Percent(100.0),
            ..default()
        },
        GlobalZIndex(410),
        bevy::ui::FocusPolicy::Pass,
    ));

    // --- Level up. ---
    commands
        .spawn((
            LevelUpRoot,
            Node {
                position_type: PositionType::Absolute,
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                flex_direction: FlexDirection::Column,
                justify_content: JustifyContent::Center,
                align_items: AlignItems::Center,
                row_gap: Val::Px(18.0),
                ..default()
            },
            // A dark vignette closing in on the cards, a slow golden light at its heart (the
            // 1400-unit burst's radius over the 768-unit canvas).
            MaterialNode(
                fills.add(
                    super::fill::FillMaterial::radial(
                        Color::srgba(0.04, 0.025, 0.0, 0.72),
                        Color::srgba(0.0, 0.0, 0.0, 0.9),
                    )
                    .with_glow(
                        Color::srgba(1.0, 0.75, 0.25, 0.22),
                        Vec2::splat(0.5),
                        Vec2::splat(700.0 / 768.0),
                    ),
                ),
            ),
            GlobalZIndex(420),
            Visibility::Hidden,
            // The build's icons stay hoverable under the cards.
            bevy::ui::FocusPolicy::Pass,
        ))
        .with_children(|root| {
            // The slow golden burst behind everything.
            root.spawn((
                super::cards::Rays,
                Node {
                    position_type: PositionType::Absolute,
                    width: Val::Px(1400.0),
                    height: Val::Px(1400.0),
                    left: Val::Percent(50.0),
                    top: Val::Percent(50.0),
                    margin: UiRect::new(
                        Val::Px(-700.0),
                        Val::Px(0.0),
                        Val::Px(-700.0),
                        Val::Px(0.0),
                    ),
                    ..default()
                },
                BackgroundGradient(vec![
                    Gradient::Conic(ConicGradient::new(
                        UiPosition::CENTER,
                        (0..24)
                            .map(|i| {
                                let a = i as f32 / 24.0 * std::f32::consts::TAU;
                                let on = i % 2 == 0;
                                AngularColorStop::new(
                                    if on {
                                        Color::srgba(1.0, 0.8, 0.3, 0.07)
                                    } else {
                                        Color::srgba(1.0, 0.8, 0.3, 0.0)
                                    },
                                    a,
                                )
                            })
                            .collect(),
                    )),
                ]),
                UiTransform::default(),
                bevy::ui::FocusPolicy::Pass,
            ));
            root.spawn(centered(f, "LEVEL UP", 52.0, GOLD));
            root.spawn((
                LevelUpSub,
                centered(f, "Choose your power", 16.0, Color::srgb(0.85, 0.78, 0.6)),
            ));
            root.spawn((
                OfferRow,
                Node {
                    column_gap: Val::Px(22.0),
                    // Room for a hovered card's lift.
                    margin: UiRect::new(Val::ZERO, Val::ZERO, Val::Px(28.0), Val::Px(16.0)),
                    ..default()
                },
            ));
            root.spawn(centered(
                f,
                "Click a card or press 1, 2 or 3; on a controller, the D-pad and A, or X, Y or B",
                14.0,
                DIM,
            ));
        });

    // --- Pause; [`super::panels`] builds its dialog once the glue art is in. ---
    commands
        .spawn((
            PauseRoot,
            Node {
                position_type: PositionType::Absolute,
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                flex_direction: FlexDirection::Column,
                justify_content: JustifyContent::Center,
                align_items: AlignItems::Center,
                ..default()
            },
            BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.4)),
            GlobalZIndex(430),
            Visibility::Hidden,
            bevy::ui::FocusPolicy::Pass,
        ));

    // --- Results; its dialog too. ---
    commands
        .spawn((
            OverRoot,
            Node {
                position_type: PositionType::Absolute,
                width: Val::Percent(100.0),
                height: Val::Percent(100.0),
                flex_direction: FlexDirection::Column,
                justify_content: JustifyContent::Center,
                align_items: AlignItems::Center,
                row_gap: Val::Px(14.0),
                ..default()
            },
            MaterialNode(fills.add(super::fill::FillMaterial::radial(
                Color::srgba(0.07, 0.02, 0.0, 0.8),
                Color::srgba(0.0, 0.0, 0.0, 0.94),
            ))),
            GlobalZIndex(440),
            Visibility::Hidden,
        ));
}

/// The menu's hero is the run's hero: respawned whenever the pick changes.
pub(super) fn menu_preview(
    mut commands: Commands,
    phase: Res<State<Phase>>,
    selection: Res<Selection>,
    mut run: ResMut<Run>,
    heroes: Query<Entity, With<Hero>>,
    world: benilla_world::world_point::WorldPoint,
    catalog: Res<super::gear::GearCatalog>,
    profile: Res<super::profile::Profile>,
    char_create: Option<Res<crate::entities::CharCreate>>,
    #[allow(clippy::type_complexity)] mut shown: Local<
        Option<(usize, u32, usize, super::units::Custom, Vec<(u8, u32)>)>,
    >,
) {
    if *phase.get() != Phase::Menu {
        return;
    }
    let want = selection
        .class
        .zip(selection.look.and_then(|i| selection.looks.get(i)).copied());
    let items: Vec<(u8, u32)> = want
        .map(|(c, (_, race, sex))| {
            let class = &data::CLASSES[c];
            let outfit = char_create
                .as_deref()
                .map_or(&[][..], |cc| cc.0.start_outfit(race, class.id, sex));
            super::gear::hero_items(class, outfit, &profile, &catalog)
        })
        .unwrap_or_default();
    // The catalog is in once it has pieces: until then the hero waits, so it isn't seen naked.
    if catalog.pieces.is_empty() || char_create.is_none() {
        return;
    }
    let key = want.map(|(c, l)| (c, l.0, selection.stage, selection.custom, items.clone()));
    if key == *shown && (key.is_none() || !heroes.is_empty()) {
        return;
    }
    for e in &heroes {
        commands.entity(e).despawn();
    }
    *shown = key;
    let Some((class, (_, race, sex))) = want else {
        return;
    };
    // A look is listed by a trainer's display; the hero wears the race and sex's own body.
    let Some(display) = char_create.as_deref().and_then(|c| c.0.body_display(race, sex)) else {
        return;
    };
    let mut pos = hero::arena(selection.stage_def());
    if let Some(h) = world.terrain_height_under(pos) {
        pos.y = h;
    }
    let serial = run.guid();
    hero::spawn_hero(
        &mut commands,
        &data::CLASSES[class],
        display,
        race,
        sex,
        selection.custom,
        &items,
        serial,
        pos,
    );
}

pub(super) fn start_run(run: &mut Run, selection: &mut Selection) -> bool {
    let (Some(class), Some(&(_, race, _))) = (
        selection.class_def(),
        selection.look.and_then(|i| selection.looks.get(i)),
    ) else {
        return false;
    };
    // The world goes to the battleground picked; until now it stood in the last one.
    selection.stage = selection.map;
    let next_guid = run.next_guid;
    let ranks = run.ranks;
    let talents = run.talents;
    *run = Run {
        class,
        race,
        next_guid,
        ranks,
        talents,
        difficulty: selection.difficulty,
        affixes: super::difficulty::active(selection.difficulty, super::difficulty::week()),
        ..Run::default()
    };
    run.rerolls = super::merchant::rerolls(&ranks);
    run.banishes = super::merchant::banishes(&ranks);
    for _ in 0..super::merchant::provisions(&ranks) {
        run.bag.add(super::bag::potion());
    }
    let first = run.own(data::ability(class.start), 0.5);
    run.abilities.push(first);
    run.take_openers();
    run.hp = run.stats().max_hp;
    run.version += 1;
    true
}

/// The race and sex pairs a class can be, `(display, race, sex)`: every pair the create screen
/// allows (`CharBaseInfo`), with the race and sex's body; before that catalog loads, the pairs its
/// class trainers come in.
pub(super) fn looks_for(
    class: &data::ClassDef,
    creatures: &crate::entities::Creatures,
    char_create: Option<&crate::entities::CharCreate>,
) -> Vec<(u32, u8, u8)> {
    let mut out: Vec<(u32, u8, u8)> = Vec::new();
    if let Some(cc) = char_create {
        for race in 1..=8u8 {
            for sex in 0..=1u8 {
                if let (true, Some(d)) = (cc.0.allows(race, class.id), cc.0.body_display(race, sex)) {
                    out.push((d, race, sex));
                }
            }
        }
        if !out.is_empty() {
            return out;
        }
    }
    for &d in class.looks {
        if let Some((race, sex)) = creatures.display_race_sex(d) {
            if !out.iter().any(|&(_, r, s)| r == race && s == sex) {
                out.push((d, race, sex));
            }
        }
    }
    out.sort_by_key(|&(_, r, s)| (r, s));
    out
}

pub(super) fn keys(
    keys: Res<ButtonInput<KeyCode>>,
    phase: Res<State<Phase>>,
    mut selection: ResMut<Selection>,
    mut run: ResMut<Run>,
    mut next: ResMut<NextState<Phase>>,
    mut settings: ResMut<super::panels::SettingsOpen>,
    bag: Res<super::panels::BagOpen>,
    map: Res<super::worldmap::MapOpen>,
    mut replay: ResMut<Replay>,
    heroes: Query<(), With<Hero>>,
    (step, delete, profile): (
        Res<super::menu::MenuStep>,
        Res<super::menu::DeleteOpen>,
        Res<super::profile::Profile>,
    ),
) {
    match phase.get() {
        Phase::Menu => {
            // A replay goes once the reset run's hero is back on its feet; Enter is Enter World
            // on character select only.
            let again = replay.0 && !heroes.is_empty();
            let enter = keys.just_pressed(KeyCode::Enter)
                && *step == super::menu::MenuStep::Select
                && !delete.0
                && profile.hero().is_some();
            if (enter || again) && start_run(&mut run, &mut selection) {
                next.set(Phase::Playing);
            }
            if again {
                replay.0 = false;
            }
        }
        Phase::Playing => {
            if keys.just_pressed(KeyCode::Escape) {
                next.set(Phase::Paused);
            }
        }
        // Escape closes Settings first, then the pause menu.
        Phase::Paused => {
            // The backpack's and the map's own Escape are [`super::panels::bag_input`]'s and
            // [`super::worldmap::map_input`]'s.
            if keys.just_pressed(KeyCode::Escape) && !bag.0 && !map.0 {
                if settings.0 {
                    settings.0 = false;
                } else {
                    next.set(Phase::Playing);
                }
            }
        }
        Phase::LevelUp => {}
        // Enter plays again, Escape goes back to the pick screen.
        Phase::GameOver => {
            if keys.just_pressed(KeyCode::Enter) {
                replay.0 = true;
                next.set(Phase::Menu);
            } else if keys.just_pressed(KeyCode::Escape) {
                next.set(Phase::Menu);
            }
        }
    }
}

/// The class's looks once the creature data is in, defaulting to the first. The auto-runner picks
/// a class with no look; the menu itself always sets both.
pub(super) fn refresh_menu(
    mut selection: ResMut<Selection>,
    creatures: Option<Res<crate::entities::Creatures>>,
    char_create: Option<Res<crate::entities::CharCreate>>,
) {
    if let (Some(class), Some(creatures)) = (selection.class_def(), creatures.as_deref()) {
        if selection.looks.is_empty() {
            let looks = looks_for(class, creatures, char_create.as_deref());
            if !looks.is_empty() {
                selection.looks = looks;
                selection.look = Some(0);
                selection.version += 1;
            }
        }
    }
}

#[allow(clippy::too_many_arguments, clippy::type_complexity)]
pub(super) fn refresh_hud(
    mut commands: Commands,
    time: Res<Time>,
    phase: Res<State<Phase>>,
    mut run: ResMut<Run>,
    selection: Res<Selection>,
    font: Res<HudFont>,
    mut texts: ParamSet<(
        Query<&mut Text, With<LevelText>>,
        Query<&mut Text, With<TimerText>>,
        Query<&mut Text, With<KillText>>,
        Query<&mut Text, With<BannerText>>,
        Query<&mut Text, With<OverTitle>>,
        Query<&mut Text, With<OverStats>>,
        Query<&mut Text, With<XpText>>,
    )>,
    mut xp_fill: Query<&mut Node, With<XpFill>>,
    slots: Query<(Entity, &BarSlot)>,
    mut sweeps: ResMut<Assets<SweepUiMaterial>>,
    mut last_version: Local<Option<u32>>,
) {
    let need = data::xp_to_next(run.level);
    if let Ok(mut n) = xp_fill.single_mut() {
        n.width = Val::Percent((run.xp / need * 100.0).clamp(0.0, 100.0));
    }
    if let Ok(mut t) = texts.p6().single_mut() {
        let xp = format!("XP {} / {}", run.xp as u32, need as u32);
        if **t != xp {
            **t = xp;
        }
    }
    if let Ok(mut t) = texts.p0().single_mut() {
        **t = format!("Level {}", run.level);
    }
    let secs = run.elapsed as u32;
    if let Ok(mut t) = texts.p1().single_mut() {
        **t = format!("{:02}:{:02}", secs / 60, secs % 60);
    }
    let kills = run.kills;
    if let Ok(mut t) = texts.p2().single_mut() {
        **t = format!("Kills {kills}");
    }
    let banner = match run.banner.as_mut() {
        Some((msg, t)) => {
            *t -= time.delta_secs();
            if *t > 0.0 {
                msg.clone()
            } else {
                String::new()
            }
        }
        None => String::new(),
    };
    if banner.is_empty() {
        run.banner = None;
    }
    // The picker owns the screen: an announcement waits until it closes.
    let banner = if *phase.get() == Phase::LevelUp {
        String::new()
    } else {
        banner
    };
    if let Ok(mut t) = texts.p3().single_mut() {
        if **t != banner {
            **t = banner;
        }
    }
    let title = if run.won {
        "Victory!"
    } else {
        "You have fallen"
    }
    .to_string();
    if let Ok(mut t) = texts.p4().single_mut() {
        **t = title;
    }
    let summary = format!(
        "{} {} in {}   —   press Enter to play again",
        crate::char_select::race_name(run.race),
        run.class.name,
        selection.map_def().name,
    );
    if let Ok(mut t) = texts.p5().single_mut() {
        if **t != summary {
            **t = summary;
        }
    }

    // The action bar's icons, rebuilt when the build changes.
    if *last_version == Some(run.version) {
        return;
    }
    *last_version = Some(run.version);
    let f = &font.0;
    for (slot, &BarSlot(i)) in &slots {
        commands.entity(slot).despawn_related::<Children>();
        let entry = if i < 6 {
            run.abilities
                .get(i)
                .map(|o| (o.def.spell, o.level, TipFor::Ability(i)))
        } else {
            run.passives
                .get(i - 6)
                .map(|(p, l)| (p.spell, *l, TipFor::Passive(i - 6)))
        };
        // An empty slot shows the bar's own socket.
        let Some((spell, level, tip)) = entry else {
            continue;
        };
        commands.entity(slot).with_children(|slot| {
            slot.spawn((
                Node {
                    width: Val::Percent(100.0),
                    height: Val::Percent(100.0),
                    ..default()
                },
                Interaction::default(),
                tip,
            ))
            .with_children(|b| {
                b.spawn(icon(spell, SLOT));
                // The cooldown sweep sits over the icon, under the frame and the rank.
                if let TipFor::Ability(index) = tip {
                    let handle = sweeps.add(SweepUiMaterial { sweep: 0.0 });
                    b.spawn((
                        Node {
                            position_type: PositionType::Absolute,
                            width: Val::Percent(100.0),
                            height: Val::Percent(100.0),
                            ..default()
                        },
                        MaterialNode(handle.clone()),
                        AbilitySweep { handle, index },
                    ));
                }
                b.spawn(quickslot_frame());
                // `Count`, NumberFontNormal at BOTTOMRIGHT (−2,2): the rank.
                b.spawn(Node {
                    position_type: PositionType::Absolute,
                    right: Val::Px(2.0),
                    bottom: Val::Px(2.0),
                    ..default()
                })
                .with_children(|n| {
                    n.spawn(text(f, level.to_string(), 12.0, Color::WHITE));
                });
            });
        });
    }
}

/// Draw each [`UiArt`] region once its file can be read.
pub(super) fn fill_art(
    mut commands: Commands,
    mut regions: Query<(Entity, &mut ImageNode, &UiArt), Without<ArtDone>>,
    assets: Option<ResMut<benilla_assets::WorldAssets>>,
    mut images: ResMut<Assets<Image>>,
) {
    let Some(mut assets) = assets else { return };
    for (e, mut img, art) in &mut regions {
        commands.entity(e).insert(ArtDone);
        let Some(h) = assets.sprite_texture(art.path, &mut images) else {
            warn!("survivors: no UI art {}", art.path);
            continue;
        };
        let [l, r, t, b] = art.coords;
        if let Some(size) = images.get(&h).map(Image::size_f32) {
            img.rect = Some(Rect::new(l * size.x, t * size.y, r * size.x, b * size.y));
        }
        img.image = h;
        img.color = art.tint;
    }
}

/// The reference lays its UI out on a screen 768 units tall at any resolution (`useUiScale` off).
pub(super) fn apply_ui_scale(
    windows: Query<&Window, With<PrimaryWindow>>,
    mut scale: ResMut<UiScale>,
) {
    let Ok(window) = windows.single() else { return };
    let want = window.height() / 768.0;
    if want > 0.0 && (scale.0 - want).abs() > 1e-4 {
        scale.0 = want;
    }
}

/// Between the hero's feet and the top of its plate's bar, in gx units.
const PLATE_FEET_GAP: f32 = 0.004;
/// A couple of screen pixels lower than the gap alone sets it.
const PLATE_NUDGE: f32 = 2.0;

/// The hero's nameplate under its feet, sized from the screen diagonal as [`crate::vplates`]
/// sizes a plate, outside the UI scale. The border's top half seats a name the hero has none of,
/// so the plate rises until its bar sits just under the feet.
#[allow(clippy::type_complexity)]
pub(super) fn hero_plate(
    run: Res<Run>,
    ui_scale: Res<UiScale>,
    hero: Query<&Transform, With<Hero>>,
    cams: Query<(&Camera, &Transform), With<WorldCamera>>,
    mut nodes: ParamSet<(
        Query<(&mut Node, &mut Visibility), With<HpFrame>>,
        Query<&mut Node, With<HpBar>>,
        Query<&mut Node, With<HpFill>>,
        Query<&mut Node, With<ShieldFill>>,
        Query<&mut Node, With<HpLevelSeat>>,
    )>,
    mut level: Query<(&mut Text, &mut TextFont), With<HpLevel>>,
) {
    use crate::vplates::{
        gx_px, plate_basis, text_px, BAR_H, BAR_OFF_X, BAR_OFF_Y, BAR_W, LEVEL_H, LEVEL_OFF_X,
        LEVEL_OFF_Y, PLATE_H, PLATE_W,
    };
    let seat = hero.single().ok().and_then(|h| {
        let (cam, tf) = cams.single().ok()?;
        let viewport = cam.logical_viewport_size()?;
        let feet = cam
            .world_to_viewport(&GlobalTransform::from(*tf), h.translation)
            .ok()?;
        Some((feet, viewport))
    });
    let mut frames = nodes.p0();
    let Ok((mut frame, mut vis)) = frames.single_mut() else {
        return;
    };
    let Some((feet, viewport)) = seat else {
        *vis = Visibility::Hidden;
        return;
    };
    *vis = Visibility::Inherited;
    let s = ui_scale.0;
    let basis = plate_basis(viewport);
    let gx = |v: f32| gx_px(v, basis) / s;
    let (pw, ph) = (gx(PLATE_W), gx(PLATE_H));
    let bar_top = ph - gx(BAR_OFF_Y) - gx(BAR_H);
    frame.width = Val::Px(pw);
    frame.height = Val::Px(ph);
    frame.left = Val::Px(feet.x / s - pw / 2.0);
    frame.top = Val::Px(feet.y / s + gx(PLATE_FEET_GAP) - bar_top + PLATE_NUDGE / s);
    if let Ok(mut bar) = nodes.p1().single_mut() {
        bar.left = Val::Px(gx(BAR_OFF_X));
        bar.top = Val::Px(bar_top);
        bar.width = Val::Px(gx(BAR_W));
        bar.height = Val::Px(gx(BAR_H));
    }
    let stats = run.stats();
    let hp = (run.hp / stats.max_hp).clamp(0.0, 1.0);
    let shield = if run.shield_t > 0.0 {
        (run.shield / stats.max_hp).clamp(0.0, 1.0)
    } else {
        0.0
    };
    if let Ok(mut n) = nodes.p2().single_mut() {
        n.width = Val::Percent(hp * 100.0);
    }
    if let Ok(mut n) = nodes.p3().single_mut() {
        n.width = Val::Percent(shield * 100.0);
    }
    if let Ok(mut seat) = nodes.p4().single_mut() {
        seat.left = Val::Px(pw - gx(LEVEL_OFF_X));
        seat.top = Val::Px(ph - gx(LEVEL_OFF_Y));
    }
    if let Ok((mut text, mut font)) = level.single_mut() {
        let n = run.level.to_string();
        if text.0 != n {
            text.0 = n;
        }
        let size = text_px(LEVEL_H, basis) / s;
        if font.font_size != size {
            font.font_size = size;
        }
    }
}

/// `MainMenuExpBar`'s `OnEnter` and `OnLeave`: the numbers show while the cursor is on the bar.
pub(super) fn xp_hover(
    bars: Query<&Interaction, (With<XpBar>, Changed<Interaction>)>,
    mut texts: Query<&mut Visibility, With<XpText>>,
) {
    for interaction in &bars {
        let want = if *interaction == Interaction::None {
            Visibility::Hidden
        } else {
            Visibility::Inherited
        };
        for mut v in &mut texts {
            *v = want;
        }
    }
}

#[allow(clippy::type_complexity)]
pub(super) fn show_panels(
    phase: Res<State<Phase>>,
    mut roots: ParamSet<(
        Query<(&mut Visibility, &mut Node), With<MenuRoot>>,
        Query<(&mut Visibility, &mut Node), With<HudRoot>>,
        Query<(&mut Visibility, &mut Node), With<LevelUpRoot>>,
        Query<(&mut Visibility, &mut Node), With<PauseRoot>>,
        Query<(&mut Visibility, &mut Node), With<OverRoot>>,
    )>,
) {
    let p = *phase.get();
    // A hidden panel leaves the layout too: a merely invisible button still takes clicks.
    let set = |(mut v, mut node): (Mut<Visibility>, Mut<Node>), on: bool| {
        let want = if on {
            Visibility::Inherited
        } else {
            Visibility::Hidden
        };
        if *v != want {
            *v = want;
        }
        let display = if on { Display::Flex } else { Display::None };
        if node.display != display {
            node.display = display;
        }
    };
    for root in &mut roots.p0() {
        set(root, p == Phase::Menu);
    }
    for root in &mut roots.p1() {
        set(root, p != Phase::Menu && p != Phase::GameOver);
    }
    for root in &mut roots.p2() {
        set(root, p == Phase::LevelUp);
    }
    for root in &mut roots.p3() {
        set(root, p == Phase::Paused);
    }
    for root in &mut roots.p4() {
        set(root, p == Phase::GameOver);
    }
}
