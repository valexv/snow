//! Bridge between the Snow core and the native macOS (SwiftUI) frontend.
//!
//! UniFFI generates the Swift side from the annotations here: see
//! `frontend_macos/build_rust.sh`. A [`Machine`] drives the emulator the same way
//! `frontend_egui` does: commands go in over an [`EmulatorCommandSender`], events
//! come back over an [`EmulatorEventReceiver`] and frames are picked up from a shared
//! [`DisplayBuffer`] slot. The emulator itself runs on its own thread.
//!
//! Machines are described by Snow workspace files (see [`workspace`]), and are
//! suspended to and resumed from save states.

// The audio backend is shared with the egui frontend rather than duplicated.
#[allow(dead_code)]
#[path = "../../../frontend_egui/src/audio_cpal.rs"]
mod audio_cpal;
mod cdrom;
mod specs;
mod video;
mod workspace;

use std::collections::VecDeque;
use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, Once};
use std::thread::{self, JoinHandle};

use anyhow::{Context, Result, anyhow, bail};
use log::{error, info, warn};
use sha2::{Digest, Sha256};
use snow_core::emulator::comm::{
    EmulatorCommand, EmulatorCommandSender, EmulatorEvent, EmulatorEventReceiver, EmulatorSpeed,
    EmulatorStatus, UserMessageType,
};
use snow_core::emulator::{Emulator, MouseMode};
use snow_core::keymap::{KeyEvent, Keymap};
use snow_core::mac::maclc::lc_475_bus;
use snow_core::mac::maclc::video as lc_video;
use snow_core::mac::quadra::dafb;
use snow_core::mac::scsi::ethernet::EthernetLinkType;
use snow_core::mac::scsi::target::ScsiTargetType;
use snow_core::mac::swim::drive::DriveType;
use snow_core::mac::{ExtraROMs, MacModel, MacMonitor, NubusDeviceKind};
use snow_core::renderer::DisplayBuffer;
use snow_core::tickable::Tickable;
use strum::IntoEnumIterator;

use crate::audio_cpal::CpalAudioProvider;
pub use crate::cdrom::CdromDisc;
use crate::specs::{ModelSpecs, model_specs};
use crate::workspace::{SCSI_TARGETS, ScsiTargetEntry, Workspace, WorkspaceDisc};

uniffi::setup_scaffolding!();

const FLOPPY_DRIVES: u32 = 3;

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// A failure to start, stop or configure a machine
#[derive(Debug, uniffi::Error)]
pub enum SnowError {
    Failed { message: String },
}

impl fmt::Display for SnowError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Failed { message } => f.write_str(message),
        }
    }
}

impl From<anyhow::Error> for SnowError {
    fn from(err: anyhow::Error) -> Self {
        error!("{:#}", err);
        Self::Failed {
            message: format!("{:#}", err),
        }
    }
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

/// A supported Macintosh model
#[derive(uniffi::Record)]
pub struct ModelInfo {
    /// Refers to the model elsewhere in this API
    pub index: u32,
    /// The core's name for the model, as workspaces store it, like "Early128K" or
    /// "SE30"
    pub identifier: String,
    pub name: String,
    /// The model cannot start without a display card/video ROM
    pub needs_display_rom: bool,
    /// The model takes a NuBus display card, whose type must match the display ROM
    pub has_display_card: bool,
    /// RAM sizes in bytes the model can be set up with
    pub ram_sizes: Vec<u64>,
    /// RAM size in bytes when none is chosen
    pub default_ram_size: u64,
    /// Video RAM sizes in bytes the model can be set up with. Empty if there's no
    /// choice.
    pub vram_sizes: Vec<u64>,
    /// Video RAM size in bytes when none is chosen, if there is a choice
    pub default_vram_size: Option<u64>,
    /// What the FPU setting means for the model
    pub fpu_option: FpuOption,
    /// A 68851 PMMU can be fitted
    pub has_pmmu_option: bool,
    /// The floppy drive can be the 800K one instead of the original 400K
    pub has_800k_floppy_option: bool,
    /// The model has a SCSI bus, so it can have hard disks
    pub has_scsi: bool,
    /// What the base model shipped with
    pub specs: ModelSpecs,
    /// Monitors the model's video can drive. Empty if it has a built-in screen or
    /// the monitor can't be chosen. With a display card, only the Display Card 8•24
    /// can drive them; the other card always has the default monitor.
    pub monitors: Vec<Monitor>,
    /// The monitor when none is chosen, if there is a choice
    pub default_monitor: Option<Monitor>,
}

/// A monitor to connect to the Macintosh
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum Monitor {
    Rgb12,
    HiRes14,
    Rgb16,
    Rgb21,
    PortraitBw,
    TwoPageBw,
    Vga,
}

impl From<MacMonitor> for Monitor {
    fn from(m: MacMonitor) -> Self {
        match m {
            MacMonitor::RGB12 => Self::Rgb12,
            MacMonitor::HiRes14 => Self::HiRes14,
            MacMonitor::RGB16 => Self::Rgb16,
            MacMonitor::RGB21 => Self::Rgb21,
            MacMonitor::PortraitBW => Self::PortraitBw,
            MacMonitor::TwoPageBW => Self::TwoPageBw,
            MacMonitor::VGA => Self::Vga,
        }
    }
}

impl From<Monitor> for MacMonitor {
    fn from(m: Monitor) -> Self {
        match m {
            Monitor::Rgb12 => Self::RGB12,
            Monitor::HiRes14 => Self::HiRes14,
            Monitor::Rgb16 => Self::RGB16,
            Monitor::Rgb21 => Self::RGB21,
            Monitor::PortraitBw => Self::PortraitBW,
            Monitor::TwoPageBw => Self::TwoPageBW,
            Monitor::Vga => Self::VGA,
        }
    }
}

/// A monitor's name and resolution, for display
#[derive(uniffi::Record)]
pub struct MonitorInfo {
    pub name: String,
    pub width: u32,
    pub height: u32,
}

#[uniffi::export]
pub fn monitor_info(monitor: Monitor) -> MonitorInfo {
    // Shorter than the core's names, like "Macintosh 21\" Two-Page monitor (WxH)":
    // without "Macintosh" and "monitor", and the resolution given separately
    let name = match monitor {
        Monitor::Rgb12 => "12\" RGB",
        Monitor::HiRes14 => "13\" High-Res",
        Monitor::Rgb16 => "16\" RGB",
        Monitor::Rgb21 => "21\" RGB",
        Monitor::PortraitBw => "15\" Portrait",
        Monitor::TwoPageBw => "21\" Two-Page",
        Monitor::Vga => "VGA",
    };
    let monitor = MacMonitor::from(monitor);
    MonitorInfo {
        name: name.to_owned(),
        width: monitor.width() as u32,
        height: monitor.height() as u32,
    }
}

/// The FPU choice a model offers
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq)]
pub enum FpuOption {
    /// The model has no FPU choice: it has an FPU or not
    None,
    /// A 68882 FPU can be fitted (LC family)
    Coprocessor,
    /// The CPU is a 68040 with an FPU or a 68LC040 without (LC 475)
    Cpu68040,
}

fn model_by_index(index: u32) -> Option<MacModel> {
    MacModel::iter().nth(index as usize)
}

fn model_index(model: MacModel) -> Option<u32> {
    MacModel::iter().position(|m| m == model).map(|i| i as u32)
}

const fn model_has_display_card(model: MacModel) -> bool {
    matches!(
        model,
        MacModel::MacII | MacModel::MacIIFDHD | MacModel::MacIIx | MacModel::MacIIcx
    )
}

const fn model_needs_display_rom(model: MacModel) -> bool {
    model_has_display_card(model) || matches!(model, MacModel::SE30)
}

// The hardware options below are the ones the egui frontend's model dialog offers

const fn model_fpu_option(model: MacModel) -> FpuOption {
    match model {
        MacModel::LC | MacModel::LCII | MacModel::LCIII => FpuOption::Coprocessor,
        MacModel::LC475 => FpuOption::Cpu68040,
        _ => FpuOption::None,
    }
}

const fn model_has_pmmu_option(model: MacModel) -> bool {
    matches!(model, MacModel::MacII | MacModel::MacIIFDHD)
}

