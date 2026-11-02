//! What outlasts a run, split as a WoW account splits it. The account keeps the purse, the copper
//! every run has brought home ([`super::bag`]), and the merchant's upgrades bought with it. Each
//! character keeps its name and looks, its zone records and the armor it has collected
//! ([`super::gear`]): the armor is bound to the character that won it.
//!
//! A character's starting zones are open from its creation; every other zone opens once the zone
//! before it in the menu's order (by level) has been won, the first of them once any starting
//! zone has.
//!
//! Saved as `benilla-config/survivors-profile.txt`, one record per tab-separated line:
//! `copper\tamount`, `upgrade\tkey\trank` and `current\tname` for the account, then each character
//! as a `char\tname\tclass\trace\tsex\tskin\tface\thair style\thair color\tfacial hair\tmap` line
//! followed by its own zones, `name\twins\truns\tbest_secs\tbest_kills\tcleared\tpick` (keyed by
//! name so a reordered or extended [`data::MAPS`] keeps every record; a line from before
//! difficulties has no `cleared` or `pick`), and pieces, `gear\tclass\tset\tslot`.
//! A save from before characters has its zones and pieces at the top with no `char` line; they
//! become the first character, with the hero of the old `survivors-pick.txt`.

use bevy::prelude::*;

use std::collections::BTreeSet;

use super::gear::{GearCatalog, Slot};
use super::units::Custom;
use super::{data, Run, Selection};

/// A zone whose weakest creature is at most this level is a starting zone.
const STARTER_LEVEL: u32 = 6;

/// Characters an account holds, as a 1.12 realm allows.
pub(super) const MAX_CHARACTERS: usize = 10;

/// A name's length in letters, as the 1.12 create screen takes it.
pub(super) const NAME_MIN: usize = 2;
pub(super) const NAME_MAX: usize = 12;

#[derive(Clone, Copy, Default)]
pub(super) struct ZoneRecord {
    pub wins: u32,
    pub runs: u32,
    pub best_secs: u32,
    pub best_kills: u32,
    /// One past the hardest difficulty won here ([`super::difficulty`]): 0 none, 1 Normal, 2
    /// Heroic, `n + 1` Mythic +n. It is also the hardest difficulty open.
    pub cleared: u8,
    /// The difficulty last picked for the zone.
    pub pick: u8,
}

/// One hero: who they are, how they look, where they last fought, and what they have won.
#[derive(Clone)]
pub(super) struct Character {
    pub name: String,
    /// An index into [`data::CLASSES`].
    pub class: usize,
    pub race: u8,
    pub sex: u8,
    pub custom: Custom,
    /// The zone last picked, an index into [`data::MAPS`].
    pub map: usize,
    /// Indexed like [`data::MAPS`].
    pub zones: Vec<ZoneRecord>,
    /// Owned armor, `(class id, set, slot index)`.
    pub gear: BTreeSet<(u8, u8, u8)>,
}

impl Character {
    pub fn new(name: String, class: usize, race: u8, sex: u8, custom: Custom, map: usize) -> Self {
        Self {
            name,
            class,
            race,
            sex,
            custom,
            map,
            zones: vec![ZoneRecord::default(); data::MAPS.len()],
            gear: BTreeSet::new(),
        }
    }

    /// Zones won, for the character list.
    pub fn wins(&self) -> usize {
        self.zones.iter().filter(|r| r.wins > 0).count()
    }
}

#[derive(Resource)]
pub(super) struct Profile {
    pub chars: Vec<Character>,
    /// The character picked, an index into `chars`.
    pub current: Option<usize>,
    /// The purse, in copper, shared by every character.
    pub copper: u64,
    /// The merchant's upgrades bought, shared by every character.
    pub ranks: super::merchant::Ranks,
    /// Bumped on every change to what the menu lists, so it rebuilds once.
    pub version: u32,
}

