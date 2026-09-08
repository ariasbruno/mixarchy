use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TrackItem {
    pub id: String,
    pub path: String,
    pub filename: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub duration: f64,
    pub duration_str: String,
    pub track_num: u32,
    pub mtime: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct PlaylistItem {
    pub name: String,
    pub path: String,
    pub track_count: usize,
    pub track_paths: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct LibraryData {
    pub last_scan: u64,
    pub music_dir: String,
    pub track_count: usize,
    pub playlist_count: usize,
    pub tracks: Vec<TrackItem>,
    pub playlists: Vec<PlaylistItem>,
}

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct PlayerState {
    pub current_track: Option<TrackItem>,
    pub queue: Vec<String>,
    pub queue_index: i32,
    pub source_name: String,
    pub shuffle: bool,
    pub is_playing: bool,
    #[serde(default)]
    pub last_position: f64,
}

pub fn format_duration(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    let mins = s / 60;
    let rem = s % 60;
    format!("{}:{:02}", mins, rem)
}
