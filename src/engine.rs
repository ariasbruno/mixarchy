use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use rand::seq::SliceRandom;
use rand::thread_rng;

use crate::library::{load_library, load_state, save_state};
use crate::models::{format_duration, LibraryData, TrackItem};
use crate::trusted::trusted_command;

pub fn socket_path() -> PathBuf {
    let runtime = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| {
        let uid = std::fs::read_to_string("/proc/self/status")
            .ok()
            .and_then(|s| {
                s.lines()
                    .find(|l| l.starts_with("Uid:"))
                    .and_then(|l| l.split_whitespace().nth(1))
                    .and_then(|v| v.parse::<u32>().ok())
            })
            .unwrap_or(1000);
        format!("/run/user/{}", uid)
    });
    PathBuf::from(runtime).join("mixarchy-mpv.sock")
}

pub fn is_mpv_running() -> bool {
    let sock = socket_path();
    if !sock.exists() {
        return false;
    }
    if UnixStream::connect(&sock).is_ok() {
        true
    } else {
        let _ = fs::remove_file(&sock);
        false
    }
}

pub fn ensure_mpv() -> bool {
    if is_mpv_running() {
        return true;
    }

    // Resolve mpv from fixed root-owned system locations with
    // regular-file/owner/mode and directory-chain checks, and hand it the
    // same fixed allow-listed environment used on every QML process boundary
    // (see crate::trusted). Never resolve or inherit through the session
    // environment.
    let Some(mut cmd) = trusted_command("mpv") else {
        return false;
    };
    let _ = cmd
        .process_group(0)
        .args([
            "--idle=yes",
            &format!("--input-ipc-server={}", socket_path().display()),
            "--no-video",
            "--audio-display=no",
            "--vid=no",
            "--sub=no",
            "--vo=null",
            "--demuxer-max-bytes=2048KiB",
            "--demuxer-max-back-bytes=1024KiB",
            "--demuxer-readahead-secs=2",
            "--audio-buffer=0.1",
            "--ytdl=no",
            "--gapless-audio=yes",
            "--replaygain=track",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();

    for _ in 0..30 {
        std::thread::sleep(Duration::from_millis(50));
        if socket_path().exists() && UnixStream::connect(socket_path()).is_ok() {
            return true;
        }
    }
    false
}

pub fn send_mpv_cmd(command: serde_json::Value) -> Option<serde_json::Value> {
    if !is_mpv_running() {
        return None;
    }
    let mut stream = UnixStream::connect(socket_path()).ok()?;
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(500)));

    let payload = serde_json::json!({ "command": command }).to_string() + "\n";
    stream.write_all(payload.as_bytes()).ok()?;

    let mut reader = BufReader::new(stream);
    let mut response_line = String::new();
    loop {
        response_line.clear();
        if reader.read_line(&mut response_line).ok()? == 0 {
            return None;
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&response_line) {
            if v.get("error").is_some() {
                return Some(v);
            }
        }
    }
}

/// Like send_mpv_cmd, but reports a failed send on stderr instead of
/// silently swallowing it. Used where a dropped command would leave the
/// player in a visible wrong state (play_track), so the operator can see
/// what was attempted from the shell session output.
fn send_mpv_cmd_logged(command: serde_json::Value) -> Option<serde_json::Value> {
    let res = send_mpv_cmd(command.clone());
    if res.is_none() {
        eprintln!(
            "mixarchy: mpv command failed: {}",
            serde_json::to_string(&command).unwrap_or_default()
        );
    }
    res
}

pub fn get_mpv_property(prop: &str) -> Option<serde_json::Value> {
    let res = send_mpv_cmd(serde_json::json!(["get_property", prop]))?;
    if res.get("error").and_then(|e| e.as_str()) == Some("success") {
        res.get("data").cloned()
    } else {
        None
    }
}

pub fn find_or_create_track(lib: &LibraryData, track_path: &str) -> TrackItem {
    lib.tracks
        .iter()
        .find(|t| t.path == track_path)
        .cloned()
        .unwrap_or_else(|| {
            let p = Path::new(track_path);
            TrackItem {
                id: "0".to_string(),
                path: track_path.to_string(),
                filename: p
                    .file_name()
                    .and_then(|s| s.to_str())
                    .unwrap_or("")
                    .to_string(),
                title: p
                    .file_stem()
                    .and_then(|s| s.to_str())
                    .unwrap_or("Unknown")
                    .to_string(),
                artist: "Local Audio".to_string(),
                album: "Music".to_string(),
                duration: 0.0,
                duration_str: "0:00".to_string(),
                track_num: 0,
                mtime: 0,
            }
        })
}

