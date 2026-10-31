//! The `warcraft-survivors` launcher: the build stamp, handed to the survivors mode, or with
//! `--classic` to benilla's own client, which logs on to a 1.12 server at the `realmList` address.
//! `--account-sql` serves the launcher's local server instead ([`account`]), `--world-maps` its
//! home server's dashboard ([`world_maps`]).

mod account;
mod world_maps;

use benilla_app::BuildId;

fn main() -> benilla_app::AppExit {
    if std::env::args().nth(1).as_deref() == Some("--account-sql") {
        return if account::run(std::env::args().nth(2).as_deref() == Some("password")) {
            benilla_app::AppExit::Success
        } else {
            benilla_app::AppExit::error()
        };
    }
    if std::env::args().nth(1).as_deref() == Some("--world-maps") {
        return if world_maps::run(
            std::env::args().nth(2).as_deref(),
            std::env::args().nth(3).as_deref(),
        ) {
            benilla_app::AppExit::Success
        } else {
            benilla_app::AppExit::error()
        };
    }
    let build = BuildId {
        version: env!("CARGO_PKG_VERSION"),
        describe: env!("BENILLA_GIT_DESCRIBE"),
        sha: env!("BENILLA_GIT_SHA"),
        short: env!("BENILLA_GIT_SHORT"),
        date: env!("BENILLA_GIT_DATE"),
        profile: env!("BENILLA_PROFILE"),
        project_dir: env!("BENILLA_PROJECT_DIR"),
        ..Default::default()
    };
    if std::env::args().skip(1).any(|a| a == "--classic") {
        benilla_app::run(build)
    } else {
        benilla_app::run_survivors(build)
    }
}
