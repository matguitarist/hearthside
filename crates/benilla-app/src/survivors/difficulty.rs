//! Difficulties, as a dungeon has them: Normal, the zone as it is; Heroic; then Mythic keystone
//! levels +2 to +[`MAX`]. Each is harder than the last and pays more: the coins a run brings
//! home, the chance a boss drops armor and the armor tier it drops. Winning a difficulty in a zone
//! opens the next there ([`super::profile::ZoneRecord::cleared`]); a loss costs nothing.
//!
//! From +2 a Mythic run also carries the week's affixes, as Mythic+ does: Fortified or Tyrannical
//! from +2, a second affix from +4 and a third from +7, the set turning over every Tuesday.
//!
//! `WOW_SURVIVORS_DIFFICULTY=<n>` starts every run at difficulty `n` whatever is open, and
//! `WOW_SURVIVORS_WEEK=<n>` picks the week's affixes, for testing.

use benilla_world::world_point::WorldPoint;
use bevy::prelude::*;

use super::data::{self, EnemyDef};
use super::enemies::{self, Enemy, Loot};
use super::hero::{self, Hero};
use super::hud::{centered_bundle, text_bundle, HudFont, MenuRoot, DIM_GREY, GOLD_TONE};
use super::menu::{DeleteOpen, MenuBuilt, MenuStep};
use super::profile::Profile;
use super::units::{self, flat, Fx, Marks, COLOR_HURT};
use super::{Phase, Rng, Run, Selection};
use crate::glue::art::GlueArt;
use crate::glue::widgets::{glue_button, GlueBtnKind};
use crate::glue::GlueClicks;

/// The hardest keystone level.
pub(super) const MAX: u8 = 20;
pub(super) const HEROIC: u8 = 1;
/// The first Mythic difficulty, +2 as a keystone begins.
pub(super) const MYTHIC: u8 = 2;

/// `Normal`, `Heroic` or `Mythic +n`.
pub(super) fn name(d: u8) -> String {
    match d {
        0 => "Normal".into(),
        HEROIC => "Heroic".into(),
        n => format!("Mythic +{n}"),
    }
}

/// Enemy health, on top of the run's own climb: +10% a keystone level.
pub(super) fn hp_mult(d: u8) -> f32 {
    match d {
        0 => 1.0,
        HEROIC => 1.5,
        n => 1.8 * 1.10f32.powi(i32::from(n - MYTHIC)),
    }
}

/// Enemy damage: +8% a keystone level.
pub(super) fn damage_mult(d: u8) -> f32 {
    match d {
        0 => 1.0,
        HEROIC => 1.3,
        n => 1.5 * 1.08f32.powi(i32::from(n - MYTHIC)),
    }
}

/// The coins a run brings home.
pub(super) fn coin_mult(d: u8) -> f32 {
    match d {
        0 => 1.0,
        HEROIC => 1.5,
        n => 2.0 + 0.25 * f32::from(n - MYTHIC),
    }
}

/// The chance a boss before the last drops a piece of armor; the last always does.
pub(super) fn armor_chance(d: u8) -> f32 {
    match d {
        0 => 0.5,
        HEROIC => 0.65,
        n => (0.8 + 0.02 * f32::from(n - MYTHIC)).min(1.0),
    }
}

/// How many armor tiers above the zone's own a boss's piece may come from.
pub(super) fn tier_bump(d: u8) -> usize {
    match d {
        0 => 0,
        HEROIC => 1,
        n if n < 10 => 2,
        _ => 3,
    }
}

/// A Mythic run's extra rule.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum Affix {
    Fortified,
    Tyrannical,
    Bolstering,
    Raging,
    Sanguine,
    Bursting,
    Volcanic,
    Explosive,
    Quaking,
    Grievous,
}

/// The keystone levels the week's three affixes start at.
pub(super) const AFFIX_FROM: [u8; 3] = [2, 4, 7];

const SECOND: [Affix; 4] = [
    Affix::Bolstering,
    Affix::Raging,
    Affix::Sanguine,
    Affix::Bursting,
];
const THIRD: [Affix; 4] = [
    Affix::Volcanic,
    Affix::Explosive,
    Affix::Quaking,
    Affix::Grievous,
];

impl Affix {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Fortified => "Fortified",
            Self::Tyrannical => "Tyrannical",
            Self::Bolstering => "Bolstering",
            Self::Raging => "Raging",
            Self::Sanguine => "Sanguine",
            Self::Bursting => "Bursting",
            Self::Volcanic => "Volcanic",
            Self::Explosive => "Explosive",
            Self::Quaking => "Quaking",
            Self::Grievous => "Grievous",
        }
    }

    pub(super) fn about(self) -> &'static str {
        match self {
            Self::Fortified => "The horde has 20% more health and deals 30% more damage.",
            Self::Tyrannical => "Bosses have 40% more health and deal 15% more damage.",
            Self::Bolstering => {
                "A creature that dies empowers the creatures near it: more health and damage."
            }
            Self::Raging => "Creatures below 30% health enrage, dealing 50% more damage.",
            Self::Sanguine => {
                "Some creatures leave a pool of ichor that heals the horde and hurts you."
            }
            Self::Bursting => "Each creature slain near you makes you bleed for a few seconds.",
            Self::Volcanic => "Plumes of lava erupt under your feet: keep moving.",
            Self::Explosive => "Orbs appear around you and explode unless destroyed in time.",
            Self::Quaking => "Every so often the ground quakes, hurting you.",
            Self::Grievous => "Below 90% health a wound bleeds, worse until you heal past it.",
        }
    }

    /// The tooltip colour: the first affix gold, the others red, as the dungeon finder shows them.
    pub(super) fn color(self) -> Color {
        match self {
            Self::Fortified | Self::Tyrannical => GOLD_TONE,
            _ => Color::srgb(1.0, 0.35, 0.25),
        }
    }
}

