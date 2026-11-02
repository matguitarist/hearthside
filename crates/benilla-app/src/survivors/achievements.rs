//! Achievements: feats the account earns once, each worth points and a purse reward. Some are
//! done within one run (kills, levels, bosses, damage, time), the rest are read off the save
//! (zones won, difficulties cleared, classes, talents, the merchant, the purse, armor, kills in
//! all). They are checked every frame; one earned pops up a toast and pays at once.
//!
//! An achievement the save already meets when it loads (a run from before achievements) is
//! granted quietly, with one toast that counts them.

use std::collections::{BTreeSet, VecDeque};

use bevy::prelude::*;

use super::hud::{
    centered_bundle, icon_bundle, text_bundle, HudFont, MenuRoot, DIM_GREY, GOLD_TONE,
};
use super::menu::{DeleteOpen, MenuBuilt, MenuStep};
use super::profile::Profile;
use super::{data, talents, Phase, Run};
use crate::glue::art::GlueArt;
use crate::glue::widgets::{glue_button, GlueBtnKind};
use crate::glue::GlueClicks;

/// What an achievement asks for.
#[derive(Clone, Copy, Debug)]
pub(super) enum Goal {
    /// Within one run.
    Kills(u32),
    Level(u32),
    Bosses(u32),
    Damage(f64),
    Survive(f32),
    /// Different zones won, by any character.
    Zones(usize),
    /// A win on this difficulty or harder ([`super::difficulty`]: 1 Heroic, n Mythic +n).
    Difficulty(u8),
    /// Classes with a win.
    Classes(usize),
    /// Every rank of a tree on one character.
    FullTree,
    /// Merchant ranks bought.
    Ranks(u32),
    /// Copper in the purse.
    Purse(u64),
    /// Armor pieces on one character.
    Armor(usize),
    /// Enemies slain over every run.
    Lifetime(u64),
}

pub(super) struct Achievement {
    pub key: &'static str,
    pub name: &'static str,
    pub text: &'static str,
    /// A spell whose icon it shows.
    pub icon: u32,
    pub points: u32,
    /// Copper paid into the purse when earned.
    pub reward: u64,
    pub goal: Goal,
}

const fn a(
    key: &'static str,
    name: &'static str,
    text: &'static str,
    icon: u32,
    points: u32,
    reward: u64,
    goal: Goal,
) -> Achievement {
    Achievement {
        key,
        name,
        text,
        icon,
        points,
        reward,
        goal,
    }
}

const S: u64 = 100;
const G: u64 = 10_000;

use Goal::*;

