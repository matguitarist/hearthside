# The macOS app

`Hearthside.app` (called Azeroth Survivors up to 0.7.3) is a small Swift launcher with the game
beside it, for Survivors, Classic 1.12 and Mists of Pandaria 5.4.8:

```
Hearthside.app/Contents/
  MacOS/Hearthside           the launcher (macos/Launcher/*.swift)
  MacOS/warcraft-survivors    the game: a player build (--no-default-features), ship profile
  Frameworks/Sparkle.framework
  Resources/                  icon, key art, data-manifest.tsv
  Resources/Server/           the local server's compose.yaml and configs (macos/Server),
                              the CMaNGOS and Pandaria recipes, Pandaria's 5.4.8 addons
  Resources/AddOns/           Classic's shipped addons (addons/), copied into benilla-config/AddOns
```

The launcher:

- **Downloads the game data** on first run into `~/Library/Application Support/Hearthside/Data`.
  No Blizzard files ship in the app. It reads the archive.org zip's directory over HTTP Range
  requests and fetches each MPQ's own byte range, three at a time (archive.org paces each
  connection), so every file resumes on its own and only a missing or damaged file is fetched
  again. Each file is checked against `scripts/data-manifest.tsv` (SHA-256). The Dock icon shows
  the progress, and a notification says when it's done if the launcher isn't in front. Settings
  can point at an existing 1.12.1 `Data` folder instead.
- **Edits the game's settings** (graphics with Performance / Balanced / Quality presets, sound):
  the cvars in `benilla-config/config.toml`,
  kept in Application Support (`$BENILLA_HOME`), never inside the bundle. The game is only told
  what it already reads at boot; the launcher edits the file only while the game is closed.
