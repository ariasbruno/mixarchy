use std::error::Error;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Write};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use lofty::file::{AudioFile, TaggedFileExt};
use lofty::probe::Probe;
use lofty::tag::Accessor;
use walkdir::WalkDir;

use crate::models::{format_duration, LibraryData, PlaylistItem, PlayerState, TrackItem};

pub fn cache_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    let path = PathBuf::from(home).join(".cache").join("mixarchy");
    // library.json / state.json carry absolute track paths and the current
    // playlist position; with the default umask (0755) any local user could
    // read them. Create (and re-assert) 0700 so the cache is private:
    // recursive creation applies the mode to every directory it creates, and
    // set_permissions tightens a pre-existing directory that predates the
    // policy. Failures stay silent — the path is still returned and the
    // cache is best-effort, exactly as before.
    let _ = fs::DirBuilder::new().mode(0o700).recursive(true).create(&path);
    let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o700));
    path
}

pub fn lib_cache_file() -> PathBuf {
    cache_dir().join("library.json")
}

pub fn state_file() -> PathBuf {
    cache_dir().join("state.json")
}

const MAX_STAGING_ATTEMPTS: usize = 128;

fn staging_candidate(destination: &Path, token: &str) -> PathBuf {
    let parent = destination.parent().unwrap_or_else(|| Path::new("."));
    let file_name = destination
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("output");
    parent.join(format!(".{file_name}.{token}.tmp"))
}

fn create_staging_file_with_candidates<F>(
    destination: &Path,
    mut next_candidate: F,
) -> io::Result<(PathBuf, File)>
where
    F: FnMut() -> io::Result<PathBuf>,
{
    for _ in 0..MAX_STAGING_ATTEMPTS {
        let candidate = next_candidate()?;
        if candidate.parent() != destination.parent() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "staging file must be in the destination directory",
            ));
        }
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => return Ok((candidate, file)),
            Err(err) if err.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(err),
        }
    }

    Err(io::Error::new(
        io::ErrorKind::AlreadyExists,
        "could not allocate an unused staging file name",
    ))
}

pub(crate) fn create_staging_file(destination: &Path) -> io::Result<(PathBuf, File)> {
    create_staging_file_with_candidates(destination, || {
        let token = format!("{:032x}", rand::random::<u128>());
        Ok(staging_candidate(destination, &token))
    })
}

fn cleanup_staging_file(path: &Path, error: io::Error) -> io::Error {
    match fs::remove_file(path) {
        Ok(()) => error,
        Err(cleanup_err) if cleanup_err.kind() == io::ErrorKind::NotFound => error,
        Err(cleanup_err) => io::Error::new(
            error.kind(),
            format!(
                "{error}; additionally failed to clean staging file {}: {cleanup_err}",
                path.display()
            ),
        ),
    }
}

// Write a file atomically: write to an exclusively-created staging file in the
// same directory, fsync it, then rename over the destination (atomic on the
// same filesystem), so a crash or concurrent reader never observes a truncated
// JSON file and an occupied staging name can never redirect the write.
pub(crate) fn atomic_write(path: &Path, contents: &str) -> io::Result<()> {
    let (tmp_path, mut file) = create_staging_file(path)?;
    if let Err(err) = file.write_all(contents.as_bytes()) {
        return Err(cleanup_staging_file(&tmp_path, err));
    }
    if let Err(err) = file.sync_all() {
        return Err(cleanup_staging_file(&tmp_path, err));
    }
    if let Err(err) = fs::rename(&tmp_path, path) {
        return Err(cleanup_staging_file(&tmp_path, err));
    }
    Ok(())
}

pub fn default_music_dir() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join("Music")
}

