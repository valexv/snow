//! Snow workspace files (`.snoww`), compatible with `frontend_egui/src/workspace.rs`.
//!
//! Only the fields this frontend needs are interpreted. Everything else in the file,
//! such as the egui frontend's window layout and shaders, is kept as it is, so a
//! workspace stays usable in both frontends. Paths are stored relative to the
//! workspace's directory, like the egui frontend does.

use std::fs::File;
use std::io::{BufReader, BufWriter, Write};
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use snow_core::emulator::MouseMode;
use snow_core::mac::swim::drive::DriveType;
use snow_core::mac::{MacModel, MacMonitor, NubusDeviceKind};

pub const SCSI_TARGETS: usize = 7;

/// Configured SCSI target, as `WorkspaceScsiTarget` in the egui frontend
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
pub enum ScsiTargetEntry {
    #[default]
    None,
    Disk(PathBuf),
    Cdrom,
    CdromFolder(PathBuf),
    Ethernet,
    Printer,
}

/// The disc in a CD-ROM drive when the machine starts. This frontend's own: the
/// egui frontend inserts discs into a running machine only.
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub enum WorkspaceDisc {
    Image(PathBuf),
    /// A folder, made into a disc when it's inserted
    Folder(PathBuf),
}

impl WorkspaceDisc {
    fn path_mut(&mut self) -> &mut PathBuf {
        match self {
            Self::Image(p) | Self::Folder(p) => p,
        }
    }
}

/// Emulator initialization arguments, as `EmulatorInitArgs` in the egui frontend
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
#[serde(default)]
pub struct InitArgs {
    pub audio_disabled: bool,
    pub monitor: Option<MacMonitor>,
    /// Deprecated; now mouse_mode
    #[serde(skip_serializing)]
    pub mouse_disabled: Option<bool>,
    pub mouse_mode: MouseMode,
    pub start_fastforward: bool,
    pub ram_size: Option<usize>,
    pub override_fdd_type: Option<DriveType>,
    pub pmmu_enabled: bool,
    pub fpu_enabled: bool,
    pub vram_size: Option<usize>,
    pub video_card: NubusDeviceKind,
    pub overclock: Option<u64>,
    #[serde(flatten)]
    pub other: Map<String, Value>,
}

/// A workspace file. Paths are absolute while loaded.
#[derive(Serialize, Deserialize, Debug, Clone, Default)]
#[serde(default)]
pub struct Workspace {
    pub rom_path: Option<PathBuf>,
    pub display_card_rom_path: Option<PathBuf>,
    pub pram_path: Option<PathBuf>,
    pub extension_rom_path: Option<PathBuf>,
    pub scsi_targets: [ScsiTargetEntry; SCSI_TARGETS],
    pub init_args: InitArgs,
    pub model: Option<MacModel>,
    pub shared_dir: Option<PathBuf>,
    pub floppy_images: Vec<PathBuf>,
    /// The disc in each CD-ROM drive, by SCSI ID
    #[serde(skip_serializing_if = "no_discs")]
    pub cdrom_discs: [Option<WorkspaceDisc>; SCSI_TARGETS],
    /// Everything this frontend doesn't use
    #[serde(flatten)]
    pub other: Map<String, Value>,
}

impl Workspace {
    fn paths_mut(&mut self) -> impl Iterator<Item = &mut PathBuf> {
        let scsi = self.scsi_targets.iter_mut().filter_map(|t| match t {
            ScsiTargetEntry::Disk(p) | ScsiTargetEntry::CdromFolder(p) => Some(p),
            _ => None,
        });
        [
            self.rom_path.as_mut(),
            self.display_card_rom_path.as_mut(),
            self.pram_path.as_mut(),
            self.extension_rom_path.as_mut(),
            self.shared_dir.as_mut(),
        ]
        .into_iter()
        .flatten()
        .chain(scsi)
        .chain(self.floppy_images.iter_mut())
        .chain(
            self.cdrom_discs
                .iter_mut()
                .flatten()
                .map(WorkspaceDisc::path_mut),
        )
    }

    fn base_dir(path: &Path) -> &Path {
        match path.parent() {
            Some(p) if !p.as_os_str().is_empty() => p,
            _ => Path::new("."),
        }
    }

    pub fn from_file(path: &Path) -> Result<Self> {
        let file = File::open(path).with_context(|| format!("Cannot open {}", path.display()))?;
        let mut ws: Self = serde_json::from_reader(BufReader::new(file))
            .with_context(|| format!("Cannot read workspace {}", path.display()))?;

        // Migrate the deprecated mouse_disabled, as the egui frontend does
        if ws.init_args.mouse_disabled == Some(true) {
            ws.init_args.mouse_mode = MouseMode::Disabled;
        }

        let base = Self::base_dir(path).to_path_buf();
        for p in ws.paths_mut() {
            *p = normalize(&base.join(&*p));
        }
        Ok(ws)
    }