pub(super) const ACHIEVEMENTS: &[Achievement] = &[
    a(
        "kills_100",
        "Bloodied",
        "Slay 100 enemies in one run",
        78,
        10,
        10 * S,
        Kills(100),
    ),
    a(
        "kills_1000",
        "Slayer",
        "Slay 1,000 enemies in one run",
        1680,
        10,
        50 * S,
        Kills(1_000),
    ),
    a(
        "kills_3000",
        "Massacre",
        "Slay 3,000 enemies in one run",
        12328,
        25,
        2 * G,
        Kills(3_000),
    ),
    a(
        "level_10",
        "Seasoned",
        "Reach level 10 in one run",
        6673,
        10,
        20 * S,
        Level(10),
    ),
    a(
        "level_20",
        "Veteran",
        "Reach level 20 in one run",
        1719,
        10,
        50 * S,
        Level(20),
    ),
    a(
        "level_30",
        "Paragon",
        "Reach level 30 in one run",
        10060,
        25,
        G,
        Level(30),
    ),
    a(
        "boss_1",
        "Giant Slayer",
        "Slay a boss",
        5308,
        10,
        20 * S,
        Bosses(1),
    ),
    a(
        "boss_5",
        "Boss Hunter",
        "Slay 5 bosses in one run",
        12294,
        25,
        G,
        Bosses(5),
    ),
    a(
        "damage",
        "Heavy Hitter",
        "Deal 100,000 damage in one run",
        11366,
        10,
        50 * S,
        Damage(100_000.0),
    ),
    a(
        "survive_5",
        "Hold the Line",
        "Survive 5 minutes in one run",
        871,
        10,
        20 * S,
        Survive(300.0),
    ),
    a(
        "win_1",
        "Victorious",
        "Win a zone",
        23214,
        10,
        50 * S,
        Zones(1),
    ),
    a(
        "win_5",
        "Conqueror",
        "Win five different zones",
        20925,
        25,
        2 * G,
        Zones(5),
    ),
    a(
        "win_all",
        "Hero of Azeroth",
        "Win every zone",
        642,
        50,
        10 * G,
        Zones(data::MAPS.len()),
    ),
    a(
        "heroic",
        "Heroic",
        "Win a zone on Heroic",
        20594,
        10,
        G,
        Difficulty(1),
    ),
    a(
        "mythic_2",
        "Keystone Initiate",
        "Win a zone on Mythic +2",
        12042,
        10,
        G,
        Difficulty(2),
    ),
    a(
        "mythic_7",
        "Keystone Challenger",
        "Win a zone on Mythic +7",
        11129,
        25,
        3 * G,
        Difficulty(7),
    ),
    a(
        "mythic_15",
        "Keystone Master",
        "Win a zone on Mythic +15",
        16166,
        25,
        5 * G,
        Difficulty(15),
    ),
    a(
        "mythic_20",
        "Keystone Hero",
        "Win a zone on Mythic +20",
        1122,
        50,
        10 * G,
        Difficulty(20),
    ),
    a(
        "classes_3",
        "Versatile",
        "Win with three classes",
        17116,
        10,
        G,
        Classes(3),
    ),
    a(
        "classes_all",
        "Master of All",
        "Win with every class",
        20608,
        50,
        5 * G,
        Classes(data::CLASSES.len()),
    ),
    a(
        "full_tree",
        "Specialist",
        "Fill a talent tree",
        19574,
        25,
        G,
        FullTree,
    ),
    a(
        "patron",
        "Patron",
        "Buy 10 ranks from the Merchant",
        1459,
        10,
        50 * S,
        Ranks(10),
    ),
    a(
        "purse",
        "Well Off",
        "Hold 100 gold in the purse",
        921,
        10,
        0,
        Purse(100 * G),
    ),
    a(
        "armor",
        "Armored",
        "Collect 9 pieces of armor on one character",
        23920,
        10,
        G,
        Armor(9),
    ),
    a(
        "lifetime",
        "Exterminator",
        "Slay 25,000 enemies in all",
        13750,
        25,
        2 * G,
        Lifetime(25_000),
    ),
];

pub(super) fn index(key: &str) -> Option<usize> {
    ACHIEVEMENTS.iter().position(|a| a.key == key)
}

/// Every rank of a tree: three a talent, the last row's one.
fn tree_full(class: u8, ranks: &talents::Picked, tree: usize) -> bool {
    (0..talents::PER_TREE).all(|k| {
        let slot = tree * talents::PER_TREE + k;
        ranks[slot] >= talents::talent(class, slot).ranks
    })
}

/// How far the account is toward `goal`, and what it asks; `None` for a goal only one run can
/// meet, which keeps no count.
pub(super) fn progress(goal: Goal, p: &Profile) -> Option<(u64, u64)> {
    let won = |c: &super::profile::Character| c.zones.iter().any(|z| z.wins > 0);
    Some(match goal {
        Zones(n) => {
            let zones = (0..data::MAPS.len())
                .filter(|&m| p.chars.iter().any(|c| c.zones[m].wins > 0))
                .count();
            (zones as u64, n as u64)
        }
        Difficulty(d) => {
            let top = p
                .chars
                .iter()
                .flat_map(|c| &c.zones)
                .map(|z| z.cleared)
                .max()
                .unwrap_or(0);
            (u64::from(top > d), 1)
        }
        Classes(n) => {
            let classes: BTreeSet<usize> =
                p.chars.iter().filter(|c| won(c)).map(|c| c.class).collect();
            (classes.len() as u64, n as u64)
        }
        FullTree => {
            let full = p.chars.iter().any(|c| {
                let class = data::CLASSES[c.class].id;
                (0..talents::TREES).any(|t| tree_full(class, &c.talents, t))
            });
            (u64::from(full), 1)
        }
        Ranks(n) => (p.ranks.iter().map(|&r| u64::from(r)).sum(), u64::from(n)),
        Purse(n) => (p.copper, n),
        Armor(n) => (
            p.chars.iter().map(|c| c.gear.len()).max().unwrap_or(0) as u64,
            n as u64,
        ),
        Lifetime(n) => (p.kills, n),
        Kills(n) => (
            p.chars
                .iter()
                .flat_map(|c| &c.zones)
                .map(|z| u64::from(z.best_kills))
                .max()
                .unwrap_or(0),
            u64::from(n),
        ),
        Level(_) | Bosses(_) | Damage(_) | Survive(_) => return None,
    })
}