/// The week since the first Tuesday reset (15:00 UTC), as the affixes turn over.
pub(super) fn week() -> u64 {
    if let Some(w) = crate::webenv::var("WOW_SURVIVORS_WEEK").and_then(|v| v.trim().parse().ok()) {
        return w;
    }
    // 1970-01-06 was a Tuesday.
    const FIRST_RESET: u64 = 5 * 86_400 + 15 * 3_600;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    now.saturating_sub(FIRST_RESET) / (7 * 86_400)
}

/// The week's three affixes: Fortified and Tyrannical by turns, and the others in a cycle that
/// pairs each second affix with each third one over sixteen weeks.
pub(super) fn of_week(week: u64) -> [Affix; 3] {
    let first = if week.is_multiple_of(2) {
        Affix::Fortified
    } else {
        Affix::Tyrannical
    };
    let second = SECOND[(week % 4) as usize];
    let third = THIRD[((week + week / 4) % 4) as usize];
    [first, second, third]
}

/// The affixes a run at difficulty `d` carries this week.
pub(super) fn active(d: u8, week: u64) -> Vec<Affix> {
    of_week(week)
        .into_iter()
        .zip(AFFIX_FROM)
        .filter(|&(_, from)| d >= from)
        .map(|(a, _)| a)
        .collect()
}

/// An enemy's `(health, damage)` multipliers for the run's difficulty and affixes.
pub(super) fn enemy_scale(run: &Run, boss: bool) -> (f32, f32) {
    let (mut hp, mut dmg) = (hp_mult(run.difficulty), damage_mult(run.difficulty));
    for a in &run.affixes {
        match a {
            Affix::Fortified if !boss => {
                hp *= 1.2;
                dmg *= 1.3;
            }
            Affix::Tyrannical if boss => {
                hp *= 1.4;
                dmg *= 1.15;
            }
            _ => {}
        }
    }
    (hp, dmg)
}

/// The difficulty `WOW_SURVIVORS_DIFFICULTY` forces, if set.
fn forced() -> Option<u8> {
    static FORCED: std::sync::OnceLock<Option<u8>> = std::sync::OnceLock::new();
    *FORCED.get_or_init(|| {
        crate::webenv::var("WOW_SURVIVORS_DIFFICULTY")
            .and_then(|v| v.trim().parse::<u8>().ok())
            .map(|d| d.min(MAX))
    })
}

pub(super) fn plugin(app: &mut App) {
    app.init_resource::<DifficultyOpen>()
        .add_systems(
            Update,
            (build_difficulty, difficulty)
                .chain()
                .after(super::menu::build_menu)
                .after(super::menu::menu_clicks)
                .before(crate::glue::GlueVisuals),
        )
        .add_systems(
            Update,
            (affix_deaths, affix_enemies, affix_hazards)
                .chain()
                .after(super::abilities::apply_hits)
                .before(hero::hero_vitals)
                .run_if(in_state(Phase::Playing))
                .run_if(|l: Res<crate::loading_screen::LoadingScreen>| !l.covering()),
        )
        .add_systems(Update, affix_line.after(super::hud::refresh_hud))
        .add_systems(
            Update,
            (auto_dialog.before(super::auto::drive), auto_affix_shots)
                .run_if(resource_exists::<super::auto::Auto>),
        );
}

/// `<class>:difficulty` also shoots the first Explosive orb, Volcanic plume and Sanguine pool
/// of the run once each has had time to show.
fn auto_affix_shots(
    mut commands: Commands,
    mut auto: ResMut<super::auto::Auto>,
    run: Res<Run>,
    orbs: Query<&Orb>,
) {
    if !auto.difficulty {
        return;
    }
    // A model streams in over a second or two.
    if orbs.iter().any(|o| o.0 < ORB_FUSE - 3.0) {
        auto.capture_once(&mut commands, "affix-orb".into());
    }
    if run.affix.plumes.iter().any(|p| p.t > 1.0) {
        auto.capture_once(&mut commands, "affix-plume".into());
    }
    if run.affix.plumes.iter().any(|p| p.t > PLUME_WARN_SECS + 0.3) {
        auto.capture_once(&mut commands, "affix-burst".into());
    }
    if run.affix.pools.iter().any(|p| p.2 > 1.0) {
        auto.capture_once(&mut commands, "affix-pool".into());
    }
}

/// `<class>:difficulty`: once the pick screen is up, open the dialog, shoot it and close it, the
/// run held back meanwhile.
fn auto_dialog(
    mut commands: Commands,
    time: Res<Time<Real>>,
    phase: Res<State<Phase>>,
    mut auto: ResMut<super::auto::Auto>,
    mut open: ResMut<DifficultyOpen>,
    mut t: Local<f32>,
) {
    let ready = auto.seen.iter().any(|s| s == "menu");
    let done = *t > 3.0;
    if !auto.difficulty || *phase.get() != Phase::Menu || !ready || done {
        return;
    }
    *t += time.delta_secs();
    auto.wait = 0.0;
    open.0 = *t > 1.0;
    // The shot is of the next frame drawn: the dialog stays up a moment after.
    if *t > 2.5 {
        auto.capture_once(&mut commands, "difficulty".into());
    }
    if *t > 3.0 {
        open.0 = false;
    }
}

// MARK: - The affixes in a run

