//! The build icons' and the bag's `GameTooltip`s, and the results screen's numbers.

use super::*;

// ── The build icons' `GameTooltip` ──────────────────────────────────────────────────────────────

/// `TOOLTIP_DEFAULT_BACKGROUND_COLOR`, the `GameTooltip` backdrop tint (`GameTooltip.lua`).
const TIP_FILL: Color = Color::srgb(0.09, 0.09, 0.19);
/// The grey a spell tooltip prints its rank in, right of the name.
const TIP_GREY: Color = Color::srgb(0.5, 0.5, 0.5);

/// One tooltip line: the left text, an optional right-aligned one, the colour and font size
/// (`GameTooltipHeaderText` 14, `GameTooltipText` 12).
struct TipLine {
    left: String,
    right: Option<(String, Color)>,
    color: Color,
    size: f32,
}

impl TipLine {
    fn new(left: impl Into<String>, color: Color) -> Self {
        Self {
            left: left.into(),
            right: None,
            color,
            size: 12.0,
        }
    }

    fn right(mut self, text: impl Into<String>, color: Color) -> Self {
        self.right = Some((text.into(), color));
        self
    }

    fn header(mut self) -> Self {
        self.size = 14.0;
        self
    }
}

/// An item's tooltip: its name in its quality's colour, its slot, what it does and its price.
fn item_lines(item: &super::super::bag::Item, count: u32) -> Vec<TipLine> {
    use super::super::bag::{Kind, Use};
    let mut lines = vec![TipLine::new(item.name.clone(), item.quality.color()).header()];
    let green = Color::srgb_u8(30, 255, 0);
    match &item.kind {
        Kind::Junk => {}
        Kind::Gear { slot, stats } => {
            lines.push(TipLine::new(slot.name(), Color::WHITE));
            for &(stat, v) in stats {
                lines.push(TipLine::new(
                    super::super::bag::stat_line(stat, v),
                    Color::WHITE,
                ));
            }
        }
        Kind::Use(u) => {
            let what = match u.effect {
                Use::Heal(f) => format!("Use: Restores {:.0}% of your health.", f * 100.0),
                Use::Food(f, t) => format!(
                    "Use: Restores {:.0}% of your health over {t:.0} sec.",
                    f * t * 100.0
                ),
                Use::Swift(b, t) => {
                    format!("Use: Increases run speed by {:.0}% for {t:.0} sec.", b * 100.0)
                }
                Use::Bomb { on_self: true, .. } => {
                    "Use: Blows up everything around you.".to_string()
                }
                Use::Bomb { stun, .. } if stun > 0.0 => format!(
                    "Use: Thrown at the nearest enemy, wounding and stunning those near it for {stun:.0} sec."
                ),
                Use::Bomb { .. } => {
                    "Use: Thrown at the nearest enemy, wounding those near it.".to_string()
                }
            };
            lines.push(TipLine::new(what, green));
            lines.push(TipLine::new(
                format!("{} sec cooldown", num(u.cooldown)),
                Color::WHITE,
            ));
        }
    }
    let price = u64::from(item.sell) * u64::from(count.max(1));
    lines.push(TipLine::new(
        format!("Sell Price: {}", super::super::bag::money(price)),
        Color::WHITE,
    ));
    lines
}

fn item_tip(bag: &super::super::bag::Bag, i: usize, key: Option<usize>) -> Vec<TipLine> {
    let (item, count) = &bag.slots[i];
    let mut lines = item_lines(item, *count);
    if *count > 1 {
        lines.insert(1, TipLine::new(format!("{count} in the bag"), TIP_GREY));
    }
    let hint = match (&item.kind, key) {
        (super::super::bag::Kind::Use(_), Some(k)) => format!("Press {k}"),
        (super::super::bag::Kind::Use(_), None) => "Click to use.".to_string(),
        (super::super::bag::Kind::Gear { .. }, _) => "Click to wear it.".to_string(),
        (super::super::bag::Kind::Junk, _) => "Sold when the run ends.".to_string(),
    };
    lines.push(TipLine::new(hint, GOLD));
    lines
}