/// Whether `goal` is met, by the account or by `run`, the run under way.
pub(super) fn met(goal: Goal, p: &Profile, run: Option<&Run>) -> bool {
    let by_run = run.is_some_and(|r| match goal {
        Kills(n) => r.kills >= n,
        Level(n) => r.level >= n,
        Bosses(n) => r.boss_kills >= n,
        Damage(n) => r.damage_done >= n,
        Survive(s) => r.elapsed >= s,
        _ => false,
    });
    by_run || progress(goal, p).is_some_and(|(have, want)| have >= want)
}

/// Achievements waiting to pop up, and the one up with its seconds left.
#[derive(Resource, Default)]
pub(super) struct Toasts {
    queue: VecDeque<Toast>,
    shown: Option<(Toast, f32)>,
}

#[derive(Clone)]
struct Toast {
    icon: u32,
    title: String,
    name: String,
    reward: u64,
}

const TOAST_SECS: f32 = 4.5;

/// Earn what is met: into the save, the reward into the purse, a toast up.
fn earn(
    phase: Res<State<Phase>>,
    run: Res<Run>,
    mut profile: ResMut<Profile>,
    mut toasts: ResMut<Toasts>,
    mut sounds: MessageWriter<crate::sound::GlueSound>,
    mut primed: Local<bool>,
) {
    // A run's own feats count only while it is on or at its results.
    let run = (*phase.get() != Phase::Menu).then_some(&*run);
    let new: Vec<usize> = (0..ACHIEVEMENTS.len())
        .filter(|&i| !profile.achieved.contains(ACHIEVEMENTS[i].key))
        .filter(|&i| met(ACHIEVEMENTS[i].goal, &profile, run))
        .collect();
    let quiet = !*primed;
    *primed = true;
    if new.is_empty() {
        return;
    }
    let mut paid = 0;
    for &i in &new {
        let a = &ACHIEVEMENTS[i];
        profile.achieved.insert(a.key);
        paid += a.reward;
        if !quiet {
            toasts.queue.push_back(Toast {
                icon: a.icon,
                title: "Achievement Earned".into(),
                name: a.name.into(),
                reward: a.reward,
            });
        }
    }
    profile.copper += paid;
    profile.version += 1;
    profile.save();
    if quiet {
        let n = new.len();
        toasts.queue.push_back(Toast {
            icon: ACHIEVEMENTS[new[0]].icon,
            title: "From your past runs".into(),
            name: format!("{n} achievement{} earned", if n == 1 { "" } else { "s" }),
            reward: paid,
        });
    }
    sounds.write(crate::sound::GlueSound("LEVELUPSOUND"));
}

impl Profile {
    pub(super) fn achievement_points(&self) -> u32 {
        ACHIEVEMENTS
            .iter()
            .filter(|a| self.achieved.contains(a.key))
            .map(|a| a.points)
            .sum()
    }
}

#[derive(Component, Clone, Copy, PartialEq, Eq)]
pub(super) enum AchievementAction {
    Open,
    Close,
}

/// Whether the achievements dialog is up.
#[derive(Resource, Default)]
pub(super) struct AchievementsOpen(pub(super) bool);