/// Spells whose visuals the affixes wear.
const ENRAGE_AURA: u32 = 8599;
/// Frenzy's flash on a creature Bolstering empowers.
const BOLSTER_FLASH: u32 = 19451;
/// Disease Cloud's ground, for a Sanguine pool: the clearest ground cloud on the brightest
/// battleground grass.
const SANGUINE_POOL: u32 = 24063;
/// A glowing disc where a Volcanic plume is about to erupt (Summoning Portal's), then the
/// eruption, a pillar of fire (Area Burn, Flamestrike's ground).
const PLUME_WARN: u32 = 16136;
const PLUME_BURST: u32 = 8000;
/// War Stomp on the hero, as the ground quakes.
const QUAKE: u32 = 20549;
/// Explosion on the hero, as an orb goes off.
const ORB_BLAST: u32 = 12158;

/// A gnome bomb-bot that does not move or bite: Explosive's orb.
static ORB: EnemyDef = EnemyDef {
    name: "Explosive Orb",
    display: 6977,
    hp: 1.0,
    speed: 0.0,
    damage: 0.0,
    scale: 0.8,
    xp: 0,
    level: 1,
    big: false,
};

const POOL_RADIUS: f32 = 2.5;
const POOL_SECS: f32 = 8.0;
const MAX_POOLS: usize = 6;
const PLUME_RADIUS: f32 = 2.5;
const PLUME_WARN_SECS: f32 = 1.6;
const ORB_FUSE: f32 = 8.0;
const QUAKE_WARN: f32 = 2.5;

/// What the affixes keep through a run; [`Run`] holds it, so a new run starts it afresh.
#[derive(Default)]
pub(crate) struct AffixState {
    /// Seconds left on each Bursting stack.
    bursts: Vec<f32>,
    /// Grievous stacks and the seconds to the next.
    grievous: u8,
    grievous_t: f32,
    /// Damage over time banked until the next whole second, shown as one number.
    bleed: f32,
    bleed_t: f32,
    pools: Vec<(Entity, Vec3, f32)>,
    plumes: Vec<Plume>,
    next_plume: f32,
    next_orb: f32,
    next_quake: f32,
    /// Seconds to the quake announced, while one is coming.
    quake_in: Option<f32>,
}

impl AffixState {
    /// Bursting and Grievous stacks, for the HUD line.
    pub(super) fn stacks(&self) -> (usize, u8) {
        (self.bursts.len(), self.grievous)
    }
}

/// A Volcanic plume: its glow, then its burst, where, and the seconds since the glow showed.
struct Plume {
    object: Entity,
    at: Vec3,
    t: f32,
}

/// A creature empowered by Bolstering, and how many times.
#[derive(Component)]
pub(super) struct Bolstered(u8);

/// A creature already enraged by Raging.
#[derive(Component)]
pub(super) struct Raged;

/// An Explosive orb and the seconds to its blast.
#[derive(Component)]
pub(super) struct Orb(f32);

/// The health an orb takes once its [`Enemy`] is in: [`enemies::spawn_enemy`] gives each
/// creature its roster health, which an orb has none of.
#[derive(Component)]
pub(super) struct Tough(f32);

fn has(run: &Run, a: Affix) -> bool {
    run.affixes.contains(&a)
}

/// Damage an affix deals the hero: past armor, but not past a shield or immunity.
fn affix_hurt(run: &mut Run, amount: f32) -> f32 {
    if run.immune_t > 0.0 || run.dead_t.is_some() {
        return 0.0;
    }
    let mut dmg = amount;
    if run.shield_t > 0.0 && run.shield > 0.0 {
        let absorbed = dmg.min(run.shield);
        run.shield -= absorbed;
        dmg -= absorbed;
    }
    run.hp -= dmg;
    dmg
}

/// Bolstering, Sanguine and Bursting: what a death sets off.
#[allow(clippy::type_complexity)]
fn affix_deaths(
    mut commands: Commands,
    mut deaths: MessageReader<Loot>,
    mut run: ResMut<Run>,
    mut rng: ResMut<Rng>,
    hero: Query<&Transform, With<Hero>>,
    mut foes: Query<(Entity, &Transform, &mut Enemy, Option<&mut Bolstered>), Without<Orb>>,
    mut fx: Fx,
) {
    let deaths: Vec<Loot> = deaths.read().copied().collect();
    if run.affixes.is_empty() || deaths.is_empty() {
        return;
    }
    let Ok(htf) = hero.single() else { return };
    let hpos = htf.translation;
    let mut flashes = 0;
    for d in &deaths {
        if has(&run, Affix::Bolstering) && !d.boss {
            // The three nearest living creatures within 8 yards, each up to five times.
            let mut near: Vec<(Entity, f32)> = foes
                .iter()
                .filter(|(_, _, e, _)| !e.dead && !e.boss)
                .map(|(ent, tf, _, _)| (ent, flat(tf.translation - d.pos).length()))
                .filter(|&(_, dist)| dist < 8.0 && dist > 0.01)
                .collect();
            near.sort_by(|a, b| a.1.total_cmp(&b.1));
            for &(ent, _) in near.iter().take(3) {
                let Ok((_, _, mut e, stacks)) = foes.get_mut(ent) else {
                    continue;
                };
                let n = stacks.as_ref().map_or(0, |s| s.0);
                if n >= 5 {
                    continue;
                }
                e.max_hp *= 1.15;
                e.hp = (e.hp * 1.15).min(e.max_hp);
                e.damage *= 1.15;
                match stacks {
                    Some(mut s) => s.0 += 1,
                    None => {
                        commands.entity(ent).insert(Bolstered(1));
                    }
                }
                if flashes < 6 {
                    fx.impact(ent, BOLSTER_FLASH);
                    flashes += 1;
                }
            }
        }
        if has(&run, Affix::Sanguine)
            && !d.boss
            && (d.rare || rng.f32() < 0.08)
            && run.affix.pools.len() < MAX_POOLS
        {
            let serial = run.guid();
            let e =
                units::spawn_area_object(&mut commands, serial, SANGUINE_POOL, POOL_RADIUS, d.pos);
            run.affix.pools.push((e, d.pos, 0.0));
        }
        if has(&run, Affix::Bursting) && flat(d.pos - hpos).length() < 12.0 {
            if run.affix.bursts.len() < 20 {
                run.affix.bursts.push(4.0);
            } else if let Some(oldest) = run.affix.bursts.iter_mut().min_by(|a, b| a.total_cmp(b)) {
                *oldest = 4.0;
            }
        }
    }
}

