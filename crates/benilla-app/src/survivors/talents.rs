//! Talents: each character's three class trees, after the 1.12 talent frame. A tree holds five
//! of the class's real talents (their names and icons), each reworked to shape the mode's own
//! spells: more damage or area for one spell, a shorter cooldown, an extra target, a stat for
//! every spell, or a spell the run starts with. The deeper rows open once enough points sit in
//! the tree, as the reference's tiers do.
//!
//! Points are earned, not bought: one for each difficulty a character has won in each zone (a
//! zone's `cleared`, [`super::profile::ZoneRecord`]), so Normal everywhere is one a zone and a
//! Mythic keystone keeps adding. Spending is free; taking them all back costs coin.
//!
//! The ranks are the character's ([`super::profile::Character::talents`]); a run copies them
//! when it begins ([`Run::talents`]), its stats add the stat talents ([`apply`]) and each spell
//! it owns carries its talents' [`Bonus`].

use bevy::prelude::*;

use super::data::{self, Stat};
use super::hud::{
    centered_bundle, icon_bundle, text_bundle, HudFont, MenuRoot, DIM_GREY, GOLD_TONE,
};
use super::menu::{DeleteOpen, MenuBuilt, MenuStep};
use super::profile::Profile;
use super::{Phase, Run, Stats};
use crate::glue::art::GlueArt;
use crate::glue::widgets::{glue_button, GlueBtnKind};
use crate::glue::GlueClicks;

/// Talents in a tree, and trees in a class.
pub(super) const PER_TREE: usize = 5;
pub(super) const TREES: usize = 3;
pub(super) const SLOTS: usize = PER_TREE * TREES;
/// The row each talent of a tree sits on.
const TIER: [u8; PER_TREE] = [0, 0, 1, 1, 2];
/// Points in a tree each row down asks for.
const PER_TIER: u32 = 3;
/// Copper to take every point back.
pub(super) const RESET_COST: u64 = 5_000;

/// A character's ranks, indexed tree by tree.
pub(super) type Picked = [u8; SLOTS];

