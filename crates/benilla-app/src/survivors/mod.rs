//! Warcraft Survivors: a top-down survival mode on the benilla world, started by
//! [`crate::run_survivors`]. There is no server: the hero, the enemies and the spells are local
//! entities dressed by the same attach, animation and spell-visual systems a streamed unit gets,
//! on a battleground picked at the menu ([`data::MAPS`]), with the player controller and FrameXML
//! off ([`crate::run_mode::CaptureMode`]).

mod abilities;
mod auto;
mod bag;
mod levelup;
mod cards;
mod data;
mod difficulty;
mod enemies;
mod fill;
mod gear;
mod grade;
mod hero;
mod hide_ui;
mod hud;
mod menu;
mod merchant;
mod minimap;
mod mobility;
mod pad;
mod panels;
mod profile;
mod talents;
mod achievements;
mod units;
mod postcard;
mod worldmap;

use benilla_world::schedule::WorldStage;
use bevy::prelude::*;

use data::{AbilityDef, ClassDef, PassiveDef};

/// Set by [`crate::run_survivors`] before the app builds. wasm32 has no process environment, so
/// the flag lives here; `WOW_SURVIVORS` (`?survivors=1` / `__wenilla_env.survivors` on the web)
/// still turns it on from outside.
pub(crate) static ACTIVE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

pub(crate) fn active() -> bool {
    ACTIVE.load(std::sync::atomic::Ordering::Relaxed)
        || crate::webenv::var("WOW_SURVIVORS").is_some()
}

pub(crate) struct SurvivorsPlugin;