/// A number as the tooltips print it: whole when near enough, else to one decimal.

/// The results screen's tiles and its line under the title.
#[allow(clippy::type_complexity)]
pub(in crate::survivors) fn refresh_results(
    run: Res<Run>,
    selection: Res<Selection>,
    mut over_texts: ParamSet<(
        Query<(&OverStat, &mut Text)>,
        Query<&mut Text, With<OverLine>>,
    )>,
) {
    let secs = run.elapsed as u32;
    let stats_line = match (run.won, run.opened) {
        (true, Some(z)) => format!(
            "{}  A new zone is open: {}.",
            selection.map_def().victory,
            data::MAPS[z].name
        ),
        (true, None) => selection.map_def().victory.to_string(),
        (false, _) => "The horde was too much this time.".to_string(),
    };
    let stats_line = match (run.difficulty, run.raised) {
        (0, None) => stats_line,
        (d, None) => format!("{}: {stats_line}", super::super::difficulty::name(d)),
        (d, Some(open)) => format!(
            "{}: {stats_line}  {} is open.",
            super::super::difficulty::name(d),
            super::super::difficulty::name(open)
        ),
    };
    let stats_line = if run.loot.is_empty() {
        stats_line
    } else {
        let names: Vec<&str> = run.loot.iter().map(|p| p.name.as_str()).collect();
        format!("{stats_line}  Loot: {}.", names.join(", "))
    };
    let stats_line = if run.earned > 0 {
        let coins = run.bag.copper + run.bag.worth();
        let bonus = if run.earned > coins {
            format!(
                ", {} more for the difficulty",
                super::super::bag::money(run.earned - coins)
            )
        } else {
            String::new()
        };
        format!(
            "{stats_line}  Earned {} (looted {}, the bag sold for {}{bonus}).",
            super::super::bag::money(run.earned),
            super::super::bag::money(run.bag.copper),
            super::super::bag::money(coins - run.bag.copper)
        )
    } else {
        stats_line
    };
    let values = [
        format!("{:02}:{:02}", secs / 60, secs % 60),
        run.level.to_string(),
        run.kills.to_string(),
        compact(run.damage_done),
        run.bosses.to_string(),
    ];
    for (stat, mut t) in &mut over_texts.p0() {
        if let Some(v) = values.get(stat.0) {
            if **t != *v {
                **t = v.clone();
            }
        }
    }
    if let Ok(mut t) = over_texts.p1().single_mut() {
        if **t != stats_line {
            **t = stats_line;
        }
    }
}

/// 12.3k, 4.5M.
pub(super) fn compact(v: f64) -> String {
    if v >= 1e6 {
        format!("{:.1}M", v / 1e6)
    } else if v >= 1e4 {
        format!("{:.1}k", v / 1e3)
    } else {
        format!("{}", v.round() as u64)
    }
}

pub(super) fn num(v: f32) -> String {
    if (v - v.round()).abs() < 0.05 {
        format!("{}", v.round() as i64)
    } else {
        format!("{v:.1}")
    }
}

pub(super) fn pct(v: f32) -> String {
    format!("{}%", num(v * 100.0))
}

/// The numbers an ability casts with at a level, as [`super::super::abilities::cast_abilities`] takes
/// them from [`Owned`].
pub(super) struct Cast {
    pub(super) dmg: f32,
    pub(super) dot: f32,
    pub(super) count: u32,
    pub(super) radius: f32,
    pub(super) duration: f32,
    pub(super) cooldown: f32,
}