- **Plays Survivors or Classic.** Classic is the original game (`warcraft-survivors --classic`),
  on a 1.12.1 server: at an address (the game's `realmList`), or **on this Mac**. benilla has no
  Warden, so a server that requires it refuses the connection; vmangos ships with it off.
- **Runs the server on this Mac** in Docker (OrbStack or Docker Desktop), from
  [vmangos-deploy](https://github.com/mserajnik/vmangos-deploy)'s prebuilt images
  (`LocalServer.swift`). Setup copies `macos/Server` (CC0, from that project's examples) to
  `Application Support/Hearthside/Server`, pulls the images (about 1 GB), reads the terrain
  and DBCs from the game's own Data folder in seconds, and builds the world database (about
  2.5 minutes in all). That quick data plays without line of sight or pathing. Settings › Server
  runs the full extraction in the background (hours); the next start swaps it in, and rolls back
  to the quick data if it does not start. Accounts are created from the launcher: the game binary
  computes the SRP6 salt and verifier (`--account-sql`, name and password on stdin) and the
  launcher feeds the SQL to the database container. The server starts as the launcher opens in
  that mode (each start takes about a minute: vmangos-deploy checks its migrations), and stops when
  the game or the launcher quits unless Settings keeps it. Ports bind to 127.0.0.1. Commands and
  their output go to `~/Library/Logs/Hearthside/server.log`, never stdin.
- **Or CMaNGOS with bots** (the Server picker): [CMaNGOS Classic](https://github.com/cmangos/mangos-classic)
  with the [playerbots](https://github.com/cmangos/playerbots) module and
  [classic-db](https://github.com/cmangos/classic-db), built on the Mac at setup from
  `macos/Server/CMaNGOS/Dockerfile` (no arm64 images exist, and playerbots has no license, so the
  app ships the recipe, not a binary): about 25 minutes with the maps, each source pinned to a tested commit.
  It lives in `Application Support/Hearthside/Server-CMaNGOS` (project
  `azeroth-survivors-cmangos`), with its own databases and accounts, on the same ports, so starting
  one stops the other. The image carries its configs: anticheat off (with it on, CMaNGOS arms
  Warden for every session, whatever `Warden.Enable` says), 100 random bots. The bots cannot run
  without line of sight and movement maps (they assert a navmesh), so setup builds the full data:
  CMaNGOS's own map extractor crashes on arm64, so vmangos's `MapExtractor`, `VMapExtractor` and
  `VMapAssembler` read the game files (the same `z1.4` maps and `VMAP_7.0` models, about a
  minute), then CMaNGOS's `MoveMapGen` builds its own movement maps (`MMAP_VERSION` 8, vmangos's
  are 6) on every core: about 7 minutes and 1.8 GB on a 10-core Mac. Two guards stay patched in
  case a map lacks them: a grid load skips a missing navmesh tile (`MoveMap.cpp`), and the bots'
  nearest-point lookup finds nothing instead of asserting (`WorldPosition.cpp`). `cmangos-install` builds the databases,
  removes the base SQL's four default accounts and names the realm `Azeroth (bots)`, which is how
  AzerothAdmin knows to send CMaNGOS's commands. Administrators are `gmlevel` 3; the random bots'
  `RNDBOT` accounts are left out of the launcher's list.
- **Or the same CMaNGOS on a home server** (Classic › Home server, Settings › Home Server;
  `HomeServer.swift`): an always-on Linux machine with Docker on the network, an Unraid box say,
  driven over SSH with a key the launcher can make (`BatchMode`, no passphrase, the host's key
  accepted on first use). Setup rsyncs the recipe and the seven MPQs the map tools read into
  `/mnt/user/appdata/azeroth-survivors-cmangos` (Unraid) or `~/azeroth-survivors-cmangos`, writes
  an `.env` (`LAN_IP` from the address, `BOTS`, `BOT_ACCOUNTS`), and starts `home-setup` there
  detached: the same steps, an hour or two on a small CPU, its step in `.setup-step`, then
  `.setup-done` or `.setup-failed`, so the launcher can quit and pick it up again. Everything after
  goes through `home-compose` (the server's `docker compose`, or the `docker:29-cli` image's where
  there is none, as on Unraid) with `compose.lan.yaml` on top: ports on the LAN address, restarts
  with the machine, kept running when the game quits. Accounts are the same `--account-sql` and
  SQL, fed to `docker exec` of its database. Settings › Bots & Rates rewrites
  `.env` keys (`BOTS`, `BOTS_NEAR_PLAYERS`, `BOTS_SYNC_LEVEL`, `RATE_XP`, `RATE_LOOT`, `RATE_GOLD`,
  `RATE_REPUTATION`, `RATE_REST`, and the auction house bot's `AH_ENABLED`, `AH_PRICES`, `AH_STOCK`)
  that `compose.yaml` passes on as CMaNGOS (`Mangosd_`), playerbots (`PlayerBots_`) and AhBot
  (`AHBot_`) settings, the stock by scaling every `AhBot.MaxAuctionCount` in `ahbot.conf` from its
  pristine copy as `mangosd` starts, then recreate `mangosd`; bringing bots to players also
  shortens how often they move on (`BOTS_MOVE_MIN`, `BOTS_MOVE_MAX`). The launcher keeps the
  server's scripts and compose files current on each look. `home-status` writes the server's state
  (players, bots by level and where they are, auctions, CPU and memory, backups, software,
  settings, the latest real errors)
  into `storage/dashboard/` every minute from cron, with a day of history, and the `dashboard`
  container (`nginx`, read-only, no Docker socket or database password) serves it with
  `dashboard.html` at `http://<LAN_IP>:8095` for any browser at home; it stays up while the game is
  stopped; its world map shows every bot and player on the two continents, over map pictures the
  launcher draws from this Mac's game files (`warcraft-survivors --world-maps`) and copies over,
  as none ship in the repository. Settings › Home Server shows the same live, with Open Dashboard. Nothing is forwarded to the internet. `home-backup` dumps the accounts and characters
  nightly at 4:30 (a dynamix cron file on Unraid, else root's crontab; to
  `/mnt/user/backups/azeroth-survivors-cmangos`, else `backups/`, 14 kept), and Settings › Backups & Updates backs up and restores on demand, a restore saving the state
  it replaces first. `home-update check` compares the commits the image was built from (`.refs`,
  else the Dockerfile's pins) with the newest on GitHub; Update Server… starts `home-update run`
  detached (`.update-step`, `update.log`): it backs up, rebuilds the image, reinstalls the world
  database from classic-db with the core's migrations (never `-InstallAll`), rebuilds the movement
  maps only when their format moved, and on any failure puts back the old image, world, maps and
  backup. It refuses a core whose terrain or line-of-sight format moved, which vmangos's extractor
  cannot follow.
- **Plays Pandaria** (the third mode; `Pandaria.swift`, `PandariaView.swift`, Settings › Pandaria):
  Mists of Pandaria 5.4.8 with bots, from
  [LoA-Pandaria-Playerbots](https://github.com/1LineAtaTime/LoA-Pandaria-Playerbots) (TrinityCore),
  on the home server beside CMaNGOS in `azeroth-survivors-pandaria` (project of the same name), on
  the same ports, so starting one stops the other. It plays with the player's own World of
  Warcraft 5.4.8 for Mac (its folder chosen in the launcher; nothing of it ships). Set Up rsyncs
  `macos/Server/Pandaria` and the client's `Data` (about 23 GB) there, writes `LAN_IP` and
  `CLIENT_DATA` to `.env`, and starts `home-setup` detached, as for CMaNGOS: the image built from
  source (a few hours), `install`, the maps read from the client, then the servers, each step
  skipped once done. Accounts are SQL fed to `docker exec` of its database:
  `sha_pass_hash` = SHA1(`NAME:PASSWORD`) uppercased, computed on the Mac (`v`, `s` cleared on a
  new password), administrators `account_access` gmlevel 3 on every realm (-1); the `RNDBOT`
  accounts are left out and counted as bots online. The first Play prepares the client with
  `mac-client-setup` (the connection patches of `mac-client-patch.py`, `glhook.dylib` with the
  OpenGL fixes and FSR in place of the removed `libcrypto.0.9.8`, an ad hoc signature, the
  realmlist, the addons); it runs under Rosetta and needs the command line developer tools. Later
  Plays only write the realmlist and the addons. Its logs (`storage/logs`) are in the Logs window.
- **Installs AzerothPlus and AzerothAdmin** for Classic (`Addons.swift`, Settings › General):
  before each Classic launch the shipped addons replace their folders in `benilla-config/AddOns`,
  so the app's version is the one that runs; other addons there are untouched, and saved settings
  live in `benilla-config/saved`. AzerothPlus (`/ap` or its minimap button) adds a cooldown manager, a
  damage meter, a swing timer, a personal resource display, smaller centered unit frames, an "All
  objectives" tracker, a windowed map with the zone's quests, quest markers on the map and minimap
  (`questmap.lua`; its places, `questdb.lua`, come from the CMaNGOS world database through
  `scripts/questdb-dump.sh` and `scripts/questdb.py`), minimap coordinates and movable buff icons,
  quest levels in the log and automatic quest accept and hand-in, vendor prices, health numbers and
  quest progress in tooltips (`infodb.lua`, from the same dump through `scripts/infodb.py`), grey
  selling, auto-repair, a bag search box and a bot party panel (`/ap bots`), each a box on a tab of
  its options; `scripts/addon-tests/` runs them against a stubbed client. AzerothAdmin sends vmangos GM commands, respelled for CMaNGOS
  (`AA.CMANGOS`, with its own Bots page), so it needs an administrator account (`gmlevel` 6 on
  vmangos, 3 on CMaNGOS, set per account in Settings › Server; new accounts default to it). The shipped `mangosd.conf` starts a GM as a player (`GM.LoginState = 0`,
  `GM.Visible = 1`, `GM.CheatGod = 0`); `migrateConf` applies that once to older copies
  (`config/.version`).
- **Updates itself** with [Sparkle](https://sparkle-project.org) from the feed at
  `https://github.com/<repo>/releases/latest/download/appcast.xml`.
- Logs the game to `~/Library/Logs/Hearthside/game.log` and shows its tail on a crash. The Logs window (Game › Show Logs, ⌘L; `LogViewer.swift`) reads it, the server on this Mac and the home server's logs (over SSH), with levels, search, the most frequent problems and live following.
- **Notices a stuck start:** if the game hasn't opened its window after 25 s (in practice an audio
  driver not answering, such as a remote-desktop one), the launcher comes back with Keep Waiting
  and Force Quit, and steps aside again by itself if the window appears.
  `defaults write io.github.matguitarist.hearthside stuckAfter -float 3` shortens the wait for testing.

## Building

```bash
make app            # → target/macos/Hearthside.app, signed with your Developer ID
make release-mac    # also notarize + staple, and write target/macos/dist/{zip,dmg,appcast.xml}
```

`scripts/macos-app.sh` holds the details and its environment knobs (`ARCHS="arm64 x86_64"` for a
universal build, `SIGN_IDENTITY`, `VERSION`, `BUILD`). The build number Sparkle compares comes
from the version (1.2.3 → 1002003), so it only ever grows with the version, whatever the history. Without a Developer ID certificate it
signs ad-hoc: the app runs on the Mac that built it, with updates off.

## One-time setup for releases

1. **Notarization credentials** for local releases, stored in the keychain (an app-specific
   password from appleid.apple.com):

   ```bash
   xcrun notarytool store-credentials AzerothSurvivors --apple-id <you@example.com> --team-id 434NVXAGUS
   ```

2. **The Sparkle signing key.** Its private half is in the login keychain under the account
   `azeroth-survivors`; the public half is `macos/sparkle-public-key.txt`, baked into every
   build. Back the private key up somewhere safe: an app signed with a lost key can never be
   updated again.

   ```bash
   target/macos/sparkle-2.10.0/bin/generate_keys --account azeroth-survivors -x sparkle-private-key.txt
   ```

3. **GitHub Actions secrets** for `.github/workflows/macos-release.yml`, all set by one script
   that asks for the passwords in hidden prompts:

   ```bash
   scripts/macos-ci-secrets.sh ~/Desktop/devide.p12
   ```

   | secret | what |
   |---|---|
   | `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD` | the Developer ID Application certificate and key, exported from Keychain Access as .p12 |
   | `NOTARY_APPLE_ID`, `NOTARY_PASSWORD`, `NOTARY_TEAM_ID` | the Apple ID, an app-specific password for it, and the team |
   | `SPARKLE_PRIVATE_KEY` | the update signing key, exported from the keychain |

   An App Store Connect API key works for notarization instead: set `NOTARY_KEY_P8` (the .p8
   file's contents), `NOTARY_KEY_ID` and `NOTARY_ISSUER`.

## Shipping a version

1. Bump `version` in the workspace `Cargo.toml`, write `macos/release-notes/<version>.md` (what's
   new, in Markdown) and merge. The notes appear in Sparkle's update dialog (rendered to HTML
   into `appcast.xml`) and as the GitHub release text. Without the file the dialog shows none.
2. Tag and push: `git tag v0.2.1 && git push origin v0.2.1`. A tag with a suffix
   (`v0.2.1-ci1`) is a dry run: everything but publishing, the files kept as a workflow artifact.
3. The workflow builds the game for each arch on its own runner (about 90 minutes each, in
   parallel: a fat-LTO link on a hosted Mac is slow), then a universal app, notarizes it, and publishes a release with the dmg,
   the zip and `appcast.xml`. Installed apps see the update on their next check.

A release can also be made locally with `make release-mac` and uploaded with
`gh release create v<version> target/macos/dist/*`. Only the latest non-draft, non-prerelease
release's `appcast.xml` is the live feed.
