//! How the guest's display is shown: scaling, and a CRT effect. Stored in the
//! workspace, `scaling_algorithm` and `shader_enabled` in the same fields as the egui
//! frontend's.
//!
//! The CRT effect is a Metal version of the egui frontend's CRT Lottes shader
//! (`frontend_egui/shaders/crt-lottes-fast.glsl`), with settings that suit the
//! machine's screen: its built-in display or its monitor. Its settings aren't
//! adjustable here, so the egui frontend's `shader_configs` are left as they are.
//! The shader renders at the window's resolution rather than the display's, as the
//! egui frontend does, so it uses its own settings.

use std::path::Path;

use anyhow::Context;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use snow_core::mac::{MacModel, MacMonitor};

use crate::workspace::Workspace;
use crate::{Monitor, SnowError, model_by_index, model_default_monitor, model_monitors};

/// How the display is filtered when it's scaled, as `ScalingAlgorithm` in the egui
/// frontend
#[derive(uniffi::Enum, Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
pub enum ScalingAlgorithm {
    Linear,
    NearestNeighbor,
}

/// How a machine's display is shown
#[derive(uniffi::Record, Clone, PartialEq, Eq, Debug)]
pub struct VideoSettings {
    /// Scale the display to the window. Otherwise it's shown at its actual size.
    pub scaling: bool,
    /// When scaling, only scale by whole numbers
    pub integer_scaling: bool,
    /// Show the display at the size it was on the real screen, on screens whose size
    /// is known. Takes over from the other scaling settings.
    pub physical_size: bool,
    pub scaling_algorithm: ScalingAlgorithm,
    /// Show the CRT effect, on screens that have one
    pub crt_effect: bool,
}

// Keys of the workspace. They're read from the fields it doesn't interpret, so the
// workspace keeps them as they were until they're changed here.
const SCALING_ALGORITHM: &str = "scaling_algorithm";
const SHADER_ENABLED: &str = "shader_enabled";
/// The display is shown at its actual size. This frontend's own.
const SCALING_DISABLED: &str = "scaling_disabled";
/// The display is only scaled by whole numbers. This frontend's own.
const INTEGER_SCALING: &str = "integer_scaling";
/// The display is shown at its real size. This frontend's own.
const PHYSICAL_SIZE: &str = "physical_size";

fn field<T: DeserializeOwned>(ws: &Workspace, key: &str) -> Option<T> {
    serde_json::from_value(ws.other.get(key)?.clone()).ok()
}

const CRT_SHADER: &str = include_str!("../../../frontend_egui/shaders/crt-lottes-fast.glsl");

/// The names and defaults of the CRT shader's parameters, from its
/// `#pragma parameter NAME "Display name" default min max [step]` lines, in order
fn crt_parameter_defaults() -> Vec<(String, f32)> {
    CRT_SHADER
        .lines()
        .filter_map(|line| line.trim().strip_prefix("#pragma parameter"))
        .filter_map(|rest| {
            let (name, rest) = rest.trim().split_once(char::is_whitespace)?;
            let rest = rest.trim_start().strip_prefix('"')?;
            let (_display_name, numbers) = rest.split_once('"')?;
            let default = numbers.split_whitespace().next()?.parse().ok()?;
            Some((name.to_owned(), default))
        })
        .collect()
}

/// What a machine's display is shown on
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Screen {
    /// The black and white CRT built into the compact Macs and the SE/30
    BuiltInMono,
    /// The Portable's
    Lcd,
    Monitor(MacMonitor),
}

impl Screen {
    /// The built-in screen, or the monitor connected: the one chosen if the model
    /// can have it, otherwise the model's default
    fn of(model: Option<MacModel>, monitor: Option<MacMonitor>) -> Self {
        match model {
            Some(MacModel::Portable | MacModel::Portable15MB) => Self::Lcd,
            Some(model) => match model_default_monitor(model) {
                None => Self::BuiltInMono,
                Some(default) => Self::Monitor(
                    monitor
                        .filter(|m| model_monitors(model).contains(m))
                        .unwrap_or(default),
                ),
            },
            None => Self::Monitor(monitor.unwrap_or_default()),
        }
    }
}