pub fn queue_next_preload(queue: &[String], current_idx: i32) {
    if !is_mpv_running() {
        return;
    }
    // Remove any currently preloaded item at index 1 if present
    if let Some(count) = get_mpv_property("playlist-count").and_then(|v| v.as_i64()) {
        if count > 1 {
            let _ = send_mpv_cmd(serde_json::json!(["playlist-remove", 1]));
        }
    }
    if queue.len() <= 1 {
        return;
    }
    let next_idx = {
        let n = (current_idx.max(0) as usize) + 1;
        if n >= queue.len() {
            0
        } else {
            n
        }
    };
    let next_path = &queue[next_idx];
    let _ = send_mpv_cmd(serde_json::json!(["loadfile", next_path, "append"]));
}

pub fn shuffle_queue<T>(vec: &mut [T]) {
    vec.shuffle(&mut thread_rng());
}

pub fn play_track(
    track_path: &str,
    source: &str,
    index: i32,
    queue: Option<Vec<String>>,
    start_pos: Option<f64>,
) -> serde_json::Value {
    if !ensure_mpv() {
        return serde_json::json!({ "ok": false, "error": "Could not start mpv" });
    }

    let pos = start_pos.unwrap_or(0.0);
    if pos > 0.5 {
        send_mpv_cmd_logged(serde_json::json!([
            "loadfile",
            track_path,
            "replace",
            -1,
            format!("start={:.2}", pos)
        ]));
    } else {
        send_mpv_cmd_logged(serde_json::json!(["loadfile", track_path, "replace"]));
    }
    send_mpv_cmd_logged(serde_json::json!(["set_property", "pause", false]));

    let mut state = load_state();
    state.is_playing = true;
    state.last_position = pos;
    state.source_name = source.to_string();
    state.queue_index = index;
    if let Some(q) = queue {
        state.queue = q;
    }

    let lib = load_library();
    let track_item = find_or_create_track(&lib, track_path);
    state.current_track = Some(track_item.clone());
    save_state(&state);

    // Preload next track for native gapless playback
    queue_next_preload(&state.queue, state.queue_index);

    serde_json::json!({ "ok": true, "track": track_item })
}