/// What a talent does with each rank. The spells are [`data::ABILITIES`] keys.
#[derive(Clone, Copy, Debug)]
pub(super) enum Fx {
    /// More damage (and healing, and shielding) for one spell.
    Dmg(&'static str, f32),
    /// A shorter cooldown for one spell.
    Cd(&'static str, f32),
    /// A wider area for one spell.
    Area(&'static str, f32),
    /// One more target a rank for one spell.
    Targets(&'static str),
    Stat(Stat, f32),
    /// The run starts with this spell.
    Opener(&'static str),
}

pub(super) struct TalentDef {
    /// The 1.12 talent's first rank spell, for its icon.
    pub spell: u32,
    pub name: &'static str,
    pub ranks: u8,
    pub fx: Fx,
}

pub(super) struct Tree {
    pub name: &'static str,
    pub talents: [TalentDef; PER_TREE],
}

const fn t(spell: u32, name: &'static str, ranks: u8, fx: Fx) -> TalentDef {
    TalentDef {
        spell,
        name,
        ranks,
        fx,
    }
}

use Fx::{Area, Cd, Dmg, Opener, Stat as S, Targets};

const WARRIOR: [Tree; TREES] = [
    Tree {
        name: "Arms",
        talents: [
            t(
                12282,
                "Improved Heroic Strike",
                3,
                Dmg("heroic_strike", 0.15),
            ),
            t(
                12163,
                "Two-Handed Weapon Specialization",
                3,
                S(Stat::Might, 0.03),
            ),
            t(12287, "Improved Thunder Clap", 3, Area("thunder_clap", 0.1)),
            t(12834, "Deep Wounds", 3, Dmg("mortal_strike", 0.15)),
            t(12292, "Sweeping Strikes", 1, Opener("sweeping_strikes")),
        ],
    },
    Tree {
        name: "Fury",
        talents: [
            t(12320, "Cruelty", 3, S(Stat::Crit, 0.02)),
            t(12329, "Improved Cleave", 3, Dmg("cleave", 0.15)),
            t(
                12324,
                "Improved Demoralizing Shout",
                3,
                Area("demoralizing_shout", 0.1),
            ),
            t(20502, "Improved Execute", 3, Cd("execute", 0.08)),
            t(12328, "Death Wish", 1, S(Stat::Might, 0.1)),
        ],
    },
    Tree {
        name: "Protection",
        talents: [
            t(12299, "Toughness", 3, S(Stat::Armor, 1.0)),
            t(12298, "Shield Specialization", 3, S(Stat::MaxHp, 0.05)),
            t(12945, "Improved Shield Block", 3, S(Stat::Regen, 0.3)),
            t(12797, "Improved Revenge", 3, Cd("retaliation", 0.08)),
            t(12975, "Last Stand", 1, S(Stat::MaxHp, 0.1)),
        ],
    },
];

const PALADIN: [Tree; TREES] = [
    Tree {
        name: "Holy",
        talents: [
            t(20262, "Divine Strength", 3, S(Stat::Might, 0.03)),
            t(20237, "Healing Light", 3, S(Stat::Regen, 0.3)),
            t(26573, "Consecration", 3, Area("consecration", 0.1)),
            t(5923, "Holy Power", 3, S(Stat::Crit, 0.02)),
            t(20473, "Holy Shock", 1, Opener("holy_shock")),
        ],
    },
    Tree {
        name: "Protection",
        talents: [
            t(20143, "Toughness", 3, S(Stat::Armor, 1.0)),
            t(20127, "Redoubt", 3, S(Stat::MaxHp, 0.05)),
            t(
                20487,
                "Improved Hammer of Justice",
                3,
                Cd("hammer_of_justice", 0.08),
            ),
            t(20174, "Guardian's Favor", 3, Cd("divine_shield", 0.08)),
            t(20925, "Holy Shield", 1, S(Stat::MaxHp, 0.1)),
        ],
    },
    Tree {
        name: "Retribution",
        talents: [
            t(25956, "Improved Judgement", 3, Cd("judgement", 0.08)),
            t(20117, "Conviction", 3, S(Stat::Crit, 0.02)),
            t(9452, "Vindication", 3, Dmg("exorcism", 0.15)),
            t(20049, "Vengeance", 3, Dmg("hammer_of_wrath", 0.15)),
            t(20218, "Sanctity Aura", 1, S(Stat::Might, 0.1)),
        ],
    },
];

const HUNTER: [Tree; TREES] = [
    Tree {
        name: "Beast Mastery",
        talents: [
            t(19583, "Endurance Training", 3, S(Stat::MaxHp, 0.05)),
            t(
                19552,
                "Improved Aspect of the Hawk",
                3,
                S(Stat::Haste, 0.03),
            ),
            t(19559, "Pathfinding", 3, S(Stat::Speed, 0.04)),
            t(19598, "Ferocity", 3, S(Stat::Crit, 0.02)),
            t(19574, "Bestial Wrath", 1, S(Stat::Might, 0.1)),
        ],
    },
    Tree {
        name: "Marksmanship",
        talents: [
            t(19454, "Improved Arcane Shot", 3, Cd("arcane_shot", 0.08)),
            t(
                19407,
                "Improved Concussive Shot",
                3,
                Dmg("concussive_shot", 0.15),
            ),
            t(
                19464,
                "Improved Serpent Sting",
                3,
                Dmg("serpent_sting", 0.15),
            ),
            t(19461, "Barrage", 3, Dmg("multi_shot", 0.15)),
            t(19434, "Aimed Shot", 1, Opener("aimed_shot")),
        ],
    },
    Tree {
        name: "Survival",
        talents: [
            t(19239, "Clever Traps", 3, Area("explosive_trap", 0.1)),
            t(19255, "Survivalist", 3, S(Stat::MaxHp, 0.05)),
            t(19376, "Trap Mastery", 3, Cd("explosive_trap", 0.08)),
            t(19370, "Killer Instinct", 3, S(Stat::Crit, 0.02)),
            t(19168, "Lightning Reflexes", 1, S(Stat::Haste, 0.1)),
        ],
    },
];

const ROGUE: [Tree; TREES] = [
    Tree {
        name: "Assassination",
        talents: [
            t(14162, "Improved Eviscerate", 3, Dmg("eviscerate", 0.15)),
            t(14138, "Malice", 3, S(Stat::Crit, 0.02)),
            t(14174, "Improved Kidney Shot", 3, Cd("kidney_shot", 0.08)),
            t(14128, "Lethality", 3, S(Stat::Might, 0.03)),
            t(14177, "Cold Blood", 1, S(Stat::Crit, 0.08)),
        ],
    },
    Tree {
        name: "Combat",
        talents: [
            t(
                13732,
                "Improved Sinister Strike",
                3,
                Cd("sinister_strike", 0.08),
            ),
            t(13741, "Improved Gouge", 3, Dmg("gouge", 0.15)),
            t(
                13715,
                "Dual Wield Specialization",
                3,
                Dmg("sinister_strike", 0.15),
            ),
            t(13705, "Precision", 3, S(Stat::Might, 0.03)),
            t(13877, "Blade Flurry", 1, Opener("blade_flurry")),
        ],
    },
    Tree {
        name: "Subtlety",
        talents: [
            t(13975, "Camouflage", 3, S(Stat::Speed, 0.04)),
            t(13981, "Elusiveness", 3, S(Stat::Armor, 1.0)),
            t(14171, "Serrated Blades", 3, Dmg("rupture", 0.15)),
            t(13983, "Setup", 3, S(Stat::Regen, 0.3)),
            t(14185, "Preparation", 1, S(Stat::Haste, 0.1)),
        ],
    },
];

const PRIEST: [Tree; TREES] = [
    Tree {
        name: "Discipline",
        talents: [
            t(
                14748,
                "Improved Power Word: Shield",
                3,
                Dmg("power_word_shield", 0.15),
            ),
            t(14522, "Unbreakable Will", 3, S(Stat::Armor, 1.0)),
            t(14521, "Meditation", 3, S(Stat::Regen, 0.3)),
            t(14520, "Mental Agility", 3, S(Stat::Haste, 0.03)),
            t(10060, "Power Infusion", 1, S(Stat::Haste, 0.1)),
        ],
    },
    Tree {
        name: "Holy",
        talents: [
            t(14889, "Holy Specialization", 3, S(Stat::Crit, 0.02)),
            t(18530, "Divine Fury", 3, Cd("smite", 0.08)),
            t(14909, "Searing Light", 3, Dmg("holy_fire", 0.15)),
            t(27789, "Holy Reach", 3, Area("holy_nova", 0.1)),
            t(15237, "Holy Nova", 1, Opener("holy_nova")),
        ],
    },
    Tree {
        name: "Shadow",
        talents: [
            t(
                15275,
                "Improved Shadow Word: Pain",
                3,
                Dmg("shadow_word_pain", 0.15),
            ),
            t(15273, "Improved Mind Blast", 3, Cd("mind_blast", 0.08)),
            t(
                15392,
                "Improved Psychic Scream",
                3,
                Cd("psychic_scream", 0.08),
            ),
            t(15259, "Darkness", 3, S(Stat::Might, 0.03)),
            t(15473, "Shadowform", 1, S(Stat::Might, 0.1)),
        ],
    },
];

const SHAMAN: [Tree; TREES] = [
    Tree {
        name: "Elemental",
        talents: [
            t(16035, "Concussion", 3, Dmg("lightning_bolt", 0.15)),
            t(16039, "Convection", 3, Cd("earth_shock", 0.08)),
            t(16038, "Call of Flame", 3, Dmg("magma_totem", 0.15)),
            t(16041, "Call of Thunder", 3, S(Stat::Crit, 0.02)),
            t(16089, "Elemental Fury", 1, Targets("chain_lightning")),
        ],
    },
    Tree {
        name: "Enhancement",
        talents: [
            t(
                16261,
                "Improved Lightning Shield",
                3,
                Dmg("lightning_shield", 0.15),
            ),
            t(16252, "Toughness", 3, S(Stat::Armor, 1.0)),
            t(16255, "Thundering Strikes", 3, S(Stat::Crit, 0.02)),
            t(16256, "Flurry", 3, S(Stat::Haste, 0.03)),
            t(17364, "Stormstrike", 1, S(Stat::Might, 0.1)),
        ],
    },
    Tree {
        name: "Restoration",
        talents: [
            t(16179, "Tidal Focus", 3, S(Stat::Regen, 0.3)),
            t(16173, "Totemic Focus", 3, Cd("searing_totem", 0.08)),
            t(16187, "Restorative Totems", 3, Area("magma_totem", 0.1)),
            t(16181, "Healing Focus", 3, S(Stat::MaxHp, 0.05)),
            t(16188, "Nature's Swiftness", 1, S(Stat::Haste, 0.1)),
        ],
    },
];

const MAGE: [Tree; TREES] = [
    Tree {
        name: "Arcane",
        talents: [
            t(
                11237,
                "Improved Arcane Missiles",
                3,
                Dmg("arcane_missiles", 0.15),
            ),
            t(11222, "Arcane Focus", 3, S(Stat::Crit, 0.02)),
            t(
                11242,
                "Improved Arcane Explosion",
                3,
                Area("arcane_explosion", 0.1),
            ),
            t(11232, "Arcane Mind", 3, S(Stat::Might, 0.03)),
            t(12042, "Arcane Power", 1, S(Stat::Might, 0.1)),
        ],
    },
    Tree {
        name: "Fire",
        talents: [
            t(11069, "Improved Fireball", 3, Cd("fireball", 0.08)),
            t(11103, "Impact", 3, Dmg("fire_blast", 0.15)),
            t(11108, "Improved Flamestrike", 3, Area("flamestrike", 0.1)),
            t(11115, "Critical Mass", 3, S(Stat::Crit, 0.02)),
            t(11366, "Pyroblast", 1, Opener("pyroblast")),
        ],
    },
    Tree {
        name: "Frost",
        talents: [
            t(11070, "Improved Frostbolt", 3, Cd("frostbolt", 0.08)),
            t(11207, "Ice Shards", 3, Dmg("frostbolt", 0.15)),
            t(11185, "Improved Blizzard", 3, Area("blizzard", 0.1)),
            t(11190, "Improved Cone of Cold", 3, Dmg("cone_of_cold", 0.15)),
            t(11426, "Ice Barrier", 1, S(Stat::MaxHp, 0.1)),
        ],
    },
];

const WARLOCK: [Tree; TREES] = [
    Tree {
        name: "Affliction",
        talents: [
            t(17810, "Improved Corruption", 3, Dmg("corruption", 0.15)),
            t(
                18827,
                "Improved Curse of Agony",
                3,
                Dmg("curse_of_agony", 0.15),
            ),
            t(17783, "Fel Concentration", 3, S(Stat::Haste, 0.03)),
            t(18271, "Shadow Mastery", 3, S(Stat::Might, 0.03)),
            t(18265, "Siphon Life", 1, S(Stat::Regen, 1.0)),
        ],
    },
    Tree {
        name: "Demonology",
        talents: [
            t(18697, "Demonic Embrace", 3, S(Stat::MaxHp, 0.05)),
            t(18748, "Fel Stamina", 3, S(Stat::Armor, 1.0)),
            t(18692, "Improved Healthstone", 3, S(Stat::Regen, 0.3)),
            t(18769, "Unholy Power", 3, Dmg("hellfire", 0.15)),
            t(19028, "Soul Link", 1, S(Stat::MaxHp, 0.1)),
        ],
    },
    Tree {
        name: "Destruction",
        talents: [
            t(17793, "Improved Shadow Bolt", 3, Dmg("shadow_bolt", 0.15)),
            t(17788, "Bane", 3, Cd("shadow_bolt", 0.08)),
            t(18130, "Devastation", 3, S(Stat::Crit, 0.02)),
            t(17815, "Improved Immolate", 3, Dmg("immolate", 0.15)),
            t(17877, "Shadowburn", 1, Opener("shadowburn")),
        ],
    },
];

const DRUID: [Tree; TREES] = [
    Tree {
        name: "Balance",
        talents: [
            t(16814, "Improved Wrath", 3, Cd("wrath", 0.08)),
            t(16821, "Improved Moonfire", 3, Dmg("moonfire", 0.15)),
            t(16850, "Improved Starfire", 3, Dmg("starfire", 0.15)),
            t(16909, "Vengeance", 3, S(Stat::Crit, 0.02)),
            t(24858, "Moonkin Form", 1, S(Stat::Might, 0.1)),
        ],
    },
    Tree {
        name: "Feral Combat",
        talents: [
            t(16934, "Ferocity", 3, S(Stat::Might, 0.03)),
            t(16929, "Thick Hide", 3, S(Stat::Armor, 1.0)),
            t(17002, "Feline Swiftness", 3, S(Stat::Speed, 0.04)),
            t(16836, "Improved Thorns", 3, Dmg("thorns", 0.15)),
            t(17003, "Heart of the Wild", 1, S(Stat::MaxHp, 0.1)),
        ],
    },
    Tree {
        name: "Restoration",
        talents: [
            t(17111, "Improved Rejuvenation", 3, Dmg("rejuvenation", 0.15)),
            t(17063, "Nature's Focus", 3, S(Stat::Regen, 0.3)),
            t(
                16918,
                "Improved Entangling Roots",
                3,
                Cd("entangling_roots", 0.08),
            ),
            t(17104, "Gift of Nature", 3, S(Stat::MaxHp, 0.05)),
            t(5570, "Insect Swarm", 1, Opener("insect_swarm")),
        ],
    },
];

/// A class's trees, by its id.
pub(super) fn trees(class: u8) -> &'static [Tree; TREES] {
    match class {
        2 => &PALADIN,
        3 => &HUNTER,
        4 => &ROGUE,
        5 => &PRIEST,
        7 => &SHAMAN,
        8 => &MAGE,
        9 => &WARLOCK,
        11 => &DRUID,
        _ => &WARRIOR,
    }
}

/// A slot's talent.
pub(super) fn talent(class: u8, slot: usize) -> &'static TalentDef {
    &trees(class)[slot / PER_TREE].talents[slot % PER_TREE]
}

/// Every talent of a class with its slot and rank.
fn picked(class: u8, ranks: &Picked) -> impl Iterator<Item = (&'static TalentDef, u8)> + '_ {
    (0..SLOTS)
        .map(move |i| (talent(class, i), ranks[i]))
        .filter(|&(_, r)| r > 0)
}

/// Points spent in one tree.
pub(super) fn in_tree(ranks: &Picked, tree: usize) -> u32 {
    ranks[tree * PER_TREE..(tree + 1) * PER_TREE]
        .iter()
        .map(|&r| u32::from(r))
        .sum()
}

pub(super) fn spent(ranks: &Picked) -> u32 {
    ranks.iter().map(|&r| u32::from(r)).sum()
}

/// Points a slot's row asks for in its tree.
pub(super) fn needs(slot: usize) -> u32 {
    u32::from(TIER[slot % PER_TREE]) * PER_TIER
}

/// Whether one more rank can go into `slot`, with `points` earned.
pub(super) fn can_learn(class: u8, ranks: &Picked, points: u32, slot: usize) -> bool {
    slot < SLOTS
        && spent(ranks) < points
        && ranks[slot] < talent(class, slot).ranks
        && in_tree(ranks, slot / PER_TREE) >= needs(slot)
}

/// What a spell's talents add to it.
#[derive(Clone, Copy, Default, PartialEq, Debug)]
pub(crate) struct Bonus {
    /// Fractions: more damage, less cooldown, more area.
    pub dmg: f32,
    pub cd: f32,
    pub area: f32,
    pub count: u32,
}

pub(super) fn bonus(class: u8, ranks: &Picked, key: &str) -> Bonus {
    let mut b = Bonus::default();
    for (t, r) in picked(class, ranks) {
        let r = f32::from(r);
        match t.fx {
            Fx::Dmg(k, v) if k == key => b.dmg += v * r,
            Fx::Cd(k, v) if k == key => b.cd += v * r,
            Fx::Area(k, v) if k == key => b.area += v * r,
            Fx::Targets(k) if k == key => b.count += r as u32,
            _ => {}
        }
    }
    b
}

/// What the stat talents add to the hero's stats.
pub(super) fn apply(class: u8, ranks: &Picked, s: &mut Stats) {
    for (t, r) in picked(class, ranks) {
        if let Fx::Stat(stat, v) = t.fx {
            super::bag::add_stat(s, stat, v * f32::from(r));
        }
    }
}

/// The spells the run starts with besides the class's first.
pub(super) fn openers(class: u8, ranks: &Picked) -> Vec<&'static str> {
    picked(class, ranks)
        .filter_map(|(t, _)| match t.fx {
            Fx::Opener(k) => Some(k),
            _ => None,
        })
        .collect()
}

impl Run {
    /// A spell the hero takes up, with what its talents add.
    pub(super) fn own(&self, def: &'static data::AbilityDef, cd: f32) -> super::Owned {
        super::Owned {
            def,
            level: 1,
            cd,
            bonus: bonus(self.class.id, &self.talents, def.key),
        }
    }

    /// The talents' spells at the start of a run.
    pub(super) fn take_openers(&mut self) {
        for key in openers(self.class.id, &self.talents) {
            if !self.abilities.iter().any(|o| o.def.key == key) {
                let o = self.own(data::ability(key), 1.0);
                self.abilities.push(o);
            }
        }
    }
}

/// What `rank` ranks of a talent do, as the dialog lists it.
fn effect(fx: Fx, rank: u8, spells: Option<&crate::ui_action::Spells>) -> String {
    let r = f32::from(rank.max(1));
    let name = |key: &str| {
        let def = data::ability(key);
        spells
            .and_then(|s| s.catalog.get(def.spell))
            .map(|d| d.name.clone())
            .unwrap_or_else(|| key.replace('_', " "))
    };
    match fx {
        Fx::Dmg(k, v) => format!("+{:.0}% {} power", v * r * 100.0, name(k)),
        Fx::Cd(k, v) => format!("-{:.0}% {} cooldown", v * r * 100.0, name(k)),
        Fx::Area(k, v) => format!("+{:.0}% {} area", v * r * 100.0, name(k)),
        Fx::Targets(k) => format!(
            "+{} {} target{}",
            r,
            name(k),
            if r > 1.0 { "s" } else { "" }
        ),
        Fx::Stat(stat, v) => super::bag::stat_line(stat, v * r),
        Fx::Opener(k) => format!("Begin each run with {}", name(k)),
    }
}

impl Profile {
    /// The picked character's talent points: one for each difficulty won in each zone.
    pub(super) fn talent_points(&self) -> u32 {
        self.hero()
            .map_or(0, |c| c.zones.iter().map(|z| u32::from(z.cleared)).sum())
    }

    /// One more rank in `slot` for the picked character; false when it cannot go there.
    pub(super) fn learn(&mut self, slot: usize) -> bool {
        let points = self.talent_points();
        let Some(c) = self.hero_mut() else {
            return false;
        };
        let class = data::CLASSES[c.class].id;
        if !can_learn(class, &c.talents, points, slot) {
            return false;
        }
        c.talents[slot] += 1;
        self.save();
        true
    }

    /// Every point back, for [`RESET_COST`]; false when none are spent or the purse is short.
    pub(super) fn reset_talents(&mut self) -> bool {
        if self.copper < RESET_COST {
            return false;
        }
        let Some(c) = self.hero_mut().filter(|c| spent(&c.talents) > 0) else {
            return false;
        };
        c.talents = [0; SLOTS];
        self.copper -= RESET_COST;
        self.save();
        true
    }
}

#[derive(Component, Clone, Copy, PartialEq, Eq)]
pub(super) enum TalentAction {
    Open,
    Close,
    Reset,
}

/// Whether the talents dialog is up.
#[derive(Resource, Default)]
pub(super) struct TalentsOpen(pub(super) bool);

#[derive(Component)]
pub(super) struct TalentsBuilt;
#[derive(Component)]
pub(super) struct TalentsOverlay;
/// The Talents button beside the Merchant's, shown on character select only.
#[derive(Component)]
pub(super) struct TalentsCorner;
/// The trees, rebuilt for each class.
#[derive(Component)]
struct TalentsBody;
#[derive(Component)]
struct PointsText;
#[derive(Component)]
struct ResetText;
/// A talent's cell: a click learns its next rank.
#[derive(Component)]
struct Cell(usize);
#[derive(Component)]
struct CellName(usize);
#[derive(Component)]
struct CellRank(usize);
#[derive(Component)]
struct CellEffect(usize);
#[derive(Component)]
struct TreePoints(usize);

const DIALOG_W: f32 = 900.0;
const TREE_W: f32 = 272.0;
const CELL_H: f32 = 58.0;
const GREEN: Color = Color::srgb(0.12, 1.0, 0.0);

pub(super) fn plugin(app: &mut App) {
    app.init_resource::<TalentsOpen>()
        .add_systems(
            Update,
            (build_talents, fill_trees, talents)
                .chain()
                .after(super::menu::build_menu)
                .after(super::menu::menu_clicks)
                .before(crate::glue::GlueVisuals),
        )
        .add_systems(
            Update,
            auto_dialog
                .before(super::auto::drive)
                .run_if(resource_exists::<super::auto::Auto>),
        );
}

/// `<class>:talents`: once the pick screen is up, open the dialog, shoot it and close it, the
/// run held back meanwhile.
fn auto_dialog(
    mut commands: Commands,
    time: Res<Time<Real>>,
    phase: Res<State<Phase>>,
    mut auto: ResMut<super::auto::Auto>,
    mut open: ResMut<TalentsOpen>,
    mut t: Local<f32>,
) {
    let ready = auto.seen.iter().any(|s| s == "menu");
    if !auto.talents || *phase.get() != Phase::Menu || !ready || *t > 3.0 {
        return;
    }
    *t += time.delta_secs();
    auto.wait = 0.0;
    open.0 = *t > 1.0;
    // The shot is of the next frame drawn: the dialog stays up a moment after.
    if *t > 2.5 {
        auto.capture_once(&mut commands, "talents".into());
    }
    if *t > 3.0 {
        open.0 = false;
    }
}

/// The Talents button and the dialog, hidden until opened; the trees come in [`fill_trees`].
#[allow(clippy::type_complexity)]
fn build_talents(
    mut commands: Commands,
    roots: Query<Entity, (With<MenuRoot>, With<MenuBuilt>, Without<TalentsBuilt>)>,
    art: Res<GlueArt>,
    font: Res<HudFont>,
) {
    let Ok(root) = roots.single() else { return };
    let f = &font.0;
    let art = &*art;
    commands.entity(root).insert(TalentsBuilt).with_children(|ui| {
        ui.spawn((
            TalentsCorner,
            Node {
                position_type: PositionType::Absolute,
                left: Val::Px(236.0),
                bottom: Val::Px(96.0),
                ..default()
            },
        ))
        .with_children(|c| {
            glue_button(
                c,
                art,
                f,
                TalentAction::Open,
                "Talents",
                200.0,
                60.0,
                GlueBtnKind::Normal,
                1.0,
            );
        });
        ui.spawn((
            TalentsOverlay,
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
            let title = centered_bundle(f, "Talents", 14.0, GOLD_TONE);
            super::panels::dialog(o, art, DIALOG_W, (), title, |b| {
                b.spawn((PointsText, centered_bundle(f, "", 15.0, Color::WHITE)));
                b.spawn(Node {
                    max_width: Val::Px(DIALOG_W - 60.0),
                    ..default()
                })
                .with_children(|n| {
                    n.spawn(centered_bundle(
                        f,
                        "Each difficulty this character wins in a zone earns a point. Click a talent to learn its next rank; deeper rows open with points in their tree.",
                        12.0,
                        DIM_GREY,
                    ));
                });
                b.spawn((
                    TalentsBody,
                    Node {
                        column_gap: Val::Px(14.0),
                        ..default()
                    },
                ));
                b.spawn(Node {
                    column_gap: Val::Px(16.0),
                    align_items: AlignItems::Center,
                    ..default()
                })
                .with_children(|row| {
                    glue_button(
                        row,
                        art,
                        f,
                        TalentAction::Reset,
                        "Reset Talents",
                        180.0,
                        34.0,
                        GlueBtnKind::Small,
                        1.0,
                    );
                    row.spawn((ResetText, text_bundle(f, "", 12.0, DIM_GREY)));
                    glue_button(
                        row,
                        art,
                        f,
                        TalentAction::Close,
                        "Done",
                        180.0,
                        34.0,
                        GlueBtnKind::Small,
                        1.0,
                    );
                });
            });
        });
    });
}

/// The picked character's class's trees into the dialog, again whenever the class changes.
fn fill_trees(
    mut commands: Commands,
    profile: Res<Profile>,
    bodies: Query<Entity, With<TalentsBody>>,
    font: Res<HudFont>,
    mut shown: Local<Option<u8>>,
) {
    let Ok(body) = bodies.single() else { return };
    let class = profile.hero().map_or(0, |c| data::CLASSES[c.class].id);
    if *shown == Some(class) {
        return;
    }
    *shown = Some(class);
    let f = &font.0;
    commands.entity(body).despawn_related::<Children>();
    commands.entity(body).with_children(|b| {
        for (i, tree) in trees(class).iter().enumerate() {
            b.spawn(Node {
                width: Val::Px(TREE_W),
                flex_direction: FlexDirection::Column,
                row_gap: Val::Px(6.0),
                ..default()
            })
            .with_children(|col| {
                col.spawn(Node {
                    justify_content: JustifyContent::SpaceBetween,
                    align_items: AlignItems::Baseline,
                    margin: UiRect::bottom(Val::Px(2.0)),
                    ..default()
                })
                .with_children(|row| {
                    row.spawn(text_bundle(f, tree.name, 16.0, GOLD_TONE));
                    row.spawn((TreePoints(i), text_bundle(f, "", 12.0, DIM_GREY)));
                });
                for k in 0..PER_TREE {
                    cell(col, f, i * PER_TREE + k, &tree.talents[k]);
                }
            });
        }
    });
}

/// One talent: the icon, the name and rank, and what its ranks do or what opens it.
fn cell(col: &mut ChildSpawnerCommands, f: &Handle<Font>, slot: usize, t: &TalentDef) {
    col.spawn((
        Cell(slot),
        Button,
        Interaction::default(),
        Node {
            width: Val::Px(TREE_W),
            height: Val::Px(CELL_H),
            padding: UiRect::all(Val::Px(6.0)),
            column_gap: Val::Px(8.0),
            align_items: AlignItems::Center,
            border: UiRect::all(Val::Px(1.0)),
            margin: UiRect::top(Val::Px(if slot % PER_TREE == 2 || slot % PER_TREE == 4 {
                8.0
            } else {
                0.0
            })),
            ..default()
        },
        BackgroundColor(Color::srgba(0.0, 0.0, 0.0, 0.45)),
        BorderColor::all(Color::srgba(0.5, 0.5, 0.5, 0.5)),
    ))
    .with_children(|w| {
        w.spawn((icon_bundle(t.spell, 38.0), bevy::ui::FocusPolicy::Pass));
        w.spawn((
            Node {
                flex_direction: FlexDirection::Column,
                flex_grow: 1.0,
                flex_shrink: 1.0,
                row_gap: Val::Px(2.0),
                ..default()
            },
            bevy::ui::FocusPolicy::Pass,
        ))
        .with_children(|c| {
            c.spawn(Node {
                justify_content: JustifyContent::SpaceBetween,
                column_gap: Val::Px(6.0),
                ..default()
            })
            .with_children(|row| {
                row.spawn((CellName(slot), text_bundle(f, t.name, 12.0, GOLD_TONE)));
                row.spawn((CellRank(slot), text_bundle(f, "", 12.0, DIM_GREY)));
            });
            c.spawn((CellEffect(slot), text_bundle(f, "", 11.0, Color::WHITE)));
        });
    });
}

/// Open and close the dialog, learn what is clicked, reset, and keep every line current.
#[allow(clippy::too_many_arguments, clippy::type_complexity)]
fn talents(
    clicks: Res<GlueClicks>,
    keys: Res<ButtonInput<KeyCode>>,
    phase: Res<State<Phase>>,
    step: Res<MenuStep>,
    delete: Res<DeleteOpen>,
    mut open: ResMut<TalentsOpen>,
    mut profile: ResMut<Profile>,
    mut run: ResMut<Run>,
    spells: Option<Res<crate::ui_action::Spells>>,
    actions: Query<(Entity, &TalentAction)>,
    mut cells: Query<(Entity, &Cell, &Interaction, &mut BorderColor)>,
    mut nodes: ParamSet<(
        Query<&mut Node, With<TalentsOverlay>>,
        Query<&mut Node, With<TalentsCorner>>,
    )>,
    mut texts: ParamSet<(
        Query<&mut Text, With<PointsText>>,
        Query<&mut Text, With<ResetText>>,
        Query<(&TreePoints, &mut Text)>,
        Query<(&CellName, &mut TextColor)>,
        Query<(&CellRank, &mut Text, &mut TextColor)>,
        Query<(&CellEffect, &mut Text, &mut TextColor)>,
    )>,
    mut sounds: MessageWriter<crate::sound::GlueSound>,
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
        return;
    }
    let was = open.0;
    for (e, a) in &actions {
        if !clicks.hit(e) {
            continue;
        }
        match a {
            TalentAction::Open => open.0 = true,
            TalentAction::Close => open.0 = false,
            TalentAction::Reset => {
                if profile.reset_talents() {
                    sounds.write(crate::sound::GlueSound("LOOTWINDOWCOINSOUND"));
                }
            }
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
    for mut node in &mut nodes.p0() {
        let want = if open.0 { Display::Flex } else { Display::None };
        if node.display != want {
            node.display = want;
        }
    }
    if open.0 {
        for (e, &Cell(slot), _, _) in &cells {
            if clicks.hit(e) && profile.learn(slot) {
                sounds.write(crate::sound::GlueSound("igAbilityIconPickup"));
            }
        }
    }

    let class = profile.hero().map_or(0, |c| data::CLASSES[c.class].id);
    let ranks = profile.hero().map_or([0; SLOTS], |c| c.talents);
    let points = profile.talent_points();
    // The run about to begin takes what is learned.
    if run.talents != ranks {
        run.talents = ranks;
    }
    if !open.0 {
        return;
    }
    let left = points.saturating_sub(spent(&ranks));
    let set = |t: &mut Text, want: String| {
        if t.0 != want {
            t.0 = want;
        }
    };
    let paint = |c: &mut TextColor, want: Color| {
        if c.0 != want {
            c.0 = want;
        }
    };
    for mut t in &mut texts.p0() {
        set(
            &mut t,
            format!(
                "{left} talent point{} to spend   ·   {points} earned",
                if left == 1 { "" } else { "s" }
            ),
        );
    }
    for mut t in &mut texts.p1() {
        set(&mut t, format!("costs {}", super::bag::money(RESET_COST)));
    }
    for (tp, mut t) in &mut texts.p2() {
        let n = in_tree(&ranks, tp.0);
        set(
            &mut t,
            format!("{n} point{}", if n == 1 { "" } else { "s" }),
        );
    }
    let open_row = |slot: usize| in_tree(&ranks, slot / PER_TREE) >= needs(slot);
    for (n, mut c) in &mut texts.p3() {
        let want = if open_row(n.0) { GOLD_TONE } else { DIM_GREY };
        paint(&mut c, want);
    }
    for (n, mut t, mut c) in &mut texts.p4() {
        let max = talent(class, n.0).ranks;
        let r = ranks[n.0];
        set(&mut t, format!("{r}/{max}"));
        paint(
            &mut c,
            if r >= max {
                GREEN
            } else if r > 0 {
                Color::WHITE
            } else {
                DIM_GREY
            },
        );
    }
    let spells = spells.as_deref();
    for (n, mut t, mut c) in &mut texts.p5() {
        let tal = talent(class, n.0);
        let r = ranks[n.0];
        let (want, color) = if !open_row(n.0) {
            let tree = trees(class)[n.0 / PER_TREE].name;
            (format!("Needs {} points in {tree}", needs(n.0)), DIM_GREY)
        } else if r == 0 {
            (effect(tal.fx, 1, spells), DIM_GREY)
        } else {
            (effect(tal.fx, r, spells), Color::WHITE)
        };
        set(&mut t, want);
        paint(&mut c, color);
    }
    // The cell under the cursor or the pad's focus lights up when it can take a point.
    for (_, &Cell(slot), interaction, mut border) in &mut cells {
        let c = if *interaction == Interaction::None {
            Color::srgba(0.5, 0.5, 0.5, 0.5)
        } else if can_learn(class, &ranks, points, slot) {
            GOLD_TONE
        } else {
            Color::srgba(0.7, 0.7, 0.7, 0.7)
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
    fn every_talent_shapes_its_own_class() {
        for class in data::CLASSES {
            for tree in trees(class.id) {
                for (k, t) in tree.talents.iter().enumerate() {
                    assert!(t.ranks >= 1, "{}", t.name);
                    assert_eq!(
                        t.ranks == 1,
                        TIER[k] == 2,
                        "{}: the last row is one rank",
                        t.name
                    );
                    let key = match t.fx {
                        Fx::Dmg(k, _) | Fx::Cd(k, _) | Fx::Area(k, _) | Fx::Targets(k) => k,
                        Fx::Opener(k) => {
                            assert_ne!(k, class.start, "{} starts with it already", class.name);
                            k
                        }
                        Fx::Stat(..) => continue,
                    };
                    assert!(
                        class.pool.contains(&key),
                        "{}: {key} is not a {} spell",
                        t.name,
                        class.name
                    );
                }
            }
        }
    }

    #[test]
    fn rows_open_with_points_in_their_tree() {
        let class = 8;
        let mut ranks: Picked = [0; SLOTS];
        assert!(can_learn(class, &ranks, 10, 0));
        assert!(
            !can_learn(class, &ranks, 10, 2),
            "the second row needs three points"
        );
        assert!(!can_learn(class, &ranks, 0, 0), "no points earned");
        ranks[0] = 3;
        assert!(
            !can_learn(class, &ranks, 10, 0),
            "a full talent takes no more"
        );
        assert!(can_learn(class, &ranks, 10, 2));
        assert!(
            !can_learn(class, &ranks, 10, PER_TREE + 2),
            "points in another tree don't count"
        );
        assert!(
            !can_learn(class, &ranks, 3, 2),
            "every point earned is spent"
        );
        ranks[2] = 3;
        assert!(can_learn(class, &ranks, 10, 4));
    }

    #[test]
    fn talents_reach_spells_stats_and_the_start() {
        let class = 8;
        let mut ranks: Picked = [0; SLOTS];
        // Fire: Improved Fireball 2, Pyroblast; Arcane: Arcane Mind 1.
        ranks[PER_TREE] = 2;
        ranks[PER_TREE + 4] = 1;
        ranks[3] = 1;
        let b = bonus(class, &ranks, "fireball");
        assert!((b.cd - 0.16).abs() < 1e-6);
        assert_eq!(bonus(class, &ranks, "frostbolt"), Bonus::default());
        assert_eq!(openers(class, &ranks), vec!["pyroblast"]);
        let mut s = Run::default().stats();
        let before = s.might;
        apply(class, &ranks, &mut s);
        assert!((s.might - before - 0.03).abs() < 1e-6);
    }
}