const fn model_has_800k_floppy_option(model: MacModel) -> bool {
    matches!(model, MacModel::Early128K | MacModel::Early512K)
}

/// Video RAM sizes to choose from, and the size if none is chosen
fn model_vram_sizes(model: MacModel) -> (&'static [usize], Option<usize>) {
    match model {
        MacModel::LC | MacModel::LCII | MacModel::LCIII => (
            lc_video::vram_sizes(model),
            Some(lc_video::vram_size_default(model)),
        ),
        // As the core does when none is chosen
        MacModel::LC475 => (lc_475_bus::VRAM_SIZES, Some(1024 * 1024)),
        _ => (&[], None),
    }
}

/// The core's name for a model, as serde writes it to workspaces
fn model_identifier(model: MacModel) -> String {
    match serde_json::to_value(model) {
        Ok(serde_json::Value::String(name)) => name,
        _ => format!("{:?}", model),
    }
}

/// The monitor a model has if none is chosen, or None if it can't have one
pub(crate) fn model_default_monitor(model: MacModel) -> Option<MacMonitor> {
    let monitors = model_monitors(model);
    if monitors.contains(&MacMonitor::default()) {
        Some(MacMonitor::default())
    } else {
        monitors.first().copied()
    }
}

pub(crate) fn model_monitors(model: MacModel) -> Vec<MacMonitor> {
    match model {
        MacModel::Quadra700 | MacModel::LC475 => dafb::MONITORS.to_vec(),
        MacModel::LC | MacModel::LCII | MacModel::LCIII => lc_video::monitors(model).to_vec(),
        // VGA monitors are only known to work on the LC III
        m if model_has_display_card(m) => MacMonitor::iter()
            .filter(|&m| m != MacMonitor::VGA)
            .collect(),
        _ => Vec::new(),
    }
}

/// The Snow core version
#[uniffi::export]
pub fn version() -> String {
    snow_core::build_version()
}

/// All supported models
#[uniffi::export]
pub fn models() -> Vec<ModelInfo> {
    MacModel::iter()
        .enumerate()
        .map(|(i, m)| ModelInfo {
            index: i as u32,
            identifier: model_identifier(m),
            name: m.to_string(),
            needs_display_rom: model_needs_display_rom(m),
            has_display_card: model_has_display_card(m),
            ram_sizes: m.ram_size_options().iter().map(|&sz| sz as u64).collect(),
            default_ram_size: m.ram_size_default() as u64,
            vram_sizes: model_vram_sizes(m).0.iter().map(|&sz| sz as u64).collect(),
            default_vram_size: model_vram_sizes(m).1.map(|sz| sz as u64),
            fpu_option: model_fpu_option(m),
            has_pmmu_option: model_has_pmmu_option(m),
            has_800k_floppy_option: model_has_800k_floppy_option(m),
            has_scsi: m.has_scsi(),
            specs: model_specs(m),
            monitors: model_monitors(m).into_iter().map(Monitor::from).collect(),
            default_monitor: model_default_monitor(m).map(Monitor::from),
        })
        .collect()
}

/// Detects the model from a ROM file. None if the file can't be read or the ROM
/// is not recognized.
#[uniffi::export]
pub fn detect_model(rom_path: &str) -> Option<u32> {
    std::fs::read(rom_path)
        .ok()
        .and_then(|rom| MacModel::detect_from_rom(&rom))
        .and_then(model_index)
}

/// The models a ROM file runs in, by index, the one it's detected as first.
///
/// Some ROMs are shared, like the one of the Macintosh II (FDHD), IIx, IIcx and
/// SE/30. Empty if the file can't be read or the ROM is not recognized.
#[uniffi::export]
pub fn models_for_rom(rom_path: &str) -> Vec<u32> {
    let Ok(rom) = std::fs::read(rom_path) else {
        return Vec::new();
    };
    models_for_rom_data(&rom)
}

fn models_for_rom_data(rom: &[u8]) -> Vec<u32> {
    let detected = MacModel::detect_from_rom(rom);
    detected
        .into_iter()
        .chain(MacModel::iter().filter(|m| Some(*m) != detected && m.is_valid_rom(rom)))
        .filter_map(model_index)
        .collect()
}

// ---------------------------------------------------------------------------
// Workspaces
// ---------------------------------------------------------------------------

/// NuBus display card of the Macintosh II family. The display ROM must be this card's.
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum DisplayCard {
    /// Macintosh Display Card 8•24 (ROM 341-0868)
    Mdc824,
    /// Macintosh II Video Card, "Toby" (ROM 342-0008)
    Toby,
}

/// What a display ROM belongs to
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum DisplayRom {
    /// A display card of the Macintosh II family
    Card { card: DisplayCard },
    /// The SE/30's built-in video
    Se30Video,
}

/// SHA-256 of the one known dump of each display ROM, as the egui frontend checks
/// them against
const DISPLAY_ROM_HASHES: [(&str, DisplayRom); 3] = [
    (
        "e2e763a6b432c9196f619a9f90107726ab1a84a1d54242fe5f5182bf3c97b238",
        DisplayRom::Card {
            card: DisplayCard::Mdc824,
        },
    ),
    (
        "02261d5b8739352ead945de0fdccd3a364890fb67d75eb5449e4bd19e18c06fc",
        DisplayRom::Card {
            card: DisplayCard::Toby,
        },
    ),
    (
        "8af892fd7fff89c2151bb3027f3dc61e531f24e4adb0e3face95c90daece4409",
        DisplayRom::Se30Video,
    ),
];

fn identify_display_rom_data(rom: &[u8]) -> Option<DisplayRom> {
    let digest = Sha256::digest(rom);
    let hex: String = digest.iter().map(|b| format!("{:02x}", b)).collect();
    DISPLAY_ROM_HASHES
        .iter()
        .find(|(hash, _)| *hash == hex)
        .map(|&(_, rom)| rom)
}

/// Identifies a display card ROM or the SE/30's video ROM. None if the file can't
/// be read or isn't a known dump.
#[uniffi::export]
pub fn identify_display_rom(path: &str) -> Option<DisplayRom> {
    std::fs::read(path)
        .ok()
        .and_then(|rom| identify_display_rom_data(&rom))
}

/// What's attached at a SCSI ID
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum ScsiDevice {
    None,
    /// A hard disk, from its image
    Disk {
        path: String,
    },
    /// A CD-ROM drive, with the disc in it when the machine starts
    Cdrom {
        disc: Option<CdromDisc>,
    },
    /// A CD-ROM drive for a folder of disc images, which the guest switches
    /// between with the BlueSCSI Toolbox
    CdromFolder {
        path: String,
    },
    /// A DaynaPORT SCSI/Link Ethernet controller
    Ethernet,
    /// A LaserWriter IISC, which saves the pages it prints to the Desktop
    Printer,
    /// Something only the egui frontend sets up. Kept as it is.
    Other,
}

/// How the Ethernet controller connects to the network, as in the egui frontend
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum EthernetLink {
    /// No link: the cable is unplugged
    Down,
    /// Through the host's connection, behind a NAT
    Nat,
    /// NAT, with HTTPS connections from the guest made for it over HTTP
    NatHttpsStripping,
}

impl From<EthernetLink> for EthernetLinkType {
    fn from(link: EthernetLink) -> Self {
        match link {
            EthernetLink::Down => Self::Down,
            EthernetLink::Nat => Self::NAT,
            EthernetLink::NatHttpsStripping => Self::NATHttpsStripping,
        }
    }
}

/// Where the printer saves the pages it prints, as PNG files: the Desktop, as in
/// the egui frontend. A resumed machine keeps saving where it did.
fn printer_output_dir() -> PathBuf {
    std::env::home_dir()
        .map(|home| home.join("Desktop"))
        .filter(|desktop| desktop.is_dir())
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_default()
}

/// Where the egui frontend keeps the link, for all Ethernet controllers
const ETHERNET_LINK_KEY: &str = "ethernet_link_type";