pub(super) fn cast_at(
    def: &'static AbilityDef,
    level: u8,
    stats: &Stats,
    bonus: crate::survivors::talents::Bonus,
) -> Cast {
    let o = Owned {
        def,
        level,
        cd: 0.0,
        bonus,
    };
    let mult = o.damage_mult() * stats.might;
    Cast {
        dmg: def.damage * mult,
        dot: def.dot * mult,
        count: o.count(),
        radius: o.radius(stats),
        duration: o.duration(),
        cooldown: o.cooldown(stats),
    }
}

fn effect_text(effect: Effect) -> Option<String> {
    Some(match effect {
        Effect::None => return None,
        Effect::Slow(m, t) => format!("slowing them by {} for {} sec", pct(1.0 - m), num(t)),
        Effect::Root(t) => format!("freezing them in place for {} sec", num(t)),
        Effect::Stun(t) => format!("stunning them for {} sec", num(t)),
        Effect::Fear(t) => format!("sending them fleeing for {} sec", num(t)),
        Effect::Weaken(m, t) => format!(
            "cutting their damage by {} for {} sec",
            pct(1.0 - m),
            num(t)
        ),
        Effect::Drain(f) => format!("healing you for {} of the damage", pct(f)),
        Effect::Execute(f) => format!("killing them outright below {} health", pct(f)),
    })
}

/// What an ability does at these numbers, in the voice of a spell description.
pub(super) fn ability_body(def: &AbilityDef, c: &Cast) -> String {
    let d = num(c.dmg);
    let burst = def.duration <= 0.0;
    let mut s = match def.kind {
        Kind::Bolt | Kind::Strike | Kind::Melee => {
            let toughest = matches!(def.key, "pyroblast" | "aimed_shot" | "exorcism" | "starfire");
            let melee = def.kind == Kind::Melee;
            let who = match (toughest, melee, c.count) {
                (true, _, 1) => "the toughest enemy in range".to_string(),
                (true, _, n) => format!("the {n} toughest enemies in range"),
                (false, true, 1) => "the closest enemy".into(),
                (false, true, n) => format!("the {n} closest enemies"),
                (false, false, 1) => "the nearest enemy".into(),
                (false, false, n) => format!("the {n} nearest enemies"),
            };
            let mut s = format!("{} {who} for {d} damage", if melee { "Strikes" } else { "Hits" });
            if c.radius > 0.0 && !melee {
                s += &format!(", and everything within {} yd of the hit", num(c.radius));
            }
            s
        }
        Kind::Nova => format!("Deals {d} damage to every enemy within {} yd of you", num(c.radius)),
        Kind::Cone => format!("Deals {d} damage to every enemy in a {} yd cone toward the closest", num(c.radius)),
        Kind::Ground | Kind::GroundSelf => {
            let at = if def.kind == Kind::GroundSelf { "around you" } else { "on the thickest pack" };
            if burst {
                format!("Strikes a {} yd area {at} for {d} damage", num(c.radius))
            } else {
                format!(
                    "Covers a {} yd area {at} for {} sec, dealing {d} damage every second",
                    num(c.radius),
                    num(c.duration)
                )
            }
        }
        Kind::Chain => format!(
            "Strikes the nearest enemy for {d} damage, then jumps to {} more within {} yd of each other, 15% weaker with every jump",
            c.count,
            num(c.radius)
        ),
        Kind::Dot => format!(
            "Afflicts {} enemies in range with {} damage every second for {} sec",
            c.count,
            num(c.dot),
            num(c.duration)
        ),
        Kind::Aura => format!(
            "Every {} sec, deals {d} damage to every enemy within {} yd of you",
            num(c.cooldown),
            num(c.radius)
        ),
        Kind::Orbit => format!(
            "Every {} sec, zaps {} within {} yd of you for {d} damage",
            num(c.cooldown),
            if c.count == 1 { "an enemy".to_string() } else { format!("{} enemies", c.count) },
            num(c.radius)
        ),
        Kind::Shield => format!("Absorbs the next {d} damage you take within {} sec", num(c.duration)),
        Kind::Immune => format!(
            "When an enemy closes in, makes you immune to all damage for {} sec",
            num(c.duration)
        ),
        Kind::Thorns => format!(
            "When enemies close in, deals {d} damage to every attacker for {} sec",
            num(c.duration)
        ),
        Kind::Heal => format!("Below 85% health, heals you for {d} over {} sec", num(c.duration)),
        Kind::Totem if def.key == "magma_totem" => format!(
            "Drops a totem for {} sec that burns every enemy within {} yd for {d} damage every 2 sec",
            num(c.duration),
            num(c.radius)
        ),
        Kind::Totem => format!(
            "Drops a totem for {} sec that hits the nearest enemy within {} yd for {d} damage every second",
            num(c.duration),
            num(def.range)
        ),
    };
    // Areas that tick carry no over-time part; a burst leaves a 5 second one.
    let ground = matches!(def.kind, Kind::Ground | Kind::GroundSelf);
    if c.dot > 0.0 && def.kind != Kind::Dot && (!ground || burst) {
        let secs = if ground { 5.0 } else { c.duration };
        s += &format!(
            ", then {} damage every second for {} sec",
            num(c.dot),
            num(secs)
        );
    }
    if let Some(e) = effect_text(def.effect) {
        s += ", ";
        s += &e;
    }
    s.push('.');
    s
}

