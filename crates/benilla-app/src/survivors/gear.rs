//! The hero's armor: each class's dungeon and raid sets, found in `ItemDisplayInfo.dbc` by the
//! texture and model names Blizzard gave them (`Plate_RaidWarrior_A_01` is Battlegear of Might),
//! so every piece is a real item's look. Bosses drop the pieces ([`boss_drops`]); the profile keeps
//! them; the hero wears the best one owned for each slot, through item templates made here and
//! cached as if a server had answered them, so the world dresses the body its usual way.

use std::collections::HashMap;

use benilla_formats::ItemDisplay;
use benilla_protocol::messages::ItemInfo;
use bevy::prelude::*;

use super::data::{self, Weapon};

/// The eight armor slots a set covers, in the armory's order.
#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub(crate) enum Slot {
    Head,
    Shoulders,
    Chest,
    Wrists,
    Hands,
    Waist,
    Legs,
    Feet,
}

impl Slot {
    pub(crate) const ALL: [Slot; 8] = [
        Slot::Head,
        Slot::Shoulders,
        Slot::Chest,
        Slot::Wrists,
        Slot::Hands,
        Slot::Waist,
        Slot::Legs,
        Slot::Feet,
    ];

    pub(crate) fn name(self) -> &'static str {
        match self {
            Slot::Head => "Head",
            Slot::Shoulders => "Shoulders",
            Slot::Chest => "Chest",
            Slot::Wrists => "Wrists",
            Slot::Hands => "Hands",
            Slot::Waist => "Waist",
            Slot::Legs => "Legs",
            Slot::Feet => "Feet",
        }
    }

    /// The paper doll's empty-slot art, `UI-PaperDoll-Slot-<name>`.
    pub(crate) fn paper_doll(self) -> &'static str {
        match self {
            Slot::Head => "Head",
            Slot::Shoulders => "Shoulder",
            Slot::Chest => "Chest",
            Slot::Wrists => "Wrists",
            Slot::Hands => "Hands",
            Slot::Waist => "Waist",
            Slot::Legs => "Legs",
            Slot::Feet => "Feet",
        }
    }

    /// The piece's noun in its name, "Helm of Might".
    fn noun(self) -> &'static str {
        match self {
            Slot::Head => "Helm",
            Slot::Shoulders => "Pauldrons",
            Slot::Chest => "Breastplate",
            Slot::Wrists => "Bracers",
            Slot::Hands => "Gauntlets",
            Slot::Waist => "Belt",
            Slot::Legs => "Legplates",
            Slot::Feet => "Boots",
        }
    }

    /// `EQUIPMENT_SLOT_*`, the `PLAYER_VISIBLE_ITEM_*` block it shows in.
    pub(crate) fn equip_slot(self) -> u8 {
        match self {
            Slot::Head => 0,
            Slot::Shoulders => 2,
            Slot::Chest => 4,
            Slot::Waist => 5,
            Slot::Legs => 6,
            Slot::Feet => 7,
            Slot::Wrists => 8,
            Slot::Hands => 9,
        }
    }

    /// `InventoryType`.
    fn inventory_type(self) -> u32 {
        match self {
            Slot::Head => 1,
            Slot::Shoulders => 3,
            Slot::Chest => 5,
            Slot::Waist => 6,
            Slot::Legs => 7,
            Slot::Feet => 8,
            Slot::Wrists => 9,
            Slot::Hands => 10,
        }
    }

    pub(crate) fn index(self) -> usize {
        Slot::ALL.iter().position(|&s| s == self).unwrap_or(0)
    }
}

/// One armor set: its name, the word its pieces are named with, and its art's name stem.
pub(crate) struct SetDef {
    pub name: &'static str,
    word: &'static str,
    stem: &'static str,
}