    /// Writes the workspace, replacing the file only once it's complete
    pub fn write_file(&self, path: &Path) -> Result<()> {
        let mut ws = self.clone();
        let base = Self::base_dir(path).to_path_buf();
        for p in ws.paths_mut() {
            if let Some(rel) = pathdiff::diff_paths(&*p, &base) {
                *p = rel;
            }
        }

        let partial = path.with_extension("snoww.partial");
        {
            let mut writer = BufWriter::new(
                File::create(&partial)
                    .with_context(|| format!("Cannot write {}", partial.display()))?,
            );
            serde_json::to_writer_pretty(&mut writer, &ws)?;
            writer.flush()?;
        }
        std::fs::rename(&partial, path)
            .with_context(|| format!("Cannot write {}", path.display()))?;
        Ok(())
    }

    /// Hard disk image per SCSI ID, if the target is a disk
    pub fn hdd_paths(&self) -> Vec<Option<PathBuf>> {
        self.scsi_targets
            .iter()
            .map(|t| match t {
                ScsiTargetEntry::Disk(p) => Some(p.clone()),
                _ => None,
            })
            .collect()
    }
}

fn no_discs(discs: &[Option<WorkspaceDisc>; SCSI_TARGETS]) -> bool {
    discs.iter().all(Option::is_none)
}

/// Resolves `.` and `..` in a path without looking at the file system, so paths to
/// files that don't exist (yet) can be read too
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => (),
            Component::ParentDir
                if matches!(out.components().next_back(), Some(Component::Normal(_))) =>
            {
                out.pop();
            }
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A workspace as the egui frontend writes it, abbreviated
    const EGUI_WORKSPACE: &str = r#"{
        "log_open": true,
        "viewport_scale": 3.0,
        "rom_path": "roms/Plus.rom",
        "display_card_rom_path": null,
        "scsi_targets": [{"Disk": "disks/hd.img"}, "Cdrom", "None", "None", "None", "None", "Ethernet"],
        "windows": {"Log": [1.0, 2.0, 3.0, 4.0]},
        "init_args": {"audio_disabled": false, "mouse_mode": "Absolute", "ram_size": 4194304,
                      "video_card": "Toby", "some_future_arg": 7},
        "model": "Plus",
        "floppy_images": ["floppies/System.img"],
        "shader_configs": [{"anything": 1}]
    }"#;

    fn temp_dir(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("snow_ffi_test_{}_{}", name, std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn reads_egui_workspace() {
        let dir = temp_dir("read");
        let path = dir.join("a.snoww");
        std::fs::write(&path, EGUI_WORKSPACE).unwrap();

        let ws = Workspace::from_file(&path).unwrap();
        assert_eq!(ws.rom_path, Some(dir.join("roms/Plus.rom")));
        assert_eq!(ws.model, Some(MacModel::Plus));
        assert_eq!(ws.init_args.ram_size, Some(4194304));
        assert_eq!(ws.init_args.video_card, NubusDeviceKind::Toby);
        assert_eq!(ws.hdd_paths()[0], Some(dir.join("disks/hd.img")));
        assert!(matches!(ws.scsi_targets[1], ScsiTargetEntry::Cdrom));
        assert_eq!(ws.floppy_images, vec![dir.join("floppies/System.img")]);
    }

    #[test]
    fn keeps_unknown_fields_and_rebases_paths() {
        let dir = temp_dir("roundtrip");
        let source = dir.join("a.snoww");
        std::fs::write(&source, EGUI_WORKSPACE).unwrap();
        std::fs::create_dir_all(dir.join("machines/m")).unwrap();
        let dest = dir.join("machines/m/b.snoww");

        Workspace::from_file(&source)
            .unwrap()
            .write_file(&dest)
            .unwrap();
        let written: Value =
            serde_json::from_str(&std::fs::read_to_string(&dest).unwrap()).unwrap();

        // Fields only the egui frontend knows are kept
        assert_eq!(written["log_open"], true);
        assert_eq!(written["viewport_scale"], 3.0);
        assert_eq!(written["windows"]["Log"][2], 3.0);
        assert_eq!(written["shader_configs"][0]["anything"], 1);
        assert_eq!(written["init_args"]["some_future_arg"], 7);
        // Paths are relative to the new location
        assert_eq!(written["rom_path"], "../../roms/Plus.rom");
        assert_eq!(written["scsi_targets"][0]["Disk"], "../../disks/hd.img");
        assert_eq!(written["scsi_targets"][6], "Ethernet");
        // And resolve to the same files
        let reread = Workspace::from_file(&dest).unwrap();
        assert_eq!(reread.rom_path, Some(dir.join("roms/Plus.rom")));
        assert!(!dir.join("machines/m/b.snoww.partial").exists());
        // No discs, so the egui frontend's file gains nothing
        assert!(written.get("cdrom_discs").is_none());
    }

    #[test]
    fn discs_round_trip_relative_to_the_workspace() {
        let dir = temp_dir("discs");
        let path = dir.join("m/a.snoww");
        std::fs::create_dir_all(dir.join("m")).unwrap();
        let mut ws = Workspace::default();
        ws.scsi_targets[3] = ScsiTargetEntry::Cdrom;
        ws.cdrom_discs[3] = Some(WorkspaceDisc::Folder(dir.join("Stuff")));
        ws.write_file(&path).unwrap();

        let written: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(written["cdrom_discs"][3]["Folder"], "../Stuff");
        let reread = Workspace::from_file(&path).unwrap();
        assert_eq!(
            reread.cdrom_discs[3],
            Some(WorkspaceDisc::Folder(dir.join("Stuff")))
        );
    }
}