/// The workspace's link, as the egui frontend reads it: NAT if there's none, and
/// down for one this build can't make, like a bridge
fn workspace_ethernet_link(ws: &Workspace) -> EthernetLink {
    match ws.other.get(ETHERNET_LINK_KEY) {
        None => EthernetLink::Nat,
        Some(serde_json::Value::String(s)) if s == "NAT" => EthernetLink::Nat,
        Some(serde_json::Value::String(s)) if s == "NATHttpsStripping" => {
            EthernetLink::NatHttpsStripping
        }
        Some(_) => EthernetLink::Down,
    }
}

fn ethernet_link_value(link: EthernetLink) -> serde_json::Value {
    serde_json::Value::from(match link {
        EthernetLink::Down => "Down",
        EthernetLink::Nat => "NAT",
        EthernetLink::NatHttpsStripping => "NATHttpsStripping",
    })
}

impl From<&WorkspaceDisc> for CdromDisc {
    fn from(disc: &WorkspaceDisc) -> Self {
        match disc {
            WorkspaceDisc::Image(p) => Self::Image {
                path: path_string(p),
            },
            WorkspaceDisc::Folder(p) => Self::Folder {
                path: path_string(p),
            },
        }
    }
}

impl From<&CdromDisc> for WorkspaceDisc {
    fn from(disc: &CdromDisc) -> Self {
        match disc {
            CdromDisc::Image { path } => Self::Image(PathBuf::from(path)),
            CdromDisc::Folder { path } => Self::Folder(PathBuf::from(path)),
        }
    }
}

/// The image to load for a disc: the disc's own, or one made from its folder
fn disc_image(disc: &WorkspaceDisc) -> Result<(PathBuf, bool)> {
    match disc {
        WorkspaceDisc::Image(p) => Ok((p.clone(), false)),
        WorkspaceDisc::Folder(dir) => Ok((cdrom::make_disc_from_folder(dir)?, true)),
    }
}

/// The part of a workspace this frontend lets the user edit
#[derive(uniffi::Record)]
pub struct MachineConfig {
    pub rom_path: String,
    /// Model index, or None to detect the model from the ROM
    pub model: Option<u32>,
    /// Display card ROM (Macintosh II family) or video ROM (SE/30)
    pub display_rom_path: Option<String>,
    pub display_card: DisplayCard,
    /// What's attached at each SCSI ID (0-6)
    pub scsi_devices: Vec<ScsiDevice>,
    /// How an Ethernet controller connects, if there is one
    pub ethernet_link: EthernetLink,
    /// File to keep the PRAM in, or None to not persist it
    pub pram_path: Option<String>,
    pub audio: bool,
    /// RAM size in bytes, or None for the model's default
    pub ram_size: Option<u64>,
    /// Video RAM size in bytes, or None for the model's default
    pub vram_size: Option<u64>,
    /// FPU fitted (LC family), or the CPU is a full 68040 (LC 475)
    pub fpu: bool,
    /// 68851 PMMU fitted (Macintosh II)
    pub pmmu: bool,
    /// The floppy drive is the 800K one (Macintosh 128K and 512K)
    pub floppy_800k: bool,
    /// The monitor connected, or None for the default
    pub monitor: Option<Monitor>,
}

fn path_string(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// Reads the settings this frontend edits from a workspace file
/// What a file is, for where it goes when dropped onto a machine
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskImageKind {
    Floppy,
    Cdrom,
}

/// Floppy images are at most this big; larger files aren't read to check
const FLOPPY_IMAGE_MAX_SIZE: u64 = 40 * 1024 * 1024;

/// Whether a file is a floppy image or a CD-ROM image, or nil if it's neither.
///
/// As in the egui frontend, a floppy image has a floppy extension and contents the
/// floppy loader recognizes, and a CD-ROM image is an .iso, .toast or .cue file.
#[uniffi::export]
pub fn disk_image_kind(path: &str) -> Option<DiskImageKind> {
    let path = Path::new(path);
    let ext = path.extension()?.to_string_lossy().to_ascii_lowercase();
    if snow_floppy::loaders::ImageType::all_extensions().contains(&ext.as_str())
        && std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.len() < FLOPPY_IMAGE_MAX_SIZE)
        && std::fs::read(path)
            .is_ok_and(|data| snow_floppy::loaders::Autodetect::detect(&data).is_ok())
    {
        return Some(DiskImageKind::Floppy);
    }
    matches!(ext.as_str(), "iso" | "toast" | "cue").then_some(DiskImageKind::Cdrom)
}

#[uniffi::export]
pub fn read_workspace(path: &str) -> Result<MachineConfig, SnowError> {
    let ws = Workspace::from_file(Path::new(path))?;
    Ok(MachineConfig {
        rom_path: ws.rom_path.as_deref().map(path_string).unwrap_or_default(),
        model: ws.model.and_then(model_index),
        display_rom_path: ws.display_card_rom_path.as_deref().map(path_string),
        display_card: match ws.init_args.video_card {
            NubusDeviceKind::Toby => DisplayCard::Toby,
            _ => DisplayCard::Mdc824,
        },
        scsi_devices: ws
            .scsi_targets
            .iter()
            .zip(&ws.cdrom_discs)
            .map(|(target, disc)| match target {
                ScsiTargetEntry::None => ScsiDevice::None,
                ScsiTargetEntry::Disk(p) => ScsiDevice::Disk {
                    path: path_string(p),
                },
                ScsiTargetEntry::Cdrom => ScsiDevice::Cdrom {
                    disc: disc.as_ref().map(CdromDisc::from),
                },
                ScsiTargetEntry::CdromFolder(p) => ScsiDevice::CdromFolder {
                    path: path_string(p),
                },
                ScsiTargetEntry::Ethernet => ScsiDevice::Ethernet,
                ScsiTargetEntry::Printer => ScsiDevice::Printer,
            })
            .collect(),
        ethernet_link: workspace_ethernet_link(&ws),
        pram_path: ws.pram_path.as_deref().map(path_string),
        audio: !ws.init_args.audio_disabled,
        ram_size: ws.init_args.ram_size.map(|sz| sz as u64),
        vram_size: ws.init_args.vram_size.map(|sz| sz as u64),
        fpu: ws.init_args.fpu_enabled,
        pmmu: ws.init_args.pmmu_enabled,
        floppy_800k: ws.init_args.override_fdd_type == Some(DriveType::GCR800KPWM),
        monitor: ws.init_args.monitor.map(Monitor::from),
    })
}

/// Writes the settings this frontend edits to a workspace file, creating it if
/// needed. Everything else in an existing file is kept.
#[uniffi::export]
pub fn write_workspace(path: &str, config: &MachineConfig) -> Result<(), SnowError> {
    let path = Path::new(path);
    let mut ws = if path.exists() {
        Workspace::from_file(path)?
    } else {
        Workspace::default()
    };

    ws.rom_path = Some(PathBuf::from(&config.rom_path));
    ws.model = config.model.and_then(model_by_index);
    ws.display_card_rom_path = config.display_rom_path.as_ref().map(PathBuf::from);
    ws.init_args.video_card = match config.display_card {
        DisplayCard::Mdc824 => NubusDeviceKind::Mdc12,
        DisplayCard::Toby => NubusDeviceKind::Toby,
    };
    for id in 0..SCSI_TARGETS {
        let Some(device) = config.scsi_devices.get(id) else {
            continue;
        };
        let (target, disc) = match device {
            ScsiDevice::None => (ScsiTargetEntry::None, None),
            ScsiDevice::Disk { path } => (ScsiTargetEntry::Disk(PathBuf::from(path)), None),
            ScsiDevice::Cdrom { disc } => (
                ScsiTargetEntry::Cdrom,
                disc.as_ref().map(WorkspaceDisc::from),
            ),
            ScsiDevice::CdromFolder { path } => {
                (ScsiTargetEntry::CdromFolder(PathBuf::from(path)), None)
            }
            ScsiDevice::Ethernet => (ScsiTargetEntry::Ethernet, None),
            ScsiDevice::Printer => (ScsiTargetEntry::Printer, None),
            // Kept as the egui frontend set it up
            ScsiDevice::Other => continue,
        };
        ws.scsi_targets[id] = target;
        ws.cdrom_discs[id] = disc;
    }
    // Left as it is when it's one this build can't make, like a bridge
    if workspace_ethernet_link(&ws) != config.ethernet_link {
        ws.other.insert(
            ETHERNET_LINK_KEY.to_string(),
            ethernet_link_value(config.ethernet_link),
        );
    }
    ws.pram_path = config.pram_path.as_ref().map(PathBuf::from);
    ws.init_args.audio_disabled = !config.audio;
    ws.init_args.ram_size = config
        .ram_size
        .map(usize::try_from)
        .transpose()
        .context("RAM size too large")?;
    ws.init_args.vram_size = config
        .vram_size
        .map(usize::try_from)
        .transpose()
        .context("Video RAM size too large")?;
    ws.init_args.fpu_enabled = config.fpu;
    ws.init_args.pmmu_enabled = config.pmmu;
    if config.floppy_800k {
        ws.init_args.override_fdd_type = Some(DriveType::GCR800KPWM);
    } else if ws.init_args.override_fdd_type == Some(DriveType::GCR800KPWM) {
        ws.init_args.override_fdd_type = None;
    }
    ws.init_args.monitor = config.monitor.map(MacMonitor::from);

    Ok(ws.write_file(path)?)
}