impl Plugin for SurvivorsPlugin {
    fn build(&self, app: &mut App) {
        // Present before `OnEnter(InWorld)`, where the UI lifecycle decides not to load FrameXML.
        // The tuned plugins leave gamepads out, as 1.12 has none; this mode reads them.
        if !app.is_plugin_added::<bevy::gilrs::GilrsPlugin>() {
            app.add_plugins(bevy::gilrs::GilrsPlugin);
        }
        app.insert_resource(crate::run_mode::CaptureMode)
            .add_plugins(grade::plugin)
            .add_plugins(hide_ui::plugin)
            .add_plugins(difficulty::plugin)
            .add_plugins(talents::plugin)
            .add_plugins(achievements::plugin)
            .init_state::<Phase>()
            .init_resource::<Rng>()
            .init_resource::<Selection>()
            .init_resource::<Run>()
            .init_resource::<profile::Profile>()
            .init_resource::<gear::GearCatalog>()
            .add_systems(Update, gear::build_catalog.before(hud::menu_preview))
            .init_resource::<panels::SettingsOpen>()
            .init_resource::<panels::Tab>()
            .init_resource::<panels::BagOpen>()
            .init_resource::<merchant::MerchantOpen>()
            .init_resource::<worldmap::MapOpen>()
            .init_resource::<menu::StageVeil>()
            .init_resource::<hud::Replay>()
            .add_systems(
                Update,
                (
                    worldmap::build_map.after(panels::build_panels),
                    worldmap::map_input.after(panels::bag_input).before(hud::keys),
                    worldmap::fill_map.after(worldmap::map_input),
                )
                    .chain()
                    .after(WorldStage::Input),
            )
            .add_systems(
                Update,
                (merchant::build_merchant, merchant::merchant)
                    .chain()
                    .after(menu::build_menu)
                    .before(crate::glue::GlueVisuals),
            )
            .add_systems(
                Update,
                (levelup::build_levelup, levelup::levelup)
                    .chain()
                    .after(panels::build_panels)
                    .before(cards::choose_card)
                    .before(crate::glue::GlueVisuals),
            )
            .add_systems(Update, panels::keep_camera.after(WorldStage::Input))
            .init_resource::<pad::Pad>()
            .add_systems(PreUpdate, pad::read_pad.after(bevy::input::InputSystems))
            .init_resource::<pad::PadFocus>()
            .add_systems(
                PreUpdate,
                pad::focus
                    .after(pad::read_pad)
                    .after(bevy::ui::UiSystems::Focus)
                    .before(crate::glue::glue_clicks),
            )
            .add_systems(Update, pad::log_pads)
            .add_systems(
                Update,
                (panels::build_panels, panels::settings.before(crate::glue::GlueVisuals)),
            )
            .add_systems(Update, hud::refresh_bar_info.after(hud::refresh_hud))
            .init_resource::<menu::MenuStep>()
            .init_resource::<menu::NameDraft>()
            .init_resource::<postcard::Postcards>()
            .add_systems(Startup, postcard::boot_stage)
            .add_systems(
                Update,
                (postcard::take_postcard, postcard::show_postcard)
                    .chain()
                    .after(hud::show_panels),
            )
            .init_resource::<menu::DeleteOpen>()
            .add_systems(
                PreUpdate,
                menu::type_name
                    .after(pad::read_pad)
                    .before(crate::glue::glue_clicks),
            )
            .add_systems(
                Update,
                (menu::show_step, menu::refresh_info, menu::refresh_chars)
                    .after(menu::menu_clicks)
                    .before(crate::glue::GlueVisuals),
            )
            .init_resource::<hero::CamRig>()
            .init_resource::<hero::AimPoint>()
            .init_resource::<abilities::PendingHits>()
            .init_resource::<enemies::Spawner>()
            .init_resource::<hud::Offer>()
            .init_resource::<cards::PendingPick>()
            .add_message::<abilities::Hit>()
            .add_message::<enemies::Loot>()
            .add_plugins(bevy::ui_render::UiMaterialPlugin::<hud::SweepUiMaterial>::default())
            .add_plugins(bevy::ui_render::UiMaterialPlugin::<fill::FillMaterial>::default())
            .add_systems(Startup, hud::setup_hud)
            .add_systems(Update, hero::daylight)
            .add_systems(
                Update,
                (
                    hero::drop_stray_buttons,
                    hero::aim_cursor,
                    mobility::cast_mobility,
                    hero::drive_hero,
                    hero::place_camera,
                )
                    .chain()
                    .in_set(WorldStage::Input),
            )
            .add_systems(
                Update,
                (
                    enemies::spawn_enemies,
                    enemies::move_enemies,
                    abilities::cast_abilities,
                    abilities::tick_areas,
                    abilities::apply_hits,
                    enemies::tick_marks,
                    enemies::drop_loot,
                    bag::drop_items,
                    gear::boss_drops,
                    enemies::collect_gems,
                    bag::collect_pickups,
                    bag::use_items,
                    hero::hero_vitals,
                )
                    .chain()
                    .after(WorldStage::Input)
                    .run_if(in_state(Phase::Playing))
                    // Entering a battleground raises its loading screen: the run waits behind it.
                    .run_if(|l: Res<crate::loading_screen::LoadingScreen>| !l.covering()),
            )
            .add_systems(
                Update,
                (enemies::reap_dead, enemies::still_gems).after(WorldStage::Input),
            )
            .add_systems(
                Update,
                (
                    hero::follow_map,
                    hud::menu_preview,
                    (panels::buttons, panels::bag_input).chain(),
                    hud::keys,
                    hud::refresh_menu,
                    menu::restore_hero,
                    menu::build_menu,
                    menu::rebuild_lists,
                    menu::refresh_armor,
                    (menu::menu_clicks, menu::stage_follows_pick, menu::stage_veil).chain(),
                    menu::refresh_menu_ui.before(crate::glue::GlueVisuals),
                    cards::deal_cards,
                    cards::choose_card,
                    cards::animate_cards,
                    hud::refresh_hud,
                    hud::refresh_results,
                    hud::fill_icons,
                    hud::update_cooldown_sweeps,
                    hud::refresh_mobility,
                    hud::show_panels,
                )
                    .chain()
                    .after(WorldStage::Input),
            )
            .add_systems(
                Update,
                (
                    hud::apply_ui_scale,
                    hud::fill_art,
                    hud::xp_hover,
                    hud::refresh_items,
                    panels::refresh_bag,
                    hud::icon_tooltip,
                    hud::hero_plate,
                    minimap::map_buttons,
                    minimap::zone_text,
                    minimap::compose,
                )
                    .chain()
                    .after(hud::show_panels),
            )
            .add_systems(OnEnter(Phase::Playing), unpause)
            .add_systems(OnEnter(Phase::LevelUp), (pause, hud::roll_offer))
            .add_systems(OnEnter(Phase::Paused), pause)
            .add_systems(OnEnter(Phase::GameOver), (unpause, profile::record_run))
            .add_systems(OnEnter(Phase::Menu), (unpause, reset_run));
        if let Some(auto) = auto::from_env() {
            app.insert_resource(auto)
                .add_systems(
                    Update,
                    auto::drive.after(hud::keys).before(hud::refresh_menu),
                )
                .add_systems(Update, auto::plan.before(WorldStage::Input))
                .add_systems(Update, (auto::extra.after(auto::drive), auto::gpu_log));
        }
    }
}