/// Raging, and Sanguine's pools healing the horde in them.
#[allow(clippy::type_complexity)]
fn affix_enemies(
    mut commands: Commands,
    time: Res<Time>,
    run: Res<Run>,
    mut foes: Query<(Entity, &Transform, &mut Enemy, &mut Marks, Has<Raged>), Without<Orb>>,
) {
    if run.affixes.is_empty() {
        return;
    }
    let dt = time.delta_secs();
    let raging = has(&run, Affix::Raging);
    for (ent, tf, mut e, mut marks, raged) in &mut foes {
        if e.dead {
            continue;
        }
        if raging && !raged && !e.boss && e.hp < e.max_hp * 0.3 {
            e.damage *= 1.5;
            marks.add(ENRAGE_AURA, f32::INFINITY);
            commands.entity(ent).insert(Raged);
        }
        for &(_, at, _) in &run.affix.pools {
            if flat(tf.translation - at).length() < POOL_RADIUS {
                e.hp = (e.hp + e.max_hp * 0.05 * dt).min(e.max_hp);
            }
        }
    }
}

/// Volcanic, Explosive, Quaking, Grievous, Bursting's bleed and the pools' bite: the hazards
/// that come for the hero.
#[allow(clippy::too_many_arguments)]
fn affix_hazards(
    mut commands: Commands,
    time: Res<Time>,
    mut run: ResMut<Run>,
    mut rng: ResMut<Rng>,
    world: WorldPoint,
    hero: Query<(Entity, &Transform), With<Hero>>,
    mut orbs: Query<(Entity, &mut Enemy, &mut Orb, Option<&Tough>)>,
    roster: Res<Selection>,
    mut fx: Fx,
) {
    if run.affixes.is_empty() || run.dead_t.is_some() {
        return;
    }
    let dt = time.delta_secs();
    let Ok((hero_e, htf)) = hero.single() else {
        return;
    };
    let hpos = htf.translation;
    let max_hp = run.stats().max_hp;
    let now = run.elapsed;
    let ground = |p: Vec3| {
        let mut p = p;
        p.y = world.terrain_height_under(p).unwrap_or(hpos.y);
        p
    };
    let mut bleed = 0.0;

    // Sanguine: the pools hurt the hero standing in one, and dry up.
    let mut pools = std::mem::take(&mut run.affix.pools);
    pools.retain_mut(|(e, at, t)| {
        *t += dt;
        if flat(hpos - *at).length() < POOL_RADIUS {
            bleed += max_hp * 0.04 * dt;
        }
        let keep = *t < POOL_SECS;
        if !keep {
            commands.entity(*e).try_despawn();
        }
        keep
    });
    run.affix.pools = pools;

    // Bursting: each stack bleeds 0.3% of health a second.
    run.affix.bursts.retain_mut(|t| {
        *t -= dt;
        *t > 0.0
    });
    bleed += max_hp * 0.003 * run.affix.bursts.len() as f32 * dt;

    // Grievous: below 90% a stack every two seconds, up to five, 0.6% a second each.
    if has(&run, Affix::Grievous) {
        if run.hp < max_hp * 0.9 {
            run.affix.grievous_t -= dt;
            if run.affix.grievous_t <= 0.0 && run.affix.grievous < 5 {
                if run.affix.grievous == 0 {
                    fx.label(hero_e, "Grievous Wound".into(), COLOR_HURT);
                }
                run.affix.grievous += 1;
                run.affix.grievous_t = 2.0;
            }
        } else {
            run.affix.grievous = 0;
            run.affix.grievous_t = 2.0;
        }
        bleed += max_hp * 0.006 * f32::from(run.affix.grievous) * dt;
    }

    // Volcanic: two plumes every six seconds, one under the hero, after a glow to step out of.
    if has(&run, Affix::Volcanic) {
        if run.affix.next_plume == 0.0 {
            run.affix.next_plume = now + 10.0;
        }
        if now >= run.affix.next_plume {
            run.affix.next_plume = now + 6.0;
            for i in 0..2 {
                let at = if i == 0 {
                    hpos
                } else {
                    let a = rng.range(0.0, std::f32::consts::TAU);
                    hpos + Vec3::new(a.cos(), 0.0, a.sin()) * rng.range(3.0, 8.0)
                };
                let at = ground(at);
                let serial = run.guid();
                let object =
                    units::spawn_area_object(&mut commands, serial, PLUME_WARN, PLUME_RADIUS, at);
                run.affix.plumes.push(Plume { object, at, t: 0.0 });
            }
        }
    }
    // A glow gives way to its burst, which hurts the hero still on it and goes a second later.
    let mut plumes = std::mem::take(&mut run.affix.plumes);
    let mut burned = 0.0;
    for p in &mut plumes {
        let before = p.t;
        p.t += dt;
        if before < PLUME_WARN_SECS && p.t >= PLUME_WARN_SECS {
            commands.entity(p.object).try_despawn();
            let serial = run.guid();
            p.object =
                units::spawn_area_object(&mut commands, serial, PLUME_BURST, PLUME_RADIUS, p.at);
            if flat(hpos - p.at).length() < PLUME_RADIUS {
                burned += max_hp * 0.15;
            }
        }
    }
    plumes.retain(|p| {
        let keep = p.t < PLUME_WARN_SECS + 1.0;
        if !keep {
            commands.entity(p.object).try_despawn();
        }
        keep
    });
    run.affix.plumes = plumes;
    if burned > 0.0 {
        let taken = affix_hurt(&mut run, burned);
        if taken > 0.0 {
            fx.number(hero_e, taken, false, COLOR_HURT);
        }
    }

    // Explosive: an orb every nine seconds, seven to ten yards out; it blasts after its fuse.
    if has(&run, Affix::Explosive) {
        if run.affix.next_orb == 0.0 {
            run.affix.next_orb = now + 15.0;
        }
        if now >= run.affix.next_orb {
            run.affix.next_orb = now + 9.0;
            let a = rng.range(0.0, std::f32::consts::TAU);
            let at = ground(hpos + Vec3::new(a.cos(), 0.0, a.sin()) * rng.range(7.0, 10.0));
            // As tough as two of the moment's creatures: a couple of spells, not a stray tick.
            let pool = data::wave_pool(now, data::roster(roster.stage).enemies.len());
            let tough = data::roster(roster.stage).enemies[pool[1]].hp * data::hp_scale(now) * 2.0;
            let e = enemies::spawn_enemy(&mut commands, &mut run, &ORB, at, hpos, false, false);
            commands.entity(e).insert((Orb(ORB_FUSE), Tough(tough)));
        }
    }
    let mut blasts = 0.0;
    for (e, mut enemy, mut orb, tough) in &mut orbs {
        if let Some(&Tough(hp)) = tough {
            enemy.hp = hp;
            enemy.max_hp = hp;
            commands.entity(e).remove::<Tough>();
        }
        if enemy.dead {
            continue;
        }
        orb.0 -= dt;
        if orb.0 <= 0.0 {
            blasts += max_hp * 0.1;
            commands.entity(e).try_despawn();
        }
    }
    if blasts > 0.0 {
        let taken = affix_hurt(&mut run, blasts);
        fx.impact(hero_e, ORB_BLAST);
        if taken > 0.0 {
            fx.number(hero_e, taken, false, COLOR_HURT);
        }
    }

    // Quaking: every twenty seconds, announced, then a stomp for 8% of health.
    if has(&run, Affix::Quaking) {
        if run.affix.next_quake == 0.0 {
            run.affix.next_quake = now + 20.0;
        }
        if run.affix.quake_in.is_none() && now >= run.affix.next_quake {
            run.affix.next_quake = now + 20.0;
            run.affix.quake_in = Some(QUAKE_WARN);
            fx.label(hero_e, "Quaking!".into(), COLOR_HURT);
        }
        if let Some(t) = run.affix.quake_in.as_mut() {
            *t -= dt;
            if *t <= 0.0 {
                run.affix.quake_in = None;
                fx.impact(hero_e, QUAKE);
                let taken = affix_hurt(&mut run, max_hp * 0.08);
                if taken > 0.0 {
                    fx.number(hero_e, taken, false, COLOR_HURT);
                }
            }
        }
    }

    // The bleeds, shown once a second as one number.
    run.affix.bleed += bleed;
    run.affix.bleed_t += dt;
    if run.affix.bleed_t >= 1.0 {
        run.affix.bleed_t = 0.0;
        let amount = std::mem::take(&mut run.affix.bleed);
        if amount > 0.0 {
            let taken = affix_hurt(&mut run, amount);
            if taken >= 1.0 {
                fx.number(hero_e, taken, false, COLOR_HURT);
            }
        }
    }
}

