//! `WOW_SURVIVORS_AUTO=<class name>`: a hands-off run for testing. It picks the class and its first
//! look, begins once the world is up, takes a random card at every level, walks to the nearest
//! gem away from the crowd and logs the run every ten seconds; `WOW_SURVIVORS_SHOTS=<dir>` also
//! saves a screenshot every few seconds, which needs no window focus. A `:idle`, `:all` or `:late`
//! suffix on the class name changes the run, as the fields below say; `:settings` pauses and shows
//! each tab of Settings, for their screenshots; `:bag` opens the backpack 25 seconds in,
//! `:merchant` the merchant on the pick screen, `:zones` stands in every zone on the pick screen
//! before the run, `:map` opens the world map 20 seconds in, and `:difficulty` shows the
//! difficulty dialog before the run (`WOW_SURVIVORS_DIFFICULTY=<n>` sets the run's).
//! `WOW_SURVIVORS_MAP=<index or name>` picks the battleground, and `WOW_SURVIVORS_LOOT=rich` makes
//! coins and items drop twenty times as often.

use bevy::prelude::*;
use bevy::render::view::screenshot::{save_to_disk, Screenshot};

use super::enemies::{Enemy, Gem};
use super::hero::Hero;
use super::hud::{self, Offer};
use super::units::flat;
use super::{data, Phase, Rng, Run, Selection};

#[derive(Resource)]
pub(super) struct Auto {
    class: usize,
    /// An index into [`data::MAPS`].
    map: usize,
    /// `<class>:idle`: stand still, to reach the results screen quickly.
    idle: bool,
    /// `<class>:all`: the class's whole ability pool from the first second.
    all: bool,
    /// `<class>:late`: the whole pool at its top level, two thirds of the way in, for the crowd at
    /// its thickest.
    late: bool,
    /// `<class>:settings`: pause a few seconds in and show each Settings tab.
    settings: bool,
    /// `<class>:bag`: open the backpack 25 seconds in.
    bag: bool,
    /// `<class>:merchant`: show the merchant before the run.
    merchant: bool,
    /// `<class>:zones`: the zones still to stand in at the menu, one screenshot each.
    zones_left: usize,
    /// `<class>:map`: open the world map 20 seconds in.
    map_shot: bool,
    /// `<class>:chars`: make three characters, show character select, both create steps and the
    /// delete dialog, then quit.
    chars: bool,
    /// `<class>:loading`: hold the boot loading screen up, show it, then quit.
    loading: bool,
    /// `<class>:difficulty`: show the difficulty dialog before the run.
    pub(super) difficulty: bool,
    /// Seconds the loading screen has covered the menu, for `:zones`' veil shots.
    veil_t: f32,
    /// `:merchant`: the seconds since the rare elite fell.
    rare_gone: f32,
    frames: u32,
    pub(super) wait: f32,
    shots: Option<std::path::PathBuf>,
    shot_t: f32,
    shot_n: u32,
    log_t: f32,
    dir: Vec3,
    /// The screens already captured once: the menu, the first level-ups, the results.
    pub(super) seen: Vec<String>,
}

impl Auto {
    /// One screenshot named for this screen, the first time it shows.
    pub(super) fn capture_once(&mut self, commands: &mut Commands, name: String) {
        if self.seen.contains(&name) {
            return;
        }
        // A browser has no folder to write to: the moment goes to the console instead, for a
        // DevTools driver to screenshot.
        let Some(dir) = &self.shots else {
            info!("survivors auto: capture {name}");
            self.seen.push(name);
            return;
        };
        let path = dir.join(format!("{name}.png"));
        commands
            .spawn(Screenshot::primary_window())
            .observe(save_to_disk(path));
        self.seen.push(name);
    }
}