/// What the next rank changes, at the current stats.
fn next_rank(def: &AbilityDef, now: &Cast, next: &Cast) -> String {
    let what = match def.kind {
        Kind::Shield => "absorbed",
        Kind::Heal => "healing",
        _ => "damage",
    };
    let mut gains = Vec::new();
    if next.dmg > 0.0 && def.kind != Kind::Dot && def.kind != Kind::Immune {
        gains.push(format!("{} {what}", num(next.dmg)));
    }
    if next.dot > 0.0 {
        gains.push(format!("{} damage per second", num(next.dot)));
    }
    if next.count != now.count
        && matches!(
            def.kind,
            Kind::Bolt | Kind::Strike | Kind::Melee | Kind::Dot | Kind::Chain | Kind::Orbit
        )
    {
        gains.push(match def.kind {
            Kind::Chain => format!("{} jumps", next.count),
            _ => format!("{} targets", next.count),
        });
    }
    if next.radius > 0.0 {
        gains.push(format!("{} yd", num(next.radius)));
    }
    if next.duration > 0.0 {
        gains.push(format!("{} sec", num(next.duration)));
    }
    gains.push(format!("{} sec cooldown", num(next.cooldown)));
    gains.join(", ")
}

fn ability_tip(
    o: &Owned,
    stats: &Stats,
    spells: Option<&crate::ui_action::Spells>,
) -> Vec<TipLine> {
    let def = o.def;
    let now = cast_at(def, o.level, stats, o.bonus);
    let mut lines = vec![
        TipLine::new(spell_name(spells, def.spell, def.key), Color::WHITE)
            .header()
            .right(format!("Rank {}", o.level), TIP_GREY),
    ];
    let range = match def.kind {
        Kind::Melee => Some("Melee Range".to_string()),
        Kind::Bolt | Kind::Strike | Kind::Chain | Kind::Dot | Kind::Ground | Kind::Totem => {
            Some(format!("{} yd range", num(def.range)))
        }
        _ => None,
    };
    let mut cast = TipLine::new("Casts itself", Color::WHITE);
    if let Some(range) = range {
        cast = cast.right(range, Color::WHITE);
    }
    lines.push(cast);
    lines.push(
        TipLine::new("Instant", Color::WHITE)
            .right(format!("{} sec cooldown", num(now.cooldown)), Color::WHITE),
    );
    lines.push(TipLine::new(ability_body(def, &now), GOLD));
    if !matches!(
        def.kind,
        Kind::Shield | Kind::Immune | Kind::Heal | Kind::Dot
    ) {
        lines.push(TipLine::new(
            format!(
                "{} chance to critically strike for double damage",
                pct(stats.crit)
            ),
            DIM,
        ));
    }
    if o.level < data::MAX_ABILITY_LEVEL {
        let next = cast_at(def, o.level + 1, stats, o.bonus);
        lines.push(TipLine::new("Next rank:", Color::WHITE));
        lines.push(TipLine::new(next_rank(def, &now, &next), GOLD));
    } else {
        lines.push(TipLine::new("Highest rank", DIM));
    }
    lines
}