/// The screen the mode is on.
#[derive(States, Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub(super) enum Phase {
    #[default]
    Menu,
    Playing,
    LevelUp,
    Paused,
    GameOver,
}

/// Everything spawned for a run, despawned when the next begins.
#[derive(Component)]
pub(super) struct RunEntity;

/// The class, look and battleground picked at the menu; the battleground holds for the run.
#[derive(Resource, Default)]
pub(super) struct Selection {
    pub class: Option<usize>,
    /// `(display, race, sex)`, one per race and sex the class's trainers come in.
    pub looks: Vec<(u32, u8, u8)>,
    pub look: Option<usize>,
    /// The look's customization dials.
    pub custom: units::Custom,
    /// An index into [`data::MAPS`].
    pub map: usize,
    /// The battleground the world is standing in. At the menu it follows `map` once the pick
    /// has rested a moment ([`menu::stage_follows_pick`]), behind a veil rather than the loading
    /// screen, so the hero stands in the zone picked.
    pub stage: usize,
    /// The difficulty picked for `map` ([`difficulty`]), within what the character has open.
    pub difficulty: u8,
    /// Bumped on every change, so the menu rebuilds once.
    pub version: u32,
}

impl Selection {
    pub fn class_def(&self) -> Option<&'static ClassDef> {
        self.class.map(|i| &data::CLASSES[i])
    }

    pub fn map_def(&self) -> &'static data::MapDef {
        &data::MAPS[self.map.min(data::MAPS.len() - 1)]
    }

    pub fn stage_def(&self) -> &'static data::MapDef {
        &data::MAPS[self.stage.min(data::MAPS.len() - 1)]
    }
}

/// An ability the hero has, with its own cooldown.
pub(super) struct Owned {
    pub def: &'static AbilityDef,
    pub level: u8,
    pub cd: f32,
    /// What the character's talents add to it.
    pub bonus: talents::Bonus,
}

impl Owned {
    pub fn damage_mult(&self) -> f32 {
        (1.0 + 0.3 * f32::from(self.level - 1)) * (1.0 + self.bonus.dmg)
    }
    pub fn cooldown(&self, stats: &Stats) -> f32 {
        let base = self.def.cooldown
            * 0.93f32.powi(i32::from(self.level) - 1)
            * (1.0 - self.bonus.cd).max(0.5);
        (base * (1.0 - stats.haste).max(0.35)).max(0.2)
    }
    pub fn count(&self) -> u32 {
        let extra = [3u8, 5, 7].iter().filter(|&&l| self.level >= l).count() as u32;
        self.def.count + extra + self.bonus.count
    }
    pub fn radius(&self, stats: &Stats) -> f32 {
        self.def.radius
            * (1.0 + 0.08 * f32::from(self.level - 1))
            * (1.0 + self.bonus.area)
            * stats.area
    }
    pub fn duration(&self) -> f32 {
        self.def.duration * (1.0 + 0.1 * f32::from(self.level - 1))
    }
}