/// A class's sets, weakest first: the dungeon set where the art names one, then the three raid
/// tiers.
pub(crate) fn sets(class: u8) -> &'static [SetDef] {
    match class {
        1 => &[
            SetDef {
                name: "Battlegear of Valor",
                word: "Valor",
                stem: "Plate_DungeonWarrior_A_01",
            },
            SetDef {
                name: "Battlegear of Might",
                word: "Might",
                stem: "Plate_RaidWarrior_A_01",
            },
            SetDef {
                name: "Battlegear of Wrath",
                word: "Wrath",
                stem: "Plate_RaidWarrior_B_01",
            },
            SetDef {
                name: "Dreadnaught's Battlegear",
                word: "the Dreadnaught",
                stem: "Plate_RaidWarrior_C_01",
            },
        ],
        2 => &[
            SetDef {
                name: "Lightforge Armor",
                word: "the Lightforge",
                stem: "Plate_DungeonPaladin_A_01",
            },
            SetDef {
                name: "Lawbringer Armor",
                word: "the Lawbringer",
                stem: "Plate_RaidPaladin_A_01",
            },
            SetDef {
                name: "Judgement Armor",
                word: "Judgement",
                stem: "Plate_RaidPaladin_B_01",
            },
            SetDef {
                name: "Redemption Armor",
                word: "Redemption",
                stem: "Plate_RaidPaladin_C_01",
            },
        ],
        3 => &[
            SetDef {
                name: "Beaststalker Armor",
                word: "the Beaststalker",
                stem: "Mail_DungeonHunter_A_01",
            },
            SetDef {
                name: "Giantstalker Armor",
                word: "the Giantstalker",
                stem: "Mail_RaidHunter_A_01",
            },
            SetDef {
                name: "Dragonstalker Armor",
                word: "the Dragonstalker",
                stem: "Mail_RaidHunter_B_01",
            },
            SetDef {
                name: "Cryptstalker Armor",
                word: "the Cryptstalker",
                stem: "Mail_RaidHunter_C_01",
            },
        ],
        4 => &[
            SetDef {
                name: "Nightslayer Armor",
                word: "the Nightslayer",
                stem: "Leather_RaidRogue_A_01",
            },
            SetDef {
                name: "Bloodfang Armor",
                word: "Bloodfang",
                stem: "Leather_RaidRogue_B_01",
            },
            SetDef {
                name: "Bonescythe Armor",
                word: "the Bonescythe",
                stem: "Leather_RaidRogue_C_01",
            },
        ],
        5 => &[
            SetDef {
                name: "Vestments of the Devout",
                word: "the Devout",
                stem: "Robe_DungeonPriest_A_01",
            },
            SetDef {
                name: "Vestments of Prophecy",
                word: "Prophecy",
                stem: "Robe_RaidPriest_A_01",
            },
            SetDef {
                name: "Vestments of Transcendence",
                word: "Transcendence",
                stem: "Robe_RaidPriest_B_01",
            },
            SetDef {
                name: "Vestments of Faith",
                word: "Faith",
                stem: "Robe_RaidPriest_C_01",
            },
        ],
        7 => &[
            SetDef {
                name: "The Elements",
                word: "the Elements",
                stem: "Mail_DungeonShaman_A_01",
            },
            SetDef {
                name: "The Earthfury",
                word: "the Earthfury",
                stem: "Mail_RaidShaman_A_01",
            },
            SetDef {
                name: "The Ten Storms",
                word: "the Ten Storms",
                stem: "Mail_RaidShaman_B_01",
            },
            SetDef {
                name: "The Earthshatterer",
                word: "the Earthshatterer",
                stem: "Robe_RaidShaman_C_01",
            },
        ],
        8 => &[
            SetDef {
                name: "Magister's Regalia",
                word: "the Magister",
                stem: "Robe_DungeonMage_A_01",
            },
            SetDef {
                name: "Arcanist Regalia",
                word: "the Arcanist",
                stem: "Robe_RaidMage_A_01",
            },
            SetDef {
                name: "Netherwind Regalia",
                word: "Netherwind",
                stem: "Robe_RaidMage_B_01",
            },
            SetDef {
                name: "Frostfire Regalia",
                word: "Frostfire",
                stem: "Robe_RaidMage_C_01",
            },
        ],
        9 => &[
            SetDef {
                name: "Dreadmist Raiment",
                word: "Dreadmist",
                stem: "Robe_DungeonWarlock_A_01",
            },
            SetDef {
                name: "Felheart Raiment",
                word: "Felheart",
                stem: "Robe_RaidWarlock_A_01",
            },
            SetDef {
                name: "Nemesis Raiment",
                word: "the Nemesis",
                stem: "Robe_RaidWarlock_B_01",
            },
            SetDef {
                name: "Plagueheart Raiment",
                word: "Plagueheart",
                stem: "Robe_RaidWarlock_C_01",
            },
        ],
        11 => &[
            SetDef {
                name: "Wildheart Raiment",
                word: "the Wildheart",
                stem: "Leather_DungeonDruid_A_01",
            },
            SetDef {
                name: "Cenarion Raiment",
                word: "Cenarius",
                stem: "Leather_RaidDruid_A_01",
            },
            SetDef {
                name: "Stormrage Raiment",
                word: "Stormrage",
                stem: "Leather_RaidDruid_B_01",
            },
            SetDef {
                name: "Dreamwalker Raiment",
                word: "the Dreamwalker",
                stem: "Leather_RaidDruid_C_01",
            },
        ],
        _ => &[],
    }
}