/// The HUD line under the clock: the difficulty, the affixes and their stacks.
#[derive(Component)]
pub(super) struct AffixText;

fn affix_line(run: Res<Run>, mut texts: Query<(&mut Text, &mut Visibility), With<AffixText>>) {
    let Ok((mut t, mut vis)) = texts.single_mut() else {
        return;
    };
    let want = if run.difficulty == 0 {
        Visibility::Hidden
    } else {
        Visibility::Inherited
    };
    if *vis != want {
        *vis = want;
    }
    let mut line = name(run.difficulty);
    let (bursts, grievous) = run.affix.stacks();
    for a in &run.affixes {
        line.push_str("   ");
        line.push_str(a.name());
        match a {
            Affix::Bursting if bursts > 0 => line.push_str(&format!(" {bursts}")),
            Affix::Grievous if grievous > 0 => line.push_str(&format!(" {grievous}")),
            _ => {}
        }
    }
    if t.0 != line {
        t.0 = line;
    }
}

// MARK: - The pick screen

/// Whether the difficulty dialog is up.
#[derive(Resource, Default)]
pub(super) struct DifficultyOpen(pub(super) bool);

#[derive(Component, Clone, Copy, PartialEq, Eq)]
pub(super) enum DifficultyAction {
    Open,
    Close,
    /// One keystone level down or up.
    Down,
    Up,
}

#[derive(Component)]
pub(super) struct DifficultyBuilt;
#[derive(Component)]
pub(super) struct DifficultyOverlay;
/// The button under the zone list, shown on character select only.
#[derive(Component)]
pub(super) struct DifficultyCorner;
/// A row of the dialog: 0 Normal, 1 Heroic, 2 Mythic. A click picks it.
#[derive(Component, Clone, Copy)]
pub(super) struct Rung(u8);
#[derive(Component)]
pub(super) struct RungName(u8);
#[derive(Component)]
pub(super) struct RungChips(u8);
#[derive(Component)]
pub(super) struct RungNote(u8);
#[derive(Component)]
pub(super) struct ZoneTitle;
/// An affix's name and the level it starts at.
#[derive(Component)]
pub(super) struct AffixName(usize);
#[derive(Component)]
pub(super) struct AffixFrom(usize);

const DIALOG_W: f32 = 640.0;
const RUNG_W: f32 = 580.0;
const RUNG_H: f32 = 58.0;
const GREEN: Color = Color::srgb(0.12, 1.0, 0.0);