/// What a passive's bonus `v` does, in the voice of a buff.
/// A stat's short name, for the card's before » after line.
pub(super) fn stat_label(stat: Stat) -> &'static str {
    match stat {
        Stat::Might => "All damage",
        Stat::MaxHp => "Maximum health",
        Stat::Speed => "Movement speed",
        Stat::Regen => "Health per second",
        Stat::Haste => "Recharge speed",
        Stat::Area => "Area size",
        Stat::Magnet => "Pickup range",
        Stat::Growth => "Experience gained",
        Stat::Armor => "Damage blocked per hit",
        Stat::Crit => "Critical strike chance",
    }
}

pub(super) fn passive_text(stat: Stat, v: f32) -> String {
    match stat {
        Stat::Might => format!("Increases all damage you deal by {}.", pct(v)),
        Stat::MaxHp => format!("Increases your maximum health by {}.", pct(v)),
        Stat::Speed => format!("Increases your movement speed by {}.", pct(v)),
        Stat::Regen => format!("Restores {} health every second.", num(v)),
        Stat::Haste => format!("Your abilities recharge {} faster.", pct(v)),
        Stat::Area => format!("Increases the size of your areas of effect by {}.", pct(v)),
        Stat::Magnet => format!("Increases your pickup range by {}.", pct(v)),
        Stat::Growth => format!("Increases the experience you gain by {}.", pct(v)),
        Stat::Armor => format!("Reduces the damage of every hit you take by {}.", num(v)),
        Stat::Crit => format!(
            "Increases your chance to critically strike for double damage by {}.",
            pct(v)
        ),
    }
}

/// The hero's total for the stat a passive raises, every source counted.
fn stat_total(stat: Stat, s: &Stats) -> String {
    match stat {
        Stat::Might => format!("Damage dealt: {}", pct(s.might)),
        Stat::MaxHp => format!("Maximum health: {}", num(s.max_hp)),
        Stat::Speed => format!("Movement speed: {} yd per second", num(s.speed)),
        Stat::Regen => format!("Health restored: {} per second", num(s.regen)),
        Stat::Haste => format!("Cooldowns: {} shorter", pct(s.haste.min(0.65))),
        Stat::Area => format!("Area of effect: {}", pct(s.area)),
        Stat::Magnet => format!("Pickup range: {} yd", num(s.magnet)),
        Stat::Growth => format!("Experience gained: {}", pct(s.growth)),
        Stat::Armor => format!("Damage blocked per hit: {}", num(s.armor)),
        Stat::Crit => format!("Critical strike chance: {}", pct(s.crit)),
    }
}

fn passive_tip(p: &PassiveDef, level: u8, stats: &Stats) -> Vec<TipLine> {
    let mut lines = vec![
        TipLine::new(p.name, Color::WHITE)
            .header()
            .right(format!("Rank {level}"), TIP_GREY),
        TipLine::new(passive_text(p.stat, p.per_level * f32::from(level)), GOLD),
        TipLine::new(stat_total(p.stat, stats), Color::WHITE),
    ];
    if level < data::MAX_PASSIVE_LEVEL {
        lines.push(TipLine::new("Next rank:", Color::WHITE));
        lines.push(TipLine::new(
            passive_text(p.stat, p.per_level * f32::from(level + 1)),
            GOLD,
        ));
    } else {
        lines.push(TipLine::new("Highest rank", DIM));
    }
    lines
}

