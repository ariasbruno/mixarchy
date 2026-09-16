mod cover;
mod engine;
mod library;
mod models;
mod trusted;

use std::path::PathBuf;

use engine::{
    get_status, next_track, play_track, prev_track, seek_playback, stop_playback,
    toggle_playback, toggle_shuffle,
};
use library::{default_music_dir, load_library, load_state, scan_library};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 2 {
        println!(
            "{}",
            serde_json::json!({
                "error": "Usage: mixarchy-ctl [scan|library|status|play|play-queue|toggle|stop|next|prev|shuffle|seek|cover]"
            })
        );
        return;
    }

    let cmd = &args[1];
    let result = match cmd.as_str() {
        "scan" => {
            let music_dir = if args.len() > 2 {
                PathBuf::from(&args[2])
            } else {
                default_music_dir()
            };
            match scan_library(&music_dir) {
                Ok(data) => serde_json::json!({
                    "ok": true,
                    "track_count": data.track_count,
                    "playlist_count": data.playlist_count
                }),
                Err(e) => serde_json::json!({ "ok": false, "error": e.to_string() }),
            }
        }
        "library" => serde_json::to_value(load_library())
            .unwrap_or_else(|e| serde_json::json!({ "error": e.to_string() })),
        "status" => get_status(),
        "play" => {
            if args.len() > 2 {
                let track_path = &args[2];
                let source = if args.len() > 3 { &args[3] } else { "Tracks" };
                play_track(track_path, source, 0, None, None)
            } else {
                toggle_playback()
            }
        }
        "play-queue" => {
            // Tracks travel as a single argv batch (Quickshell spawns with
            // argv only — no shell). Queues on the order of 100k paths can
            // exceed the kernel ARG_MAX limit (~2 MiB of stack), so callers
            // with huge libraries should chunk the request.
            let source = if args.len() > 2 { &args[2] } else { "Tracks" };
            let mut queue: Vec<String> = args.iter().skip(4).cloned().collect();
            if !queue.is_empty() {
                let state = load_state();
                let start_arg = if args.len() > 3 { args[3].as_str() } else { "0" };

                let (actual_idx, target) = if start_arg == "play-all" || start_arg == "random" {
                    if state.shuffle && queue.len() > 1 {
                        engine::shuffle_queue(&mut queue);
                    }
                    (0, queue[0].clone())
                } else if let Ok(requested_idx) = start_arg.parse::<usize>() {
                    if requested_idx < queue.len() {
                        if state.shuffle && queue.len() > 1 {
                            let picked = queue.remove(requested_idx);
                            engine::shuffle_queue(&mut queue);
                            queue.insert(0, picked);
                            (0, queue[0].clone())
                        } else {
                            (requested_idx, queue[requested_idx].clone())
                        }
                    } else {
                        (0, queue[0].clone())
                    }
                } else {
                    (0, queue[0].clone())
                };

                play_track(&target, source, actual_idx as i32, Some(queue), None)
            } else {
                serde_json::json!({ "ok": false, "error": "No tracks provided in queue" })
            }
        }
        "toggle" => toggle_playback(),
        "stop" => stop_playback(),
        "next" => next_track(),
        "prev" => prev_track(),
        "shuffle" => toggle_shuffle(),
        "seek" => {
            if args.len() > 2 {
                if let Ok(sec) = args[2].parse::<f64>() {
                    seek_playback(sec)
                } else {
                    serde_json::json!({ "ok": false, "error": "Invalid seek position" })
                }
            } else {
                serde_json::json!({ "ok": false, "error": "Missing seek argument" })
            }
        }
        "cover" => {
            // `cover <id>` returns the full-res data_uri for the now-playing
            // area; `cover --thumb <id>` returns only the cached thumb path
            // so track-list rows never transport megabytes through QML.
            let thumb_only = args.get(2).is_some_and(|a| a == "--thumb");
            let id = args.get(if thumb_only { 3 } else { 2 }).map(|s| s.as_str());
            match id {
                Some(id) => cover::get_cover(id, thumb_only),
                None => serde_json::json!({ "ok": false, "error": "Missing track id" }),
            }
        }
        _ => serde_json::json!({ "ok": false, "error": format!("Unknown command: {}", cmd) }),
    };

    println!("{}", result);
}