pub(super) fn from_env() -> Option<Auto> {
    let want = crate::webenv::var("WOW_SURVIVORS_AUTO")?;
    let (name, mode) = want.trim().split_once(':').unwrap_or((want.trim(), ""));
    let idle = mode.eq_ignore_ascii_case("idle");
    let late = mode.eq_ignore_ascii_case("late");
    let all = late || mode.eq_ignore_ascii_case("all");
    let settings = mode.eq_ignore_ascii_case("settings");
    let bag = mode.eq_ignore_ascii_case("bag");
    let merchant = mode.eq_ignore_ascii_case("merchant");
    let zones = mode.eq_ignore_ascii_case("zones");
    let map_shot = mode.eq_ignore_ascii_case("map");
    let chars = mode.eq_ignore_ascii_case("chars");
    let loading = mode.eq_ignore_ascii_case("loading");
    let difficulty = mode.eq_ignore_ascii_case("difficulty");
    let class = data::CLASSES
        .iter()
        .position(|c| c.name.eq_ignore_ascii_case(name))
        .unwrap_or(0);
    let map = crate::webenv::var("WOW_SURVIVORS_MAP").map_or(0, |m| {
        let m = m.trim().to_ascii_lowercase();
        m.parse::<usize>()
            .ok()
            .filter(|&i| i < data::MAPS.len())
            .unwrap_or_else(|| {
                data::MAPS
                    .iter()
                    .position(|d| d.name.to_ascii_lowercase().contains(&m))
                    .unwrap_or(0)
            })
    });
    let shots = std::env::var_os("WOW_SURVIVORS_SHOTS").map(std::path::PathBuf::from);
    if let Some(dir) = &shots {
        let _ = std::fs::create_dir_all(dir);
    }
    Some(Auto {
        class,
        map,
        idle,
        all,
        late,
        settings,
        bag,
        merchant,
        zones_left: if zones { data::MAPS.len() } else { 0 },
        map_shot,
        chars,
        loading,
        difficulty,
        veil_t: 0.0,
        rare_gone: 0.0,
        frames: 0,
        wait: 0.0,
        shots,
        shot_t: 3.0,
        shot_n: 0,
        log_t: 0.0,
        dir: Vec3::ZERO,
        seen: Vec::new(),
    })
}

/// The walk the autopilot steers, for [`super::hero::drive_hero`].
pub(super) fn steer(auto: &Auto) -> Vec3 {
    auto.dir
}

/// Toward the nearest gem, pushed off by every enemy close enough to bite, drifting home when
/// there is nothing to pick up.
pub(super) fn plan(
    time: Res<Time<Real>>,
    mut auto: ResMut<Auto>,
    selection: Res<Selection>,
    hero: Query<&Transform, With<Hero>>,
    gems: Query<&Transform, (With<Gem>, Without<Hero>)>,
    foes: Query<(&Transform, &Enemy), Without<Hero>>,
) {
    let Some(hero) = hero.single().ok().filter(|_| !auto.idle) else {
        auto.dir = Vec3::ZERO;
        return;
    };
    let at = hero.translation;
    let mut want = gems
        .iter()
        .map(|t| flat(t.translation - at))
        .filter(|d| d.length() < 30.0)
        .min_by(|a, b| a.length().total_cmp(&b.length()))
        .map_or(Vec3::ZERO, |d| d.normalize_or_zero());
    if want == Vec3::ZERO {
        let a = time.elapsed_secs() * 0.35;
        want = Vec3::new(a.cos(), 0.0, a.sin()) * 0.5;
        let map = selection.map_def();
        let home = flat(super::hero::arena(map) - at);
        if home.length() > (map.leash * 0.5).min(40.0) {
            want += home.normalize();
        }
    }
    let mut away = Vec3::ZERO;
    for (t, e) in &foes {
        if e.dead {
            continue;
        }
        let d = flat(at - t.translation);
        let len = d.length();
        let reach = 7.0 + e.radius;
        if len < reach && len > 0.01 {
            away += d / len * (reach - len) / reach * 3.0;
        }
    }
    auto.dir = (want + away).normalize_or_zero();
}

