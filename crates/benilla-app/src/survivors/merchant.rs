//! The merchant: what the purse buys. On the pick screen a Merchant button opens a dialog of
//! permanent upgrades, each a few ranks deep at a rising price, the survivors-game way to make
//! the next run go further. The ranks bought are the profile's ([`super::profile`]); a run copies
//! them when it begins ([`Run::ranks`]) and its stats add them ([`apply`]).

use bevy::prelude::*;

use super::data::{self, Stat};
use super::hud::{
    centered_bundle, icon_bundle, text_bundle, HudFont, MenuRoot, UiArt, DIM_GREY, GOLD_TONE,
};
use super::profile::Profile;
use super::{Phase, Run, Stats};
use crate::glue::art::GlueArt;
use crate::glue::widgets::{glue_button, GlueBtnKind};
use crate::glue::GlueClicks;

/// What an upgrade does with each rank.
#[derive(Clone, Copy)]
pub(super) enum Boon {
    Stat(Stat, f32),
    /// Coins dropped, up by this fraction.
    Greed(f32),
    /// Minor Healing Potions in the bag at the start of a run.
    Provisions,
    /// A fresh hand of level-up cards, once a run per rank.
    Reroll,
    /// A level-up card struck from the run's pool, once a run per rank.
    Banish,
}

pub(super) struct Upgrade {
    pub key: &'static str,
    pub name: &'static str,
    pub boon: Boon,
    pub ranks: u8,
    /// The first rank's price in copper; each rank after costs 1.8 times the one before.
    pub base: u64,
    /// The icon, for the upgrades that are no passive's: an item's, `Interface\Icons\<name>`.
    art: Option<&'static str>,
}

const fn stat(
    key: &'static str,
    name: &'static str,
    s: Stat,
    per: f32,
    ranks: u8,
    base: u64,
) -> Upgrade {
    Upgrade {
        key,
        name,
        boon: Boon::Stat(s, per),
        ranks,
        base,
        art: None,
    }
}

pub(super) const UPGRADES: [Upgrade; 14] = [
    stat("might", "Might", Stat::Might, 0.05, 5, 2_000),
    stat("fortitude", "Fortitude", Stat::MaxHp, 0.08, 5, 2_000),
    stat("swiftness", "Swiftness", Stat::Speed, 0.04, 5, 2_500),
    stat("renewal", "Renewal", Stat::Regen, 0.3, 5, 2_000),
    stat("haste", "Haste", Stat::Haste, 0.03, 5, 3_000),
    stat("reach", "Reach", Stat::Area, 0.04, 5, 3_000),
    stat("magnetism", "Magnetism", Stat::Magnet, 0.12, 3, 1_500),
    stat("wisdom", "Wisdom", Stat::Growth, 0.05, 5, 2_500),
    stat("armor", "Armor", Stat::Armor, 1.0, 5, 2_000),
    stat("precision", "Precision", Stat::Crit, 0.02, 5, 3_000),
    Upgrade {
        key: "greed",
        name: "Greed",
        boon: Boon::Greed(0.1),
        ranks: 5,
        base: 2_500,
        art: Some("Interface\\Icons\\INV_Misc_Coin_02"),
    },
    Upgrade {
        key: "provisions",
        name: "Provisions",
        boon: Boon::Provisions,
        ranks: 3,
        base: 1_500,
        art: Some("Interface\\Icons\\INV_Potion_49"),
    },
    Upgrade {
        key: "reroll",
        name: "Fortune",
        boon: Boon::Reroll,
        ranks: 3,
        base: 3_000,
        art: Some("Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01"),
    },
    Upgrade {
        key: "banish",
        name: "Banishment",
        boon: Boon::Banish,
        ranks: 3,
        base: 4_000,
        art: Some("Interface\\Icons\\Spell_Holy_DispelMagic"),
    },
];

/// The ranks bought, indexed like [`UPGRADES`].
pub(super) type Ranks = [u8; UPGRADES.len()];

impl Upgrade {
    /// The price of the rank after `rank`.
    pub(super) fn price(&self, rank: u8) -> u64 {
        (self.base as f64 * 1.8f64.powi(i32::from(rank))).round() as u64
    }

    /// The passive's spell whose icon a stat upgrade shows.
    fn spell(&self) -> u32 {
        match self.boon {
            Boon::Stat(s, _) => data::PASSIVES
                .iter()
                .find(|p| p.stat == s)
                .map_or(0, |p| p.spell),
            _ => 0,
        }
    }

