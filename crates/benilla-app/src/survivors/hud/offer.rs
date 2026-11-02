//! The level-up offer: the cards dealt from the run's pool, a reroll or banish, the pick, and
//! what each card says.

use super::*;

fn choices_for(run: &Run, rng: &mut Rng) -> Vec<Choice> {
    let mut pool: Vec<(Choice, f32)> = Vec::new();
    for (i, o) in run.abilities.iter().enumerate() {
        if o.level < data::MAX_ABILITY_LEVEL {
            pool.push((Choice::Upgrade(i), 1.2));
        }
    }
    if run.abilities.len() < data::MAX_ABILITIES {
        for key in run.class.pool {
            if !run.abilities.iter().any(|o| o.def.key == *key) && !run.banished.contains(key) {
                pool.push((Choice::NewAbility(data::ability(key)), 1.0));
            }
        }
    }
    for (i, (_, level)) in run.passives.iter().enumerate() {
        if *level < data::MAX_PASSIVE_LEVEL {
            pool.push((Choice::UpPassive(i), 0.8));
        }
    }
    if run.passives.len() < data::MAX_PASSIVES {
        for p in data::PASSIVES {
            if !run.passives.iter().any(|(q, _)| q.key == p.key) && !run.banished.contains(&p.key) {
                pool.push((Choice::NewPassive(p), 0.5));
            }
        }
    }
    let mut out = Vec::with_capacity(3);
    while out.len() < 3 && !pool.is_empty() {
        let total: f32 = pool.iter().map(|(_, w)| w).sum();
        let mut pick = rng.f32() * total;
        let mut idx = pool.len() - 1;
        for (i, (_, w)) in pool.iter().enumerate() {
            if pick < *w {
                idx = i;
                break;
            }
            pick -= w;
        }
        out.push(pool.swap_remove(idx).0);
    }
    if out.is_empty() {
        out.push(Choice::Heal);
    }
    out
}

pub(in crate::survivors) fn roll_offer(
    mut run: ResMut<Run>,
    mut rng: ResMut<Rng>,
    mut offer: ResMut<Offer>,
) {
    run.banishing = false;
    offer.choices = choices_for(&run, &mut rng);
}

/// A fresh hand, spending a reroll.
pub(in crate::survivors) fn reroll(run: &mut Run, offer: &mut Offer, rng: &mut Rng) -> bool {
    if run.rerolls == 0 {
        return false;
    }
    run.rerolls -= 1;
    run.banishing = false;
    offer.choices = choices_for(run, rng);
    true
}

/// The key a card would strike from the pool: only spells and auras not yet had.
pub(in crate::survivors) fn banish_key(choice: Choice) -> Option<&'static str> {
    match choice {
        Choice::NewAbility(def) => Some(def.key),
        Choice::NewPassive(p) => Some(p.key),
        _ => None,
    }
}

/// Strike card `i` from the run, spending a banish, and deal again.
pub(in crate::survivors) fn banish(
    i: usize,
    run: &mut Run,
    offer: &mut Offer,
    rng: &mut Rng,
) -> bool {
    let Some(key) = offer.choices.get(i).copied().and_then(banish_key) else {
        return false;
    };
    if run.banishes == 0 {
        return false;
    }
    run.banishes -= 1;
    run.banishing = false;
    run.banished.push(key);
    offer.choices = choices_for(run, rng);
    true
}

pub(in crate::survivors) fn pick(
    i: usize,
    run: &mut Run,
    offer: &mut Offer,
    rng: &mut Rng,
    next: &mut NextState<Phase>,
) {
    let Some(&choice) = offer.choices.get(i) else {
        return;
    };
    match choice {
        Choice::NewAbility(def) => {
            let o = run.own(def, 0.3);
            run.abilities.push(o);
        }
        Choice::Upgrade(k) => run.abilities[k].level += 1,
        Choice::NewPassive(p) => run.passives.push((p, 1)),
        Choice::UpPassive(k) => run.passives[k].1 += 1,
        Choice::Heal => run.hp = run.stats().max_hp,
    }
    run.version += 1;
    run.pending_levels = run.pending_levels.saturating_sub(1);
    if run.pending_levels > 0 {
        offer.choices = choices_for(run, rng);
    } else {
        offer.choices.clear();
        next.set(Phase::Playing);
    }
}