/// The hero's derived numbers, from the base and the passives.
#[derive(Clone, Copy)]
pub(super) struct Stats {
    pub might: f32,
    pub max_hp: f32,
    pub speed: f32,
    pub regen: f32,
    pub haste: f32,
    pub area: f32,
    pub magnet: f32,
    pub growth: f32,
    pub armor: f32,
    pub crit: f32,
}

pub(super) const BASE_HP: f32 = 120.0;
pub(super) const BASE_SPEED: f32 = 7.0;
pub(super) const BASE_MAGNET: f32 = 4.5;

/// One run's state.
#[derive(Resource)]
pub(super) struct Run {
    pub class: &'static ClassDef,
    pub race: u8,
    pub elapsed: f32,
    pub kills: u32,
    pub level: u32,
    pub xp: f32,
    pub hp: f32,
    pub abilities: Vec<Owned>,
    pub passives: Vec<(&'static PassiveDef, u8)>,
    pub shield: f32,
    pub shield_t: f32,
    pub immune_t: f32,
    pub thorns: f32,
    pub thorns_t: f32,
    pub thorns_spell: u32,
    pub heal_rate: f32,
    pub heal_t: f32,
    /// The class mobility's cooldown and running effect.
    mobile: mobility::MobilityState,
    pub pending_levels: u32,
    pub bosses: u32,
    pub rings: u32,
    pub won: bool,
    /// The zone this run's win opened, for the results.
    pub opened: Option<usize>,
    /// Bosses killed, and the armor they dropped this run.
    pub boss_kills: u32,
    pub loot: Vec<gear::Piece>,
    /// What the armor worn adds, [`gear::bonus`].
    pub gear_might: f32,
    pub gear_hp: f32,
    /// Seconds since the hero fell, while the death plays out.
    pub dead_t: Option<f32>,
    pub next_guid: u64,
    pub damage_done: f64,
    /// Bumped whenever abilities or passives change, so the HUD rebuilds the icon rows once.
    pub version: u32,
    /// A centre-screen announcement and its seconds left.
    pub banner: Option<(String, f32)>,
    /// The backpack, the worn trinkets and the coins picked up.
    pub bag: bag::Bag,
    /// At the results: what went to the purse, the coins and the bag sold.
    pub earned: u64,
    /// The merchant's upgrades, as bought when the run began.
    pub ranks: merchant::Ranks,
    /// The character's talents, as learned when the run began.
    pub talents: talents::Picked,
    /// The run time the next rare elite shows; 0 until the first is rolled.
    pub next_rare: f32,
    /// Level-up rerolls and banishes left, from the merchant's Fortune and Banishment.
    pub rerolls: u8,
    pub banishes: u8,
    /// The spells and auras banished: they are offered no more this run.
    pub banished: Vec<&'static str>,
    /// The next card picked is banished rather than taken.
    pub banishing: bool,
    /// The run's difficulty ([`difficulty`]) and the week's affixes it brings.
    pub difficulty: u8,
    pub affixes: Vec<difficulty::Affix>,
    pub affix: difficulty::AffixState,
    /// At the results: the difficulty this run's win opened, if it opened one.
    pub raised: Option<u8>,
}

impl Default for Run {
    fn default() -> Self {
        Self {
            class: &data::CLASSES[0],
            race: 0,
            elapsed: 0.0,
            kills: 0,
            level: 1,
            xp: 0.0,
            hp: BASE_HP,
            abilities: Vec::new(),
            passives: Vec::new(),
            shield: 0.0,
            shield_t: 0.0,
            immune_t: 0.0,
            thorns: 0.0,
            thorns_t: 0.0,
            thorns_spell: 0,
            heal_rate: 0.0,
            heal_t: 0.0,
            mobile: mobility::MobilityState::default(),
            pending_levels: 0,
            bosses: 0,
            rings: 0,
            won: false,
            opened: None,
            boss_kills: 0,
            loot: Vec::new(),
            gear_might: 0.0,
            gear_hp: 0.0,
            dead_t: None,
            next_guid: 1,
            damage_done: 0.0,
            version: 0,
            banner: None,
            bag: bag::Bag::default(),
            earned: 0,
            ranks: [0; merchant::UPGRADES.len()],
            talents: [0; talents::SLOTS],
            next_rare: 0.0,
            rerolls: 0,
            banishes: 0,
            banished: Vec::new(),
            banishing: false,
            difficulty: 0,
            affixes: Vec::new(),
            affix: difficulty::AffixState::default(),
            raised: None,
        }
    }
}

impl Run {
    pub fn stats(&self) -> Stats {
        let mut s = Stats {
            might: 1.0,
            max_hp: BASE_HP,
            speed: BASE_SPEED,
            regen: 0.0,
            haste: 0.0,
            area: 1.0,
            magnet: BASE_MAGNET,
            growth: 1.0,
            armor: 0.0,
            crit: 0.05,
        };
        // Tanky classes start tougher, cloth starts quicker.
        match self.class.id {
            1 | 2 => s.max_hp += 40.0,
            7 | 11 | 3 | 4 => s.max_hp += 15.0,
            _ => s.speed += 0.5,
        }
        s.might += self.gear_might;
        s.max_hp *= 1.0 + self.gear_hp;
        for &(p, level) in &self.passives {
            bag::add_stat(&mut s, p.stat, p.per_level * f32::from(level));
        }
        self.bag.apply(&mut s);
        merchant::apply(&self.ranks, &mut s);
        talents::apply(self.class.id, &self.talents, &mut s);
        s
    }

