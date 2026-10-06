// SPDX-License-Identifier: GPL-3.0-only

//! POP Flow: "Show desktop" section of the Displays page.
//!
//! One switch: whether "show desktop" (the panel button, the screen corner, the
//! keyboard toggle) clears only the screen it was triggered on, or all of them.
//! This page only reads and writes the setting; the show-desktop toggle itself
//! lives in POP Flow's cosmic-applets fork and reads the same key.
//!
//! Contract with that consumer — keep both sides in step:
//! cosmic-config id `com.popflow.ShowDesktop`, version 1, key `per_output`
//! (bool), `true` when the key is absent.

use cosmic::widget::settings;
use cosmic::{Apply, Element};
use cosmic_config::cosmic_config_derive::CosmicConfigEntry;
use cosmic_config::{ConfigGet, ConfigSet, CosmicConfigEntry};
use cosmic_settings_page::Section;
use slab::Slab;

use super::{Message, Page};

pub const CONFIG_ID: &str = "com.popflow.ShowDesktop";
pub const CONFIG_VERSION: u64 = 1;
pub const PER_OUTPUT: &str = "per_output";
/// What an absent (or unreadable) key means.
pub const PER_OUTPUT_DEFAULT: bool = true;

/// Only here so the page can subscribe to changes with `watch_config`, which
/// wants a `CosmicConfigEntry`. The page never trusts the value it carries: a
/// deleted key would leave the old value in it, so every notification is
/// answered by reading the key again with [`per_output`].
#[derive(Clone, CosmicConfigEntry, Debug, PartialEq)]
#[version = 1]
pub struct ShowDesktopConfig {
    pub per_output: bool,
}

impl Default for ShowDesktopConfig {
    fn default() -> Self {
        Self {
            per_output: PER_OUTPUT_DEFAULT,
        }
    }
}

/// Opens (creating it if needed) the user config. `None` when there is no
/// config directory; the switch is then shown with the default and writes are
/// dropped with a log line.
pub fn open() -> Option<cosmic_config::Config> {
    match cosmic_config::Config::new(CONFIG_ID, CONFIG_VERSION) {
        Ok(config) => Some(config),
        Err(why) => {
            tracing::error!(?why, "failed to open {CONFIG_ID} config");
            None
        }
    }
}

/// The current value: absent or unreadable keys fall back to the default, so
/// a missing file and a corrupted one both mean "only this screen".
pub fn per_output(config: Option<&cosmic_config::Config>) -> bool {
    let Some(config) = config else {
        return PER_OUTPUT_DEFAULT;
    };

    match config.get::<bool>(PER_OUTPUT) {
        Ok(value) => value,
        Err(why) => {
            if why.is_err() {
                tracing::warn!(?why, "unreadable {CONFIG_ID}/{PER_OUTPUT}, using default");
            }
            PER_OUTPUT_DEFAULT
        }
    }
}

pub fn set_per_output(config: Option<&cosmic_config::Config>, value: bool) {
    let Some(config) = config else {
        tracing::error!("no {CONFIG_ID} config to write {PER_OUTPUT} to");
        return;
    };

    if let Err(why) = config.set(PER_OUTPUT, value) {
        tracing::error!(?why, "failed to write {CONFIG_ID}/{PER_OUTPUT}");
    }
}

pub fn section() -> Section<crate::pages::Message> {
    let mut descriptions = Slab::new();

    let per_output_label = descriptions.insert(fl!("pop-flow-show-desktop", "per-output"));
    let per_output_desc = descriptions.insert(fl!("pop-flow-show-desktop", "per-output-desc"));

    Section::default()
        .title(fl!("pop-flow-show-desktop"))
        .descriptions(descriptions)
        .view::<Page>(move |_binder, page, section| {
            let descriptions = &section.descriptions;

            settings::section()
                .title(&section.title)
                .add(
                    settings::item::builder(&descriptions[per_output_label])
                        .description(&descriptions[per_output_desc])
                        .toggler(page.show_desktop_per_output, Message::ShowDesktopPerOutput),
                )
                .apply(Element::from)
                .map(crate::pages::Message::Displays)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A throwaway config under the temp dir — never the user's ~/.config.
    fn temp_config(tag: &str) -> (std::path::PathBuf, cosmic_config::Config) {
        let dir = std::env::temp_dir().join(format!(
            "pop-flow-show-desktop-test-{}-{tag}",
            std::process::id()
        ));
        _ = std::fs::remove_dir_all(&dir);
        let config =
            cosmic_config::Config::with_custom_path(CONFIG_ID, CONFIG_VERSION, dir.clone())
                .unwrap();
        (dir, config)
    }

    #[test]
    fn absent_key_means_per_output() {
        let (dir, config) = temp_config("absent");
        assert!(per_output(Some(&config)));
        _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn no_config_means_per_output() {
        assert!(per_output(None));
    }

    #[test]
    fn round_trips_both_values() {
        let (dir, config) = temp_config("roundtrip");
        set_per_output(Some(&config), false);
        assert!(!per_output(Some(&config)));
        set_per_output(Some(&config), true);
        assert!(per_output(Some(&config)));
        _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn written_where_the_consumer_reads_it() {
        // The consumer reads ~/.config/cosmic/com.popflow.ShowDesktop/v1/per_output
        // as RON; a plain `false` is what it expects to find there.
        let (dir, config) = temp_config("path");
        set_per_output(Some(&config), false);
        let file = dir.join("cosmic").join(CONFIG_ID).join("v1").join(PER_OUTPUT);
        assert_eq!(std::fs::read_to_string(file).unwrap().trim(), "false");
        _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn garbage_falls_back_to_default() {
        let (dir, config) = temp_config("garbage");
        let file = dir.join("cosmic").join(CONFIG_ID).join("v1").join(PER_OUTPUT);
        std::fs::write(file, "not a bool").unwrap();
        assert!(per_output(Some(&config)));
        _ = std::fs::remove_dir_all(dir);
    }
}