/// Sets whether the machine starts fast-forwarding.
///
/// It's the egui frontend's "start in fast-forward mode". This app sets it to what the machine was doing when
/// it last ran, rather than letting it be chosen, so it's apart from the rest of
/// the settings. Applies to resuming a saved state too.
#[uniffi::export]
pub fn write_workspace_fast_forward(path: &str, fast_forward: bool) -> Result<(), SnowError> {
    let path = Path::new(path);
    let mut ws = Workspace::from_file(path)?;
    if ws.init_args.start_fastforward == fast_forward {
        return Ok(());
    }
    ws.init_args.start_fastforward = fast_forward;
    Ok(ws.write_file(path)?)
}

/// Copies a workspace file to another location, keeping the paths in it pointing
/// to the same files
#[uniffi::export]
pub fn import_workspace(source: &str, destination: &str) -> Result<(), SnowError> {
    let ws = Workspace::from_file(Path::new(source))?;
    Ok(ws.write_file(Path::new(destination))?)
}

// ---------------------------------------------------------------------------
// Status and messages
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Clone, Copy)]
pub enum EmulationSpeed {
    /// Actual speed of the real hardware
    Accurate,
    /// Actual speed while sound plays, otherwise uncapped
    Dynamic,
    /// As fast as possible, without sound
    Uncapped,
    /// Synced to 60 fps video, without sound
    Video,
}

impl From<EmulationSpeed> for EmulatorSpeed {
    fn from(value: EmulationSpeed) -> Self {
        match value {
            EmulationSpeed::Accurate => Self::Accurate,
            EmulationSpeed::Dynamic => Self::Dynamic,
            EmulationSpeed::Uncapped => Self::Uncapped,
            EmulationSpeed::Video => Self::Video,
        }
    }
}

impl From<EmulatorSpeed> for EmulationSpeed {
    fn from(value: EmulatorSpeed) -> Self {
        match value {
            EmulatorSpeed::Accurate => Self::Accurate,
            EmulatorSpeed::Dynamic => Self::Dynamic,
            EmulatorSpeed::Uncapped | EmulatorSpeed::FastForward(_) => Self::Uncapped,
            EmulatorSpeed::Video => Self::Video,
        }
    }
}

/// General emulator status
#[derive(uniffi::Record)]
pub struct MachineStatus {
    pub running: bool,
    /// Model index
    pub model: Option<u32>,
    /// Speed relative to the real machine, 1.0 = 100%
    pub effective_speed: f64,
    pub cycles: u64,
    pub speed: EmulationSpeed,
    pub floppies: Vec<FloppyStatus>,
    /// The CD-ROM drives, by SCSI ID
    pub cdroms: Vec<CdromStatus>,
}

/// Status of a CD-ROM drive
#[derive(uniffi::Record)]
pub struct CdromStatus {
    pub id: u32,
    /// The disc in the drive: its image, or the folder it was made from. None if
    /// the drive is empty.
    pub disc_path: Option<String>,
    /// The drive switches between the disc images of this folder, as the guest
    /// chooses with the BlueSCSI Toolbox
    pub managed_folder: Option<String>,
}

/// Status of a floppy drive
#[derive(uniffi::Record)]
pub struct FloppyStatus {
    pub drive: u32,
    /// The machine has this drive
    pub present: bool,
    /// A disk is in the drive
    pub inserted: bool,
    pub motor: bool,
    pub writing: bool,
    pub dirty: bool,
    pub title: String,
}

/// `made_discs` are the discs made from folders, with their folders
fn machine_status(s: &EmulatorStatus, made_discs: &[(PathBuf, PathBuf)]) -> MachineStatus {
    MachineStatus {
        running: s.running,
        model: model_index(s.model),
        effective_speed: s.effective_speed,
        cycles: s.cycles,
        speed: s.speed.into(),
        floppies: s
            .fdd
            .iter()
            .enumerate()
            .map(|(i, f)| FloppyStatus {
                drive: i as u32,
                present: f.present,
                inserted: f.present && !f.ejected,
                motor: f.motor,
                writing: f.writing,
                dirty: f.dirty,
                title: if f.present && !f.ejected {
                    f.image_title.clone()
                } else {
                    String::new()
                },
            })
            .collect(),
        cdroms: s
            .scsi
            .iter()
            .enumerate()
            .filter_map(|(id, target)| {
                let target = target.as_ref()?;
                (target.target_type == ScsiTargetType::Cdrom).then(|| CdromStatus {
                    id: id as u32,
                    disc_path: target.image.as_ref().map(|image| {
                        let source = made_discs
                            .iter()
                            .find(|(made, _)| made == image)
                            .map_or(image, |(_, folder)| folder);
                        path_string(source)
                    }),
                    managed_folder: target.cdrom_folder.as_deref().map(path_string),
                })
            })
            .collect(),
    }
}

#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq)]
pub enum MessageKind {
    Success,
    Notice,
    Warning,
    Error,
}

/// A message from the emulator, meant for the user
#[derive(uniffi::Record)]
pub struct MachineMessage {
    pub kind: MessageKind,
    pub text: String,
}

impl From<(UserMessageType, String)> for MachineMessage {
    fn from((kind, text): (UserMessageType, String)) -> Self {
        let kind = match kind {
            UserMessageType::Success => MessageKind::Success,
            UserMessageType::Notice => MessageKind::Notice,
            UserMessageType::Warning => MessageKind::Warning,
            UserMessageType::Error => MessageKind::Error,
        };
        Self { kind, text }
    }
}

/// A frame of the guest's display
#[derive(uniffi::Record)]
pub struct Frame {
    pub width: u16,
    pub height: u16,
    /// RGBA, 4 bytes per pixel, rows without padding
    pub pixels: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Machine
// ---------------------------------------------------------------------------

fn init_logging() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = env_logger::builder()
            .filter_level(log::LevelFilter::Info)
            .try_init();
    });
}

/// Stack size for setting up an emulator, as much as a main thread usually has
const SETUP_STACK_SIZE: usize = 8 * 1024 * 1024;

/// Runs `f` on a thread with a stack of [`SETUP_STACK_SIZE`] and waits for it.
///
/// Setting up an emulator takes more stack than the threads of some callers have:
/// Swift concurrency's threads, which the macOS frontend calls from, have 512 KiB,
/// and running out of it crashes the process.
fn with_large_stack<T: Send>(f: impl FnOnce() -> Result<T> + Send) -> Result<T> {
    thread::scope(|scope| {
        thread::Builder::new()
            .name("snow-setup".into())
            .stack_size(SETUP_STACK_SIZE)
            .spawn_scoped(scope, f)?
            .join()
            .map_err(|_| anyhow!("Setting up the emulator failed unexpectedly"))?
    })
}

/// What the frontend has received from the emulator
#[derive(Default)]
struct Received {
    status: Option<Box<EmulatorStatus>>,
    messages: VecDeque<MachineMessage>,
    /// SCSI IDs of the drives the guest ejected a disc from, oldest first
    ejected_discs: Vec<u32>,
}

/// After a save state is loaded, the core runs its hard disks from copies in a
/// temporary directory. These are written back to the workspace's disk images when
/// the machine stops, so the images keep up with what the guest wrote.
struct DiskWriteback {
    temp_dir: PathBuf,
    /// Disk image per SCSI ID, from the workspace
    images: Vec<Option<PathBuf>>,
}

