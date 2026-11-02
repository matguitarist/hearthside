//! Alt-Z hides the whole interface for a clean screenshot, as in WoW: every bevy_ui node is drawn
//! hidden while it is on. The nodes' own `Visibility` is left alone, so nothing has to be put back:
//! turning it off marks them changed, and Bevy's propagation works their visibility out again.
//! Any screen but the run itself (level-up cards, pause, results) shows the interface again, so a
//! choice is never waiting unseen.

use bevy::camera::visibility::{InheritedVisibility, VisibilitySystems};
use bevy::prelude::*;

use super::Phase;

/// Whether Alt-Z has hidden the interface.
#[derive(Resource, Default)]
pub(super) struct UiHidden(pub bool);

pub(super) fn plugin(app: &mut App) {
    app.init_resource::<UiHidden>()
        .add_systems(Update, toggle)
        .add_systems(OnExit(Phase::Playing), show)
        .add_systems(
            PostUpdate,
            hide.after(VisibilitySystems::VisibilityPropagate),
        );
}

fn toggle(
    keys: Res<ButtonInput<KeyCode>>,
    phase: Res<State<Phase>>,
    mut hidden: ResMut<UiHidden>,
    nodes: Query<&mut Visibility, With<Node>>,
) {
    let alt = keys.any_pressed([KeyCode::AltLeft, KeyCode::AltRight]);
    if alt && keys.just_pressed(KeyCode::KeyZ) && (hidden.0 || *phase.get() == Phase::Playing) {
        hidden.0 = !hidden.0;
        if !hidden.0 {
            reveal(nodes);
        }
    }
}

fn show(mut hidden: ResMut<UiHidden>, nodes: Query<&mut Visibility, With<Node>>) {
    if hidden.0 {
        hidden.0 = false;
        reveal(nodes);
    }
}

/// Every node's visibility worked out again on this frame's propagation.
fn reveal(mut nodes: Query<&mut Visibility, With<Node>>) {
    for mut v in &mut nodes {
        v.set_changed();
    }
}

fn hide(hidden: Res<UiHidden>, mut nodes: Query<&mut InheritedVisibility, With<Node>>) {
    if hidden.0 {
        for mut v in &mut nodes {
            *v = InheritedVisibility::HIDDEN;
        }
    }
}

#[cfg(test)]
mod tests {
    use bevy::camera::visibility::VisibilityPlugin;
    use bevy::state::app::StatesPlugin;

    use super::*;

    fn app() -> (App, Entity, Entity) {
        let mut app = App::new();
        app.add_plugins((MinimalPlugins, StatesPlugin, VisibilityPlugin))
            .init_resource::<ButtonInput<KeyCode>>()
            // `VisibilityPlugin` computes meshes' bounds too.
            .init_resource::<Assets<Mesh>>()
            .init_state::<Phase>()
            .add_plugins(plugin);
        let child = app.world_mut().spawn(Node::default()).id();
        let root = app.world_mut().spawn(Node::default()).add_child(child).id();
        app.world_mut().resource_mut::<NextState<Phase>>().set(Phase::Playing);
        app.update();
        (app, root, child)
    }

    fn shown(app: &App, e: Entity) -> bool {
        app.world().get::<InheritedVisibility>(e).unwrap().get()
    }

    fn alt_z(app: &mut App) {
        let mut keys = app.world_mut().resource_mut::<ButtonInput<KeyCode>>();
        keys.press(KeyCode::AltLeft);
        keys.press(KeyCode::KeyZ);
        app.update();
        let mut keys = app.world_mut().resource_mut::<ButtonInput<KeyCode>>();
        keys.release(KeyCode::KeyZ);
        keys.release(KeyCode::AltLeft);
        keys.clear();
        app.update();
    }

    #[test]
    fn alt_z_hides_then_shows_every_node() {
        let (mut app, root, child) = app();
        assert!(shown(&app, root) && shown(&app, child));
        alt_z(&mut app);
        assert!(!shown(&app, root) && !shown(&app, child));
        alt_z(&mut app);
        assert!(shown(&app, root) && shown(&app, child));
    }

    #[test]
    fn leaving_the_run_shows_it_again() {
        let (mut app, root, _) = app();
        alt_z(&mut app);
        assert!(!shown(&app, root));
        app.world_mut().resource_mut::<NextState<Phase>>().set(Phase::LevelUp);
        app.update();
        app.update();
        assert!(shown(&app, root));
    }

    #[test]
    fn a_node_hidden_by_its_screen_stays_hidden() {
        let (mut app, root, _) = app();
        app.world_mut().entity_mut(root).insert(Visibility::Hidden);
        app.update();
        alt_z(&mut app);
        alt_z(&mut app);
        assert!(!shown(&app, root));
    }
}