#[derive(Component)]
struct AchievementsBuilt;
#[derive(Component)]
struct AchievementsOverlay;
#[derive(Component)]
struct AchievementsCorner;
#[derive(Component)]
struct SummaryText;
#[derive(Component)]
struct EntryName(usize);
#[derive(Component)]
struct EntryText(usize);
#[derive(Component)]
struct EntryState(usize);
/// The veil over a locked achievement's icon.
#[derive(Component)]
struct EntryDim(usize);
#[derive(Component)]
struct ToastRoot;
#[derive(Component)]
struct ToastIcon;
#[derive(Component)]
struct ToastTitle;
#[derive(Component)]
struct ToastName;
#[derive(Component)]
struct ToastReward;

const DIALOG_W: f32 = 1000.0;
const ENTRY_W: f32 = 300.0;
const ENTRY_H: f32 = 50.0;
const GREEN: Color = Color::srgb(0.12, 1.0, 0.0);

pub(super) fn plugin(app: &mut App) {
    app.init_resource::<AchievementsOpen>()
        .init_resource::<Toasts>()
        .add_systems(
            Update,
            (build_achievements, achievements)
                .chain()
                .after(super::menu::build_menu)
                .after(super::menu::menu_clicks)
                .before(crate::glue::GlueVisuals),
        )
        .add_systems(Update, (build_toast, earn, show_toast).chain())
        .add_systems(
            Update,
            auto_dialog
                .before(super::auto::drive)
                .run_if(resource_exists::<super::auto::Auto>),
        );
}

/// `<class>:achievements`: once the pick screen is up, open the dialog, shoot it and close it,
/// the run held back meanwhile.
fn auto_dialog(
    mut commands: Commands,
    time: Res<Time<Real>>,
    phase: Res<State<Phase>>,
    mut auto: ResMut<super::auto::Auto>,
    mut open: ResMut<AchievementsOpen>,
    mut t: Local<f32>,
) {
    let ready = auto.seen.iter().any(|s| s == "menu");
    if !auto.achievements || *phase.get() != Phase::Menu || !ready || *t > 7.0 {
        return;
    }
    *t += time.delta_secs();
    auto.wait = 0.0;
    // The first shot catches the toast of past runs; the second, the dialog.
    if *t > 1.5 {
        auto.capture_once(&mut commands, "achievement-toast".into());
    }
    open.0 = *t > 5.0;
    if *t > 6.5 {
        auto.capture_once(&mut commands, "achievements".into());
    }
    if *t > 7.0 {
        open.0 = false;
    }
}

/// The toast, top centre over everything, hidden until something is earned.
fn build_toast(
    mut commands: Commands,
    font: Option<Res<HudFont>>,
    built: Query<(), With<ToastRoot>>,
) {
    let Some(font) = font else { return };
    if !built.is_empty() {
        return;
    }
    let f = &font.0;
    commands
        .spawn((
            ToastRoot,
            Node {
                position_type: PositionType::Absolute,
                width: Val::Percent(100.0),
                top: Val::Px(150.0),
                justify_content: JustifyContent::Center,
                display: Display::None,
                ..default()
            },
            GlobalZIndex(450),
            bevy::ui::FocusPolicy::Pass,
        ))
        .with_children(|r| {
            r.spawn((
                Node {
                    width: Val::Px(340.0),
                    padding: UiRect::all(Val::Px(8.0)),
                    column_gap: Val::Px(10.0),
                    align_items: AlignItems::Center,
                    border: UiRect::all(Val::Px(2.0)),
                    ..default()
                },
                BackgroundColor(Color::srgba(0.02, 0.02, 0.04, 0.88)),
                BorderColor::all(GOLD_TONE),
                bevy::ui::FocusPolicy::Pass,
            ))
            .with_children(|b| {
                b.spawn((ToastIcon, icon_bundle(0, 44.0)));
                b.spawn(Node {
                    flex_direction: FlexDirection::Column,
                    row_gap: Val::Px(2.0),
                    ..default()
                })
                .with_children(|c| {
                    c.spawn((ToastTitle, text_bundle(f, "", 11.0, GOLD_TONE)));
                    c.spawn((ToastName, text_bundle(f, "", 16.0, Color::WHITE)));
                    c.spawn((ToastReward, text_bundle(f, "", 11.0, DIM_GREY)));
                });
            });
        });
}