    pub fn guid(&mut self) -> u64 {
        self.next_guid += 1;
        self.next_guid
    }
}

/// xorshift64*: the mode's dice, seeded from the clock.
#[derive(Resource)]
pub(super) struct Rng(u64);

impl Default for Rng {
    fn default() -> Self {
        let seed = web_time::SystemTime::now()
            .duration_since(web_time::UNIX_EPOCH)
            .map(|d| d.as_nanos() as u64)
            .unwrap_or(0x9E37_79B9_7F4A_7C15);
        Self(seed | 1)
    }
}

impl Rng {
    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }
    /// Uniform in `[0, 1)`.
    pub fn f32(&mut self) -> f32 {
        (self.next_u64() >> 40) as f32 / (1u64 << 24) as f32
    }
    pub fn range(&mut self, lo: f32, hi: f32) -> f32 {
        lo + (hi - lo) * self.f32()
    }
    pub fn index(&mut self, len: usize) -> usize {
        (self.next_u64() % len.max(1) as u64) as usize
    }
}

fn pause(mut time: ResMut<Time<Virtual>>) {
    time.pause();
}

fn unpause(mut time: ResMut<Time<Virtual>>) {
    time.unpause();
}

/// Back at the menu: everything the last run spawned goes, and the run starts over.
fn reset_run(
    mut commands: Commands,
    spawned: Query<Entity, With<RunEntity>>,
    mut run: ResMut<Run>,
    mut pending: ResMut<abilities::PendingHits>,
    mut spawner: ResMut<enemies::Spawner>,
    mut selection: ResMut<Selection>,
) {
    for e in &spawned {
        commands.entity(e).despawn();
    }
    // Guids stay unique across runs: caches keyed by guid may outlive a despawn by a frame.
    let next_guid = run.next_guid;
    *run = Run {
        next_guid,
        ..Run::default()
    };
    pending.0.clear();
    *spawner = enemies::Spawner::default();
    // The preview hero is respawned for the look still picked.
    selection.version += 1;
}