pub fn extract_feat_from_title(title: &str) -> Option<String> {
    let lower = title.to_lowercase();
    for marker in &[
        "(feat.", "(feat ", "[feat.", "[feat ", "(ft.", "(ft ", "[ft.", "[ft ",
    ] {
        if let Some(start) = lower.find(marker) {
            // `lower` may have a different byte length than `title`
            // (`to_lowercase()` can expand a char, e.g. 'İ' -> "i\u{307}"),
            // so `lower` indices are NOT valid on `title` — slicing `title`
            // with them panics on a non-char-boundary or mis-slices. All
            // markers and the delimited content are ASCII in practice, so
            // slicing `lower` is always safe; the result may be lowercased.
            let rest = &lower[start + marker.len()..];
            let close_char = if marker.starts_with('(') { ')' } else { ']' };
            if let Some(end) = rest.find(close_char) {
                let feat_content = rest[..end].trim();
                if !feat_content.is_empty() {
                    return Some(feat_content.to_string());
                }
            }
        }
    }
    None
}

pub fn parse_audio_metadata(file_path: &Path) -> (String, String, String, f64, u32) {
    let mut title = String::new();
    let mut artists: Vec<String> = Vec::new();
    let mut album = String::new();
    let mut duration = 0.0;
    let mut track_num = 0;

    if let Ok(tagged_file) = Probe::open(file_path).and_then(|p| p.read()) {
        duration = tagged_file.properties().duration().as_secs_f64();
        if let Some(tag) = tagged_file
            .primary_tag()
            .or_else(|| tagged_file.first_tag())
        {
            if let Some(t) = tag.title() {
                title = t.trim().to_string();
            }

            // Extract all contributing artists (TrackArtist tag items)
            for item in tag.items() {
                if *item.key() == lofty::tag::ItemKey::TrackArtist {
                    if let lofty::tag::ItemValue::Text(s) = item.value() {
                        let trimmed = s.trim();
                        if !trimmed.is_empty()
                            && !artists.iter().any(|a| a.eq_ignore_ascii_case(trimmed))
                        {
                            artists.push(trimmed.to_string());
                        }
                    }
                }
            }

            if artists.is_empty() {
                if let Some(a) = tag.artist() {
                    let trimmed = a.trim();
                    if !trimmed.is_empty() {
                        artists.push(trimmed.to_string());
                    }
                }
            }

            if artists.is_empty() {
                if let Some(aa) = tag.get_string(&lofty::tag::ItemKey::AlbumArtist) {
                    let trimmed = aa.trim();
                    if !trimmed.is_empty() {
                        artists.push(trimmed.to_string());
                    }
                }
            }

            if let Some(al) = tag.album() {
                album = al.trim().to_string();
            }
            if let Some(num) = tag.track() {
                track_num = num;
            }
        }
    }

    // Check if title has a feat that wasn't already in the artist list
    if let Some(feat_str) = extract_feat_from_title(&title) {
        for part in feat_str.split([',', '&']) {
            let trimmed = part.trim();
            if !trimmed.is_empty() && !artists.iter().any(|a| a.eq_ignore_ascii_case(trimmed)) {
                artists.push(trimmed.to_string());
            }
        }
    }

    let mut artist = if artists.len() > 1 {
        let primary = &artists[0];
        let feats = &artists[1..];
        if primary.to_lowercase().contains("feat") || primary.to_lowercase().contains("ft") {
            artists.join(", ")
        } else {
            format!("{} ft. {}", primary, feats.join(", "))
        }
    } else if !artists.is_empty() {
        artists[0].clone()
    } else {
        String::new()
    };

    // Fallbacks
    if title.is_empty() {
        let stem = file_path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Unknown");
        if stem.contains(" - ") {
            let parts: Vec<&str> = stem.splitn(2, " - ").collect();
            if artist.is_empty() {
                artist = parts[0]
                    .trim_start_matches(|c: char| c.is_ascii_digit() || c == '.' || c == ' ')
                    .to_string();
            }
            title = parts[1].trim().to_string();
        } else {
            title = stem.to_string();
        }
    }

    if artist.is_empty() {
        if let Some(parent) = file_path.parent() {
            if let Some(grandparent) = parent.parent() {
                artist = grandparent
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("Unknown Artist")
                    .to_string();
            } else {
                artist = parent
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("Unknown Artist")
                    .to_string();
            }
        } else {
            artist = "Unknown Artist".to_string();
        }
    }

    if album.is_empty() {
        if let Some(parent) = file_path.parent() {
            album = parent
                .file_name()
                .and_then(|s| s.to_str())
                .unwrap_or("Unknown Album")
                .to_string();
        } else {
            album = "Unknown Album".to_string();
        }
    }

    (title, artist, album, duration, track_num)
}

