use std::fs;
use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};

use image::imageops::FilterType;
use image::GenericImageView;
use lofty::file::TaggedFileExt;
use lofty::picture::Picture;
use lofty::probe::Probe;

use crate::library::{cache_dir, load_library};

const THUMB_SIZE: u32 = 96;

fn covers_dir() -> PathBuf {
    let dir = cache_dir().join("covers");
    let _ = fs::create_dir_all(&dir);
    dir
}

fn thumb_path(file_path: &str, mtime: u64) -> PathBuf {
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    file_path.hash(&mut hasher);
    let hash = hasher.finish();
    covers_dir().join(format!("thumb-{:016x}-{}.png", hash, mtime))
}

fn extract_picture(file_path: &Path) -> Option<Picture> {
    let tagged_file = Probe::open(file_path).ok()?.read().ok()?;
    tagged_file
        .primary_tag()
        .or_else(|| tagged_file.first_tag())
        .and_then(|tag| tag.pictures().first().cloned())
}

fn generate_thumbnail(data: &[u8], dest: &Path) -> image::ImageResult<()> {
    let img = image::load_from_memory(data)?;
    let (w, h) = img.dimensions();
    // Scale to fit within a 96x96 box, preserving aspect ratio.
    let (nw, nh) = if w >= h {
        (THUMB_SIZE, ((h as u64 * u64::from(THUMB_SIZE)) / u64::from(w)) as u32)
    } else {
        (((w as u64 * u64::from(THUMB_SIZE)) / u64::from(h)) as u32, THUMB_SIZE)
    };
    let nw = nw.max(1);
    let nh = nh.max(1);
    let thumb = img.resize(nw, nh, FilterType::Triangle);
    thumb.save(dest)
}

fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = *chunk.get(1).unwrap_or(&0) as u32;
        let b2 = *chunk.get(2).unwrap_or(&0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[(n >> 18) as usize & 63] as char);
        out.push(TABLE[(n >> 12) as usize & 63] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(n >> 6) as usize & 63] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[n as usize & 63] as char
        } else {
            '='
        });
    }
    out
}

pub fn get_cover(track_id: &str, thumb_only: bool) -> serde_json::Value {
    let lib = load_library();
    let track = match lib.tracks.iter().find(|t| t.id == track_id) {
        Some(t) => t,
        None => {
            return serde_json::json!({
                "ok": false,
                "error": format!("Track not found: {}", track_id)
            });
        }
    };

    let picture = match extract_picture(Path::new(&track.path)) {
        Some(p) => p,
        None => return serde_json::json!({ "ok": true, "has_cover": false }),
    };

    let thumb = thumb_path(&track.path, track.mtime);

    // Generate the 96x96 thumbnail once and persist it to disk. It survives
    // reboots and is recreated lazily if a cache cleaner removes it. The full
    // cover is never written to disk (avoid unbounded disk accumulation).
    if !thumb.exists() && generate_thumbnail(picture.data(), &thumb).is_err() {
        return serde_json::json!({ "ok": true, "has_cover": false });
    }

    if thumb_only {
        // Lightweight response for track-list rows: no base64 payload, so a
        // visible ListView batch (~20 rows) never moves megabytes through QML.
        return serde_json::json!({
            "ok": true,
            "has_cover": true,
            "thumb": thumb.to_string_lossy().to_string(),
        });
    }

    let mime = picture
        .mime_type()
        .map(|m| m.as_str().to_string())
        .unwrap_or_else(|| "image/jpeg".to_string());
    let data_uri = format!("data:{};base64,{}", mime, base64_encode(picture.data()));

    serde_json::json!({
        "ok": true,
        "has_cover": true,
        "thumb": thumb.to_string_lossy().to_string(),
        "data_uri": data_uri
    })
}