/// The `GameTooltip` frame: `UI-Tooltip-Background` tiled under `UI-Tooltip-Border`, 16-unit edges
/// and 5-unit insets, its lines 10 units in. Returns the frame and its line column.
fn spawn_tooltip(
    commands: &mut Commands,
    assets: &mut benilla_assets::WorldAssets,
    images: &mut Assets<Image>,
    ui_scale: f32,
) -> (Entity, Entity) {
    use crate::glue::backdrop::{backdrop_border, backdrop_edges, tiled_bg_node};
    let bg = assets.sprite_texture("Interface\\Tooltips\\UI-Tooltip-Background", images);
    let edges = backdrop_edges(assets, "Interface\\Tooltips\\UI-Tooltip-Border", images);
    let mut body = Entity::PLACEHOLDER;
    let mut root = commands.spawn((
        GameTooltip,
        Node {
            position_type: PositionType::Absolute,
            max_width: Val::Px(300.0),
            ..default()
        },
        GlobalZIndex(1000),
        Visibility::Hidden,
        bevy::ui::FocusPolicy::Pass,
    ));
    if bg.is_none() || edges.is_none() {
        root.insert(BackgroundColor(TIP_FILL.with_alpha(0.95)));
    }
    root.with_children(|t| {
        if let Some(bg) = bg {
            t.spawn((
                tiled_bg_node(bg, 16.0, ui_scale, TIP_FILL),
                Node {
                    position_type: PositionType::Absolute,
                    left: Val::Px(5.0),
                    right: Val::Px(5.0),
                    top: Val::Px(5.0),
                    bottom: Val::Px(5.0),
                    ..default()
                },
            ));
        }
        if let Some(edges) = &edges {
            backdrop_border(t, edges, 16.0, Color::WHITE);
        }
        body = t
            .spawn((
                TipBody,
                Node {
                    flex_direction: FlexDirection::Column,
                    row_gap: Val::Px(2.0),
                    padding: UiRect::all(Val::Px(10.0)),
                    ..default()
                },
            ))
            .id();
    });
    (root.id(), body)
}

