use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
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

#[derive(Debug, Serialize, Deserialize, Clone, Default, PartialEq)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum QueueMutation {
    Append,
    PlayNext,
}

impl PlayerState {
    /// Apply a queue-only mutation without touching playback state or
    /// reshuffling existing entries. The returned index identifies the insert.
    pub fn apply_queue_mutation(&mut self, mutation: QueueMutation, track_path: String) -> usize {
        match mutation {
            QueueMutation::Append => {
                let inserted_index = self.queue.len();
                self.queue.push(track_path);
                inserted_index
            }
            QueueMutation::PlayNext => {
                let inserted_index =
                    if self.queue_index >= 0 && (self.queue_index as usize) < self.queue.len() {
                        self.queue_index as usize + 1
                    } else {
                        0
                    };
                self.queue.insert(inserted_index, track_path);
                inserted_index
            }
        }
    }

    /// Find a queue path after the current position, so duplicate paths cannot
    /// make a native transition resolve to an earlier queue entry.
    pub fn queue_index_for_path_forward(&self, track_path: &str) -> Option<usize> {
        let start = if self.queue_index >= 0 {
            self.queue_index as usize + 1
        } else {
            0
        };
        self.queue
            .iter()
            .enumerate()
            .skip(start)
            .find(|(_, path)| path.as_str() == track_path)
            .map(|(index, _)| index)
    }
}

pub fn format_duration(seconds: f64) -> String {
    let s = seconds.max(0.0) as u64;
    let mins = s / 60;
    let rem = s % 60;
    format!("{}:{:02}", mins, rem)
}