/// A running emulator. The emulator thread stops when this is released, or
/// earlier with [`Machine::power_off`].
#[derive(uniffi::Object)]
pub struct Machine {
    thread: Mutex<Option<JoinHandle<()>>>,
    cmd: EmulatorCommandSender,
    events: EmulatorEventReceiver,
    frames: Arc<Mutex<Option<DisplayBuffer>>>,
    received: Mutex<Received>,
    writeback: Mutex<Option<DiskWriteback>>,
    /// Discs made from folders, with their folders. They're removed when the
    /// machine stops; a saved state has its own copy of the discs in it.
    made_discs: Mutex<Vec<(PathBuf, PathBuf)>>,
    audio: Option<Arc<Mutex<CpalAudioProvider>>>,
}

/// Whether a machine starts with sound. This app always starts machines with
/// sound and mutes them from the toolbar instead, so the workspace's
/// `audio_disabled` (the egui frontend's "disable audio" option) is kept but not
/// used. Tests start without sound, as there may be no audio device.
const fn starts_with_sound() -> bool {
    !cfg!(test)
}

impl Machine {
    fn send(&self, cmd: EmulatorCommand) {
        // Fails only once the emulator thread is gone, which is_alive() reports
        let _ = self.cmd.send(cmd);
    }

    fn start(
        mut emulator: Emulator,
        frames: Arc<Mutex<Option<DisplayBuffer>>>,
        audio: bool,
        writeback: Option<DiskWriteback>,
    ) -> Result<Arc<Self>> {
        let cmd = emulator.create_cmd_sender();
        let events = emulator.create_event_recv();

        let mut audio_provider = None;
        if audio {
            match CpalAudioProvider::new() {
                Ok(provider) => {
                    let provider = Arc::new(Mutex::new(provider));
                    if let Err(e) = emulator.set_audio_provider(provider.clone()) {
                        error!("Failed to initialize audio: {:?}", e);
                    } else {
                        audio_provider = Some(provider);
                    }
                }
                Err(e) => error!("Failed to initialize audio: {:?}", e),
            }
        }
        if audio_provider.is_none() {
            // Without audio to pace it, pace the emulator to the video
            cmd.send(EmulatorCommand::SetSpeed(EmulatorSpeed::Video))?;
        }
        cmd.send(EmulatorCommand::Run)?;

        let thread = thread::Builder::new()
            .name("snow-emulator".into())
            .spawn(move || {
                loop {
                    match emulator.tick(1, ()) {
                        Ok(0) => break,
                        Ok(_) => (),
                        Err(e) => {
                            error!("Emulator error: {:#}", e);
                            break;
                        }
                    }
                }
            })?;

        let machine = Arc::new(Self {
            thread: Mutex::new(Some(thread)),
            cmd,
            events,
            frames,
            received: Mutex::default(),
            writeback: Mutex::new(writeback),
            made_discs: Mutex::default(),
            audio: audio_provider,
        });
        machine.wait_for_status();
        Ok(machine)
    }

    /// Waits for the first status, like the egui frontend does. Disk write-back
    /// relies on it to know where the disks run from.
    fn wait_for_status(&self) {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while self.receive().status.is_none() {
            let Some(left) = deadline.checked_duration_since(std::time::Instant::now()) else {
                warn!("No status from the emulator yet");
                return;
            };
            match self.events.recv_timeout(left) {
                Ok(EmulatorEvent::Status(status)) => {
                    self.received.lock().expect("never poisoned").status = Some(status);
                }
                Ok(EmulatorEvent::UserMessage(kind, text)) => {
                    let mut received = self.received.lock().expect("never poisoned");
                    received.messages.push_back((kind, text).into());
                }
                Ok(_) => (),
                Err(_) => return,
            }
        }
    }

    /// Starts fast-forwarding, if the workspace says so. Dynamic, as the toolbar's
    /// fast-forward button: as fast as it can, except while it plays sound.
    fn start_fast_forwarding_if(&self, fast_forward: bool) {
        if fast_forward {
            self.send(EmulatorCommand::SetSpeed(EmulatorSpeed::Dynamic));
        }
    }

    /// Puts a disc in a CD-ROM drive. Failing to read the disc is reported as a
    /// message, as the emulator reports a disc it can't load.
    fn load_disc(&self, id: usize, disc: &WorkspaceDisc) {
        match disc_image(disc) {
            Ok((image, made)) => {
                if made && let WorkspaceDisc::Folder(dir) = disc {
                    self.made_discs
                        .lock()
                        .expect("never poisoned")
                        .push((image.clone(), dir.clone()));
                }
                self.send(EmulatorCommand::ScsiLoadMedia(id, image));
            }
            Err(e) => {
                let text = format!("SCSI ID #{}: {:#}", id, e);
                warn!("{}", text);
                let mut received = self.received.lock().expect("never poisoned");
                received
                    .messages
                    .push_back((UserMessageType::Error, text).into());
            }
        }
    }

    /// Connects the Ethernet controllers the workspace has. Neither a new machine
    /// nor a resumed one has a link until it's set.
    fn connect_ethernet(&self, ws: &Workspace) {
        let link = workspace_ethernet_link(ws);
        for (id, target) in ws.scsi_targets.iter().enumerate() {
            if matches!(target, ScsiTargetEntry::Ethernet) {
                self.send(EmulatorCommand::EthernetSetLink(id, link.into()));
            }
        }
    }

    /// Whether the drive at a SCSI ID is a CD-ROM drive, and has a disc in it
    fn cdrom_has_disc(&self, id: usize) -> Option<bool> {
        self.receive()
            .status
            .as_ref()?
            .scsi
            .get(id)?
            .as_ref()
            .filter(|target| target.target_type == ScsiTargetType::Cdrom)
            .map(|target| target.image.is_some())
    }

    fn boot(workspace_path: &Path) -> Result<Arc<Self>> {
        let ws = Workspace::from_file(workspace_path)?;
        let rom_path = ws
            .rom_path
            .as_ref()
            .ok_or_else(|| anyhow!("No ROM selected"))?;
        let rom = std::fs::read(rom_path)
            .with_context(|| format!("Cannot read ROM {}", rom_path.display()))?;
        let model = match ws.model {
            Some(m) => m,
            None => MacModel::detect_from_rom(&rom)
                .ok_or_else(|| anyhow!("Unsupported ROM file; select the model manually"))?,
        };

        let read = |p: &PathBuf, what: &str| {
            std::fs::read(p).with_context(|| format!("Cannot read {} {}", what, p.display()))
        };
        let display_rom = ws
            .display_card_rom_path
            .as_ref()
            .map(|p| read(p, "display ROM"))
            .transpose()?;
        let extension_rom = ws
            .extension_rom_path
            .as_ref()
            .map(|p| read(p, "extension ROM"))
            .transpose()?;

        // As the egui frontend does
        let mut extra_roms = Vec::new();
        if let Some(ref data) = display_rom {
            if model == MacModel::SE30 {
                extra_roms.push(ExtraROMs::SE30Video(data));
            } else if ws.init_args.video_card == NubusDeviceKind::Toby {
                extra_roms.push(ExtraROMs::Toby(data));
            } else {
                extra_roms.push(ExtraROMs::MDC12(data));
            }
        }
        if let Some(ref data) = extension_rom {
            extra_roms.push(ExtraROMs::ExtensionROM(data));
        }

        let args = &ws.init_args;
        let (mut emulator, frames) = Emulator::new_with_extra(
            &rom,
            &extra_roms,
            model,
            args.monitor,
            // The screen view positions the guest's cursor directly
            MouseMode::Absolute,
            args.ram_size,
            args.override_fdd_type,
            args.pmmu_enabled,
            args.fpu_enabled,
            args.vram_size,
            ws.shared_dir.clone(),
        )?;

        if model.has_scsi() {
            for (id, target) in ws.scsi_targets.iter().enumerate() {
                match target {
                    ScsiTargetEntry::Disk(path) => {
                        emulator.load_hdd_image(path, id).with_context(|| {
                            format!("SCSI ID {}: cannot load {}", id, path.display())
                        })?;
                    }
                    ScsiTargetEntry::Cdrom => emulator.attach_cdrom(id),
                    ScsiTargetEntry::CdromFolder(dir) => {
                        emulator.attach_cdrom_folder(id, dir.clone())?;
                    }
                    ScsiTargetEntry::Ethernet => emulator.attach_ethernet(id),
                    ScsiTargetEntry::Printer => emulator.attach_printer(id, printer_output_dir()),
                    ScsiTargetEntry::None => (),
                }
            }
        }
        if let Some(ref pram) = ws.pram_path {
            emulator.persist_pram(pram);
        }

        let machine = Self::start(emulator, frames, starts_with_sound(), None)?;
        machine.start_fast_forwarding_if(args.start_fastforward);
        machine.send(EmulatorCommand::SetOverclock(args.overclock));
        for (drive, image) in ws
            .floppy_images
            .iter()
            .take(FLOPPY_DRIVES as usize)
            .enumerate()
        {
            machine.send(EmulatorCommand::InsertFloppy(
                drive,
                path_string(image),
                false,
            ));
        }
        if model.has_scsi() {
            for (id, target) in ws.scsi_targets.iter().enumerate() {
                if let (ScsiTargetEntry::Cdrom, Some(disc)) = (target, &ws.cdrom_discs[id]) {
                    machine.load_disc(id, disc);
                }
            }
            machine.connect_ethernet(&ws);
        }
        Ok(machine)
    }