#[allow(clippy::type_complexity)]
fn show_toast(
    mut commands: Commands,
    time: Res<Time<Real>>,
    loading: Res<crate::loading_screen::LoadingScreen>,
    phase: Res<State<Phase>>,
    mut toasts: ResMut<Toasts>,
    mut root: Query<&mut Node, With<ToastRoot>>,
    icon: Query<Entity, With<ToastIcon>>,
    mut texts: ParamSet<(
        Query<&mut Text, With<ToastTitle>>,
        Query<&mut Text, With<ToastName>>,
        Query<&mut Text, With<ToastReward>>,
    )>,
) {
    // Held while the loading screen covers the world, so none plays out unseen, and under the
    // level-up cards and the pause menu, whose titles sit where it does.
    let held = loading.covering() || matches!(phase.get(), Phase::LevelUp | Phase::Paused);
    let mut changed = false;
    if !held {
        if let Some((_, t)) = &mut toasts.shown {
            *t -= time.delta_secs();
            if *t <= 0.0 {
                toasts.shown = None;
                changed = true;
            }
        }
        if toasts.shown.is_none() {
            if let Some(next) = toasts.queue.pop_front() {
                toasts.shown = Some((next, TOAST_SECS));
                changed = true;
            }
        }
    }
    let want = if toasts.shown.is_some() && !held {
        Display::Flex
    } else {
        Display::None
    };
    for mut node in &mut root {
        if node.display != want {
            node.display = want;
        }
    }
    if !changed {
        return;
    }
    let shown = toasts.shown.as_ref().map(|(t, _)| t.clone());
    let Some(t) = shown else { return };
    for e in &icon {
        commands
            .entity(e)
            .remove::<super::hud::IconDone>()
            .insert(super::hud::SpellIcon(t.icon));
    }
    let reward = if t.reward > 0 {
        format!("Reward: {}", super::bag::money(t.reward))
    } else {
        String::new()
    };
    for mut q in &mut texts.p0() {
        q.0.clone_from(&t.title);
    }
    for mut q in &mut texts.p1() {
        q.0.clone_from(&t.name);
    }
    for mut q in &mut texts.p2() {
        q.0.clone_from(&reward);
    }
}

/// The Achievements button beside Quit, and the dialog, hidden until opened.
#[allow(clippy::type_complexity)]
fn build_achievements(
    mut commands: Commands,
    roots: Query<Entity, (With<MenuRoot>, With<MenuBuilt>, Without<AchievementsBuilt>)>,
    art: Res<GlueArt>,
    font: Res<HudFont>,
) {
    let Ok(root) = roots.single() else { return };
    let f = &font.0;
    let art = &*art;
    commands
        .entity(root)
        .insert(AchievementsBuilt)
        .with_children(|ui| {
            ui.spawn((
                AchievementsCorner,
                Node {
                    position_type: PositionType::Absolute,
                    left: Val::Px(236.0),
                    bottom: Val::Px(30.0),
                    ..default()
                },
            ))
            .with_children(|c| {
                glue_button(
                    c,
                    art,
                    f,
                    AchievementAction::Open,
                    "Achievements",
                    200.0,
                    60.0,
                    GlueBtnKind::Normal,
                    1.0,
                );
            });
            ui.spawn((
                AchievementsOverlay,
                // Block, not Node's default Pass: clicks on it must not reach the screen beneath.
                Interaction::default(),
                bevy::ui::FocusPolicy::Block,
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
                let title = centered_bundle(f, "Achievements", 14.0, GOLD_TONE);
                super::panels::dialog(o, art, DIALOG_W, (), title, |b| {
                    b.spawn((SummaryText, centered_bundle(f, "", 15.0, Color::WHITE)));
                    b.spawn(Node {
                        display: Display::Grid,
                        grid_template_columns: RepeatedGridTrack::px(3, ENTRY_W),
                        column_gap: Val::Px(10.0),
                        row_gap: Val::Px(6.0),
                        ..default()
                    })
                    .with_children(|g| {
                        for (i, a) in ACHIEVEMENTS.iter().enumerate() {
                            entry(g, f, i, a);
                        }
                    });
                    glue_button(
                        b,
                        art,
                        f,
                        AchievementAction::Close,
                        "Close",
                        180.0,
                        34.0,
                        GlueBtnKind::Small,
                        1.0,
                    );
                });
            });
        });
}