impl Default for Profile {
    fn default() -> Self {
        let mut p = Self::empty();
        if let Some(text) = path().and_then(|p| crate::local_state::read_to_string(&p).ok()) {
            let legacy = p.parse(&text);
            if p.chars.is_empty() {
                let pick = pick_path().and_then(|p| crate::local_state::read_to_string(&p).ok());
                p.migrate(legacy, pick.as_deref());
            }
        }
        p
    }
}

fn path() -> Option<std::path::PathBuf> {
    crate::local_state::home().map(|h| h.join("survivors-profile.txt"))
}

/// The hero picked before characters: `class race sex map` and the five dials.
fn pick_path() -> Option<std::path::PathBuf> {
    crate::local_state::home().map(|h| h.join("survivors-pick.txt"))
}

impl Profile {
    fn empty() -> Self {
        Self {
            chars: Vec::new(),
            current: None,
            copper: 0,
            ranks: [0; super::merchant::UPGRADES.len()],
            version: 0,
        }
    }

    /// Read a save; what came before any `char` line, a save from before characters.
    fn parse(&mut self, text: &str) -> Option<Character> {
        let mut legacy: Option<Character> = None;
        let mut current = None;
        for line in text.lines() {
            let mut f = line.split('\t');
            let Some(name) = f.next() else { continue };
            match name {
                "copper" => self.copper = f.next().and_then(|v| v.parse().ok()).unwrap_or(0),
                "upgrade" => {
                    let key = f.next().unwrap_or("");
                    let rank = f.next().and_then(|v| v.parse().ok()).unwrap_or(0);
                    if let Some(i) = super::merchant::index(key) {
                        self.ranks[i] = rank.min(super::merchant::UPGRADES[i].ranks);
                    }
                }
                "current" => current = f.next().map(str::to_string),
                "char" => {
                    let Some(name) = f.next().filter(|n| valid_name(n)) else {
                        continue;
                    };
                    let v: Vec<usize> = f.filter_map(|v| v.parse().ok()).collect();
                    let Some(
                        &[class, race, sex, skin, face, hair_style, hair_color, facial_hair, map],
                    ) = v.get(..9)
                    else {
                        continue;
                    };
                    let custom = custom([skin, face, hair_style, hair_color, facial_hair]);
                    self.chars.push(Character::new(
                        name.to_string(),
                        class.min(data::CLASSES.len() - 1),
                        race as u8,
                        sex as u8,
                        custom,
                        map.min(data::MAPS.len() - 1),
                    ));
                }
                _ => {
                    // A zone or a piece: the character above it's, or the old save's.
                    let target = match self.chars.last_mut() {
                        Some(c) => c,
                        None => legacy.get_or_insert_with(|| {
                            Character::new(String::new(), 0, 1, 0, Custom::default(), 0)
                        }),
                    };
                    if name == "gear" {
                        let v: Vec<u8> = f.filter_map(|v| v.parse().ok()).collect();
                        if let [class, set, slot] = v[..] {
                            target.gear.insert((class, set, slot));
                        }
                    } else if let Some(i) = data::MAPS.iter().position(|m| m.name == name) {
                        let mut n = || f.next().and_then(|v| v.parse().ok());
                        let (wins, runs, best_secs, best_kills) = (
                            n().unwrap_or(0),
                            n().unwrap_or(0),
                            n().unwrap_or(0),
                            n().unwrap_or(0),
                        );
                        // Before difficulties every win was on Normal.
                        let cleared = n().map_or(u8::from(wins > 0), |c: u32| c as u8);
                        let pick = n().unwrap_or(0) as u8;
                        target.zones[i] = ZoneRecord {
                            wins,
                            runs,
                            best_secs,
                            best_kills,
                            cleared: cleared.min(super::difficulty::MAX + 1),
                            pick: pick.min(cleared.min(super::difficulty::MAX)),
                        };
                    }
                }
            }
        }
        self.current = current
            .and_then(|n| self.find(&n))
            .or((!self.chars.is_empty()).then_some(0));
        legacy
    }

