use std::fs;
use std::path::{Path, PathBuf};

use lofty::file::TaggedFileExt;
use lofty::probe::Probe;
use lofty::tag::ItemKey;
use serde::{Deserialize, Serialize};

use crate::library::load_library;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LyricLine {
    pub time: f64,
    pub text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LyricsResult {
    pub ok: bool,
    pub has_lyrics: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub synced: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub lines: Option<Vec<LyricLine>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub raw: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Parse [mm:ss.xx] or [mm:ss] into seconds (f64).
fn parse_timestamp(ts: &str) -> Option<f64> {
    let parts: Vec<&str> = ts.split(':').collect();
    if parts.len() != 2 {
        return None;
    }
    let mins: f64 = parts[0].parse().ok()?;
    let secs: f64 = parts[1].parse().ok()?;
    Some(mins * 60.0 + secs)
}

/// Parse raw lyrics text (LRC format or plain text) into a list of LyricLine.
pub fn parse_lyrics_text(raw: &str) -> (bool, Vec<LyricLine>) {
    let mut parsed_lines = Vec::new();
    let mut has_timestamps = false;

    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        // Check if line contains timestamp markers e.g. [01:23.45]
        if trimmed.starts_with('[') {
            // Check for metadata tags like [ti:Title], [ar:Artist], [al:Album], [by:Maker], [offset:0]
            if let Some(close_bracket) = trimmed.find(']') {
                let tag_candidate = &trimmed[1..close_bracket];
                if let Some(colon) = tag_candidate.find(':') {
                    let prefix = &tag_candidate[..colon];
                    // Non-numeric prefix indicates metadata header, skip
                    if prefix.chars().any(|c| !c.is_ascii_digit()) {
                        continue;
                    }
                }
            }
        }

        // Extract timestamps and text
        let mut rest = trimmed;
        let mut line_timestamps = Vec::new();

        while rest.starts_with('[') {
            if let Some(close_bracket) = rest.find(']') {
                let tag_content = &rest[1..close_bracket];
                if let Some(ts) = parse_timestamp(tag_content) {
                    line_timestamps.push(ts);
                    rest = rest[close_bracket + 1..].trim_start();
                    continue;
                }
            }
            break;
        }

        if !line_timestamps.is_empty() {
            has_timestamps = true;
            for ts in line_timestamps {
                parsed_lines.push(LyricLine {
                    time: (ts * 100.0).round() / 100.0,
                    text: rest.to_string(),
                });
            }
        } else {
            // Unsynced plain line
            parsed_lines.push(LyricLine {
                time: -1.0,
                text: trimmed.to_string(),
            });
        }
    }

    if has_timestamps {
        // Sort synced lines by timestamp
        parsed_lines.sort_by(|a, b| a.time.partial_cmp(&b.time).unwrap_or(std::cmp::Ordering::Equal));
    }

    (has_timestamps, parsed_lines)
}

/// Find a local companion .lrc file for the given audio track.
pub fn find_companion_lrc(track_path: &Path) -> Option<PathBuf> {
    // 1. Check <filename>.lrc (same basename without audio ext)
    let candidate1 = track_path.with_extension("lrc");
    if candidate1 != track_path && candidate1.is_file() {
        return Some(candidate1);
    }

    // 2. Check <filename>.<ext>.lrc (e.g. song.mp3.lrc)
    let candidate2 = PathBuf::from(format!("{}.lrc", track_path.display()));
    if candidate2.is_file() {
        return Some(candidate2);
    }

    None
}

/// Extract embedded lyrics from audio tags using lofty.
pub fn extract_embedded_lyrics(track_path: &Path) -> Option<String> {
    let tagged_file = Probe::open(track_path).ok()?.read().ok()?;
    let tag = tagged_file.primary_tag().or_else(|| tagged_file.first_tag())?;

    // Try standard ItemKey::Lyrics
    if let Some(lyrics) = tag.get_string(&ItemKey::Lyrics) {
        if !lyrics.trim().is_empty() {
            return Some(lyrics.to_string());
        }
    }

    // Fallback: search tag items for any item with key lyrics or description lyrics
    for item in tag.items() {
        if item.key() == &ItemKey::Lyrics {
            if let lofty::tag::ItemValue::Text(ref s) = item.value() {
                if !s.trim().is_empty() {
                    return Some(s.clone());
                }
            }
        }
    }

    None
}

/// Main entry point: get lyrics for a track ID.
pub fn get_lyrics(track_id: &str) -> LyricsResult {
    let lib = load_library();
    let track = match lib.tracks.iter().find(|t| t.id == track_id) {
        Some(t) => t,
        None => {
            return LyricsResult {
                ok: false,
                has_lyrics: false,
                source: None,
                synced: None,
                lines: None,
                raw: None,
                error: Some(format!("Track not found: {}", track_id)),
            };
        }
    };

    let track_path = Path::new(&track.path);

    // 1. Check companion .lrc file first (highest user control)
    if let Some(lrc_path) = find_companion_lrc(track_path) {
        // Limit read to 512 KiB to prevent memory exhaustion on bogus files
        if let Ok(metadata) = fs::metadata(&lrc_path) {
            if metadata.len() <= 512 * 1024 {
                if let Ok(content) = fs::read_to_string(&lrc_path) {
                    let (synced, lines) = parse_lyrics_text(&content);
                    return LyricsResult {
                        ok: true,
                        has_lyrics: true,
                        source: Some("file".to_string()),
                        synced: Some(synced),
                        lines: Some(lines),
                        raw: Some(content),
                        error: None,
                    };
                }
            }
        }
    }

    // 2. Check embedded audio tags
    if let Some(content) = extract_embedded_lyrics(track_path) {
        let (synced, lines) = parse_lyrics_text(&content);
        return LyricsResult {
            ok: true,
            has_lyrics: true,
            source: Some("tag".to_string()),
            synced: Some(synced),
            lines: Some(lines),
            raw: Some(content),
            error: None,
        };
    }

    // 3. No lyrics found
    LyricsResult {
        ok: true,
        has_lyrics: false,
        source: None,
        synced: None,
        lines: None,
        raw: None,
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_synced_lrc() {
        let sample = r#"
[ti:Sample Song]
[ar:Artist Name]
[al:Album Name]
[00:10.50]First line of the song
[00:15.00]Second line here
[00:20.25]Third line
"#;
        let (synced, lines) = parse_lyrics_text(sample);
        assert!(synced);
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0].time, 10.50);
        assert_eq!(lines[0].text, "First line of the song");
        assert_eq!(lines[1].time, 15.00);
        assert_eq!(lines[1].text, "Second line here");
        assert_eq!(lines[2].time, 20.25);
        assert_eq!(lines[2].text, "Third line");
    }

    #[test]
    fn test_parse_unsynced_lyrics() {
        let sample = "Just some words\nWithout timestamps\nLiving in the moment";
        let (synced, lines) = parse_lyrics_text(sample);
        assert!(!synced);
        assert_eq!(lines.len(), 3);
        assert_eq!(lines[0].time, -1.0);
        assert_eq!(lines[0].text, "Just some words");
    }

    #[test]
    fn test_parse_multi_timestamp_lrc() {
        let sample = "[00:10.00][00:30.00]Repeated chorus";
        let (synced, lines) = parse_lyrics_text(sample);
        assert!(synced);
        assert_eq!(lines.len(), 2);
        assert_eq!(lines[0].time, 10.00);
        assert_eq!(lines[0].text, "Repeated chorus");
        assert_eq!(lines[1].time, 30.00);
        assert_eq!(lines[1].text, "Repeated chorus");
    }
}