/// The CRT shader's settings for a screen, in the order the shader takes them, or
/// None for a screen that isn't a CRT.
///
/// The shader draws scanlines, and the mask of a color monitor, a little. The screen
/// isn't curved, which would move the picture from under the pointer.
fn crt_parameters(screen: Screen) -> Option<Vec<f32>> {
    // Mask types
    const NO_MASK: f32 = 0.0;
    const APERTURE_GRILLE: f32 = 1.0;
    const SHADOW_MASK: f32 = 3.0;
    let (scanline_thinness, mask, mask_intensity, corner) = match screen {
        // A small, rounded black and white tube
        Screen::BuiltInMono => (0.3, NO_MASK, 0.0, 2.0),
        Screen::Lcd => return None,
        // Apple's color monitors were Trinitrons, with an aperture grille. The 21"
        // packs its lines closer, so they show less.
        Screen::Monitor(MacMonitor::RGB12 | MacMonitor::HiRes14 | MacMonitor::RGB16) => {
            (0.3, APERTURE_GRILLE, 0.25, 1.0)
        }
        Screen::Monitor(MacMonitor::RGB21) => (0.0, APERTURE_GRILLE, 0.25, 1.0),
        // Large black and white monitors with fine lines
        Screen::Monitor(MacMonitor::PortraitBW | MacMonitor::TwoPageBW) => (0.0, NO_MASK, 0.0, 1.0),
        // A PC monitor, most of which had a shadow mask
        Screen::Monitor(MacMonitor::VGA) => (0.3, SHADOW_MASK, 0.25, 1.0),
    };
    let overrides = [
        ("CRT_GAMMA", 2.1),
        ("SCANLINE_THINNESS", scanline_thinness),
        ("SCAN_BLUR", 2.5),
        ("MASK", mask),
        ("MASK_INTENSITY", mask_intensity),
        ("CURVATURE", 0.0),
        ("TRINITRON_CURVE", 0.0),
        ("CORNER", corner),
    ];
    Some(
        crt_parameter_defaults()
            .into_iter()
            .map(|(name, default)| {
                overrides
                    .iter()
                    .find(|(n, _)| *n == name)
                    .map_or(default, |&(_, value)| value)
            })
            .collect(),
    )
}

fn workspace_model(ws: &Workspace) -> Option<MacModel> {
    ws.model.or_else(|| {
        let rom = std::fs::read(ws.rom_path.as_ref()?).ok()?;
        MacModel::detect_from_rom(&rom)
    })
}

/// The CRT shader's settings for the screen of a model with a monitor, in the order
/// the shader takes them, or None if it isn't a CRT. The monitor is ignored if the
/// model can't have it.
#[uniffi::export]
pub fn crt_effect_parameters(model: Option<u32>, monitor: Option<Monitor>) -> Option<Vec<f32>> {
    crt_parameters(Screen::of(
        model.and_then(model_by_index),
        monitor.map(MacMonitor::from),
    ))
}

/// How many of a screen's pixels there were to the inch, or None if it isn't known
fn pixels_per_inch(screen: Screen) -> Option<f64> {
    match screen {
        // The compact Macs' 9" display
        Screen::BuiltInMono => Some(72.0),
        Screen::Monitor(MacMonitor::RGB12) => Some(64.0),
        Screen::Monitor(MacMonitor::HiRes14) => Some(69.0),
        Screen::Monitor(MacMonitor::RGB16) => Some(70.0),
        Screen::Monitor(MacMonitor::RGB21) => Some(79.0),
        Screen::Monitor(MacMonitor::PortraitBW) => Some(77.0),
        Screen::Monitor(MacMonitor::TwoPageBW) => Some(77.0),
        // VGA monitors came in many sizes; this is a typical one
        Screen::Monitor(MacMonitor::VGA) => Some(60.0),
        // The Portable's LCD
        Screen::Lcd => Some(77.0),
    }
}

/// What a machine's display is shown on: its built-in display or its monitor
#[derive(uniffi::Record, Clone, PartialEq, Debug)]
pub struct ScreenInfo {
    /// The CRT shader's settings for it, in the order the shader takes them, or None
    /// if it isn't a CRT
    pub crt_parameters: Option<Vec<f32>>,
    /// How many of its pixels there were to the inch, or None if it isn't known
    pub pixels_per_inch: Option<f64>,
    /// The monitor, or None for a built-in display
    pub monitor: Option<Monitor>,
    /// Its resolution in pixels
    pub width: u32,
    pub height: u32,
    /// It shows color, rather than black and white
    pub color: bool,
}