    /// A save from before characters becomes the first: its zones and pieces, the hero last
    /// picked and a name. The old pick file goes once the new save is written, so a later
    /// account with every character deleted does not bring it back.
    fn migrate(&mut self, legacy: Option<Character>, pick: Option<&str>) {
        if legacy.is_none() && pick.is_none() {
            return;
        }
        let mut hero =
            legacy.unwrap_or_else(|| Character::new(String::new(), 0, 1, 0, Custom::default(), 0));
        let v: Vec<usize> = pick
            .unwrap_or("")
            .split_whitespace()
            .filter_map(|t| t.parse().ok())
            .collect();
        if let Some(&[class, race, sex, map]) = v.get(..4) {
            hero.class = class.min(data::CLASSES.len() - 1);
            hero.race = race as u8;
            hero.sex = sex as u8;
            hero.map = map.min(data::MAPS.len() - 1);
        }
        if let Some(&[skin, face, hair_style, hair_color, facial_hair]) = v.get(4..9) {
            hero.custom = custom([skin, face, hair_style, hair_color, facial_hair]);
        }
        hero.name = random_name(hero.race, &mut |n| {
            (hero.zones.iter().map(|r| r.runs as usize).sum::<usize>() + v.iter().sum::<usize>())
                % n.max(1)
        });
        self.chars.push(hero);
        self.current = Some(0);
        if self.save() {
            if let Some(p) = pick_path() {
                let _ = crate::local_state::remove_file(&p);
            }
        }
    }

    /// Write the save; false when it could not be.
    fn save(&self) -> bool {
        let mut text = String::new();
        if self.copper > 0 {
            text.push_str(&format!("copper\t{}\n", self.copper));
        }
        for (u, &r) in super::merchant::UPGRADES.iter().zip(&self.ranks) {
            if r > 0 {
                text.push_str(&format!("upgrade\t{}\t{r}\n", u.key));
            }
        }
        if let Some(c) = self.hero() {
            text.push_str(&format!("current\t{}\n", c.name));
        }
        for c in &self.chars {
            let d = c.custom;
            text.push_str(&format!(
                "char\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
                c.name,
                c.class,
                c.race,
                c.sex,
                d.skin,
                d.face,
                d.hair_style,
                d.hair_color,
                d.facial_hair,
                c.map
            ));
            for (m, r) in data::MAPS.iter().zip(&c.zones).filter(|(_, r)| r.runs > 0) {
                text.push_str(&format!(
                    "{}\t{}\t{}\t{}\t{}\t{}\t{}\n",
                    m.name, r.wins, r.runs, r.best_secs, r.best_kills, r.cleared, r.pick
                ));
            }
            for (class, set, slot) in &c.gear {
                text.push_str(&format!("gear\t{class}\t{set}\t{slot}\n"));
            }
        }
        path().is_some_and(|p| crate::local_state::write_atomic(&p, &text).is_ok())
    }

    /// The character picked.
    pub fn hero(&self) -> Option<&Character> {
        self.current.and_then(|i| self.chars.get(i))
    }

    fn hero_mut(&mut self) -> Option<&mut Character> {
        self.current.and_then(|i| self.chars.get_mut(i))
    }

    /// A character by name, as the game compares names: ignoring case.
    pub fn find(&self, name: &str) -> Option<usize> {
        self.chars
            .iter()
            .position(|c| c.name.to_lowercase() == name.to_lowercase())
    }