/// One achievement: the icon (veiled until earned), the name and points, what it asks and where
/// the account stands.
fn entry(g: &mut ChildSpawnerCommands, f: &Handle<Font>, i: usize, a: &Achievement) {
    g.spawn((
        Node {
            width: Val::Px(ENTRY_W),
            height: Val::Px(ENTRY_H),
            padding: UiRect::all(Val::Px(5.0)),
            column_gap: Val::Px(8.0),
            align_items: AlignItems::Center,
            border: UiRect::all(Val::Px(1.0)),
            ..default()
        },
        BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.45)),
        BorderColor::all(Color::srgba(0.5, 0.5, 0.5, 0.5)),
    ))
    .with_children(|w| {
        w.spawn(Node {
            width: Val::Px(38.0),
            height: Val::Px(38.0),
            ..default()
        })
        .with_children(|ic| {
            ic.spawn(icon_bundle(a.icon, 38.0));
            ic.spawn((
                EntryDim(i),
                Node {
                    position_type: PositionType::Absolute,
                    width: Val::Percent(100.0),
                    height: Val::Percent(100.0),
                    ..default()
                },
                BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.65)),
            ));
        });
        w.spawn(Node {
            flex_direction: FlexDirection::Column,
            flex_grow: 1.0,
            flex_shrink: 1.0,
            row_gap: Val::Px(2.0),
            ..default()
        })
        .with_children(|c| {
            c.spawn(Node {
                justify_content: JustifyContent::SpaceBetween,
                column_gap: Val::Px(6.0),
                ..default()
            })
            .with_children(|row| {
                row.spawn((EntryName(i), text_bundle(f, a.name, 12.0, GOLD_TONE)));
                row.spawn((EntryState(i), text_bundle(f, "", 11.0, DIM_GREY)));
            });
            c.spawn((EntryText(i), text_bundle(f, a.text, 11.0, Color::WHITE)));
        });
    });
}