/// One piece the hero can own.
#[derive(Clone)]
pub(crate) struct Piece {
    pub set: usize,
    pub slot: Slot,
    pub display: u32,
    pub icon: Option<String>,
    pub name: String,
}

impl Piece {
    /// The template entry it is cached under: high enough that no real item uses it.
    pub(crate) fn entry(&self) -> u32 {
        ARMOR_ENTRY | self.display
    }
}

const ARMOR_ENTRY: u32 = 0x5000_0000;
const WEAPON_ENTRY: u32 = 0x6000_0000;
const OUTFIT_ENTRY: u32 = 0x7000_0000;

/// A starting-outfit piece's `EQUIPMENT_SLOT_*` and the armor slot it stands in for: the level-1
/// clothes a fresh character wears (`CharStartOutfit`), under the armor until a piece replaces them.
/// The shirt has no armor slot, so it is always worn.
fn outfit_slot(inv_type: u8) -> Option<(u8, Option<Slot>)> {
    Some(match inv_type {
        1 => (0, Some(Slot::Head)),
        3 => (2, Some(Slot::Shoulders)),
        4 => (3, None),
        5 | 20 => (4, Some(Slot::Chest)),
        6 => (5, Some(Slot::Waist)),
        7 => (6, Some(Slot::Legs)),
        8 => (7, Some(Slot::Feet)),
        9 => (8, Some(Slot::Wrists)),
        10 => (9, Some(Slot::Hands)),
        _ => return None,
    })
}

/// Every class's pieces, found once `ItemDisplayInfo.dbc` is loaded.
#[derive(Resource, Default)]
pub(crate) struct GearCatalog {
    /// Class id → its pieces, set by set, slot by slot within a set; a slot whose art isn't
    /// found has no piece.
    pub pieces: HashMap<u8, Vec<Piece>>,
}

impl GearCatalog {
    pub(crate) fn for_class(&self, class: u8) -> &[Piece] {
        self.pieces.get(&class).map_or(&[], Vec::as_slice)
    }

    pub(crate) fn piece(&self, class: u8, set: usize, slot: Slot) -> Option<&Piece> {
        self.for_class(class)
            .iter()
            .find(|p| p.set == set && p.slot == slot)
    }
}

/// The slot a display row dresses, by its art's own names, and how many of its textures belong
/// to `stem`; `None` when the row isn't an item of `stem` (an NPC's composite, a mixed row).
fn classify(row: &ItemDisplay, stem: &str, exists: &dyn Fn(&str) -> bool) -> Option<(Slot, usize)> {
    let stem = stem.to_ascii_lowercase();
    // An inventory icon marks a real item's row; NPC armor rows have none.
    row.icon.as_ref()?;
    let model = row.model[0].as_deref().unwrap_or("").to_ascii_lowercase();
    if model.contains(&stem) {
        if model.contains("helm") {
            return Some((Slot::Head, 1));
        }
        if model.contains("shoulder") {
            return Some((Slot::Shoulders, 1));
        }
    }
    let textures: Vec<String> = row
        .region_textures
        .iter()
        .flatten()
        .map(|t| t.to_ascii_lowercase())
        .collect();
    if textures.is_empty() || !textures.iter().all(|t| t.contains(&stem)) {
        return None;
    }
    // Some rows name art that never shipped (`…_Robe_LL_U` where only `…_Robe_LL_U.blp` exists,
    // so the composite's `_U` lookup misses): the region would paint as bare skin.
    let shipped = row.region_textures.iter().enumerate().all(|(layer, t)| {
        t.as_deref().is_none_or(|name| {
            (0..2).any(|sex| {
                benilla_formats::equip_region_candidates(layer, name, sex)
                    .iter()
                    .any(|path| exists(path))
            })
        })
    });
    if !shipped {
        return None;
    }
    // Each texture's part, named after the stem: `Robe_RaidPriest_A_01Gold_Belt_LU` is a belt,
    // though its stem says robe.
    const PARTS: [&str; 8] = [
        "sleeve", "chest", "robe", "pant", "boot", "glove", "belt", "bracer",
    ];
    let parts: Vec<&str> = textures
        .iter()
        .filter_map(|t| {
            let rest = &t[t.find(&stem)? + stem.len()..];
            PARTS.iter().copied().find(|p| rest.contains(p))
        })
        .collect();
    let has = |k: &str| parts.contains(&k);
    let (slot, own): (Slot, &[&str]) = if has("chest") || has("robe") {
        (Slot::Chest, &["sleeve", "chest", "robe"])
    } else if has("pant") {
        (Slot::Legs, &["pant"])
    } else if has("boot") {
        (Slot::Feet, &["boot"])
    } else if has("glove") {
        (Slot::Hands, &["glove"])
    } else if has("belt") {
        (Slot::Waist, &["belt"])
    } else if has("bracer") {
        (Slot::Wrists, &["bracer"])
    } else {
        return None;
    };
    // A row that paints another slot's part too (a robe whose skirt is a boot texture) is a
    // worse fit than one that keeps to its own.
    let score = parts.iter().filter(|p| own.contains(p)).count() as i32 * 2
        - parts.iter().filter(|p| !own.contains(p)).count() as i32 * 3;
    Some((slot, score.max(1) as usize))
}