    /// Why `name` cannot be a new character's, if it cannot.
    pub fn refuse(&self, name: &str) -> Option<&'static str> {
        let letters = name.chars().count();
        if self.chars.len() >= MAX_CHARACTERS {
            Some("You have the most characters an account can hold.")
        } else if letters < NAME_MIN {
            Some("Names must be at least 2 letters.")
        } else if letters > NAME_MAX || !valid_name(name) {
            Some("Names are up to 12 letters, and only letters.")
        } else if self.find(name).is_some() {
            Some("That name is taken.")
        } else {
            None
        }
    }

    /// Add a character and pick it; false (and nothing added) when [`Self::refuse`] says no.
    pub fn create(&mut self, hero: Character) -> bool {
        if self.refuse(&hero.name).is_some() {
            return false;
        }
        self.chars.push(hero);
        self.current = Some(self.chars.len() - 1);
        self.version += 1;
        self.save();
        true
    }

    /// Pick the `i`th character.
    pub fn choose(&mut self, i: usize) {
        if i < self.chars.len() && self.current != Some(i) {
            self.current = Some(i);
            self.version += 1;
            self.save();
        }
    }

    /// Delete the `i`th character, its zones and its armor; the purse and the upgrades stay.
    pub fn delete(&mut self, i: usize) {
        if i >= self.chars.len() {
            return;
        }
        self.chars.remove(i);
        self.current = match self.current {
            _ if self.chars.is_empty() => None,
            Some(c) if c > i => Some(c - 1),
            Some(c) => Some(c.min(self.chars.len() - 1)),
            None => Some(0),
        };
        self.version += 1;
        self.save();
    }

    /// The zone the character picked; unlike a new pick of character, not a change the menu
    /// rebuilds for.
    pub fn set_map(&mut self, map: usize) {
        if let Some(c) = self.hero_mut().filter(|c| c.map != map) {
            c.map = map;
            self.save();
        }
    }

    pub fn owns(&self, class: u8, set: usize, slot: Slot) -> bool {
        self.hero()
            .is_some_and(|c| c.gear.contains(&(class, set as u8, slot.index() as u8)))
    }

    /// Add a piece to the character's armor; false if it was owned already.
    pub fn grant(&mut self, class: u8, set: usize, slot: Slot) -> bool {
        let fresh = self
            .hero_mut()
            .is_some_and(|c| c.gear.insert((class, set as u8, slot.index() as u8)));
        if fresh {
            self.version += 1;
            self.save();
        }
        fresh
    }

    /// The set worn in each slot: the strongest owned. `WOW_SURVIVORS_GEAR=<set>` dresses the
    /// hero in that whole set instead, for looking at the art.
    pub fn worn(&self, class: u8, catalog: &GearCatalog) -> Vec<(Slot, usize)> {
        // Read once: the menu asks every frame.
        static FORCED: std::sync::OnceLock<Option<usize>> = std::sync::OnceLock::new();
        let forced = *FORCED.get_or_init(|| {
            crate::webenv::var("WOW_SURVIVORS_GEAR").and_then(|v| v.parse::<usize>().ok())
        });
        Slot::ALL
            .iter()
            .filter_map(|&slot| {
                let owned = |set: &usize| match forced {
                    Some(f) => *set == f,
                    None => self.owns(class, *set, slot),
                };
                let best = (0..super::gear::sets(class).len())
                    .rev()
                    .filter(owned)
                    .find(|&set| catalog.piece(class, set, slot).is_some())?;
                Some((slot, best))
            })
            .collect()
    }

    pub fn won(&self, map: usize) -> bool {
        self.hero()
            .and_then(|c| c.zones.get(map))
            .is_some_and(|r| r.wins > 0)
    }

    /// `None` when `map` is open, else the zone whose win opens it (`None` inside: any starting
    /// zone).
    pub fn lock(&self, map: usize) -> Option<Option<usize>> {
        let order = zone_order();
        let pos = order.iter().position(|z| z.map == map)?;
        if order[pos].starter {
            return None;
        }
        let prev = &order[pos - 1];
        let open = if prev.starter {
            order.iter().any(|z| z.starter && self.won(z.map))
        } else {
            self.won(prev.map)
        };
        (!open).then_some((!prev.starter).then_some(prev.map))
    }

    pub fn is_open(&self, map: usize) -> bool {
        self.lock(map).is_none()
    }

    /// The character's record for `map`, if there is a character.
    pub fn zone(&self, map: usize) -> Option<&ZoneRecord> {
        self.hero().and_then(|c| c.zones.get(map))
    }

    /// The hardest difficulty open in `map`: winning a difficulty opens the next.
    pub fn top_difficulty(&self, map: usize) -> u8 {
        self.zone(map)
            .map_or(0, |r| r.cleared)
            .min(super::difficulty::MAX)
    }

    /// The difficulty last picked for `map`, within what is open.
    pub fn picked_difficulty(&self, map: usize) -> u8 {
        self.zone(map)
            .map_or(0, |r| r.pick)
            .min(self.top_difficulty(map))
    }

    /// Remember the difficulty picked for `map`.
    pub fn set_difficulty(&mut self, map: usize, d: u8) {
        let d = d.min(self.top_difficulty(map));
        if let Some(r) = self.hero_mut().and_then(|c| c.zones.get_mut(map)) {
            if r.pick != d {
                r.pick = d;
                self.save();
            }
        }
    }

    /// Buy the next rank of the `i`th upgrade; false at the top rank or short of coin.
    pub fn buy(&mut self, i: usize) -> bool {
        let u = &super::merchant::UPGRADES[i];
        let r = self.ranks[i];
        if r >= u.ranks || self.copper < u.price(r) {
            return false;
        }
        self.copper -= u.price(r);
        self.ranks[i] += 1;
        self.version += 1;
        self.save();
        true
    }

    /// Record a finished run for the character; the zone it opened, if it opened one. The coins
    /// go to the purse either way.
    pub fn record(&mut self, map: usize, run: &Run) -> Option<usize> {
        let before: Vec<bool> = (0..data::MAPS.len()).map(|m| self.is_open(m)).collect();
        if let Some(r) = self.hero_mut().and_then(|c| c.zones.get_mut(map)) {
            r.runs += 1;
            r.wins += u32::from(run.won);
            r.best_secs = r.best_secs.max(run.elapsed as u32);
            r.best_kills = r.best_kills.max(run.kills);
            if run.won {
                r.cleared = r.cleared.max(run.difficulty + 1);
            }
        }
        self.copper += run.earned;
        self.version += 1;
        self.save();
        (0..data::MAPS.len()).find(|&m| !before[m] && self.is_open(m))
    }
}