/// Hovering a build icon raises its `GameTooltip` over the bar's right end, every number from the current
/// rank and stats, and what the next rank brings.
#[allow(clippy::too_many_arguments)]
pub(in crate::survivors) fn icon_tooltip(
    mut commands: Commands,
    phase: Res<State<Phase>>,
    run: Res<Run>,
    spells: Option<Res<crate::ui_action::Spells>>,
    font: Res<HudFont>,
    ui_scale: Res<UiScale>,
    mut assets: Option<ResMut<benilla_assets::WorldAssets>>,
    mut images: ResMut<Assets<Image>>,
    slots: Query<(&Interaction, &TipFor)>,
    mut frames: Query<(&mut Node, &mut Visibility), With<GameTooltip>>,
    mut built: Local<Option<(Entity, Entity)>>,
    mut shown: Local<Option<(TipFor, u32)>>,
) {
    let Some((frame, body)) = *built else {
        if let Some(assets) = assets.as_deref_mut() {
            *built = Some(spawn_tooltip(
                &mut commands,
                assets,
                &mut images,
                ui_scale.0,
            ));
        }
        return;
    };
    let Ok((mut node, mut vis)) = frames.get_mut(frame) else {
        return;
    };
    let hovered = slots
        .iter()
        .find(|(i, ..)| **i != Interaction::None)
        .filter(|_| *phase.get() != Phase::Menu);
    let Some((_, &tip)) = hovered else {
        if *vis != Visibility::Hidden {
            *vis = Visibility::Hidden;
        }
        *shown = None;
        return;
    };
    // An action button's tooltip takes `GameTooltip_SetDefaultAnchor`'s place: BOTTOMRIGHT of
    // the screen, (−CONTAINER_OFFSET_X − 13, CONTAINER_OFFSET_Y), over the bar.
    let (right, bottom) = (Val::Px(13.0), Val::Px(70.0));
    if node.right != right || node.bottom != bottom {
        node.right = right;
        node.bottom = bottom;
    }
    if *shown == Some((tip, run.version)) {
        if *vis != Visibility::Inherited {
            *vis = Visibility::Inherited;
        }
        return;
    }
    let stats = run.stats();
    let lines = match tip {
        TipFor::Ability(i) => run
            .abilities
            .get(i)
            .map(|o| ability_tip(o, &stats, spells.as_deref())),
        TipFor::Passive(i) => run
            .passives
            .get(i)
            .map(|&(p, level)| passive_tip(p, level, &stats)),
        TipFor::Mobility => run.mobility().map(|m| {
            vec![
                TipLine::new(spell_name(spells.as_deref(), m.spell, m.name), Color::WHITE).header(),
                TipLine::new("Press F", Color::WHITE)
                    .right(format!("{} sec cooldown", num(m.cooldown)), Color::WHITE),
                TipLine::new(m.desc, GOLD),
            ]
        }),
        TipFor::Quick(k) => run
            .bag
            .quick()
            .get(k)
            .map(|&i| item_tip(&run.bag, i, Some(k + 1))),
        TipFor::Bag(super::super::panels::BagCell::Slot(i)) => {
            run.bag.slots.get(i).map(|_| item_tip(&run.bag, i, None))
        }
        TipFor::Bag(super::super::panels::BagCell::Worn(i)) => {
            run.bag.worn.get(i).and_then(Option::as_ref).map(|item| {
                let mut lines = item_lines(item, 1);
                lines.push(TipLine::new("Click to take it off.", GOLD));
                lines
            })
        }
        TipFor::Backpack => Some(vec![
            TipLine::new("Backpack", Color::WHITE).header(),
            TipLine::new(
                format!(
                    "{} of {} slots used",
                    run.bag.slots.len(),
                    super::super::bag::BAG_SLOTS
                ),
                Color::WHITE,
            ),
            TipLine::new(
                format!("Looted: {}", super::super::bag::money(run.bag.copper)),
                Color::WHITE,
            ),
            TipLine::new("Press B", GOLD),
        ]),
        TipFor::Loot(i) => run.loot.get(i).map(|p| {
            vec![
                TipLine::new(p.name.clone(), Color::srgb(0.64, 0.21, 0.93)).header(),
                TipLine::new(p.slot.name(), Color::WHITE).right(
                    super::super::gear::sets(run.class.id)[p.set].name,
                    Color::WHITE,
                ),
                TipLine::new("Dropped this run. Yours for good: worn on every run.", GOLD),
            ]
        }),
    };
    let Some(lines) = lines else { return };
    *shown = Some((tip, run.version));
    // Shown from the next frame, once the new lines have laid out.
    *vis = Visibility::Hidden;
    let f = &font.0;
    commands.entity(body).despawn_related::<Children>();
    commands.entity(body).with_children(|b| {
        for line in lines {
            let face = |s: String, size: f32, color: Color| {
                (
                    Text::new(s),
                    TextFont {
                        font: f.clone(),
                        font_size: size,
                        ..default()
                    },
                    TextColor(color),
                    TextShadow {
                        offset: Vec2::splat(1.0),
                        color: Color::BLACK,
                    },
                )
            };
            b.spawn(Node {
                justify_content: JustifyContent::SpaceBetween,
                column_gap: Val::Px(16.0),
                ..default()
            })
            .with_children(|row| {
                row.spawn(face(line.left, line.size, line.color));
                if let Some((text, color)) = line.right {
                    row.spawn((
                        face(text, line.size, color),
                        TextLayout::new(Justify::Right, LineBreak::NoWrap),
                    ));
                }
            });
        }
    });
}