/// Find every class's pieces in the display catalog: per set and slot, the row covering the most
/// of the slot's art, the lowest id on a tie (the base colour before its recolours).
pub(crate) fn build_catalog(
    displays: Option<Res<crate::entities::ItemDisplays>>,
    assets: Option<Res<benilla_assets::WorldAssets>>,
    char_create: Option<Res<crate::entities::CharCreate>>,
    mut catalog: ResMut<GearCatalog>,
    mut items: ResMut<crate::items::Items>,
    mut done: Local<bool>,
) {
    if *done {
        return;
    }
    let (Some(displays), Some(assets), Some(char_create)) = (displays, assets, char_create) else {
        return;
    };
    *done = true;
    let Ok(chain) = assets.chain.lock() else {
        return;
    };
    let exists = |path: &str| chain.contains(path);
    let mut rows: Vec<(u32, &ItemDisplay)> = displays.catalog.iter().collect();
    rows.sort_by_key(|&(id, _)| id);
    for class in data::CLASSES {
        let mut pieces = Vec::new();
        for (si, s) in sets(class.id).iter().enumerate() {
            let mut best: HashMap<Slot, (usize, u32, &ItemDisplay)> = HashMap::new();
            for &(id, row) in &rows {
                let Some((slot, score)) = classify(row, s.stem, &exists) else {
                    continue;
                };
                if best.get(&slot).is_none_or(|b| score > b.0) {
                    best.insert(slot, (score, id, row));
                }
            }
            for slot in Slot::ALL {
                let Some(&(_, display, row)) = best.get(&slot) else {
                    continue;
                };
                pieces.push(Piece {
                    set: si,
                    slot,
                    display,
                    icon: row.icon.clone(),
                    name: format!("{} of {}", slot.noun(), s.word),
                });
            }
        }
        info!(
            "survivors: {} gear, {} pieces in {} sets",
            class.name,
            pieces.len(),
            sets(class.id).len()
        );
        for p in &pieces {
            items.insert_template(p.entry(), Some(armor_template(p)));
        }
        catalog.pieces.insert(class.id, pieces);
    }
    for class in data::CLASSES {
        for w in class.weapons {
            items.insert_template(weapon_entry(w), Some(weapon_template(w)));
        }
        for race in 1..=8u8 {
            for sex in 0..=1u8 {
                for o in char_create.0.start_outfit(race, class.id, sex) {
                    if outfit_slot(o.inv_type).is_some() {
                        let mut t = blank("", o.display_id);
                        t.class = 4;
                        t.inventory_type = u32::from(o.inv_type);
                        items.insert_template(OUTFIT_ENTRY | o.display_id, Some(t));
                    }
                }
            }
        }
    }
}

pub(crate) fn weapon_entry(w: &Weapon) -> u32 {
    WEAPON_ENTRY | w.1
}

/// `EQUIPMENT_SLOT_*` of a class weapon's held slot (mainhand, offhand, ranged).
pub(crate) fn weapon_equip_slot(w: &Weapon) -> u8 {
    15 + w.0 as u8
}