/// The rung a difficulty sits on.
fn rung(d: u8) -> u8 {
    d.min(MYTHIC)
}

/// A difficulty's numbers, as the dialog lists them.
fn chips(d: u8) -> String {
    let x = |v: f32| {
        let s = format!("{v:.2}");
        let s = s.trim_end_matches('0').trim_end_matches('.').to_string();
        format!("×{s}")
    };
    let mut s = format!(
        "Health {}   Damage {}   Coins {}   Armor {:.0}%",
        x(hp_mult(d)),
        x(damage_mult(d)),
        x(coin_mult(d)),
        armor_chance(d) * 100.0
    );
    match tier_bump(d) {
        0 => {}
        1 => s.push_str(" +1 tier"),
        n => s.push_str(&format!(" +{n} tiers")),
    }
    s
}

/// The Difficulty button under the zone list and the dialog, hidden until opened.
#[allow(clippy::type_complexity)]
fn build_difficulty(
    mut commands: Commands,
    roots: Query<Entity, (With<MenuRoot>, With<MenuBuilt>, Without<DifficultyBuilt>)>,
    art: Res<GlueArt>,
    font: Res<HudFont>,
) {
    let Ok(root) = roots.single() else { return };
    let f = &font.0;
    let art = &*art;
    let week = of_week(week());
    commands
        .entity(root)
        .insert(DifficultyBuilt)
        .with_children(|ui| {
            // Under the zone frame, as wide as its rows.
            ui.spawn((
                DifficultyCorner,
                Node {
                    position_type: PositionType::Absolute,
                    right: Val::Px(22.0),
                    top: Val::Px(super::menu::ZONE_FRAME_BOTTOM + 4.0),
                    width: Val::Px(236.0),
                    justify_content: JustifyContent::Center,
                    ..default()
                },
            ))
            .with_children(|c| {
                glue_button(
                    c,
                    art,
                    f,
                    DifficultyAction::Open,
                    "Normal",
                    236.0,
                    30.0,
                    GlueBtnKind::Small,
                    1.0,
                );
            });
            ui.spawn((
                DifficultyOverlay,
                Interaction::default(),
                Node {
                    position_type: PositionType::Absolute,
                    width: Val::Percent(100.0),
                    height: Val::Percent(100.0),
                    justify_content: JustifyContent::Center,
                    align_items: AlignItems::Center,
                    display: Display::None,
                    ..default()
                },
                BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.55)),
                ZIndex(10),
            ))
            .with_children(|o| {
                let title = centered_bundle(f, "Difficulty", 14.0, GOLD_TONE);
                super::panels::dialog(o, art, DIALOG_W, (), title, |b| {
                    b.spawn((ZoneTitle, centered_bundle(f, "", 18.0, GOLD_TONE)));
                    b.spawn(Node {
                        max_width: Val::Px(RUNG_W),
                        ..default()
                    })
                    .with_children(|n| {
                        n.spawn(centered_bundle(
                            f,
                            "Harder difficulties bring home more coin, and their bosses drop armor more often and from stronger sets. Winning one in a zone opens the next there.",
                            12.0,
                            DIM_GREY,
                        ));
                    });
                    for r in 0..=MYTHIC {
                        rung_row(b, art, f, r);
                    }
                    affix_box(b, f, &week);
                    glue_button(
                        b,
                        art,
                        f,
                        DifficultyAction::Close,
                        "Done",
                        180.0,
                        34.0,
                        GlueBtnKind::Small,
                        1.0,
                    );
                });
            });
        });
}

/// One rung: its name (with the keystone arrows on Mythic's), its numbers, and a note on what
/// opens it or what it is.
fn rung_row(b: &mut ChildSpawnerCommands, art: &GlueArt, f: &Handle<Font>, r: u8) {
    b.spawn((
        Rung(r),
        Button,
        Interaction::default(),
        Node {
            width: Val::Px(RUNG_W),
            height: Val::Px(RUNG_H),
            padding: UiRect::axes(Val::Px(10.0), Val::Px(6.0)),
            column_gap: Val::Px(10.0),
            align_items: AlignItems::Center,
            border: UiRect::all(Val::Px(1.0)),
            ..default()
        },
        BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.45)),
        BorderColor::all(Color::srgba(0.5, 0.5, 0.5, 0.5)),
    ))
    .with_children(|w| {
        w.spawn((
            Node {
                width: Val::Px(170.0),
                align_items: AlignItems::Center,
                column_gap: Val::Px(4.0),
                ..default()
            },
            bevy::ui::FocusPolicy::Pass,
        ))
        .with_children(|n| {
            if r == MYTHIC {
                glue_button(
                    n,
                    art,
                    f,
                    DifficultyAction::Down,
                    "<",
                    24.0,
                    24.0,
                    GlueBtnKind::Small,
                    1.0,
                );
            }
            n.spawn((RungName(r), text_bundle(f, "", 17.0, GOLD_TONE)));
            if r == MYTHIC {
                glue_button(
                    n,
                    art,
                    f,
                    DifficultyAction::Up,
                    ">",
                    24.0,
                    24.0,
                    GlueBtnKind::Small,
                    1.0,
                );
            }
        });
        w.spawn((
            Node {
                flex_direction: FlexDirection::Column,
                flex_grow: 1.0,
                row_gap: Val::Px(3.0),
                ..default()
            },
            bevy::ui::FocusPolicy::Pass,
        ))
        .with_children(|col| {
            col.spawn((RungChips(r), text_bundle(f, "", 12.0, Color::WHITE)));
            col.spawn((RungNote(r), text_bundle(f, "", 12.0, DIM_GREY)));
        });
    });
}