#[allow(clippy::too_many_arguments)]
pub(super) fn drive(
    mut commands: Commands,
    time: Res<Time<Real>>,
    mut auto: ResMut<Auto>,
    phase: Res<State<Phase>>,
    mut next: ResMut<NextState<Phase>>,
    mut selection: ResMut<Selection>,
    mut run: ResMut<Run>,
    mut offer: ResMut<Offer>,
    mut rng: ResMut<Rng>,
    loading: Res<crate::loading_screen::LoadingScreen>,
    heroes: Query<&Transform, With<Hero>>,
    enemies: Query<(&Enemy, &Transform), Without<Hero>>,
    mut open: ResMut<super::panels::SettingsOpen>,
    mut tab: ResMut<super::panels::Tab>,
    mut bag: ResMut<super::panels::BagOpen>,
    mut shop: ResMut<super::merchant::MerchantOpen>,
) {
    let dt = time.delta_secs();
    auto.wait += dt;
    auto.frames += 1;
    match phase.get() {
        Phase::Menu => {
            if selection.map != auto.map {
                selection.map = auto.map;
                selection.version += 1;
                auto.wait = 0.0;
            } else if selection.class != Some(auto.class) {
                selection.class = Some(auto.class);
                selection.looks.clear();
                selection.look = None;
                selection.version += 1;
                auto.wait = 0.0;
            } else if heroes.is_empty() || loading.covering() {
                // `:zones` also shows the veil a move stands behind.
                auto.veil_t = if loading.covering() {
                    auto.veil_t + dt
                } else {
                    0.0
                };
                if auto.zones_left > 0 && auto.veil_t > 0.3 {
                    let name = format!("veil-{}", auto.map);
                    auto.capture_once(&mut commands, name);
                }
                auto.wait = 0.0;
            } else if auto.merchant && !auto.seen.iter().any(|s| s == "merchant") {
                shop.0 = auto.wait > 1.5;
                if auto.wait > 3.0 {
                    auto.capture_once(&mut commands, "merchant".into());
                    auto.wait = 0.0;
                }
            } else if shop.0 {
                shop.0 = false;
            } else if auto.zones_left > 0 {
                // Long enough for the ground around a new zone to stream in.
                if auto.wait > 5.0 {
                    let name = format!("zone-{}", auto.map);
                    auto.capture_once(&mut commands, name);
                    auto.map = (auto.map + 1) % data::MAPS.len();
                    auto.zones_left -= 1;
                    auto.wait = 0.0;
                    auto.veil_t = 0.0;
                }
            } else if auto.wait > 2.0 && auto.wait < 3.0 {
                auto.capture_once(&mut commands, "menu".into());
            } else if auto.wait > 3.0 && hud::start_run(&mut run, &mut selection) {
                info!(
                    "survivors auto: run begins as {} at {}",
                    run.class.name,
                    selection.map_def().name
                );
                if auto.all {
                    for key in run.class.pool {
                        if !run.abilities.iter().any(|o| o.def.key == *key) {
                            run.abilities.push(super::Owned {
                                def: data::ability(key),
                                level: 1,
                                cd: 0.5,
                            });
                        }
                    }
                }
                if auto.late {
                    for o in &mut run.abilities {
                        o.level = data::MAX_ABILITY_LEVEL;
                    }
                    run.elapsed = data::VICTORY_SECS * 2.0 / 3.0;
                    run.bosses = 3;
                    run.boss_kills = 3;
                    run.rings = 4;
                }
                next.set(Phase::Playing);
                auto.wait = 0.0;
            }
        }
        Phase::LevelUp => {
            // `:merchant` shows the bought charges: at level 3 a banish armed, then spent.
            if auto.merchant && run.level == 3 && auto.wait > 0.5 && run.banishes > 0 {
                run.banishing = true;
            }
            if auto.merchant && run.level == 3 && auto.wait > 1.0 && run.banishing {
                auto.capture_once(&mut commands, "banish".into());
            }
            if auto.merchant && run.level == 3 && auto.wait > 1.5 && run.banishing {
                let i = (0..offer.len()).find(|&i| hud::banish_key(offer.choices()[i]).is_some());
                if let Some(i) = i {
                    let key = hud::banish_key(offer.choices()[i]);
                    hud::banish(i, &mut run, &mut offer, &mut rng);
                    info!("survivors auto: banished {key:?}, {} left", run.banishes);
                }
            }
            // After the deal-in, so the shot shows the cards settled.
            if auto.wait > 1.2 && (run.level <= 3 || run.level == 10) {
                auto.capture_once(&mut commands, format!("levelup-{}", run.level));
            }
            if auto.wait > 1.6 {
                let n = offer.len().max(1);
                let i = (rng.range(0.0, n as f32) as usize).min(n - 1);
                hud::pick(i, &mut run, &mut offer, &mut rng, &mut next);
                auto.wait = 0.0;
            }
        }
        Phase::GameOver => {
            if auto.wait > 1.5 {
                auto.capture_once(&mut commands, "over".into());
            }
            if auto.wait > 6.0 {
                next.set(Phase::Menu);
                auto.wait = 0.0;
            }
        }
        Phase::Playing if auto.settings => {
            if auto.wait > 4.0 && !auto.seen.iter().any(|s| s.starts_with("settings")) {
                next.set(Phase::Paused);
                open.0 = true;
                auto.wait = 0.0;
            }
        }
        // `:merchant` calls a rare elite early, and shows it.
        Phase::Playing if auto.merchant => {
            auto.wait = 0.0;
            if run.next_rare == 0.0 {
                run.next_rare = 6.0;
            }
            let hero = heroes.single().map(|t| t.translation).unwrap_or_default();
            let rare = enemies.iter().find(|(e, _)| e.rare);
            // Close up while it lives; the frame after it falls, its drop under a blue beam.
            if let Some((e, t)) = rare {
                if !e.dead && t.translation.distance(hero) < 12.0 {
                    auto.capture_once(&mut commands, "rare".into());
                }
                if e.dead {
                    auto.rare_gone += dt;
                    if auto.rare_gone > 0.05 {
                        auto.capture_once(&mut commands, "rare-slain".into());
                    }
                }
            }
        }
        Phase::Playing if auto.bag => {
            if run.elapsed > 25.0 && !auto.seen.iter().any(|s| s == "bag") {
                next.set(Phase::Paused);
                bag.0 = true;
                auto.wait = 0.0;
            }
        }
        Phase::Paused if auto.bag => {
            if auto.wait > 1.0 {
                auto.capture_once(&mut commands, "bag".into());
            }
            if auto.wait > 2.0 {
                bag.0 = false;
                next.set(Phase::Playing);
            }
        }
        Phase::Paused if auto.settings => {
            use super::panels::Tab;
            for (i, (t, name)) in [
                (Tab::Video, "video"),
                (Tab::Sound, "sound"),
                (Tab::Controls, "controls"),
            ]
            .into_iter()
            .enumerate()
            {
                let at = 1.0 + i as f32 * 1.5;
                if auto.wait > at && auto.wait < at + 1.5 {
                    if *tab != t {
                        *tab = t;
                    } else if auto.wait > at + 0.8 {
                        auto.capture_once(&mut commands, format!("settings-{name}"));
                    }
                }
            }
        }
        _ => auto.wait = 0.0,
    }

    auto.log_t -= dt;
    if auto.log_t <= 0.0 && *phase.get() != Phase::Menu {
        auto.log_t = 10.0;
        let fps = auto.frames as f32 / 10.0;
        auto.frames = 0;
        let alive = enemies.iter().filter(|(e, _)| !e.dead).count();
        let build: Vec<String> = run
            .abilities
            .iter()
            .map(|o| format!("{}:{}", o.def.key, o.level))
            .chain(run.passives.iter().map(|(p, l)| format!("{}:{}", p.key, l)))
            .collect();
        info!(
            "survivors auto: {:?} t={:.0}s fps={fps:.0} alive={alive} level={} hp={:.0} kills={} damage={:.0} build=[{}]",
            phase.get(),
            run.elapsed,
            run.level,
            run.hp,
            run.kills,
            run.damage_done,
            build.join(" ")
        );
    }

    if let Some(dir) = auto.shots.clone() {
        auto.shot_t -= dt;
        if auto.shot_t <= 0.0 {
            auto.shot_t = 6.0;
            auto.shot_n += 1;
            let path = dir.join(format!("shot-{:03}.png", auto.shot_n));
            commands
                .spawn(Screenshot::primary_window())
                .observe(save_to_disk(path));
        }
    }
}