    /// What `rank` ranks give, as the merchant lists it.
    fn effect(&self, rank: u8) -> String {
        match self.boon {
            Boon::Stat(s, per) => super::bag::stat_line(s, per * f32::from(rank)),
            Boon::Greed(per) => format!("+{:.0}% Coins", per * 100.0 * f32::from(rank)),
            Boon::Provisions => format!("{rank} Minor Healing Potions to start"),
            Boon::Reroll => format!("{rank} level-up rerolls a run"),
            Boon::Banish => format!("{rank} level-up banishes a run"),
        }
    }
}

pub(super) fn index(key: &str) -> Option<usize> {
    UPGRADES.iter().position(|u| u.key == key)
}

/// What the ranks add to the hero's stats.
pub(super) fn apply(ranks: &Ranks, s: &mut Stats) {
    for (u, &r) in UPGRADES.iter().zip(ranks) {
        if let Boon::Stat(stat, per) = u.boon {
            if r > 0 {
                super::bag::add_stat(s, stat, per * f32::from(r));
            }
        }
    }
}

/// The coins multiplier [`Boon::Greed`] gives.
pub(super) fn greed(ranks: &Ranks) -> f32 {
    UPGRADES
        .iter()
        .zip(ranks)
        .map(|(u, &r)| match u.boon {
            Boon::Greed(per) => per * f32::from(r),
            _ => 0.0,
        })
        .sum::<f32>()
        + 1.0
}

/// The ranks of the upgrades `boon` matches: one potion, reroll or banish a run each.
fn count(ranks: &Ranks, boon: impl Fn(Boon) -> bool) -> u8 {
    UPGRADES
        .iter()
        .zip(ranks)
        .filter(|(u, _)| boon(u.boon))
        .map(|(_, &r)| r)
        .sum()
}

/// How many potions [`Boon::Provisions`] starts a run with.
pub(super) fn provisions(ranks: &Ranks) -> u8 {
    count(ranks, |b| matches!(b, Boon::Provisions))
}

/// The level-up rerolls [`Boon::Reroll`] gives a run.
pub(super) fn rerolls(ranks: &Ranks) -> u8 {
    count(ranks, |b| matches!(b, Boon::Reroll))
}

/// The level-up banishes [`Boon::Banish`] gives a run.
pub(super) fn banishes(ranks: &Ranks) -> u8 {
    count(ranks, |b| matches!(b, Boon::Banish))
}

#[derive(Component, Clone, Copy, PartialEq, Eq)]
pub(super) enum MerchantAction {
    Open,
    Close,
}

/// Whether the merchant's dialog is up.
#[derive(Resource, Default)]
pub(super) struct MerchantOpen(pub(super) bool);

#[derive(Component)]
pub(super) struct MerchantBuilt;
#[derive(Component)]
pub(super) struct MerchantOverlay;
/// An upgrade's cell: a click buys its next rank.
#[derive(Component)]
pub(super) struct Ware(usize);
#[derive(Component)]
pub(super) struct WareRank(usize);
#[derive(Component)]
pub(super) struct WareEffect(usize);
#[derive(Component)]
pub(super) struct WarePrice(usize);
/// The Merchant button and the purse over it, shown on character select only.
#[derive(Component)]
pub(super) struct MerchantCorner;
/// The purse, under the Merchant button and in the dialog.
#[derive(Component)]
pub(super) struct PurseText;

const MERCHANT_W: f32 = 660.0;
const WARE_W: f32 = 300.0;
const WARE_H: f32 = 50.0;