fn custom([skin, face, hair_style, hair_color, facial_hair]: [usize; 5]) -> Custom {
    Custom {
        skin: skin as u8,
        face: face as u8,
        hair_style: hair_style as u8,
        hair_color: hair_color as u8,
        facial_hair: facial_hair as u8,
    }
}

/// Letters only, up to [`NAME_MAX`] of them.
fn valid_name(name: &str) -> bool {
    let n = name.chars().count();
    (1..=NAME_MAX).contains(&n) && name.chars().all(char::is_alphabetic)
}

/// A name as the game writes one: the first letter capital, the rest small.
pub(super) fn tidy_name(name: &str) -> String {
    let mut out = String::new();
    for (i, c) in name
        .chars()
        .filter(|c| c.is_alphabetic())
        .take(NAME_MAX)
        .enumerate()
    {
        if i == 0 {
            out.extend(c.to_uppercase());
        } else {
            out.extend(c.to_lowercase());
        }
    }
    out
}

/// A name in the race's sound, from two or three syllables; `pick(n)` draws one of `n`.
pub(super) fn random_name(race: u8, pick: &mut impl FnMut(usize) -> usize) -> String {
    let (first, middle, last): (&[&str], &[&str], &[&str]) = match race {
        // Orc, Troll: hard stops.
        2 | 8 => (
            &[
                "Gor", "Thra", "Zul", "Grom", "Kar", "Vol", "Rok", "Jin", "Dra", "Mok",
            ],
            &["ga", "ru", "zan", "ok", "ta", "jo"],
            &["ash", "gar", "rok", "jin", "tar", "gul", "nak", "zug"],
        ),
        // Undead: hollow.
        5 => (
            &["Mor", "Vex", "Sar", "Kel", "Dre", "Nath", "Vel", "Cor"],
            &["e", "i", "ra", "go", "vi"],
            &["thus", "mir", "drin", "ix", "ane", "wick", "zar"],
        ),
        // Tauren: long and open.
        6 => (
            &["Hau", "Tah", "Ka", "Mu", "Ba", "Hu", "Ma", "Ton"],
            &["no", "wa", "ro", "le", "ta"],
            &["rok", "hoof", "mane", "tau", "nar", "wak", "hu"],
        ),
        // Night Elf: soft.
        4 => (
            &["Ely", "Ara", "Syl", "Tyr", "Fan", "Shan", "Lyr", "Ill"],
            &["an", "ri", "the", "la", "dra", "ni"],
            &["dris", "wen", "las", "dor", "andra", "iel", "is"],
        ),
        // Dwarf, Gnome: stout.
        3 | 7 => (
            &["Brom", "Thor", "Gim", "Dur", "Fiz", "Bix", "Mag", "Bel"],
            &["bo", "di", "gar", "ni", "zle"],
            &["din", "grim", "son", "wick", "bolt", "ric", "gan"],
        ),
        // Human.
        _ => (
            &[
                "Al", "Ber", "Cor", "Dar", "Ed", "Gar", "Jor", "Mar", "Ro", "Wil",
            ],
            &["a", "e", "i", "o", "en"],
            &["ric", "win", "den", "ton", "mund", "ius", "ard", "ell"],
        ),
    };
    let mut name = first[pick(first.len())].to_string();
    if pick(3) == 0 {
        name.push_str(middle[pick(middle.len())]);
    }
    name.push_str(last[pick(last.len())]);
    tidy_name(&name)
}