/// The whole-frame GPU time each ten seconds, median and 90th percentile, beside the run's own
/// line; the frame rate alone cannot tell the GPU from the main thread.
pub(super) fn gpu_log(
    time: Res<Time<Real>>,
    gpu: Option<Res<crate::perf::GpuMsShared>>,
    mut samples: Local<Vec<f32>>,
    mut since: Local<f32>,
) {
    let Some(gpu) = gpu else {
        return;
    };
    let ns = gpu.0.load(std::sync::atomic::Ordering::Relaxed);
    if ns > 0 {
        samples.push(ns as f32 / 1e6);
    }
    *since += time.delta_secs();
    if *since < 10.0 || samples.is_empty() {
        return;
    }
    *since = 0.0;
    samples.sort_by(f32::total_cmp);
    let n = samples.len();
    info!(
        "survivors auto: gpu median={:.2}ms p90={:.2}ms over {n} frames",
        samples[n / 2],
        samples[n * 9 / 10]
    );
    samples.clear();
}

/// What [`drive`] has no parameters left for: `:map` opens the world map 20 seconds into the run,
/// captures it and shuts it; `:idle` takes the results' Play Again.
#[allow(clippy::too_many_arguments)]
pub(super) fn extra(
    mut commands: Commands,
    time: Res<Time<Real>>,
    mut auto: ResMut<Auto>,
    phase: Res<State<Phase>>,
    mut next: ResMut<NextState<Phase>>,
    run: Res<Run>,
    mut map: ResMut<super::worldmap::MapOpen>,
    mut replay: ResMut<super::hud::Replay>,
    mut shown: Local<f32>,
    (mut profile, selection, mut step, mut delete, mut draft): (
        ResMut<super::profile::Profile>,
        Res<super::Selection>,
        ResMut<super::menu::MenuStep>,
        ResMut<super::menu::DeleteOpen>,
        ResMut<super::menu::NameDraft>,
    ),
    (mut exit, mut chars_t): (MessageWriter<AppExit>, Local<f32>),
    mut screen: ResMut<crate::loading_screen::LoadingScreen>,
) {
    if auto.loading {
        *chars_t += time.delta_secs();
        if *chars_t < 1.0 {
            screen.hold_for_capture(Some(selection.stage_def().map));
        }
        if *chars_t > 8.0 {
            auto.capture_once(&mut commands, "loading".into());
        }
        if *chars_t > 10.0 {
            exit.write(AppExit::Success);
        }
        return;
    }
    // A run needs a character to count for: a fresh account gets one, of the class driven.
    let look = selection.look.and_then(|i| selection.looks.get(i));
    if let (Phase::Menu, true, Some(class), Some(&(_, race, sex))) =
        (phase.get(), profile.hero().is_none(), selection.class, look)
    {
        let name = format!("Auto{}", ["a", "b", "c", "d"][profile.chars.len().min(3)]);
        let hero =
            super::profile::Character::new(name, class, race, sex, selection.custom, auto.map);
        if profile.create(hero) {
            info!("survivors auto: created a {}", data::CLASSES[class].name);
            *step = super::menu::MenuStep::Select;
        }
    }
    if auto.chars && *phase.get() == Phase::Menu && profile.hero().is_some() {
        // The drive starts its run three seconds into the menu; hold it until the shots are in.
        auto.wait = 0.0;
        *chars_t += time.delta_secs();
        let t = *chars_t;
        if profile.chars.len() < 3 {
            let (class, race) = [(4, 4), (3, 6)][profile.chars.len() - 1];
            let name = ["Ilyandra", "Hautok"][profile.chars.len() - 1].to_string();
            let hero = super::profile::Character::new(name, class, race, 1, selection.custom, 0);
            profile.create(hero);
            profile.choose(0);
        }
        let shot = |auto: &mut Auto, commands: &mut Commands, at: f32, name: &str| {
            if t > at {
                auto.capture_once(commands, name.into());
            }
        };
        if t > 4.0 && t < 7.0 && *step == super::menu::MenuStep::Select && !delete.0 {
            shot(&mut auto, &mut commands, 4.0, "chars-select");
        }
        if t > 7.0 && t < 10.0 {
            *step = super::menu::MenuStep::Hero;
            shot(&mut auto, &mut commands, 9.0, "chars-create");
        }
        if t > 10.0 && t < 13.0 {
            *step = super::menu::MenuStep::Customize;
            if draft.text.is_empty() {
                draft.text = "Arthas".into();
            }
            shot(&mut auto, &mut commands, 12.0, "chars-name");
        }
        if t > 13.0 && t < 16.0 {
            *step = super::menu::MenuStep::Select;
            delete.0 = true;
            shot(&mut auto, &mut commands, 15.0, "chars-delete");
        }
        if t > 16.0 {
            info!("survivors auto: chars shots done");
            exit.write(AppExit::Success);
        }
    }
    if auto.idle && *phase.get() == Phase::GameOver && auto.wait > 3.0 && !replay.0 {
        info!("survivors auto: play again");
        replay.0 = true;
        next.set(Phase::Menu);
        auto.wait = 0.0;
    }
    if !auto.map_shot {
        return;
    }
    match phase.get() {
        Phase::Playing if run.elapsed > 20.0 && !map.0 => {
            map.0 = true;
            next.set(Phase::Paused);
            *shown = 0.0;
        }
        Phase::Paused if map.0 => {
            *shown += time.delta_secs();
            if *shown > 1.5 {
                auto.capture_once(&mut commands, "worldmap".into());
                auto.map_shot = false;
                map.0 = false;
                next.set(Phase::Playing);
            }
        }
        _ => {}
    }
}