/// The Merchant button over Quit, the purse beside it, and the dialog, hidden until opened.
pub(super) fn build_merchant(
    mut commands: Commands,
    roots: Query<
        Entity,
        (
            With<MenuRoot>,
            With<super::menu::MenuBuilt>,
            Without<MerchantBuilt>,
        ),
    >,
    art: Res<GlueArt>,
    font: Res<HudFont>,
) {
    let Ok(root) = roots.single() else { return };
    let f = &font.0;
    let art = &*art;
    commands.entity(root).insert(MerchantBuilt).with_children(|ui| {
        ui.spawn((MerchantCorner, Node {
            position_type: PositionType::Absolute,
            left: Val::Px(24.0),
            bottom: Val::Px(96.0),
            flex_direction: FlexDirection::Column,
            align_items: AlignItems::Center,
            row_gap: Val::Px(2.0),
            ..default()
        }))
        .with_children(|c| {
            c.spawn((PurseText, centered_bundle(f, "", 13.0, Color::WHITE)));
            glue_button(
                c,
                art,
                f,
                MerchantAction::Open,
                "Merchant",
                200.0,
                60.0,
                GlueBtnKind::Normal,
                1.0,
            );
        });
        // Over the whole screen, so nothing under it takes a click or a drag while it is up.
        ui.spawn((
            MerchantOverlay,
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
            let title = centered_bundle(f, "Merchant", 14.0, GOLD_TONE);
            super::panels::dialog(o, art, MERCHANT_W, (), title, |b| {
                b.spawn(Node {
                    max_width: Val::Px(MERCHANT_W - 60.0),
                    ..default()
                })
                .with_children(|n| {
                    n.spawn(centered_bundle(
                        f,
                        "Every rank lasts: it makes each run after it stronger. Click a ware to buy its next rank.",
                        12.0,
                        DIM_GREY,
                    ));
                });
                b.spawn(Node {
                    display: Display::Grid,
                    grid_template_columns: RepeatedGridTrack::px(2, WARE_W),
                    column_gap: Val::Px(12.0),
                    row_gap: Val::Px(6.0),
                    ..default()
                })
                .with_children(|g| {
                    for (i, u) in UPGRADES.iter().enumerate() {
                        ware(g, f, i, u);
                    }
                });
                b.spawn(Node {
                    margin: UiRect::top(Val::Px(4.0)),
                    ..default()
                })
                .with_children(|n| {
                    n.spawn((PurseText, centered_bundle(f, "", 13.0, Color::WHITE)));
                });
                glue_button(
                    b,
                    art,
                    f,
                    MerchantAction::Close,
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

/// One ware: the icon, the name and rank, what the ranks give, and the next rank's price.
fn ware(g: &mut ChildSpawnerCommands, f: &Handle<Font>, i: usize, u: &Upgrade) {
    g.spawn((
        Ware(i),
        Button,
        Interaction::default(),
        Node {
            width: Val::Px(WARE_W),
            height: Val::Px(WARE_H),
            padding: UiRect::all(Val::Px(6.0)),
            column_gap: Val::Px(8.0),
            align_items: AlignItems::Center,
            border: UiRect::all(Val::Px(1.0)),
            ..default()
        },
        BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.45)),
        BorderColor::all(Color::srgba(0.5, 0.5, 0.5, 0.5)),
    ))
    .with_children(|w| {
        match u.art {
            Some(path) => w.spawn((
                Node {
                    width: Val::Px(36.0),
                    height: Val::Px(36.0),
                    ..default()
                },
                ImageNode {
                    color: Color::NONE,
                    ..default()
                },
                UiArt::crop(path, [0.0, 1.0, 0.0, 1.0]),
                bevy::ui::FocusPolicy::Pass,
            )),
            None => w.spawn((icon_bundle(u.spell(), 36.0), bevy::ui::FocusPolicy::Pass)),
        };
        w.spawn((
            Node {
                flex_direction: FlexDirection::Column,
                flex_grow: 1.0,
                ..default()
            },
            bevy::ui::FocusPolicy::Pass,
        ))
        .with_children(|col| {
            col.spawn(Node {
                justify_content: JustifyContent::SpaceBetween,
                ..default()
            })
            .with_children(|row| {
                row.spawn(text_bundle(f, u.name, 13.0, GOLD_TONE));
                row.spawn((WareRank(i), text_bundle(f, "", 12.0, DIM_GREY)));
            });
            col.spawn(Node {
                justify_content: JustifyContent::SpaceBetween,
                ..default()
            })
            .with_children(|row| {
                row.spawn((WareEffect(i), text_bundle(f, "", 12.0, Color::WHITE)));
                row.spawn((WarePrice(i), text_bundle(f, "", 12.0, Color::WHITE)));
            });
        });
    });
}

/// Open and close the dialog, buy what is clicked, and keep the purse and the wares' lines.
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
pub(super) fn merchant(
    clicks: Res<GlueClicks>,
    keys: Res<ButtonInput<KeyCode>>,
    phase: Res<State<Phase>>,
    mut open: ResMut<MerchantOpen>,
    mut profile: ResMut<Profile>,
    mut run: ResMut<Run>,
    actions: Query<(Entity, &MerchantAction)>,
    mut wares: Query<(Entity, &Ware, &Interaction, &mut BorderColor)>,
    mut overlay: Query<&mut Node, With<MerchantOverlay>>,
    mut texts: ParamSet<(
        Query<&mut Text, With<PurseText>>,
        Query<(&WareRank, &mut Text)>,
        Query<(&WareEffect, &mut Text)>,
        Query<(&WarePrice, &mut Text, &mut TextColor)>,
    )>,
    mut sounds: MessageWriter<crate::sound::GlueSound>,
) {
    if *phase.get() != Phase::Menu {
        open.0 = false;
        return;
    }
    let was = open.0;
    for (e, a) in &actions {
        if clicks.hit(e) {
            open.0 = *a == MerchantAction::Open;
        }
    }
    if open.0 && keys.just_pressed(KeyCode::Escape) {
        open.0 = false;
    }
    if open.0 != was {
        sounds.write(crate::sound::GlueSound(if open.0 {
            "igMainMenuOpen"
        } else {
            "igMainMenuClose"
        }));
    }
    for mut node in &mut overlay {
        let want = if open.0 { Display::Flex } else { Display::None };
        if node.display != want {
            node.display = want;
        }
    }
    if open.0 {
        for (e, &Ware(i), _, _) in &wares {
            if clicks.hit(e) && profile.buy(i) {
                sounds.write(crate::sound::GlueSound("LOOTWINDOWCOINSOUND"));
            }
        }
    }
    // The run about to begin wears what is bought.
    if run.ranks != profile.ranks {
        run.ranks = profile.ranks;
    }
    let purse = format!("Purse: {}", super::bag::money(profile.copper));
    for mut t in &mut texts.p0() {
        if t.0 != purse {
            t.0 = purse.clone();
        }
    }
    let rank = |i: usize| profile.ranks[i];
    for (w, mut t) in &mut texts.p1() {
        let want = format!("Rank {}/{}", rank(w.0), UPGRADES[w.0].ranks);
        if t.0 != want {
            t.0 = want;
        }
    }
    for (w, mut t) in &mut texts.p2() {
        let u = &UPGRADES[w.0];
        let r = rank(w.0);
        let want = if r == 0 {
            format!("{} a rank", u.effect(1))
        } else {
            u.effect(r)
        };
        if t.0 != want {
            t.0 = want;
        }
    }
    for (w, mut t, mut color) in &mut texts.p3() {
        let u = &UPGRADES[w.0];
        let r = rank(w.0);
        let (want, c) = if r >= u.ranks {
            ("Max".to_string(), Color::srgb_u8(30, 255, 0))
        } else {
            let p = u.price(r);
            let c = if p <= profile.copper {
                Color::WHITE
            } else {
                Color::srgb(1.0, 0.25, 0.25)
            };
            (super::bag::money(p), c)
        };
        if t.0 != want {
            t.0 = want;
        }
        if color.0 != c {
            color.0 = c;
        }
    }
    // The ware under the cursor or the pad's focus lights up.
    for (_, _, interaction, mut border) in &mut wares {
        let c = if *interaction == Interaction::None {
            Color::srgba(0.5, 0.5, 0.5, 0.5)
        } else {
            GOLD_TONE
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
    fn each_rank_costs_more_than_the_last() {
        let u = &UPGRADES[0];
        assert_eq!(u.price(0), 2_000);
        assert_eq!(u.price(1), 3_600);
        assert!(u.price(4) > u.price(3));
    }

    #[test]
    fn ranks_add_their_stats_and_coins() {
        let mut ranks: Ranks = [0; UPGRADES.len()];
        ranks[index("might").unwrap()] = 2;
        ranks[index("greed").unwrap()] = 3;
        ranks[index("provisions").unwrap()] = 1;
        let mut s = Run::default().stats();
        let before = s.might;
        apply(&ranks, &mut s);
        assert!((s.might - before - 0.10).abs() < 1e-6);
        assert!((greed(&ranks) - 1.3).abs() < 1e-6);
        assert_eq!(provisions(&ranks), 1);
    }

    #[test]
    fn a_banished_card_is_offered_no_more() {
        use super::super::hud::{self, Offer};
        let mut ranks: Ranks = [0; UPGRADES.len()];
        ranks[index("reroll").unwrap()] = 2;
        ranks[index("banish").unwrap()] = 3;
        let mut run = Run {
            rerolls: rerolls(&ranks),
            banishes: banishes(&ranks),
            ..Run::default()
        };
        let mut rng = super::super::Rng::default();
        let mut offer = Offer::default();
        assert!(hud::reroll(&mut run, &mut offer, &mut rng));
        assert_eq!(run.rerolls, 1);
        let i = (0..offer.len())
            .find(|&i| hud::banish_key(offer.choices()[i]).is_some())
            .expect("a new run is offered new spells");
        let key = hud::banish_key(offer.choices()[i]).unwrap();
        assert!(hud::banish(i, &mut run, &mut offer, &mut rng));
        assert_eq!(run.banishes, 2);
        for _ in 0..50 {
            hud::reroll(&mut run, &mut offer, &mut rng);
            run.rerolls = 1;
            assert!(offer.choices().iter().all(|&c| hud::banish_key(c) != Some(key)));
        }
    }
}