/// This week's affixes, each with the level it starts at.
fn affix_box(b: &mut ChildSpawnerCommands, f: &Handle<Font>, week: &[Affix; 3]) {
    b.spawn(Node {
        width: Val::Px(RUNG_W),
        flex_direction: FlexDirection::Column,
        padding: UiRect::all(Val::Px(10.0)),
        row_gap: Val::Px(5.0),
        border: UiRect::all(Val::Px(1.0)),
        margin: UiRect::top(Val::Px(4.0)),
        ..default()
    })
    .insert((
        BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.45)),
        BorderColor::all(Color::srgba(0.5, 0.5, 0.5, 0.5)),
    ))
    .with_children(|col| {
        col.spawn(text_bundle(f, "This Week's Affixes", 14.0, GOLD_TONE));
        for (i, a) in week.iter().enumerate() {
            col.spawn(Node {
                column_gap: Val::Px(10.0),
                align_items: AlignItems::Center,
                ..default()
            })
            .with_children(|row| {
                row.spawn((
                    Node {
                        width: Val::Px(90.0),
                        ..default()
                    },
                    AffixName(i),
                    text_bundle(f, a.name(), 13.0, a.color()),
                ));
                row.spawn((
                    Node {
                        flex_grow: 1.0,
                        width: Val::Px(380.0),
                        ..default()
                    },
                    text_bundle(f, a.about(), 12.0, Color::WHITE),
                ));
                row.spawn((
                    AffixFrom(i),
                    text_bundle(f, format!("from +{}", AFFIX_FROM[i]), 12.0, DIM_GREY),
                ));
            });
        }
    });
}

