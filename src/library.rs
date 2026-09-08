use std::error::Error;
use std::fs::{self, File};
use std::io::{BufRead, BufReader};
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
    let _ = fs::create_dir_all(&path);
    path
}

pub fn lib_cache_file() -> PathBuf {
    cache_dir().join("library.json")
}

pub fn state_file() -> PathBuf {
    cache_dir().join("state.json")
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
            let rest = &title[start + marker.len()..];
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

pub fn scan_library(music_dir: &Path) -> Result<LibraryData, Box<dyn Error>> {
    let mut tracks = Vec::new();
    let mut playlists = Vec::new();

    let valid_exts = ["flac", "mp3", "m4a", "opus", "ogg", "wav"];

    // Bound traversal depth to avoid unbounded recursion/scan on deeply nested
    // or self-referential hierarchies. A typical music tree (gtcm -> artist ->
    // album -> track) rarely exceeds 4 levels; 8 leaves generous headroom.
    for entry in WalkDir::new(music_dir).max_depth(8)
        .into_iter()
        .filter_map(|e| e.ok())
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
            if let Ok(file) = File::open(path) {
                let reader = BufReader::new(file);
                let mut resolved_paths = Vec::new();
                for line in reader.lines().map_while(Result::ok) {
                    let trimmed = line.trim();
                    if trimmed.is_empty() || trimmed.starts_with('#') {
                        continue;
                    }
                    if let Some(parent) = path.parent() {
                        let candidate = parent.join(trimmed);
                        if candidate.exists() {
                            resolved_paths.push(candidate.to_string_lossy().to_string());
                        }
                    }
                }

                let stem = path
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("Playlist");
                let name = stem.replace("_playlist", "").trim().to_string();

                playlists.push(PlaylistItem {
                    name,
                    path: path.to_string_lossy().to_string(),
                    track_count: resolved_paths.len(),
                    track_paths: resolved_paths,
                });
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

    let cache_path = lib_cache_file();
    let json_str = serde_json::to_string_pretty(&data)?;
    fs::write(&cache_path, json_str)?;

    Ok(data)
}

pub fn load_library() -> LibraryData {
    let cache_path = lib_cache_file();
    if cache_path.exists() {
        if let Ok(content) = fs::read_to_string(&cache_path) {
            if let Ok(data) = serde_json::from_str::<LibraryData>(&content) {
                return data;
            }
        }
    }
    let music_dir = default_music_dir();
    scan_library(&music_dir).unwrap_or_else(|_| LibraryData {
        last_scan: 0,
        music_dir: music_dir.to_string_lossy().to_string(),
        track_count: 0,
        playlist_count: 0,
        tracks: vec![],
        playlists: vec![],
    })
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
        let _ = fs::write(path, json_str);
    }
}