/// A zone in the menu's order.
pub(super) struct Zone {
    pub map: usize,
    /// The weakest and strongest creature's level.
    pub lo: u32,
    pub hi: u32,
    pub starter: bool,
}

/// Every zone, by its weakest creature's level, then name: the menu's rows and the unlock chain.
pub(super) fn zone_order() -> &'static [Zone] {
    static ORDER: std::sync::LazyLock<Vec<Zone>> = std::sync::LazyLock::new(|| {
        let mut order: Vec<Zone> = (0..data::MAPS.len())
            .map(|map| {
                let levels = data::roster(map).enemies.iter().map(|e| e.level);
                let lo = levels.clone().min().unwrap_or(1);
                let hi = levels.max().unwrap_or(lo);
                Zone {
                    map,
                    lo,
                    hi,
                    starter: lo <= STARTER_LEVEL,
                }
            })
            .collect();
        order.sort_by_key(|z| (z.lo, data::MAPS[z.map].name));
        order
    });
    &ORDER
}

/// At the results: count the run toward its zone, and say so if it opened the next.
pub(super) fn record_run(
    mut profile: ResMut<Profile>,
    mut run: ResMut<Run>,
    selection: Res<Selection>,
) {
    // The coins picked up, and the bag and the worn pieces sold, more on a harder difficulty.
    let coins = run.bag.copper + run.bag.worth();
    run.earned = (coins as f64 * f64::from(super::difficulty::coin_mult(run.difficulty))) as u64;
    let top = profile.top_difficulty(selection.stage);
    let opened = profile.record(selection.stage, &run);
    run.opened = opened;
    let now = profile.top_difficulty(selection.stage);
    run.raised = (now > top).then_some(now);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An account with one character, picked.
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

    fn win(p: &mut Profile, map: usize) -> Option<usize> {
        let run = Run {
            won: true,
            elapsed: data::VICTORY_SECS,
            ..Run::default()
        };
        p.record(map, &run)
    }

    #[test]
    fn starters_open_and_each_win_opens_the_next() {
        let mut p = account();
        let order = zone_order();
        let starters: Vec<usize> = order.iter().filter(|z| z.starter).map(|z| z.map).collect();
        let rest: Vec<usize> = order.iter().filter(|z| !z.starter).map(|z| z.map).collect();
        assert!(!starters.is_empty() && rest.len() >= 2);
        assert!(starters.iter().all(|&m| p.is_open(m)));
        assert_eq!(p.lock(rest[0]), Some(None));
        assert_eq!(p.lock(rest[1]), Some(Some(rest[0])));

        // A loss opens nothing; a starting zone's win opens the first of the rest.
        assert_eq!(p.record(starters[0], &Run::default()), None);
        assert_eq!(win(&mut p, starters[0]), Some(rest[0]));
        assert!(!p.is_open(rest[1]));
        assert_eq!(win(&mut p, rest[0]), Some(rest[1]));
        assert_eq!(win(&mut p, rest[0]), None);
    }

    #[test]
    fn a_run_brings_its_coins_home() {
        let mut p = account();
        p.copper = 50;
        let run = Run {
            earned: 1_250,
            ..Run::default()
        };
        p.record(0, &run);
        assert_eq!(p.copper, 1_300);
        // Short of the first rank of Might's 20 silver, then spent at the merchant.
        assert!(!p.buy(0));
        p.copper = 5_000;
        assert!(p.buy(0));
        assert_eq!(p.copper, 3_000);
        assert_eq!(p.ranks[0], 1);
        // The second rank, 36 silver, is out of reach.
        assert!(!p.buy(0));
    }

    #[test]
    fn zones_and_armor_are_the_characters_and_the_purse_is_shared() {
        let mut p = account();
        let first = zone_order().iter().find(|z| !z.starter).unwrap().map;
        let starter = zone_order()[0].map;
        win(&mut p, starter);
        assert!(p.grant(1, 0, Slot::ALL[0]));
        p.copper = 900;
        assert!(p.create(Character::new(
            "Jaina".into(),
            1,
            1,
            1,
            Custom::default(),
            0
        )));
        // The new character starts over, with the same purse.
        assert!(!p.is_open(first));
        assert!(!p.owns(1, 0, Slot::ALL[0]));
        assert_eq!(p.copper, 900);
        p.choose(0);
        assert!(p.is_open(first));
        assert!(p.owns(1, 0, Slot::ALL[0]));
    }

    #[test]
    fn names_are_checked_like_the_create_screen() {
        let mut p = account();
        assert_eq!(tidy_name("tHRALL9 x"), "Thrallx");
        assert!(p.refuse("thrall").is_some(), "names ignore case");
        assert!(p.refuse("A").is_some());
        assert!(p.refuse("Abcdefghijklm").is_some());
        assert!(p.refuse("Jaina").is_none());
        for i in 1..MAX_CHARACTERS {
            let name: String = tidy_name(&"abcdefghij"[..1].repeat(2 + i));
            assert!(p.create(Character::new(name, 0, 1, 0, Custom::default(), 0)));
        }
        assert!(p.refuse("Jaina").is_some(), "the account is full");
        let mut n = 0;
        let name = random_name(2, &mut |k| {
            n += 1;
            n % k
        });
        assert!(valid_name(&name) && name.chars().count() >= NAME_MIN);
    }

    #[test]
    fn delete_keeps_the_pick_on_a_character_still_there() {
        let mut p = account();
        p.create(Character::new(
            "Jaina".into(),
            1,
            1,
            1,
            Custom::default(),
            0,
        ));
        p.create(Character::new(
            "Rexxar".into(),
            2,
            2,
            0,
            Custom::default(),
            0,
        ));
        p.choose(2);
        p.delete(0);
        assert_eq!(p.hero().map(|c| c.name.as_str()), Some("Rexxar"));
        p.delete(1);
        assert_eq!(p.hero().map(|c| c.name.as_str()), Some("Jaina"));
        p.delete(0);
        assert!(p.hero().is_none() && p.chars.is_empty());
    }

    #[test]
    fn a_save_round_trips_and_an_old_one_becomes_a_character() {
        // The new layout: two characters, the second picked.
        let mut p = Profile::empty();
        let text = format!(
            "copper\t42\ncurrent\tJaina\nchar\tThrall\t0\t2\t0\t1\t2\t3\t4\t0\t3\n{}\t1\t2\t300\t40\ngear\t1\t0\t2\nchar\tJaina\t1\t1\t1\t0\t0\t0\t0\t0\t0\n",
            data::MAPS[3].name
        );
        assert!(p.parse(&text).is_none());
        assert_eq!(p.chars.len(), 2);
        assert_eq!(p.hero().map(|c| c.name.as_str()), Some("Jaina"));
        assert_eq!(p.chars[0].zones[3].wins, 1);
        assert_eq!(p.chars[0].custom.hair_color, 4);
        assert!(p.chars[0].gear.contains(&(1, 0, 2)));
        assert!(p.chars[1].gear.is_empty());
        assert_eq!(p.copper, 42);

        // The old layout: zones and pieces with no character, the hero in the pick file.
        let mut q = Profile::empty();
        let old = format!(
            "No Such Zone\t9\t9\t9\t9\n{}\t1\t1\t300\t40\ngear\t8\t1\t0\ncopper\t7\n",
            data::MAPS[3].name
        );
        let legacy = q.parse(&old);
        q.migrate(legacy, Some("2 1 1 5 1 2 3 4 0"));
        assert_eq!(q.chars.len(), 1);
        let c = q.hero().unwrap();
        assert_eq!((c.class, c.race, c.sex, c.map), (2, 1, 1, 5));
        assert_eq!(c.custom.face, 2);
        assert_eq!(c.zones[3].wins, 1);
        assert_eq!(c.zones.iter().map(|r| r.runs).sum::<u32>(), 1);
        assert!(c.gear.contains(&(8, 1, 0)));
        assert!(q.refuse(&c.name.clone()).is_some() && valid_name(&c.name));
        assert_eq!(q.copper, 7);
    }

    #[test]
    fn each_win_opens_the_next_difficulty() {
        let mut p = account();
        let map = zone_order()[0].map;
        assert_eq!(p.top_difficulty(map), 0);
        let mut play = |p: &mut Profile, difficulty: u8, won: bool| {
            p.record(
                map,
                &Run {
                    won,
                    difficulty,
                    ..Run::default()
                },
            );
        };
        play(&mut p, 0, true);
        assert_eq!(p.top_difficulty(map), 1);
        play(&mut p, 1, true);
        assert_eq!(p.top_difficulty(map), 2);
        // A loss keeps the keystone where it was; an easier win takes nothing away.
        play(&mut p, 2, false);
        play(&mut p, 0, true);
        assert_eq!(p.top_difficulty(map), 2);
        p.set_difficulty(map, 9);
        assert_eq!(p.picked_difficulty(map), 2);

        // Saved and read back, the record and the pick hold; a line from before difficulties
        // counts its wins as Normal.
        let mut q = Profile::empty();
        q.parse(&format!(
            "char\tThrall\t0\t2\t0\t0\t0\t0\t0\t0\t0\n{}\t3\t5\t900\t400\t3\t2\n{}\t1\t1\t900\t400\n",
            data::MAPS[map].name,
            data::MAPS[(map + 1) % data::MAPS.len()].name
        ));
        assert_eq!(q.top_difficulty(map), 3);
        assert_eq!(q.picked_difficulty(map), 2);
        assert_eq!(q.top_difficulty((map + 1) % data::MAPS.len()), 1);
    }
}
