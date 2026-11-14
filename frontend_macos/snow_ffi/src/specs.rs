//! What each supported model shipped with, for showing and for defaults when setting
//! up a machine. The configurations are those of each model's base (least expensive)
//! configuration when it was introduced.

use snow_core::mac::MacModel;

/// The kind of machine a model is
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum FormFactor {
    /// Screen built in: the compact Macs, from the 128K to the Classic and SE/30
    AllInOne,
    /// A separate monitor: the Macintosh II, LC and Quadra lines
    Desktop,
    /// Battery powered: the Macintosh Portable
    Portable,
}

/// A kind of floppy drive
#[derive(uniffi::Enum, Clone, Copy, PartialEq, Eq, Debug)]
pub enum FloppyKind {
    /// 400K single-sided
    Gcr400k,
    /// 800K double-sided
    Gcr800k,
    /// 1.4MB FDHD SuperDrive, which also reads 400K and 800K disks
    SuperDrive,
}

/// What a model shipped with
#[derive(uniffi::Record, Clone, PartialEq, Debug)]
pub struct ModelSpecs {
    pub form_factor: FormFactor,
    /// Year Apple introduced it
    pub release_year: u16,
    /// CPU part, like "68030" or "68LC040"
    pub cpu: String,
    /// CPU clock in MHz
    pub cpu_mhz: f64,
    /// Built-in floppy drives
    pub floppy_drives: u8,
    pub floppy_kind: FloppyKind,
    /// Size of the internal hard disk in MB, or None if the base model had none
    pub hard_disk_mb: Option<u32>,
}

/// 7.8336 MHz, the clock of the compact Macs
const COMPACT_MHZ: f64 = 7.8336;
/// 15.6672 MHz, twice the compact Macs' clock
const MAC_II_MHZ: f64 = 15.6672;

pub fn model_specs(model: MacModel) -> ModelSpecs {
    use FloppyKind::*;
    use FormFactor::*;
    #[rustfmt::skip]
    let (form_factor, release_year, cpu, cpu_mhz, floppy_drives, floppy_kind, hard_disk_mb) =
        match model {
            MacModel::Early128K => (AllInOne, 1984, "68000", COMPACT_MHZ, 1, Gcr400k, None),
            MacModel::Early512K => (AllInOne, 1984, "68000", COMPACT_MHZ, 1, Gcr400k, None),
            MacModel::Early512Ke => (AllInOne, 1986, "68000", COMPACT_MHZ, 1, Gcr800k, None),
            MacModel::Plus => (AllInOne, 1986, "68000", COMPACT_MHZ, 1, Gcr800k, None),
            MacModel::SE => (AllInOne, 1987, "68000", COMPACT_MHZ, 2, Gcr800k, None),
            MacModel::SeFdhd => (AllInOne, 1989, "68000", COMPACT_MHZ, 1, SuperDrive, Some(20)),
            MacModel::Classic => (AllInOne, 1990, "68000", COMPACT_MHZ, 1, SuperDrive, None),
            MacModel::Portable | MacModel::Portable15MB => {
                (Portable, 1989, "68HC000", MAC_II_MHZ, 1, SuperDrive, Some(40))
            }
            MacModel::MacII => (Desktop, 1987, "68020", MAC_II_MHZ, 1, Gcr800k, None),
            MacModel::MacIIFDHD => (Desktop, 1989, "68020", MAC_II_MHZ, 1, SuperDrive, Some(40)),
            MacModel::MacIIx => (Desktop, 1988, "68030", MAC_II_MHZ, 1, SuperDrive, Some(80)),
            MacModel::MacIIcx => (Desktop, 1989, "68030", MAC_II_MHZ, 1, SuperDrive, Some(40)),
            MacModel::SE30 => (AllInOne, 1989, "68030", MAC_II_MHZ, 1, SuperDrive, Some(40)),
            MacModel::LC => (Desktop, 1990, "68020", MAC_II_MHZ, 1, SuperDrive, Some(40)),
            MacModel::LCII => (Desktop, 1992, "68030", MAC_II_MHZ, 1, SuperDrive, Some(40)),
            MacModel::LCIII => (Desktop, 1993, "68030", 25.0, 1, SuperDrive, Some(80)),
            MacModel::LC475 => (Desktop, 1993, "68LC040", 25.0, 1, SuperDrive, Some(80)),
            MacModel::Quadra700 => (Desktop, 1991, "68040", 25.0, 1, SuperDrive, Some(80)),
        };
    ModelSpecs {
        form_factor,
        release_year,
        cpu: cpu.to_owned(),
        cpu_mhz,
        floppy_drives,
        floppy_kind,
        hard_disk_mb,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use strum::IntoEnumIterator;

    /// The CPU family in the record matches the one the core emulates
    #[test]
    fn cpu_matches_the_core() {
        for model in MacModel::iter() {
            let specs = model_specs(model);
            // The core's CPU types are the part numbers: 68000, 68020...
            let family = format!("{:03}", model.cpu_type() % 1000);
            assert!(specs.cpu.ends_with(&family), "{:?}: {}", model, specs.cpu);
        }
    }

    /// Models without SCSI can't have had a hard disk, and the drives fit in the
    /// emulated machine
    #[test]
    fn fits_the_emulated_hardware() {
        for model in MacModel::iter() {
            let specs = model_specs(model);
            if !model.has_scsi() {
                assert_eq!(specs.hard_disk_mb, None, "{:?}", model);
            }
            assert!(
                usize::from(specs.floppy_drives) <= model.fdd_drives().len(),
                "{:?}",
                model
            );
            assert_eq!(
                specs.floppy_kind == FloppyKind::SuperDrive,
                model.fdd_hd(),
                "{:?}",
                model
            );
        }
    }
}
