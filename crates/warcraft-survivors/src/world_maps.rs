//! `--world-maps <dir> [<Data>]`: the two continents' world maps, from the game's own MPQs, as
//! `azeroth.png` and `kalimdor.png` in `<dir>` (the MPQs from `<Data>`, else `WOW_DATA`), for the home server's dashboard. The launcher
//! copies them to the server; no map art ships with the app or the repository.
//!
//! Each map is twelve 256² tiles, four across and three down (`WorldMapFrame.xml`'s
//! `WorldMapDetailTile1..12`), of which the in-game frame shows the top left 1002×668.

use std::path::Path;

use anyhow::{Context, Result};

const TILE: u32 = 256;
const COLUMNS: u32 = 4;
const ROWS: u32 = 3;
const WIDTH: u32 = 1002;
const HEIGHT: u32 = 668;

/// Write both maps, or `false` with the reason on stderr.
pub fn run(out: Option<&str>, data: Option<&str>) -> bool {
    match write(out, data) {
        Ok(()) => true,
        Err(e) => {
            eprintln!("--world-maps: {e:#}");
            false
        }
    }
}

fn write(out: Option<&str>, data: Option<&str>) -> Result<()> {
    let out = Path::new(out.context("usage: warcraft-survivors --world-maps <dir> [<Data>]")?);
    let data = match data {
        Some(d) => d.to_owned(),
        None => std::env::var("WOW_DATA").context("no Data folder given, nor WOW_DATA")?,
    };
    let mut chain = benilla_formats::open_chain(Path::new(&data))?;
    std::fs::create_dir_all(out).with_context(|| format!("creating {}", out.display()))?;
    for continent in ["Azeroth", "Kalimdor"] {
        let mut map = image::RgbaImage::new(TILE * COLUMNS, TILE * ROWS);
        for i in 0..COLUMNS * ROWS {
            let path = format!("Interface\\WorldMap\\{continent}\\{continent}{}.blp", i + 1);
            let (w, h, rgba) = benilla_formats::read_texture_rgba(&mut chain, &path)?;
            let tile =
                image::RgbaImage::from_raw(w, h, rgba).context("tile buffer size mismatch")?;
            let tile =
                image::imageops::resize(&tile, TILE, TILE, image::imageops::FilterType::Triangle);
            image::imageops::replace(
                &mut map,
                &tile,
                i64::from(i % COLUMNS * TILE),
                i64::from(i / COLUMNS * TILE),
            );
        }
        let file = out.join(format!("{}.png", continent.to_lowercase()));
        image::imageops::crop_imm(&map, 0, 0, WIDTH, HEIGHT)
            .to_image()
            .save(&file)
            .with_context(|| format!("writing {}", file.display()))?;
    }
    Ok(())
}