/// Open and close the dialog, and keep each entry's colours and standing current.
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
fn achievements(
    clicks: Res<GlueClicks>,
    keys: Res<ButtonInput<KeyCode>>,
    phase: Res<State<Phase>>,
    step: Res<MenuStep>,
    delete: Res<DeleteOpen>,
    mut open: ResMut<AchievementsOpen>,
    profile: Res<Profile>,
    actions: Query<(Entity, &AchievementAction)>,
    mut nodes: ParamSet<(
        Query<&mut Node, With<AchievementsOverlay>>,
        Query<&mut Node, With<AchievementsCorner>>,
        Query<(&EntryDim, &mut Node)>,
    )>,
    mut texts: ParamSet<(
        Query<&mut Text, With<SummaryText>>,
        Query<(&EntryName, &mut TextColor)>,
        Query<(&EntryText, &mut TextColor)>,
        Query<(&EntryState, &mut Text, &mut TextColor)>,
    )>,
    mut sounds: MessageWriter<crate::sound::GlueSound>,
    mut shown: Local<Option<u32>>,
) {
    let menu = *phase.get() == Phase::Menu;
    for mut node in &mut nodes.p1() {
        let want = if menu && *step == MenuStep::Select && !delete.0 && profile.hero().is_some() {
            Display::Flex
        } else {
            Display::None
        };
        if node.display != want {
            node.display = want;
        }
    }
    if !menu {
        open.0 = false;
    }
    let was = open.0;
    if menu {
        for (e, a) in &actions {
            if clicks.hit(e) {
                open.0 = *a == AchievementAction::Open;
            }
        }
        if open.0 && keys.just_pressed(KeyCode::Escape) {
            open.0 = false;
        }
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
    // The entries change only with the save.
    if !open.0 || *shown == Some(profile.version) {
        return;
    }
    *shown = Some(profile.version);
    let earned = |i: usize| profile.achieved.contains(ACHIEVEMENTS[i].key);
    let count = (0..ACHIEVEMENTS.len()).filter(|&i| earned(i)).count();
    let summary = format!(
        "{count} of {} earned    {} points",
        ACHIEVEMENTS.len(),
        profile.achievement_points()
    );
    for mut t in &mut texts.p0() {
        t.0 = summary.clone();
    }
    for (d, mut node) in &mut nodes.p2() {
        node.display = if earned(d.0) {
            Display::None
        } else {
            Display::Flex
        };
    }
    for (n, mut c) in &mut texts.p1() {
        c.0 = if earned(n.0) { GOLD_TONE } else { DIM_GREY };
    }
    for (n, mut c) in &mut texts.p2() {
        c.0 = if earned(n.0) { Color::WHITE } else { DIM_GREY };
    }
    for (s, mut t, mut c) in &mut texts.p3() {
        let a = &ACHIEVEMENTS[s.0];
        let (want, color) = if earned(s.0) {
            (format!("{} pts", a.points), GREEN)
        } else {
            match progress(a.goal, &profile).filter(|&(_, want)| want > 1) {
                Some((have, want)) => (
                    format!(
                        "{}/{}",
                        count_text(have.min(want), a.goal),
                        count_text(want, a.goal)
                    ),
                    Color::WHITE,
                ),
                None => (format!("{} pts", a.points), DIM_GREY),
            }
        };
        t.0 = want;
        c.0 = color;
    }
}

/// A count as the dialog writes it: gold for the purse, thousands grouped.
fn count_text(n: u64, goal: Goal) -> String {
    if matches!(goal, Purse(_)) {
        return format!("{}g", n / G);
    }
    let s = n.to_string();
    let mut out = String::new();
    for (k, ch) in s.chars().enumerate() {
        if k > 0 && (s.len() - k).is_multiple_of(3) {
            out.push(',');
        }
        out.push(ch);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::super::profile::Character;
    use super::super::units::Custom;
    use super::*;

    fn account() -> Profile {
        let mut p = Profile::empty();
        assert!(p.create(Character::new(
            "Thrall".into(),
            0,
            2,
            0,
            Custom::default(),
            0
        )));
        p
    }

    #[test]
    fn keys_are_unique() {
        for (i, a) in ACHIEVEMENTS.iter().enumerate() {
            assert_eq!(index(a.key), Some(i), "{} twice", a.key);
        }
    }

    #[test]
    fn a_run_and_the_save_each_meet_their_own() {
        let mut p = account();
        let run = Run {
            kills: 150,
            level: 12,
            ..Run::default()
        };
        assert!(met(Kills(100), &p, Some(&run)));
        assert!(met(Level(10), &p, Some(&run)));
        assert!(!met(Level(20), &p, Some(&run)));
        assert!(!met(Kills(100), &p, None), "no run, no best kills yet");
        p.chars[0].zones[0].best_kills = 120;
        assert!(met(Kills(100), &p, None), "a past run's best counts");
        assert!(!met(Zones(1), &p, None));
        p.chars[0].zones[0].wins = 1;
        p.chars[0].zones[0].cleared = 3;
        assert!(met(Zones(1), &p, None));
        assert!(met(Difficulty(1), &p, None), "Heroic");
        assert!(met(Difficulty(2), &p, None), "Mythic +2");
        assert!(!met(Difficulty(3), &p, None));
        assert!(met(Classes(1), &p, None));
        assert!(!met(Classes(3), &p, None));
    }

    #[test]
    fn a_full_tree_takes_every_rank() {
        let mut p = account();
        let class = data::CLASSES[0].id;
        for k in 0..talents::PER_TREE - 1 {
            p.chars[0].talents[k] = talents::talent(class, k).ranks;
        }
        assert!(!met(FullTree, &p, None));
        p.chars[0].talents[talents::PER_TREE - 1] = 1;
        assert!(met(FullTree, &p, None));
    }

    #[test]
    fn counts_group_their_thousands() {
        assert_eq!(count_text(25_000, Lifetime(0)), "25,000");
        assert_eq!(count_text(999, Lifetime(0)), "999");
        assert_eq!(count_text(1_000_000, Purse(0)), "100g");
    }
}