pub fn toggle_playback() -> serde_json::Value {
    if !is_mpv_running() {
        let state = load_state();
        if let Some(tr) = state.current_track {
            return play_track(
                &tr.path,
                &state.source_name,
                state.queue_index,
                None,
                Some(state.last_position),
            );
        }
        let lib = load_library();
        if !lib.tracks.is_empty() {
            let mut q: Vec<String> = lib.tracks.iter().map(|t| t.path.clone()).collect();
            if state.shuffle && q.len() > 1 {
                shuffle_queue(&mut q);
            }
            let target = q[0].clone();
            return play_track(&target, "Tracks", 0, Some(q), None);
        }
        return serde_json::json!({ "ok": false, "error": "No tracks in library" });
    }

    // Auto-sleep on pause: save timestamp and quit mpv to drop RAM to 0 MB
    let pos = get_mpv_property("time-pos").and_then(|v| v.as_f64()).unwrap_or(0.0);
    let _ = send_mpv_cmd(serde_json::json!(["quit"]));
    for _ in 0..10 {
        if !socket_path().exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    let mut state = load_state();
    state.is_playing = false;
    state.last_position = pos;
    save_state(&state);

    serde_json::json!({ "ok": true, "is_playing": false, "time_pos": pos })
}

pub fn stop_playback() -> serde_json::Value {
    if is_mpv_running() {
        let _ = send_mpv_cmd(serde_json::json!(["quit"]));
        for _ in 0..10 {
            if !socket_path().exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    let mut state = load_state();
    state.is_playing = false;
    state.last_position = 0.0;
    save_state(&state);

    serde_json::json!({ "ok": true })
}

pub fn next_track() -> serde_json::Value {
    let mut state = load_state();
    if state.queue.is_empty() {
        let lib = load_library();
        state.queue = lib.tracks.iter().map(|t| t.path.clone()).collect();
        if state.shuffle && state.queue.len() > 1 {
            shuffle_queue(&mut state.queue);
        }
    }
    if state.queue.is_empty() {
        return serde_json::json!({ "ok": false, "error": "Empty queue" });
    }

    let next_idx = if state.queue_index >= 0 {
        let n = (state.queue_index as usize) + 1;
        if n >= state.queue.len() {
            if state.shuffle && state.queue.len() > 1 {
                shuffle_queue(&mut state.queue);
            }
            0
        } else {
            n
        }
    } else {
        0
    };

    let target_path = state.queue[next_idx].clone();
    let q = state.queue.clone();
    play_track(&target_path, &state.source_name, next_idx as i32, Some(q), None)
}

pub fn prev_track() -> serde_json::Value {
    let state = load_state();
    if state.queue.is_empty() {
        return serde_json::json!({ "ok": false, "error": "Empty queue" });
    }

    // If at the very first song in the queue, cannot go back further; seek to 0:00
    if state.queue_index <= 0 {
        if is_mpv_running() {
            let _ = send_mpv_cmd(serde_json::json!(["seek", 0, "absolute"]));
        }
        let mut s = state;
        s.last_position = 0.0;
        save_state(&s);
        return serde_json::json!({ "ok": true, "at_beginning": true });
    }

    let prev_idx = (state.queue_index as usize) - 1;
    let target_path = state.queue[prev_idx].clone();
    let q = state.queue.clone();
    play_track(&target_path, &state.source_name, prev_idx as i32, Some(q), None)
}

pub fn toggle_shuffle() -> serde_json::Value {
    let mut state = load_state();
    state.shuffle = !state.shuffle;
    if state.shuffle && state.queue.len() > 1 {
        let curr_idx = if state.queue_index >= 0 && (state.queue_index as usize) < state.queue.len() {
            state.queue_index as usize
        } else {
            0
        };
        let current_path = state.queue.remove(curr_idx);
        shuffle_queue(&mut state.queue);
        state.queue.insert(0, current_path);
        state.queue_index = 0;
    }
    save_state(&state);
    queue_next_preload(&state.queue, state.queue_index);
    serde_json::json!({ "ok": true, "shuffle": state.shuffle })
}

pub fn seek_playback(sec: f64) -> serde_json::Value {
    if is_mpv_running() {
        let _ = send_mpv_cmd(serde_json::json!(["seek", sec, "absolute"]));
    }
    let mut state = load_state();
    state.last_position = sec;
    save_state(&state);
    serde_json::json!({ "ok": true, "seek_to": sec })
}

pub fn get_status() -> serde_json::Value {
    let running = is_mpv_running();
    let mut state = load_state();

    let mut time_pos = state.last_position;
    let mut duration = state
        .current_track
        .as_ref()
        .map(|t| t.duration)
        .unwrap_or(0.0);
    let mut is_paused = !state.is_playing;

    if running {
        // 1. Check if mpv is idle or has reached EOF
        let is_idle = get_mpv_property("idle-active").and_then(|v| v.as_bool()).unwrap_or(false);
        let eof_reached = get_mpv_property("eof-reached").and_then(|v| v.as_bool()).unwrap_or(false);

        if is_idle || eof_reached {
            let _ = next_track();
            state = load_state();
            time_pos = 0.0;
            duration = state
                .current_track
                .as_ref()
                .map(|t| t.duration)
                .unwrap_or(0.0);
            is_paused = false;
        } else {
            // 2. Check if mpv transitioned to a preloaded track
            if let Some(mpv_path) = get_mpv_property("path").and_then(|v| v.as_str().map(|s| s.to_string())) {
                let current_path = state
                    .current_track
                    .as_ref()
                    .map(|t| t.path.clone())
                    .unwrap_or_default();

                if !current_path.is_empty() && current_path != mpv_path {
                    // Track transitioned natively via mpv gapless preload
                    if let Some(pos) = get_mpv_property("playlist-pos").and_then(|v| v.as_i64()) {
                        if pos > 0 {
                            for _ in 0..pos {
                                let _ = send_mpv_cmd(serde_json::json!(["playlist-remove", 0]));
                            }
                        }
                    }

                    if let Some(idx) = state.queue.iter().position(|p| p == &mpv_path) {
                        state.queue_index = idx as i32;
                    } else if !state.queue.is_empty() {
                        state.queue_index = (state.queue_index + 1) % (state.queue.len() as i32);
                    }

                    let lib = load_library();
                    let track_item = find_or_create_track(&lib, &mpv_path);
                    state.current_track = Some(track_item);
                    state.last_position = 0.0;

                    queue_next_preload(&state.queue, state.queue_index);
                    save_state(&state);
                }
            }

            if let Some(pos) = get_mpv_property("time-pos").and_then(|v| v.as_f64()) {
                time_pos = pos;
                state.last_position = pos;
            }
            if let Some(dur) = get_mpv_property("duration").and_then(|v| v.as_f64()) {
                duration = dur;
            }
            if let Some(pause) = get_mpv_property("pause").and_then(|v| v.as_bool()) {
                is_paused = pause;
            }
            state.is_playing = !is_paused;
            save_state(&state);
        }
    } else {
        state.is_playing = false;
        is_paused = true;
        time_pos = state.last_position;
        if let Some(ref tr) = state.current_track {
            duration = tr.duration;
        }
    }

    let queue_total = state.queue.len();
    let queue_index = if state.queue_index >= 0 {
        state.queue_index + 1
    } else {
        0
    };

    serde_json::json!({
        "ok": true,
        "running": running,
        "is_playing": state.is_playing,
        "is_paused": is_paused,
        "shuffle": state.shuffle,
        "time_pos": (time_pos * 10.0).round() / 10.0,
        "time_pos_str": format_duration(time_pos),
        "duration": (duration * 10.0).round() / 10.0,
        "duration_str": format_duration(duration),
        "track": state.current_track,
        "source_name": state.source_name,
        "queue_index": queue_index,
        "queue_total": queue_total
    })
}