    fn resume_state(
        state_path: &Path,
        workspace_path: &Path,
        temp_dir: &Path,
    ) -> Result<Arc<Self>> {
        let ws = Workspace::from_file(workspace_path)?;
        std::fs::create_dir_all(temp_dir)
            .with_context(|| format!("Cannot create {}", temp_dir.display()))?;
        let (mut emulator, frames) = Emulator::load_state(state_path, temp_dir)?;
        if let Some(ref pram) = ws.pram_path {
            // Keep persisting the PRAM; the file holds what the state does
            emulator.persist_pram(pram);
        }
        let writeback = DiskWriteback {
            temp_dir: temp_dir.to_path_buf(),
            images: ws.hdd_paths(),
        };
        let machine = Self::start(emulator, frames, starts_with_sound(), Some(writeback))?;
        machine.start_fast_forwarding_if(ws.init_args.start_fastforward);
        // The state has the discs that were in the drives. A disc chosen for a
        // drive left empty goes in, as if it were inserted while suspended.
        for (id, disc) in ws.cdrom_discs.iter().enumerate() {
            if let Some(disc) = disc
                && machine.cdrom_has_disc(id) == Some(false)
            {
                machine.load_disc(id, disc);
            }
        }
        machine.connect_ethernet(&ws);
        Ok(machine)
    }

    /// Takes in what the emulator sent
    fn receive(&self) -> MutexGuard<'_, Received> {
        let mut received = self.received.lock().expect("never poisoned");
        while let Ok(event) = self.events.try_recv() {
            match event {
                EmulatorEvent::Status(status) => received.status = Some(status),
                EmulatorEvent::UserMessage(kind, text) => {
                    received.messages.push_back((kind, text).into());
                }
                EmulatorEvent::ScsiMediaEjected(id) => received.ejected_discs.push(id as u32),
                _ => (),
            }
        }
        received
    }

    /// Stops the emulator thread and waits for it, then writes the disks back
    fn finish(&self) -> Result<()> {
        let thread = self.thread.lock().expect("never poisoned").take();
        if let Some(thread) = thread {
            let _ = self.cmd.send(EmulatorCommand::Quit);
            let _ = thread.join();
        }

        for (disc, _) in self.made_discs.lock().expect("never poisoned").drain(..) {
            let _ = std::fs::remove_file(disc);
        }

        let Some(writeback) = self.writeback.lock().expect("never poisoned").take() else {
            return Ok(());
        };
        // Where the emulator ran each disk from, as of its last status
        let running_images: Vec<Option<PathBuf>> = self
            .receive()
            .status
            .as_ref()
            .map(|s| {
                s.scsi
                    .iter()
                    .map(|t| t.as_ref().and_then(|t| t.image.clone()))
                    .collect()
            })
            .unwrap_or_default();

        let mut result = Ok(());
        for (id, image) in writeback.images.iter().enumerate() {
            let (Some(image), Some(Some(running))) = (image, running_images.get(id)) else {
                continue;
            };
            if running == image || !running.starts_with(&writeback.temp_dir) {
                continue;
            }
            match std::fs::copy(running, image) {
                Ok(_) => {
                    info!("SCSI ID {}: wrote disk back to {}", id, image.display());
                    let _ = std::fs::remove_file(running);
                }
                Err(e) => {
                    // Keep the copy so it isn't lost
                    let msg = format!(
                        "SCSI ID {}: cannot write the disk back to {}: {}. Its contents are in {}",
                        id,
                        image.display(),
                        e,
                        running.display()
                    );
                    warn!("{}", msg);
                    result = Err(anyhow!(msg));
                }
            }
        }
        result
    }

    fn power_off_saving(&self, state_path: Option<&Path>) -> Result<()> {
        let partial = state_path.map(|p| p.with_extension("snows.partial"));
        if let Some(ref partial) = partial {
            // Handled before the Quit that finish() sends
            self.send(EmulatorCommand::SaveState(partial.clone(), None));
        }
        let finished = self.finish();

        if let (Some(partial), Some(state_path)) = (partial, state_path) {
            let failure = self
                .receive()
                .messages
                .iter()
                .find(|m| {
                    m.kind == MessageKind::Error && m.text.starts_with("Failed to save state")
                })
                .map(|m| m.text.clone());
            if let Some(failure) = failure {
                let _ = std::fs::remove_file(&partial);
                bail!(failure);
            }
            if !partial.exists() {
                bail!("The emulator stopped before saving its state");
            }
            // Replace the previous state only with a complete one
            std::fs::rename(&partial, state_path)
                .with_context(|| format!("Cannot write {}", state_path.display()))?;
        }
        finished
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        if let Err(e) = self.finish() {
            error!("{:#}", e);
        }
    }
}

#[uniffi::export]
impl Machine {
    /// Starts a machine from a workspace file
    #[uniffi::constructor]
    pub fn from_workspace(workspace_path: &str) -> Result<Arc<Self>, SnowError> {
        init_logging();
        Ok(with_large_stack(|| Self::boot(Path::new(workspace_path)))?)
    }

    /// Resumes a machine from a save state. The workspace provides the settings that
    /// aren't in the state, like where its disks and PRAM are kept. `temp_dir` holds
    /// the disks while the machine runs; they are written back when it stops.
    #[uniffi::constructor]
    pub fn resume(
        state_path: &str,
        workspace_path: &str,
        temp_dir: &str,
    ) -> Result<Arc<Self>, SnowError> {
        init_logging();
        Ok(with_large_stack(|| {
            Self::resume_state(
                Path::new(state_path),
                Path::new(workspace_path),
                Path::new(temp_dir),
            )
        })?)
    }

    /// Stops the machine for good, first saving its state if `state_path` is set.
    /// Blocks until done, which can take a while with large disks. An existing
    /// state file is only replaced once the new one is complete.
    // UniFFI passes optional arguments by value
    #[allow(clippy::needless_pass_by_value)]
    pub fn power_off(&self, state_path: Option<String>) -> Result<(), SnowError> {
        Ok(self.power_off_saving(state_path.as_deref().map(Path::new))?)
    }

    /// False once the emulator thread has stopped (quit or crashed)
    pub fn is_alive(&self) -> bool {
        self.thread
            .lock()
            .expect("never poisoned")
            .as_ref()
            .is_some_and(|t| !t.is_finished())
    }

    /// The latest status, or None until the emulator first reports it
    pub fn status(&self) -> Option<MachineStatus> {
        let made_discs = self.made_discs.lock().expect("never poisoned").clone();
        self.receive()
            .status
            .as_deref()
            .map(|status| machine_status(status, &made_discs))
    }

    /// Takes the messages received since the last call
    pub fn take_messages(&self) -> Vec<MachineMessage> {
        self.receive().messages.drain(..).collect()
    }