/// A screen's resolution in pixels
fn resolution(screen: Screen) -> (u32, u32) {
    match screen {
        // The compact Macs and the SE/30
        Screen::BuiltInMono => (512, 342),
        Screen::Lcd => (640, 400),
        Screen::Monitor(m) => (m.width() as u32, m.height() as u32),
    }
}

/// The screen of a workspace's machine, as it's saved
#[uniffi::export]
pub fn workspace_screen(path: &str) -> Result<ScreenInfo, SnowError> {
    let ws = Workspace::from_file(Path::new(path))?;
    let screen = Screen::of(workspace_model(&ws), ws.init_args.monitor);
    let (width, height) = resolution(screen);
    Ok(ScreenInfo {
        crt_parameters: crt_parameters(screen),
        pixels_per_inch: pixels_per_inch(screen),
        monitor: match screen {
            Screen::Monitor(m) => Some(m.into()),
            Screen::BuiltInMono | Screen::Lcd => None,
        },
        width,
        height,
        // The built-in displays, the Portable's LCD included, are black and white
        color: matches!(screen, Screen::Monitor(m) if m.has_color()),
    })
}

/// Reads how a machine's display is shown
#[uniffi::export]
pub fn read_video_settings(path: &str) -> Result<VideoSettings, SnowError> {
    let ws = Workspace::from_file(Path::new(path))?;
    Ok(VideoSettings {
        scaling: !field(&ws, SCALING_DISABLED).unwrap_or(false),
        integer_scaling: field(&ws, INTEGER_SCALING).unwrap_or(false),
        physical_size: field(&ws, PHYSICAL_SIZE).unwrap_or(false),
        // The egui frontend always writes it, so a workspace without it is this
        // frontend's, which showed the pixels sharp before it could be chosen
        scaling_algorithm: field(&ws, SCALING_ALGORITHM)
            .unwrap_or(ScalingAlgorithm::NearestNeighbor),
        crt_effect: field(&ws, SHADER_ENABLED).unwrap_or(false),
    })
}