pub fn read_playlist(path: &Path) -> io::Result<PlaylistItem> {
    let canonical_path = fs::canonicalize(path)?;
    let file = File::open(&canonical_path)?;
    let reader = BufReader::new(file);
    let mut resolved_paths = Vec::new();

    for line in reader.lines().map_while(|result| match result {
        Ok(line) => Some(line),
        Err(err) => {
            eprintln!(
                "mixarchy: {}: failed to read playlist: {err}",
                canonical_path.display()
            );
            None
        }
    }) {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some(parent) = canonical_path.parent() {
            let candidate = parent.join(trimmed);
            if candidate.exists() {
                resolved_paths.push(candidate.to_string_lossy().to_string());
            }
        }
    }

    let stem = canonical_path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("Playlist");
    let name = stem.replace("_playlist", "").trim().to_string();

    Ok(PlaylistItem {
        name,
        path: canonical_path.to_string_lossy().to_string(),
        track_count: resolved_paths.len(),
        track_paths: resolved_paths,
    })
}

pub fn scan_library_to(music_dir: &Path, cache_path: &Path) -> Result<LibraryData, Box<dyn Error>> {
    let mut tracks = Vec::new();
    let mut playlists = Vec::new();

    let valid_exts = ["flac", "mp3", "m4a", "opus", "ogg", "wav"];

    // Bound traversal depth to avoid unbounded recursion/scan on deeply nested
    // or self-referential hierarchies. A typical music tree (gtcm -> artist ->
    // album -> track) rarely exceeds 4 levels; 8 leaves generous headroom.
    for entry in WalkDir::new(music_dir).max_depth(8)
        .into_iter()
        .filter_map(|e| match e {
            Ok(entry) => Some(entry),
            Err(err) => {
                // Unreadable/unwalkable subtree (permissions, vanished
                // mounts): skip it but stay diagnosable instead of silently
                // shipping a partial library.
                eprintln!("mixarchy: scan skipped: {err}");
                None
            }
        })
    {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }

        let ext = path
            .extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_lowercase())
            .unwrap_or_default();

        if valid_exts.contains(&ext.as_str()) {
            let (title, artist, album, duration, track_num) = parse_audio_metadata(path);
            let mtime = entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map(|d| d.as_secs())
                .unwrap_or(0);

            let id = tracks.len().to_string();
            tracks.push(TrackItem {
                id,
                path: path.to_string_lossy().to_string(),
                filename: path
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_string(),
                title,
                artist,
                album,
                duration: (duration * 10.0).round() / 10.0,
                duration_str: format_duration(duration),
                track_num,
                mtime,
            });
        } else if ext == "m3u8" || ext == "m3u" {
            match read_playlist(path) {
                Ok(playlist) => playlists.push(playlist),
                Err(err) => {
                    eprintln!(
                        "mixarchy: {}: failed to read playlist: {err}",
                        path.display()
                    );
                }
            }
        }
    }

    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    let data = LibraryData {
        last_scan: now,
        music_dir: music_dir.to_string_lossy().to_string(),
        track_count: tracks.len(),
        playlist_count: playlists.len(),
        tracks,
        playlists,
    };

    if let Some(parent) = cache_path.parent() {
        fs::create_dir_all(parent)?;
    }
    let json_str = serde_json::to_string_pretty(&data)?;
    atomic_write(cache_path, &json_str)?;

    Ok(data)
}

pub fn scan_library(music_dir: &Path) -> Result<LibraryData, Box<dyn Error>> {
    scan_library_to(music_dir, &lib_cache_file())
}