fn armor_template(p: &Piece) -> ItemInfo {
    let mut t = blank(&p.name, p.display);
    t.class = 4; // armor
    t.quality = 4;
    t.inventory_type = p.slot.inventory_type();
    t
}

fn weapon_template(w: &Weapon) -> ItemInfo {
    let &(_, display, class, subclass, material, inv, sheath) = w;
    let mut t = blank("", display);
    t.class = u32::from(class);
    t.subclass = u32::from(subclass);
    t.material = u32::from(material);
    t.inventory_type = u32::from(inv);
    t.sheath = u32::from(sheath);
    t
}

fn blank(name: &str, display: u32) -> ItemInfo {
    ItemInfo {
        class: 0,
        subclass: 0,
        name: name.into(),
        display_info_id: display,
        quality: 1,
        flags: 0,
        buy_price: 0,
        sell_price: 0,
        inventory_type: 0,
        allowable_class: -1,
        allowable_race: -1,
        item_level: 0,
        required_level: 0,
        required_skill: 0,
        required_skill_rank: 0,
        required_spell: 0,
        required_honor_rank: 0,
        required_city_rank: 0,
        required_rep_faction: 0,
        required_rep_rank: 0,
        max_count: 0,
        stackable: 1,
        container_slots: 0,
        stats: Vec::new(),
        damages: Vec::new(),
        dmg_min: 0.0,
        dmg_max: 0.0,
        dmg_type: 0,
        armor: 0,
        resistances: [0; 6],
        delay_ms: 0,
        ammo_type: 0,
        ranged_mod_range: 0.0,
        spells: Vec::new(),
        spell_charges_0: 0,
        use_spell: None,
        bonding: 0,
        description: String::new(),
        page_text: 0,
        language_id: 0,
        page_material: 0,
        start_quest: 0,
        lock_id: 0,
        material: 0,
        sheath: 0,
        random_property: 0,
        block: 0,
        item_set: 0,
        max_durability: 0,
        area: 0,
        map: 0,
        bag_family: 0,
    }
}

/// The hero's visible items, `(EQUIPMENT_SLOT_*, entry)`: the armor worn, the starting outfit
/// where no armor is, and the class's weapons.
pub(crate) fn hero_items(
    class: &data::ClassDef,
    outfit: &[benilla_formats::StartOutfitItem],
    profile: &super::profile::Profile,
    catalog: &GearCatalog,
) -> Vec<(u8, u32)> {
    let worn = profile.worn(class.id, catalog);
    let armor = worn
        .iter()
        .filter_map(|&(slot, set)| catalog.piece(class.id, set, slot))
        .map(|p| (p.slot.equip_slot(), p.entry()));
    let clothes = outfit.iter().filter_map(|o| {
        let (equip, slot) = outfit_slot(o.inv_type)?;
        let covered = slot.is_some_and(|s| worn.iter().any(|&(w, _)| w == s));
        (!covered).then_some((equip, OUTFIT_ENTRY | o.display_id))
    });
    let weapons = class
        .weapons
        .iter()
        .map(|w| (weapon_equip_slot(w), weapon_entry(w)));
    armor.chain(clothes).chain(weapons).collect()
}

/// A set's rank, 1 for a dungeon set to 4 for the third raid tier, whatever sets the class has.
fn rank(class: u8, set: usize) -> usize {
    set + 4 - sets(class).len().min(4) + 1
}

/// What the armor worn adds: `(damage, health)` fractions. Each piece gives 1% damage and 1.5%
/// health per rank, so a full third-tier set is +32% damage and +48% health.
pub(crate) fn bonus(
    class: u8,
    profile: &super::profile::Profile,
    catalog: &GearCatalog,
) -> (f32, f32) {
    profile
        .worn(class, catalog)
        .into_iter()
        .map(|(_, set)| rank(class, set) as f32)
        .fold((0.0, 0.0), |(m, h), r| (m + 0.01 * r, h + 0.015 * r))
}

/// The set a zone's bosses drop: by the zone's level and the difficulty's bump
/// ([`super::difficulty::tier_bump`]), scaled to the sets the class has.
fn zone_set(class: u8, map: usize, difficulty: u8) -> usize {
    let lo = super::profile::zone_order()
        .iter()
        .find(|z| z.map == map)
        .map_or(1, |z| z.lo);
    let tier = match lo {
        0..=15 => 0,
        16..=35 => 1,
        36..=52 => 2,
        _ => 3,
    };
    let tier = (tier + super::difficulty::tier_bump(difficulty)).min(3);
    let n = sets(class).len().max(1);
    tier * (n - 1) / 3
}

