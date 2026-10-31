# Working in this repository

Azeroth Survivors is a WoW-roguelike mode on a from-scratch WoW 1.12.1 client in Rust + Bevy:
[benilla](https://github.com/samwhosung/benilla), by way of its browser fork
[wenilla](https://github.com/Arnesen/wenilla) and the original port
[OutThisLife/azeroth-survivors-re](https://github.com/OutThisLife/azeroth-survivors-re). This
fork builds the game **natively only**, with a macOS app around it. The browser build, its local
host and its page were removed; the original still ships one at [wow.aethus.pl](https://wow.aethus.pl/).
Upstream's own map and rules for the client crates are `docs/METHOD.md`, `docs/MAP.md` and
`docs/CONTRIBUTING.md`; read them before changing client code.

## What lives where

| path | what |
|---|---|
| `crates/benilla-*` | the client: formats, world, UI, protocol, app |
| `crates/benilla-app/src/survivors/` | the survivors mode |
| `crates/warcraft-survivors` | the game binary |
| `macos/`, `scripts/macos-app.sh` | Hearthside.app: the Swift launcher, Sparkle updates, the signed app (`macos/README.md`) |
| `macos/Server/` | the launcher's local Classic servers: vmangos-deploy compose file and configs; `CMaNGOS/`, the recipe for CMaNGOS with playerbots, built on the Mac or a home server (`home-setup`, `home-compose`) |
| `addons/` | addons the app installs for Classic: `AzerothPlus` (QoL), `AzerothAdmin` (GM window for the local server); Lua 5.0, so they also run on the original client |
| `scripts/fetch-data.sh` | downloads the 1.12.1 client and extracts its MPQs into `wow-data/Data` |
| `third_party/` | vendored Lua 5.1 (`lua-src`) and kira, each with a `BENILLA.md` of its hunks |
| `.github/workflows/` | `ci.yml` (fmt, clippy, tests), `check.yml` (quick UI/carry regressions), `macos-release.yml` |

## Commands

```bash
make native                 # fetch data if missing, build and run the game
cargo build --release -p warcraft-survivors
WOW_DATA="$PWD/wow-data/Data" ./target/release/warcraft-survivors
WOW_DATA="$PWD/wow-data/Data" ./target/release/warcraft-survivors --classic   # the original game; needs a 1.12 server at `realmList`
make app                    # the signed macOS app into target/macos/
cargo check --workspace --all-targets      # Debian/Ubuntu: libasound2-dev libudev-dev
cargo test --release -p benilla-app survivors
cargo test --workspace                     # ~320 tests need a 1.12.1 patch chain and fail without one
```

## Notes

- **The wasm target is not built.** The engine files still hold `#[cfg(target_arch = "wasm32")]`
  arms inherited from wenilla; they compile to nothing natively and are left in place so merges
  from the original stay small. New code does not need a wasm arm, a `web-time` clock or a
  threadless path.
- **Touch upstream files lightly.** The original keeps evolving the engine; every changed line in
  a shared file is a potential conflict at the next merge. New work goes in new files where it can.
- **`ring_reaction` returns 0..7**; every consumer adds `+ 1` for the Lua 1..8 scale.
- **`gh pr create` needs an explicit `-R`.** Without it `gh` may target the fork's parent.