/// Keep the pick within what is open, open and close the dialog, take its clicks, and keep its
/// lines and the button's caption.
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
fn difficulty(
    clicks: Res<GlueClicks>,
    keys: Res<ButtonInput<KeyCode>>,
    phase: Res<State<Phase>>,
    step: Res<MenuStep>,
    delete: Res<DeleteOpen>,
    mut open: ResMut<DifficultyOpen>,
    mut profile: ResMut<Profile>,
    mut selection: ResMut<Selection>,
    actions: Query<(Entity, &DifficultyAction)>,
    mut rungs: Query<(Entity, &Rung, &Interaction, &mut BorderColor)>,
    mut nodes: ParamSet<(
        Query<&mut Node, With<DifficultyOverlay>>,
        Query<&mut Node, With<DifficultyCorner>>,
    )>,
    children: Query<&Children>,
    mut texts: ParamSet<(
        Query<&mut Text>,
        Query<(&RungName, &mut Text, &mut TextColor)>,
        Query<(&RungChips, &mut Text, &mut TextColor)>,
        Query<(&RungNote, &mut Text, &mut TextColor)>,
        Query<&mut Text, With<ZoneTitle>>,
        Query<(&AffixFrom, &mut TextColor)>,
        Query<(&AffixName, &mut TextColor), Without<AffixFrom>>,
    )>,
    mut synced: Local<Option<(usize, Option<usize>, u32)>>,
    mut sounds: MessageWriter<crate::sound::GlueSound>,
) {
    if *phase.get() != Phase::Menu {
        open.0 = false;
        return;
    }
    let map = selection.map;
    let top = profile.top_difficulty(map);
    // A new zone or character brings back the difficulty last picked there.
    let key = (map, profile.current, profile.version);
    if *synced != Some(key) {
        let fresh = synced.is_none_or(|(m, c, _)| m != map || c != profile.current);
        *synced = Some(key);
        if fresh {
            selection.difficulty = profile.picked_difficulty(map);
        }
    }
    if let Some(d) = forced() {
        selection.difficulty = d;
    } else if selection.difficulty > top {
        selection.difficulty = top;
    }

    let was = open.0;
    let mut pick = None;
    for (e, a) in &actions {
        if !clicks.hit(e) {
            continue;
        }
        match a {
            DifficultyAction::Open => open.0 = profile.hero().is_some(),
            DifficultyAction::Close => open.0 = false,
            DifficultyAction::Down if selection.difficulty > MYTHIC => {
                pick = Some(selection.difficulty - 1)
            }
            DifficultyAction::Up
                if selection.difficulty >= MYTHIC && selection.difficulty < top =>
            {
                pick = Some(selection.difficulty + 1)
            }
            // The arrows on a Mythic rung not yet picked pick it.
            DifficultyAction::Down | DifficultyAction::Up
                if selection.difficulty < MYTHIC && top >= MYTHIC =>
            {
                pick = Some(top)
            }
            _ => {}
        }
    }
    if open.0 && keys.just_pressed(KeyCode::Escape) {
        open.0 = false;
    }
    if open.0 && pick.is_none() {
        for (e, &Rung(r), _, _) in &rungs {
            if !clicks.hit(e) {
                continue;
            }
            // Mythic picks the highest level open, a keystone as it stands.
            let d = if r == MYTHIC { top } else { r };
            if r <= top && rung(selection.difficulty) != r {
                pick = Some(d);
            }
        }
    }
    if let Some(d) = pick.filter(|&d| d <= top || forced().is_some()) {
        selection.difficulty = d;
        profile.set_difficulty(map, d);
        sounds.write(crate::sound::GlueSound("igMainMenuOptionCheckBoxOn"));
    }
    if open.0 != was {
        sounds.write(crate::sound::GlueSound(if open.0 {
            "igMainMenuOpen"
        } else {
            "igMainMenuClose"
        }));
    }
    for mut node in &mut nodes.p0() {
        let want = if open.0 { Display::Flex } else { Display::None };
        if node.display != want {
            node.display = want;
        }
    }
    let shown = *step == MenuStep::Select && !delete.0 && profile.hero().is_some();
    for mut node in &mut nodes.p1() {
        let want = if shown { Display::Flex } else { Display::None };
        if node.display != want {
            node.display = want;
        }
    }

    let d = selection.difficulty;
    // The button's caption: every text under it, the outline's copies too.
    let caption = format!("Difficulty: {}", name(d));
    let buttons: Vec<Entity> = actions
        .iter()
        .filter(|(_, a)| **a == DifficultyAction::Open)
        .map(|(e, _)| e)
        .collect();
    for b in buttons {
        for child in children.iter_descendants(b) {
            if let Ok(mut t) = texts.p0().get_mut(child) {
                if t.0 != caption {
                    t.0 = caption.clone();
                }
            }
        }
    }
    if !open.0 {
        return;
    }
    let zone = data::MAPS[map].name;
    for mut t in &mut texts.p4() {
        if t.0 != zone {
            t.0 = zone.to_string();
        }
    }
    // The Mythic rung shows the level picked, else the highest open.
    let mythic = if d >= MYTHIC { d } else { top.max(MYTHIC) };
    let level_of = |r: u8| if r == MYTHIC { mythic } else { r };
    let locked = |r: u8| r > top && forced().is_none();
    for (n, mut t, mut c) in &mut texts.p1() {
        let want = name(level_of(n.0));
        if t.0 != want {
            t.0 = want;
        }
        let color = if locked(n.0) { DIM_GREY } else { GOLD_TONE };
        if c.0 != color {
            c.0 = color;
        }
    }
    for (n, mut t, mut c) in &mut texts.p2() {
        let want = if n.0 == 0 {
            "The zone as it is.".to_string()
        } else {
            chips(level_of(n.0))
        };
        if t.0 != want {
            t.0 = want;
        }
        let color = if locked(n.0) { DIM_GREY } else { Color::WHITE };
        if c.0 != color {
            c.0 = color;
        }
    }
    let best = profile.zone(map).map_or(0, |r| r.cleared);
    for (n, mut t, mut c) in &mut texts.p3() {
        let (want, color) = match n.0 {
            0 if best == 0 => ("Win it to open Heroic.".to_string(), DIM_GREY),
            0 => ("Won.".to_string(), GREEN),
            HEROIC if locked(HEROIC) => (format!("Win {zone} on Normal to open Heroic."), DIM_GREY),
            HEROIC if best > HEROIC => ("Won.".to_string(), GREEN),
            HEROIC => ("Win it to open Mythic +2.".to_string(), DIM_GREY),
            _ if locked(MYTHIC) => (format!("Win {zone} on Heroic to open Mythic +2."), DIM_GREY),
            _ if best > MYTHIC => (
                format!(
                    "Best: {}. Win a level to open the next, up to +{MAX}.",
                    name(best - 1)
                ),
                GREEN,
            ),
            _ => (
                format!("Win a level to open the next, up to +{MAX}."),
                DIM_GREY,
            ),
        };
        if t.0 != want {
            t.0 = want;
        }
        if c.0 != color {
            c.0 = color;
        }
    }
    // The affixes the difficulty picked brings stand out; the others are dimmed.
    let at = d;
    let week = of_week(week());
    for (a, mut c) in &mut texts.p6() {
        let color = if at >= AFFIX_FROM[a.0] {
            week[a.0].color()
        } else {
            DIM_GREY
        };
        if c.0 != color {
            c.0 = color;
        }
    }
    for (a, mut c) in &mut texts.p5() {
        let color = if at >= AFFIX_FROM[a.0] {
            GREEN
        } else {
            DIM_GREY
        };
        if c.0 != color {
            c.0 = color;
        }
    }
    // The rung picked has a gold border, the one under the cursor a pale one.
    for (_, &Rung(r), interaction, mut border) in &mut rungs {
        let c = if r == rung(d) {
            GOLD_TONE
        } else if *interaction != Interaction::None && !locked(r) {
            Color::srgba(0.9, 0.9, 0.9, 0.7)
        } else {
            Color::srgba(0.5, 0.5, 0.5, 0.5)
        };
        if border.top != c {
            *border = BorderColor::all(c);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_level_is_harder_and_pays_more() {
        for d in 0..MAX {
            assert!(hp_mult(d + 1) > hp_mult(d));
            assert!(damage_mult(d + 1) > damage_mult(d));
            assert!(coin_mult(d + 1) > coin_mult(d));
            assert!(armor_chance(d + 1) >= armor_chance(d));
            assert!(tier_bump(d + 1) >= tier_bump(d));
        }
        assert_eq!(name(0), "Normal");
        assert_eq!(name(1), "Heroic");
        assert_eq!(name(7), "Mythic +7");
    }

    #[test]
    fn affixes_come_with_the_level() {
        assert!(active(0, 0).is_empty());
        assert!(active(HEROIC, 0).is_empty());
        assert_eq!(active(2, 0), vec![Affix::Fortified]);
        assert_eq!(active(4, 1).len(), 2);
        assert_eq!(active(4, 1)[0], Affix::Tyrannical);
        assert_eq!(active(MAX, 3).len(), 3);
    }

    #[test]
    fn the_weeks_cycle_through_every_pair() {
        let mut pairs: Vec<(Affix, Affix)> = (0..16)
            .map(|w| {
                let [_, b, c] = of_week(w);
                (b, c)
            })
            .collect();
        pairs.sort_by_key(|p| (p.0 as u8, p.1 as u8));
        pairs.dedup();
        assert_eq!(pairs.len(), 16);
    }

    #[test]
    fn fortified_spares_bosses_and_tyrannical_spares_the_horde() {
        let run = Run {
            difficulty: 2,
            affixes: vec![Affix::Fortified],
            ..Run::default()
        };
        assert!(enemy_scale(&run, false).0 > enemy_scale(&run, true).0);
        let run = Run {
            difficulty: 2,
            affixes: vec![Affix::Tyrannical],
            ..Run::default()
        };
        assert!(enemy_scale(&run, true).0 > enemy_scale(&run, false).0);
    }
}