/// Writes how a machine's display is shown to its workspace, keeping everything else
#[uniffi::export]
pub fn write_video_settings(path: &str, settings: &VideoSettings) -> Result<(), SnowError> {
    let path = Path::new(path);
    let mut ws = Workspace::from_file(path)?;
    let fields = [
        (SCALING_DISABLED, serde_json::to_value(!settings.scaling)),
        (
            INTEGER_SCALING,
            serde_json::to_value(settings.integer_scaling),
        ),
        (PHYSICAL_SIZE, serde_json::to_value(settings.physical_size)),
        (
            SCALING_ALGORITHM,
            serde_json::to_value(settings.scaling_algorithm),
        ),
        (SHADER_ENABLED, serde_json::to_value(settings.crt_effect)),
    ];
    for (key, value) in fields {
        ws.other.insert(
            key.to_owned(),
            value.context("Cannot write the video settings")?,
        );
    }
    Ok(ws.write_file(path)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The value of a parameter in the CRT settings for a model and monitor
    fn crt_value(model: MacModel, monitor: Option<Monitor>, name: &str) -> f32 {
        let values = crt_effect_parameters(crate::model_index(model), monitor).unwrap();
        let index = crt_parameter_defaults()
            .iter()
            .position(|(n, _)| n == name)
            .unwrap();
        values[index]
    }

    #[test]
    fn parameters_are_read_from_the_shader() {
        let names: Vec<String> = crt_parameter_defaults()
            .into_iter()
            .map(|(n, _)| n)
            .collect();
        // In the order the Metal shader's LottesParameters has them
        assert_eq!(
            names,
            [
                "MASK",
                "MASK_INTENSITY",
                "SCANLINE_THINNESS",
                "SCAN_BLUR",
                "CURVATURE",
                "TRINITRON_CURVE",
                "CORNER",
                "CRT_GAMMA"
            ]
        );
    }

    #[test]
    fn settings_follow_the_screen() {
        // The default monitor, a color Trinitron
        assert_eq!(crt_value(MacModel::MacII, None, "MASK"), 1.0);
        assert_eq!(
            crt_value(MacModel::MacII, Some(Monitor::PortraitBw), "MASK"),
            0.0
        );
        assert_eq!(crt_value(MacModel::LCIII, Some(Monitor::Vga), "MASK"), 3.0);
        // The Mac II can't have a VGA monitor, so it has its default
        assert_eq!(crt_value(MacModel::MacII, Some(Monitor::Vga), "MASK"), 1.0);
        // A built-in screen, whatever the workspace says
        assert_eq!(crt_value(MacModel::Plus, Some(Monitor::Rgb21), "MASK"), 0.0);
        // Never curved
        assert_eq!(crt_value(MacModel::Plus, None, "CURVATURE"), 0.0);
        // The Portable's LCD has no CRT effect
        assert_eq!(
            crt_effect_parameters(crate::model_index(MacModel::Portable), None),
            None
        );
    }

    #[test]
    fn pixels_per_inch_follow_the_screen() {
        let ppi = |model: MacModel, monitor: Option<Monitor>| {
            pixels_per_inch(Screen::of(Some(model), monitor.map(MacMonitor::from)))
        };
        assert_eq!(ppi(MacModel::Plus, None), Some(72.0));
        assert_eq!(ppi(MacModel::SE30, Some(Monitor::Rgb21)), Some(72.0));
        assert_eq!(ppi(MacModel::MacII, Some(Monitor::Rgb21)), Some(79.0));
        assert_eq!(ppi(MacModel::LCIII, Some(Monitor::Rgb12)), Some(64.0));
        assert_eq!(ppi(MacModel::LCIII, Some(Monitor::Vga)), Some(60.0));
        assert_eq!(ppi(MacModel::Portable, None), Some(77.0));
    }

    #[test]
    fn video_settings_round_trip() {
        let dir = std::env::temp_dir().join(format!("snow_ffi_video_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("video.snoww");
        // An egui workspace, with its own shader settings
        std::fs::write(
            &path,
            r#"{"model":"LCIII","init_args":{"monitor":"VGA"},
                "scaling_algorithm":"Linear","shader_enabled":true,
                "shader_configs":[{"id":"CrtLottes","enabled":true,"parameters":{"MASK":2.0}}],
                "viewport_scale":3.0}"#,
        )
        .unwrap();
        let path = path.to_str().unwrap();

        let mut settings = read_video_settings(path).unwrap();
        assert_eq!(
            settings,
            VideoSettings {
                scaling: true,
                integer_scaling: false,
                physical_size: false,
                scaling_algorithm: ScalingAlgorithm::Linear,
                crt_effect: true,
            }
        );
        // The settings come from the monitor, not the egui frontend's shaders
        assert_eq!(
            workspace_screen(path).unwrap().crt_parameters,
            crt_effect_parameters(crate::model_index(MacModel::LCIII), Some(Monitor::Vga))
        );

        settings.scaling = false;
        settings.integer_scaling = true;
        settings.physical_size = true;
        settings.scaling_algorithm = ScalingAlgorithm::NearestNeighbor;
        settings.crt_effect = false;
        write_video_settings(path, &settings).unwrap();
        assert_eq!(read_video_settings(path).unwrap(), settings);

        let json: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        assert_eq!(json["viewport_scale"], 3.0);
        assert_eq!(json["scaling_algorithm"], "NearestNeighbor");
        assert_eq!(json["shader_enabled"], false);
        // Kept for the egui frontend
        assert_eq!(json["shader_configs"][0]["parameters"]["MASK"], 2.0);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_new_workspace_shows_sharp_pixels_without_effects() {
        let dir = std::env::temp_dir().join(format!("snow_ffi_video_new_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("video.snoww");
        std::fs::write(&path, "{}").unwrap();
        let settings = read_video_settings(path.to_str().unwrap()).unwrap();
        assert_eq!(
            settings.scaling_algorithm,
            ScalingAlgorithm::NearestNeighbor
        );
        assert!(settings.scaling && !settings.integer_scaling && !settings.crt_effect);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