    /// Takes the SCSI IDs of the CD-ROM drives the guest ejected a disc from since
    /// the last call, oldest first
    pub fn take_ejected_discs(&self) -> Vec<u32> {
        std::mem::take(&mut self.receive().ejected_discs)
    }

    /// Takes the newest frame, if there is one the frontend has not taken yet
    pub fn take_frame(&self) -> Option<Frame> {
        let frame = self.frames.lock().ok()?.take()?;
        Some(Frame {
            width: frame.width(),
            height: frame.height(),
            pixels: frame.into_inner(),
        })
    }

    pub fn run(&self) {
        self.send(EmulatorCommand::Run);
    }

    pub fn stop(&self) {
        self.send(EmulatorCommand::Stop);
    }

    pub fn reset(&self) {
        self.send(EmulatorCommand::Reset);
    }

    pub fn programmer_key(&self) {
        self.send(EmulatorCommand::ProgKey);
    }

    pub fn set_speed(&self, speed: EmulationSpeed) {
        self.send(EmulatorCommand::SetSpeed(speed.into()));
    }

    /// Silences the machine's sound, or lets it play again. Muted, the sound is
    /// still made and thrown away, so the machine keeps the same speed.
    pub fn set_muted(&self, muted: bool) {
        if let Some(audio) = &self.audio {
            audio.lock().unwrap().set_mute(muted);
        }
    }

    /// Key press or release, as a 'Snow universal' scancode (Apple Extended Keyboard)
    pub fn key(&self, scancode: u8, down: bool) {
        let ev = if down {
            KeyEvent::KeyDown(scancode, Keymap::Universal)
        } else {
            KeyEvent::KeyUp(scancode, Keymap::Universal)
        };
        self.send(EmulatorCommand::KeyEvent(ev));
    }

    pub fn release_all_inputs(&self) {
        self.send(EmulatorCommand::ReleaseAllInputs);
    }

    /// Moves the mouse to a position on the guest's screen, in pixels
    pub fn mouse_absolute(&self, x: u16, y: u16) {
        self.send(EmulatorCommand::MouseUpdateAbsolute { x, y });
    }

    pub fn mouse_button(&self, down: bool) {
        self.send(EmulatorCommand::MouseUpdateRelative {
            relx: 0,
            rely: 0,
            btn: Some(down),
        });
    }

    /// Inserts a floppy image file. Failures come back through take_messages().
    pub fn insert_floppy(&self, drive: u32, path: String, write_protect: bool) {
        if drive < FLOPPY_DRIVES {
            self.send(EmulatorCommand::InsertFloppy(
                drive as usize,
                path,
                write_protect,
            ));
        }
    }

    /// Puts a disc in the CD-ROM drive at a SCSI ID, replacing the one in it. Does
    /// nothing if there's no CD-ROM drive there.
    // UniFFI passes arguments by value
    #[allow(clippy::needless_pass_by_value)]
    pub fn insert_disc(&self, id: u32, disc: CdromDisc) {
        let id = id as usize;
        if self.cdrom_has_disc(id).is_some() {
            self.load_disc(id, &WorkspaceDisc::from(&disc));
        }
    }

    /// Adds a CD-ROM drive at a free SCSI ID while the machine runs, with a disc in
    /// it. Does nothing if something is at that ID already.
    // UniFFI passes arguments by value
    #[allow(clippy::needless_pass_by_value)]
    pub fn attach_cdrom(&self, id: u32, disc: CdromDisc) {
        let id = id as usize;
        let free = self
            .receive()
            .status
            .as_ref()
            .and_then(|s| s.scsi.get(id).map(Option::is_none));
        if free == Some(true) {
            self.send(EmulatorCommand::ScsiAttachCdrom(id));
            self.load_disc(id, &WorkspaceDisc::from(&disc));
        }
    }

    /// Changes how the Ethernet controllers connect
    pub fn set_ethernet_link(&self, link: EthernetLink) {
        let ids: Vec<usize> = self
            .receive()
            .status
            .as_ref()
            .map(|s| {
                s.scsi
                    .iter()
                    .enumerate()
                    .filter(|(_, t)| {
                        t.as_ref()
                            .is_some_and(|t| t.target_type == ScsiTargetType::Ethernet)
                    })
                    .map(|(id, _)| id)
                    .collect()
            })
            .unwrap_or_default();
        for id in ids {
            self.send(EmulatorCommand::EthernetSetLink(id, link.into()));
        }
    }

    pub fn eject_floppy(&self, drive: u32) {
        if drive < FLOPPY_DRIVES {
            self.send(EmulatorCommand::EjectFloppy(drive as usize));
        }
    }

    /// Writes a copy of the current state to a file, leaving the machine running.
    /// Failures come back through take_messages().
    pub fn export_state(&self, path: String) {
        self.send(EmulatorCommand::SaveState(PathBuf::from(path), None));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Seek, SeekFrom, Write};

    const DISK_SIZE: usize = 2 * 1024 * 1024;