/// What a level-up card shows.
pub(in crate::survivors) struct CardText {
    pub spell: u32,
    pub name: String,
    pub tag: String,
    pub tag_color: Color,
    pub desc: String,
    /// `(rank now, top rank)`, for the pips; `None` for the healthstone.
    pub ranks: Option<(u8, u8)>,
}

pub(in crate::survivors) fn describe_card(
    choice: Choice,
    run: &Run,
    spells: Option<&crate::ui_action::Spells>,
) -> CardText {
    let new = Color::srgb(0.3, 1.0, 0.3);
    match choice {
        Choice::NewAbility(def) => {
            let stats = run.stats();
            let c = cast_at(def, 1, &stats, run.own(def, 0.0).bonus);
            CardText {
                spell: def.spell,
                name: spell_name(spells, def.spell, def.key),
                tag: "New spell".into(),
                tag_color: new,
                desc: format!("{}.", ability_body(def, &c)),
                ranks: Some((0, data::MAX_ABILITY_LEVEL)),
            }
        }
        Choice::Upgrade(k) => {
            let o = &run.abilities[k];
            let next = o.level + 1;
            let stats = run.stats();
            let (a, b) = (
                cast_at(o.def, o.level, &stats, o.bonus),
                cast_at(o.def, next, &stats, o.bonus),
            );
            // What actually changes, as before → after.
            let mut lines = Vec::new();
            let (da, db) = if a.dmg > 0.0 {
                (a.dmg, b.dmg)
            } else {
                (a.dot, b.dot)
            };
            if db > da {
                lines.push(format!("Damage {} » {}", num(da), num(db)));
            }
            if b.cooldown < a.cooldown - 0.01 {
                lines.push(format!(
                    "Cooldown {}s » {}s",
                    num(a.cooldown),
                    num(b.cooldown)
                ));
            }
            if b.count > a.count {
                lines.push(format!("Targets {} » {}", a.count, b.count));
            }
            if b.radius > a.radius + 0.05 {
                lines.push(format!("Area {} » {} yd", num(a.radius), num(b.radius)));
            }
            if b.duration > a.duration + 0.05 {
                lines.push(format!("Lasts {}s » {}s", num(a.duration), num(b.duration)));
            }
            CardText {
                spell: o.def.spell,
                name: spell_name(spells, o.def.spell, o.def.key),
                tag: format!("Rank {} » {next}", o.level),
                tag_color: Color::WHITE,
                desc: lines.join("\n"),
                ranks: Some((o.level, data::MAX_ABILITY_LEVEL)),
            }
        }
        Choice::NewPassive(p) => CardText {
            spell: p.spell,
            name: p.name.into(),
            tag: "New talent".into(),
            tag_color: new,
            desc: passive_text(p.stat, p.per_level),
            ranks: Some((0, data::MAX_PASSIVE_LEVEL)),
        },
        Choice::UpPassive(k) => {
            let (p, level) = run.passives[k];
            let fmt = |v: f32| match p.stat {
                Stat::Regen | Stat::Armor => num(v),
                _ => pct(v),
            };
            CardText {
                spell: p.spell,
                name: p.name.into(),
                tag: format!("Rank {level} » {}", level + 1),
                tag_color: Color::WHITE,
                desc: format!(
                    "{}\n{} » {}",
                    stat_label(p.stat),
                    fmt(p.per_level * f32::from(level)),
                    fmt(p.per_level * f32::from(level + 1)),
                ),
                ranks: Some((level, data::MAX_PASSIVE_LEVEL)),
            }
        }
        Choice::Heal => CardText {
            spell: 5720,
            name: "Healthstone".into(),
            tag: "Restore".into(),
            tag_color: Color::WHITE,
            desc: "Everything is mastered. Restores all health.".into(),
            ranks: None,
        },
    }
}