pub fn load_library_from(cache_path: &Path, music_dir: &Path) -> LibraryData {
    if cache_path.exists() {
        if let Ok(content) = fs::read_to_string(cache_path) {
            if let Ok(data) = serde_json::from_str::<LibraryData>(&content) {
                return data;
            }
        }
    }
    scan_library_to(music_dir, cache_path).unwrap_or_else(|_| LibraryData {
        last_scan: 0,
        music_dir: music_dir.to_string_lossy().to_string(),
        track_count: 0,
        playlist_count: 0,
        tracks: vec![],
        playlists: vec![],
    })
}

pub fn load_library() -> LibraryData {
    load_library_from(&lib_cache_file(), &default_music_dir())
}

pub fn load_state() -> PlayerState {
    let path = state_file();
    if path.exists() {
        if let Ok(content) = fs::read_to_string(&path) {
            if let Ok(st) = serde_json::from_str::<PlayerState>(&content) {
                return st;
            }
        }
    }
    PlayerState {
        current_track: None,
        queue: vec![],
        queue_index: -1,
        source_name: "Tracks".to_string(),
        shuffle: false,
        is_playing: false,
        last_position: 0.0,
    }
}

pub fn save_state(state: &PlayerState) {
    let path = state_file();
    if let Ok(json_str) = serde_json::to_string_pretty(state) {
        let _ = atomic_write(&path, &json_str);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_feat_handles_unicode_uppercase_titles() {
        // 'İ' (U+0130) lowercases to "i̇" (i + combining dot), changing the
        // byte length between `title` and `lower`; slicing `title` with
        // `lower` indices used to panic or mis-slice. Must never panic and
        // must return the (lowercased) featured artist.
        assert_eq!(
            extract_feat_from_title("İSTANBUL (feat. X)"),
            Some("x".to_string())
        );
        assert_eq!(
            extract_feat_from_title("CAFÉ (ft. Y)"),
            Some("y".to_string())
        );
    }

    #[test]
    fn extract_feat_plain_ascii_titles() {
        assert_eq!(
            extract_feat_from_title("Song Title (feat. Artist Name)"),
            Some("artist name".to_string())
        );
        assert_eq!(
            extract_feat_from_title("Song [ft. Guest]"),
            Some("guest".to_string())
        );
        assert_eq!(extract_feat_from_title("No Collaboration"), None);
    }

    #[test]
    fn staging_creation_retries_occupied_symlink_without_following_it() {
        use std::os::unix::fs::symlink;
        use std::process::Command;

        let output = Command::new("mktemp")
            .arg("-d")
            .output()
            .expect("mktemp -d should be available");
        assert!(output.status.success());
        let temp = PathBuf::from(
            String::from_utf8(output.stdout)
                .expect("valid temp path")
                .trim()
                .to_string(),
        );
        let music_dir = temp.join("Music");
        fs::create_dir(&music_dir).unwrap();
        let destination = music_dir.join("Set.m3u");
        let victim = temp.join("victim.txt");
        fs::write(&destination, "playlist").unwrap();
        fs::write(&victim, "victim").unwrap();

        let occupied = staging_candidate(&destination, "occupied");
        let free = staging_candidate(&destination, "free");
        symlink(&victim, &occupied).unwrap();

        let mut attempts = 0;
        let (staging_path, _file) = create_staging_file_with_candidates(&destination, || {
            attempts += 1;
            if attempts == 1 {
                Ok(occupied.clone())
            } else {
                Ok(free.clone())
            }
        })
        .unwrap();

        assert_eq!(staging_path, free);
        assert_eq!(fs::read_to_string(&victim).unwrap(), "victim");
        assert_eq!(fs::read_to_string(&destination).unwrap(), "playlist");
        assert!(fs::symlink_metadata(&occupied)
            .unwrap()
            .file_type()
            .is_symlink());
        fs::remove_file(&staging_path).unwrap();
        fs::remove_dir_all(&temp).unwrap();
    }
}