    #[test]
    fn dropped_files_are_told_apart() {
        let dir = std::env::temp_dir().join(format!("snow_ffi_kind_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let write = |name: &str, data: &[u8]| {
            let path = dir.join(name);
            std::fs::write(&path, data).unwrap();
            path.to_string_lossy().into_owned()
        };
        let mut moof = b"MOOF\xFF\n\r\n".to_vec();
        moof.resize(1024, 0);

        assert_eq!(
            disk_image_kind(&write("disk.moof", &moof)),
            Some(DiskImageKind::Floppy)
        );
        assert_eq!(
            disk_image_kind(&write("disc.iso", &[0; 1024])),
            Some(DiskImageKind::Cdrom)
        );
        assert_eq!(
            disk_image_kind(&write("disc.CUE", b"FILE")),
            Some(DiskImageKind::Cdrom)
        );
        // A floppy extension, but not what a floppy image holds
        assert_eq!(disk_image_kind(&write("notes.dc42", b"text")), None);
        assert_eq!(disk_image_kind(&write("notes.txt", b"text")), None);
        assert_eq!(
            disk_image_kind(&dir.join("missing.moof").to_string_lossy()),
            None
        );

        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// A Macintosh Plus with a blank ROM, which just runs no-ops, and a hard disk
    fn setup(name: &str) -> (PathBuf, PathBuf, PathBuf) {
        let dir =
            std::env::temp_dir().join(format!("snow_ffi_machine_{}_{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        std::fs::write(dir.join("blank.rom"), vec![0u8; 128 * 1024]).unwrap();
        let disk = dir.join("hd.img");
        std::fs::write(&disk, vec![0xAAu8; DISK_SIZE]).unwrap();

        let ws_path = dir.join("Machine.snoww");
        write_workspace(
            ws_path.to_str().unwrap(),
            &MachineConfig {
                rom_path: path_string(&dir.join("blank.rom")),
                model: model_index(MacModel::Plus),
                display_rom_path: None,
                display_card: DisplayCard::Mdc824,
                scsi_devices: vec![ScsiDevice::Disk {
                    path: path_string(&disk),
                }],
                ethernet_link: EthernetLink::Nat,
                pram_path: Some(path_string(&dir.join("PRAM.pram"))),
                audio: false,
                ram_size: Some(1024 * 1024),
                vram_size: None,
                fpu: false,
                pmmu: false,
                floppy_800k: false,
                monitor: None,
            },
        )
        .unwrap();
        (dir, ws_path, disk)
    }

    #[test]
    fn ethernet_round_trips_as_the_egui_frontend_keeps_it() {
        let (dir, ws_path, _) = setup("ethernet");
        let path = ws_path.to_str().unwrap();
        // Without a link, the egui frontend uses NAT
        assert_eq!(
            read_workspace(path).unwrap().ethernet_link,
            EthernetLink::Nat
        );

        let mut config = read_workspace(path).unwrap();
        config.scsi_devices[6] = ScsiDevice::Ethernet;
        config.ethernet_link = EthernetLink::NatHttpsStripping;
        write_workspace(path, &config).unwrap();
        let written: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&ws_path).unwrap()).unwrap();
        assert_eq!(written["scsi_targets"][6], "Ethernet");
        assert_eq!(written["ethernet_link_type"], "NATHttpsStripping");
        let reread = read_workspace(path).unwrap();
        assert_eq!(reread.scsi_devices[6], ScsiDevice::Ethernet);
        assert_eq!(reread.ethernet_link, EthernetLink::NatHttpsStripping);

        // A bridge, which this build can't make, reads as down and is kept
        let mut ws = Workspace::from_file(&ws_path).unwrap();
        ws.other.insert(
            ETHERNET_LINK_KEY.to_string(),
            serde_json::json!({"Bridge": 4}),
        );
        ws.write_file(&ws_path).unwrap();
        let config = read_workspace(path).unwrap();
        assert_eq!(config.ethernet_link, EthernetLink::Down);
        write_workspace(path, &config).unwrap();
        let written: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&ws_path).unwrap()).unwrap();
        assert_eq!(written["ethernet_link_type"]["Bridge"], 4);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn unknown_roms_run_in_no_model() {
        assert!(models_for_rom_data(&[0u8; 1024]).is_empty());
        assert!(models_for_rom("/nonexistent.rom").is_empty());
    }

    #[test]
    fn model_identifiers_are_the_workspace_names() {
        let all = models();
        for info in &all {
            let model = model_by_index(info.index).unwrap();
            let json = serde_json::to_string(&model).unwrap();
            assert_eq!(json, format!("\"{}\"", info.identifier));
        }
        assert_eq!(all[0].identifier, "Early128K");
        // Unique even when lowercased, as the app's symbol names are
        let mut lowercased: Vec<String> = all.iter().map(|m| m.identifier.to_lowercase()).collect();
        lowercased.sort();
        lowercased.dedup();
        assert_eq!(lowercased.len(), all.len());
    }

    #[test]
    fn unknown_display_roms_are_not_identified() {
        assert_eq!(identify_display_rom_data(&[0; 32 * 1024]), None);
        assert_eq!(identify_display_rom("/nonexistent/display.rom"), None);
    }

    #[test]
    fn monitor_info_splits_name_and_resolution() {
        let info = monitor_info(Monitor::Rgb21);
        assert_eq!(info.name, "21\" RGB");
        assert_eq!((info.width, info.height), (1152, 870));
        assert_eq!(monitor_info(Monitor::TwoPageBw).name, "21\" Two-Page");
        assert_eq!(monitor_info(Monitor::Vga).name, "VGA");
    }

    #[test]
    fn hardware_options_round_trip() {
        let (dir, ws_path, _) = setup("options");
        let path = ws_path.to_str().unwrap();
        let mut config = read_workspace(path).unwrap();
        assert_eq!(config.ram_size, Some(1024 * 1024));

        config.model = model_index(MacModel::Early128K);
        config.ram_size = None;
        config.floppy_800k = true;
        config.fpu = true;
        config.pmmu = true;
        config.monitor = Some(Monitor::Rgb21);
        config.vram_size = Some(512 * 1024);
        write_workspace(path, &config).unwrap();

        let ws = Workspace::from_file(&ws_path).unwrap();
        assert_eq!(ws.init_args.ram_size, None);
        assert_eq!(ws.init_args.override_fdd_type, Some(DriveType::GCR800KPWM));
        assert!(ws.init_args.fpu_enabled && ws.init_args.pmmu_enabled);
        // Set on its own, and kept by writing the rest
        assert!(!ws.init_args.start_fastforward);
        write_workspace_fast_forward(path, true).unwrap();
        write_workspace(path, &config).unwrap();
        assert!(
            Workspace::from_file(&ws_path)
                .unwrap()
                .init_args
                .start_fastforward
        );
        assert_eq!(ws.init_args.monitor, Some(MacMonitor::RGB21));
        assert_eq!(ws.init_args.vram_size, Some(512 * 1024));
        assert_eq!(read_workspace(path).unwrap().vram_size, Some(512 * 1024));

        let read = read_workspace(path).unwrap();
        assert!(read.floppy_800k && read.fpu && read.pmmu);

        config.floppy_800k = false;
        write_workspace(path, &config).unwrap();
        assert_eq!(
            Workspace::from_file(&ws_path)
                .unwrap()
                .init_args
                .override_fdd_type,
            None
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    /// Where the emulator runs a disk from. The first status can predate the disks
    /// being attached, so this waits for one that has it.
    fn running_image(machine: &Machine, id: usize) -> PathBuf {
        for _ in 0..200 {
            let image = machine
                .receive()
                .status
                .as_ref()
                .and_then(|s| s.scsi[id].as_ref())
                .and_then(|t| t.image.clone());
            if let Some(image) = image {
                return image;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("SCSI ID {} never showed up in the status", id);
    }

    /// Writes into a disk image the way the guest would
    fn poke(path: &Path, offset: u64, data: &[u8]) {
        let mut f = std::fs::OpenOptions::new().write(true).open(path).unwrap();
        f.seek(SeekFrom::Start(offset)).unwrap();
        f.write_all(data).unwrap();
    }

    fn peek(path: &Path, offset: u64, len: usize) -> Vec<u8> {
        let mut f = File::open(path).unwrap();
        f.seek(SeekFrom::Start(offset)).unwrap();
        let mut buf = vec![0; len];
        f.read_exact(&mut buf).unwrap();
        buf
    }

    use std::fs::File;

    /// Setting up any model must not depend on the caller's stack. Swift
    /// concurrency's threads have 512 KiB.
    #[test]
    fn sets_up_every_model_from_a_small_stack() {
        let (dir, ws_path, _) = setup("stack");
        for model in MacModel::iter() {
            let mut config = read_workspace(ws_path.to_str().unwrap()).unwrap();
            config.model = model_index(model);
            write_workspace(ws_path.to_str().unwrap(), &config).unwrap();

            let ws = path_string(&ws_path);
            let result = thread::Builder::new()
                .stack_size(512 * 1024)
                .spawn(move || Machine::from_workspace(&ws).map(|m| m.power_off(None)))
                .unwrap()
                .join();
            // Some models refuse a blank ROM or need a display ROM; that's fine as
            // long as it's an error rather than a crash
            assert!(result.is_ok(), "{} crashed", model);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn suspend_resume_and_write_disks_back() {
        let (dir, ws_path, disk) = setup("cycle");
        let state = dir.join("State.snows");
        let temp = dir.join("tmp");

        // Cold boot runs from the disk image itself
        let machine = Machine::boot(&ws_path).unwrap();
        assert!(machine.is_alive());
        assert_eq!(running_image(&machine, 0), disk);
        std::thread::sleep(std::time::Duration::from_millis(200));
        machine.power_off_saving(Some(&state)).unwrap();
        assert!(!machine.is_alive());
        assert!(state.exists());
        assert!(!state.with_extension("snows.partial").exists());

        // Resuming runs from a copy in the temporary directory
        let machine = Machine::resume_state(&state, &ws_path, &temp).unwrap();
        let copy = running_image(&machine, 0);
        assert!(
            copy.starts_with(&temp),
            "{} is not a temporary copy",
            copy.display()
        );
        poke(&copy, 4096, b"written by the guest");

        // Powering off writes the copy back and removes it
        machine.power_off_saving(None).unwrap();
        assert_eq!(peek(&disk, 4096, 20), b"written by the guest");
        assert_eq!(peek(&disk, 0, 4), [0xAA; 4]);
        assert_eq!(std::fs::metadata(&disk).unwrap().len(), DISK_SIZE as u64);
        assert!(!copy.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn suspending_a_resumed_machine_keeps_the_disk_current() {
        let (dir, ws_path, disk) = setup("resuspend");
        let state = dir.join("State.snows");
        let temp = dir.join("tmp");

        Machine::boot(&ws_path)
            .unwrap()
            .power_off_saving(Some(&state))
            .unwrap();

        let machine = Machine::resume_state(&state, &ws_path, &temp).unwrap();
        poke(&running_image(&machine, 0), 0, b"second session");
        machine.power_off_saving(Some(&state)).unwrap();
        // The image is current even while the machine is suspended
        assert_eq!(peek(&disk, 0, 14), b"second session");

        // And the new state carries the change too
        let machine = Machine::resume_state(&state, &ws_path, &temp).unwrap();
        assert_eq!(peek(&running_image(&machine, 0), 0, 14), b"second session");
        drop(machine);
        // Dropping without power_off also writes back
        assert_eq!(peek(&disk, 0, 14), b"second session");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
