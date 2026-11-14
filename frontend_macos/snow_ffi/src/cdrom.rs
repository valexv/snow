//! Discs for CD-ROM drives: disc images, and folders made into discs.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use anyhow::{Context, Result, bail};
use log::warn;

/// A disc in a CD-ROM drive
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum CdromDisc {
    /// An image of a disc (`.iso`, `.toast`, `.cue`)
    Image { path: String },
    /// A folder, whose files are made into a disc when it's inserted
    Folder { path: String },
}

/// Makes the files in a folder into a disc image in the temporary directory, as the
/// egui frontend's "Mount image from files" does. Only the folder's own files go on
/// the disc, without its subfolders or hidden files.
pub fn make_disc_from_folder(folder: &Path) -> Result<PathBuf> {
    let mut entries: Vec<PathBuf> = std::fs::read_dir(folder)
        .with_context(|| format!("Cannot read {}", folder.display()))?
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.is_file())
        .filter(|p| {
            !p.file_name()
                .map(|n| n.to_string_lossy().starts_with('.'))
                .unwrap_or(true)
        })
        .collect();
    entries.sort();
    if entries.is_empty() {
        bail!("{} has no files to put on a disc", folder.display());
    }

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let path = std::env::temp_dir().join(format!(
        "snow_disc_{}_{}.iso",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let volume = folder
        .file_name()
        .map(|n| volume_name(&n.to_string_lossy()))
        .unwrap_or_default();
    write_iso(
        &entries,
        if volume.is_empty() { "SNOW" } else { &volume },
        &path,
    )?;
    Ok(path)
}

/// An ISO 9660 volume identifier: upper case letters, digits and underscores
fn volume_name(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .take(32)
        .collect()
}

/// As `create_temp_iso` in the egui frontend
fn write_iso(paths: &[PathBuf], volume: &str, out: &Path) -> Result<()> {
    // ISO-9660 interchange level 2 is max 31 characters
    const MAX_FILENAME_LEN: usize = 30;

    let mut files = hadris_iso::FileInput::empty();
    for p in paths {
        let Some(stem) = p.file_stem().map(|s| s.to_string_lossy().to_string()) else {
            warn!("Skipping {}: no name", p.display());
            continue;
        };

        // The extension: upper case, at most 3 letters and digits
        let mut extension = p
            .extension()
            .unwrap_or_default()
            .to_string_lossy()
            .to_ascii_uppercase()
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .take(3)
            .collect::<String>();
        if !extension.is_empty() {
            extension = format!(".{}", extension);
        }

        // The characters ISO-9660 allows
        let mut name = stem
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || c == '_' {
                    c
                } else {
                    '_'
                }
            })
            .collect::<String>();

        // Shortened to fit, numbered to keep names apart
        let max_len = MAX_FILENAME_LEN - extension.len();
        if name.len() > max_len {
            for n in 1.. {
                let suffix = format!("_{}", n);
                let truncated = format!("{}{}", &name[..(max_len - suffix.len())], suffix);
                if files.get(&format!("{}{}", truncated, extension)).is_none() {
                    name = truncated;
                    break;
                }
            }
        }
        name.push_str(&extension);

        files.append(hadris_iso::File {
            path: name,
            data: hadris_iso::FileData::File(p.clone()),
        });
    }
    let options = hadris_iso::FormatOption::default()
        .with_files(files)
        .with_volume_name(volume.to_string());
    hadris_iso::IsoImage::format_file(out, options)
        .with_context(|| format!("Cannot make a disc of the files in {}", out.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn makes_a_disc_of_a_folders_files() {
        let dir = std::env::temp_dir().join(format!("snow_ffi_disc_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("Sub folder")).unwrap();
        std::fs::write(dir.join("Read Me.txt"), b"hello").unwrap();
        std::fs::write(dir.join(".hidden"), b"secret").unwrap();
        std::fs::write(dir.join("Sub folder/inner"), b"inner").unwrap();

        let iso = make_disc_from_folder(&dir).unwrap();
        let data = std::fs::read(&iso).unwrap();
        let _ = std::fs::remove_file(&iso);
        let contains = |needle: &[u8]| data.windows(needle.len()).any(|w| w == needle);
        assert!(contains(b"READ_ME.TXT") || contains(b"Read_Me.TXT"));
        assert!(contains(b"hello"));
        assert!(!contains(b"secret"));
        assert!(!contains(b"inner"));
    }

    #[test]
    fn an_empty_folder_makes_no_disc() {
        let dir = std::env::temp_dir().join(format!("snow_ffi_nodisc_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        assert!(make_disc_from_folder(&dir).is_err());
    }
}