/// Every boss has a chance to drop a piece of the class's armor, one in two on Normal and more on
/// harder difficulties ([`super::difficulty::armor_chance`]), the run's last boss
/// always: a piece of the zone's set not owned yet, else of a weaker set. It is the profile's at
/// once, worn at once if it beats what the slot has, and named in the banner and the results.
#[allow(clippy::too_many_arguments)]
pub(crate) fn boss_drops(
    mut drops: MessageReader<super::enemies::Loot>,
    mut run: ResMut<super::Run>,
    mut profile: ResMut<super::profile::Profile>,
    selection: Res<super::Selection>,
    catalog: Res<GearCatalog>,
    mut rng: ResMut<super::Rng>,
    mut hero: Query<&mut crate::net::ObjectStore, With<super::hero::Hero>>,
    char_create: Option<Res<crate::entities::CharCreate>>,
) {
    for d in drops.read() {
        if !d.boss {
            continue;
        }
        run.boss_kills += 1;
        let last = run.boss_kills as usize >= data::roster(selection.stage).bosses.len();
        if !last && rng.f32() >= super::difficulty::armor_chance(run.difficulty) {
            continue;
        }
        let class = run.class.id;
        let top = zone_set(class, selection.stage, run.difficulty);
        let piece = (0..=top).rev().find_map(|set| {
            let open: Vec<&Piece> = catalog
                .for_class(class)
                .iter()
                .filter(|p| p.set == set && !profile.owns(class, set, p.slot))
                .collect();
            (!open.is_empty()).then(|| open[rng.index(open.len())].clone())
        });
        let Some(piece) = piece else { continue };
        profile.grant(class, piece.set, piece.slot);
        run.banner = Some((format!("Loot: {}!", piece.name), 4.0));
        run.loot.push(piece.clone());
        (run.gear_might, run.gear_hp) = bonus(class, &profile, &catalog);
        if let Ok(mut store) = hero.single_mut() {
            let sex = store.0.unit_gender().unwrap_or(0);
            let outfit = char_create
                .as_deref()
                .map_or(&[][..], |c| c.0.start_outfit(run.race, class, sex));
            let items = hero_items(run.class, outfit, &profile, &catalog);
            super::units::set_visible_items(&mut store, &items);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn map(name: &str) -> usize {
        data::MAPS.iter().position(|m| m.name == name).unwrap()
    }

    #[test]
    fn zones_drop_sets_by_level_scaled_to_the_class() {
        // A warrior has a dungeon set and three raid tiers, a rogue only the raid tiers.
        assert_eq!(zone_set(1, map("Elwynn Forest"), 0), 0);
        assert_eq!(zone_set(1, map("Duskwood"), 0), 1);
        assert_eq!(zone_set(1, map("Naxxramas"), 0), 3);
        assert_eq!(zone_set(4, map("Elwynn Forest"), 0), 0);
        assert_eq!(zone_set(4, map("Naxxramas"), 0), 2);
    }

    #[test]
    fn harder_difficulties_drop_stronger_sets() {
        assert_eq!(zone_set(1, map("Elwynn Forest"), 1), 1);
        assert_eq!(zone_set(1, map("Elwynn Forest"), 2), 2);
        assert_eq!(zone_set(1, map("Elwynn Forest"), 10), 3);
        assert_eq!(zone_set(1, map("Naxxramas"), 20), 3);
    }

    #[test]
    fn a_rogue_first_set_ranks_as_a_raid_tier() {
        assert_eq!(rank(1, 0), 1);
        assert_eq!(rank(1, 3), 4);
        assert_eq!(rank(4, 0), 2);
        assert_eq!(rank(4, 2), 4);
    }

    #[test]
    fn the_outfit_fills_only_what_the_armor_leaves() {
        assert_eq!(outfit_slot(20), Some((4, Some(Slot::Chest))));
        assert_eq!(outfit_slot(4), Some((3, None)));
        assert_eq!(outfit_slot(13), None); // a one-hander: the class weapons are held instead
        for slot in Slot::ALL {
            assert_eq!(
                outfit_slot(slot.inventory_type() as u8).map(|o| o.0),
                Some(slot.equip_slot())
            );
        }
    }
}
