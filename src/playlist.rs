use std::fmt;
use std::fs;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

use crate::library::{atomic_write, create_staging_file, read_playlist, scan_library_to};
use crate::models::PlaylistItem;

const MAX_PLAYLIST_NAME_BYTES: usize = 200;

#[derive(Debug, Clone)]
pub struct PlaylistError(String);

impl PlaylistError {
    fn new(message: impl Into<String>) -> Self {
        Self(message.into())
    }
}

impl fmt::Display for PlaylistError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PlaylistError {}

fn canonical_music_dir(music_dir: &Path) -> Result<PathBuf, PlaylistError> {
    let canonical = fs::canonicalize(music_dir).map_err(|err| {
        PlaylistError::new(format!(
            "Music directory is unavailable: {}: {err}",
            music_dir.display()
        ))
    })?;
    if !canonical.is_dir() {
        return Err(PlaylistError::new(format!(
            "Music directory is not a directory: {}",
            canonical.display()
        )));
    }
    Ok(canonical)
}

fn sanitize_playlist_name(display_name: &str) -> Result<String, PlaylistError> {
    let trimmed = display_name.trim();
    if trimmed.is_empty() {
        return Err(PlaylistError::new("Playlist name cannot be empty"));
    }
    if trimmed == "." || trimmed == ".." {
        return Err(PlaylistError::new(
            "Playlist name cannot be a path component",
        ));
    }
    if trimmed.contains('/') || trimmed.contains('\\') {
        return Err(PlaylistError::new(
            "Playlist name cannot contain path separators",
        ));
    }
    if trimmed.chars().any(char::is_control) {
        return Err(PlaylistError::new(
            "Playlist name cannot contain control characters",
        ));
    }
    if trimmed.starts_with('.') {
        return Err(PlaylistError::new(
            "Playlist name cannot start with a dot",
        ));
    }

    let mut sanitized: String = trimmed
        .chars()
        .map(|character| {
            if matches!(character, '<' | '>' | ':' | '"' | '|' | '?' | '*') {
                '_'
            } else {
                character
            }
        })
        .collect();
    sanitized = sanitized
        .trim_end_matches(|character| character == ' ' || character == '.')
        .to_string();

    if sanitized.is_empty() || sanitized == "." || sanitized == ".." {
        return Err(PlaylistError::new("Playlist name is invalid"));
    }
    if sanitized.len() > MAX_PLAYLIST_NAME_BYTES {
        return Err(PlaylistError::new(format!(
            "Playlist name cannot exceed {MAX_PLAYLIST_NAME_BYTES} bytes"
        )));
    }
    Ok(sanitized)
}

fn recognized_playlist_path(
    music_dir: &Path,
    playlist_path: &Path,
) -> Result<PathBuf, PlaylistError> {
    let music_dir = canonical_music_dir(music_dir)?;
    let canonical = fs::canonicalize(playlist_path).map_err(|err| {
        PlaylistError::new(format!(
            "Playlist file is unavailable: {}: {err}",
            playlist_path.display()
        ))
    })?;

    if !canonical.starts_with(&music_dir) {
        return Err(PlaylistError::new(
            "Playlist path must be inside the music library",
        ));
    }
    if !canonical.is_file() {
        return Err(PlaylistError::new("Playlist path is not a file"));
    }
    let extension = canonical
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| value.to_ascii_lowercase());
    if !matches!(extension.as_deref(), Some("m3u") | Some("m3u8")) {
        return Err(PlaylistError::new(
            "Playlist path must reference an .m3u or .m3u8 file",
        ));
    }
    Ok(canonical)
}

fn canonical_track_path(track_path: &Path) -> Result<PathBuf, PlaylistError> {
    let canonical = fs::canonicalize(track_path).map_err(|err| {
        PlaylistError::new(format!(
            "Track file is unavailable: {}: {err}",
            track_path.display()
        ))
    })?;
    if !canonical.is_file() {
        return Err(PlaylistError::new(
            "Track path must reference an existing file",
        ));
    }
    Ok(canonical)
}

#[cfg(target_os = "linux")]
fn rename_noreplace(source: &Path, destination: &Path) -> io::Result<()> {
    use std::ffi::CString;
    use std::os::raw::{c_char, c_int, c_uint};
    use std::os::unix::ffi::OsStrExt;

    const AT_FDCWD: c_int = -100;
    const RENAME_NOREPLACE: c_uint = 1;

    unsafe extern "C" {
        fn renameat2(
            olddirfd: c_int,
            oldpath: *const c_char,
            newdirfd: c_int,
            newpath: *const c_char,
            flags: c_uint,
        ) -> c_int;
    }

    let source = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "source path contains NUL"))?;
    let destination = CString::new(destination.as_os_str().as_bytes()).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidInput, "destination path contains NUL")
    })?;

    // SAFETY: both pointers reference live NUL-terminated C strings for the
    // duration of the call, and the only flag passed is RENAME_NOREPLACE.
    let result = unsafe {
        renameat2(
            AT_FDCWD,
            source.as_ptr(),
            AT_FDCWD,
            destination.as_ptr(),
            RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(not(target_os = "linux"))]
fn rename_noreplace(_source: &Path, _destination: &Path) -> io::Result<()> {
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "atomic no-overwrite rename is unavailable on this platform",
    ))
}

fn cleanup_staging_file(path: &Path, primary: PlaylistError) -> PlaylistError {
    match fs::remove_file(path) {
        Ok(()) => primary,
        Err(err) if err.kind() == io::ErrorKind::NotFound => primary,
        Err(err) => PlaylistError::new(format!(
            "{primary}; failed to clean staging file {}: {err}",
            path.display()
        )),
    }
}

fn atomic_create(path: &Path, contents: &[u8]) -> Result<(), PlaylistError> {
    let (temp_path, mut file) = create_staging_file(path)
        .map_err(|err| PlaylistError::new(format!("Could not stage playlist file: {err}")))?;

    if let Err(err) = file.write_all(contents) {
        return Err(cleanup_staging_file(
            &temp_path,
            PlaylistError::new(format!("Could not stage playlist file: {err}")),
        ));
    }
    if let Err(err) = file.sync_all() {
        return Err(cleanup_staging_file(
            &temp_path,
            PlaylistError::new(format!("Could not sync staged playlist file: {err}")),
        ));
    }

    if let Err(err) = rename_noreplace(&temp_path, path) {
        let primary = if err.kind() == io::ErrorKind::AlreadyExists {
            PlaylistError::new(format!("Playlist already exists: {}", path.display()))
        } else {
            PlaylistError::new(format!(
                "Could not atomically create playlist file without replacing it: {err}"
            ))
        };
        return Err(cleanup_staging_file(&temp_path, primary));
    }
    Ok(())
}

fn atomic_rename_no_replace(source: &Path, destination: &Path) -> Result<(), PlaylistError> {
    if source == destination {
        return Ok(());
    }
    rename_noreplace(source, destination).map_err(|err| {
        if err.kind() == io::ErrorKind::AlreadyExists {
            PlaylistError::new(format!(
                "Playlist already exists: {}",
                destination.display()
            ))
        } else {
            PlaylistError::new(format!(
                "Atomic no-overwrite playlist rename failed; refusing an unsafe fallback: {err}"
            ))
        }
    })
}

fn refresh_library(music_dir: &Path, cache_path: &Path) -> Result<(), PlaylistError> {
    scan_library_to(music_dir, cache_path)
        .map(|_| ())
        .map_err(|err| PlaylistError::new(format!("Could not refresh library index: {err}")))
}

fn restored_after_refresh_failure(refresh_error: PlaylistError) -> PlaylistError {
    PlaylistError::new(format!("{refresh_error}; playlist was restored"))
}

fn restoration_failed_after_refresh_failure(
    refresh_error: PlaylistError,
    restore_error: PlaylistError,
) -> PlaylistError {
    PlaylistError::new(format!(
        "Playlist could not be restored after cache refresh failure: {restore_error}; refresh error: {refresh_error}"
    ))
}

fn restore_text_file(path: &Path, original: &str) -> Result<(), PlaylistError> {
    atomic_write(path, original)
        .map_err(|err| PlaylistError::new(format!("Could not restore playlist file: {err}")))?;
    let restored = fs::read(path)
        .map_err(|err| PlaylistError::new(format!("Could not verify restored playlist: {err}")))?;
    if restored != original.as_bytes() {
        return Err(PlaylistError::new(
            "Restored playlist contents did not match the original file",
        ));
    }
    Ok(())
}

fn restore_deleted_playlist(path: &Path, original: &[u8]) -> Result<(), PlaylistError> {
    atomic_create(path, original)?;
    let restored = fs::read(path)
        .map_err(|err| PlaylistError::new(format!("Could not verify restored playlist: {err}")))?;
    if restored != original {
        return Err(PlaylistError::new(
            "Restored playlist contents did not match the original file",
        ));
    }
    Ok(())
}

fn playlist_entry_path(playlist_path: &Path, entry: &str) -> Option<PathBuf> {
    let parent = playlist_path.parent()?;
    let candidate = parent.join(entry);
    fs::canonicalize(candidate).ok()
}

fn playlist_result(playlist: &PlaylistItem) -> serde_json::Value {
    serde_json::json!({
        "ok": true,
        "path": playlist.path,
        "playlist": playlist
    })
}

fn command_error(message: impl Into<String>) -> serde_json::Value {
    serde_json::json!({ "ok": false, "error": message.into() })
}

pub fn create_playlist(
    music_dir: &Path,
    cache_path: &Path,
    display_name: &str,
) -> Result<PlaylistItem, PlaylistError> {
    let music_dir = canonical_music_dir(music_dir)?;
    let name = sanitize_playlist_name(display_name)?;
    let target = music_dir.join(format!("{name}.m3u"));

    atomic_create(&target, b"")?;
    if let Err(refresh_error) = refresh_library(&music_dir, cache_path) {
        return match fs::remove_file(&target) {
            Ok(()) => Err(PlaylistError::new(format!(
                "{refresh_error}; created playlist was removed"
            ))),
            Err(remove_error) => Err(PlaylistError::new(format!(
                "Created playlist could not be removed after cache refresh failure: {remove_error}; refresh error: {refresh_error}"
            ))),
        };
    }
    read_playlist(&target)
        .map_err(|err| PlaylistError::new(format!("Could not read created playlist: {err}")))
}

pub fn add_track_to_playlist(
    music_dir: &Path,
    cache_path: &Path,
    playlist_path: &Path,
    track_path: &Path,
) -> Result<PlaylistItem, PlaylistError> {
    let playlist_path = recognized_playlist_path(music_dir, playlist_path)?;
    let track_path = canonical_track_path(track_path)?;
    let original = fs::read_to_string(&playlist_path)
        .map_err(|err| PlaylistError::new(format!("Could not read playlist file: {err}")))?;

    let mut updated = original.clone();
    if !updated.is_empty() && !updated.ends_with('\n') {
        updated.push('\n');
    }
    updated.push_str(&track_path.to_string_lossy());
    updated.push('\n');

    atomic_write(&playlist_path, &updated)
        .map_err(|err| PlaylistError::new(format!("Could not update playlist file: {err}")))?;
    if let Err(refresh_error) = refresh_library(music_dir, cache_path) {
        return match restore_text_file(&playlist_path, &original) {
            Ok(()) => Err(restored_after_refresh_failure(refresh_error)),
            Err(restore_error) => Err(restoration_failed_after_refresh_failure(
                refresh_error,
                restore_error,
            )),
        };
    }
    read_playlist(&playlist_path)
        .map_err(|err| PlaylistError::new(format!("Could not read updated playlist: {err}")))
}

pub fn remove_track_from_playlist(
    music_dir: &Path,
    cache_path: &Path,
    playlist_path: &Path,
    track_path: &Path,
) -> Result<PlaylistItem, PlaylistError> {
    let playlist_path = recognized_playlist_path(music_dir, playlist_path)?;
    let track_path = canonical_track_path(track_path)?;
    let original = fs::read_to_string(&playlist_path)
        .map_err(|err| PlaylistError::new(format!("Could not read playlist file: {err}")))?;

    let mut updated = String::new();
    let mut removed = false;
    for line in original.split_inclusive('\n') {
        let entry = line.trim();
        if !removed
            && !entry.is_empty()
            && !entry.starts_with('#')
            && playlist_entry_path(&playlist_path, entry).as_ref() == Some(&track_path)
        {
            removed = true;
            continue;
        }
        updated.push_str(line);
    }
    if !removed {
        return Err(PlaylistError::new("Track is not present in the playlist"));
    }

    atomic_write(&playlist_path, &updated)
        .map_err(|err| PlaylistError::new(format!("Could not update playlist file: {err}")))?;
    if let Err(refresh_error) = refresh_library(music_dir, cache_path) {
        return match restore_text_file(&playlist_path, &original) {
            Ok(()) => Err(restored_after_refresh_failure(refresh_error)),
            Err(restore_error) => Err(restoration_failed_after_refresh_failure(
                refresh_error,
                restore_error,
            )),
        };
    }
    read_playlist(&playlist_path)
        .map_err(|err| PlaylistError::new(format!("Could not read updated playlist: {err}")))
}

pub fn rename_playlist(
    music_dir: &Path,
    cache_path: &Path,
    playlist_path: &Path,
    display_name: &str,
) -> Result<PlaylistItem, PlaylistError> {
    let playlist_path = recognized_playlist_path(music_dir, playlist_path)?;
    let name = sanitize_playlist_name(display_name)?;
    let extension = playlist_path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("m3u");
    let parent = playlist_path
        .parent()
        .ok_or_else(|| PlaylistError::new("Playlist path does not have a parent directory"))?;
    let destination = parent.join(format!("{name}.{extension}"));

    if destination != playlist_path {
        atomic_rename_no_replace(&playlist_path, &destination)?;
        if let Err(refresh_error) = refresh_library(music_dir, cache_path) {
            return match atomic_rename_no_replace(&destination, &playlist_path) {
                Ok(()) => Err(restored_after_refresh_failure(refresh_error)),
                Err(restore_error) => Err(restoration_failed_after_refresh_failure(
                    refresh_error,
                    restore_error,
                )),
            };
        }
    }
    read_playlist(&destination)
        .map_err(|err| PlaylistError::new(format!("Could not read renamed playlist: {err}")))
}

fn delete_playlist_with_refresh<F>(
    music_dir: &Path,
    playlist_path: &Path,
    refresh: F,
) -> Result<PathBuf, PlaylistError>
where
    F: FnOnce() -> Result<(), PlaylistError>,
{
    let playlist_path = recognized_playlist_path(music_dir, playlist_path)?;
    let original = fs::read(&playlist_path)
        .map_err(|err| PlaylistError::new(format!("Could not read playlist file: {err}")))?;

    fs::remove_file(&playlist_path)
        .map_err(|err| PlaylistError::new(format!("Could not delete playlist file: {err}")))?;
    if let Err(refresh_error) = refresh() {
        return match restore_deleted_playlist(&playlist_path, &original) {
            Ok(()) => Err(restored_after_refresh_failure(refresh_error)),
            Err(restore_error) => Err(restoration_failed_after_refresh_failure(
                refresh_error,
                restore_error,
            )),
        };
    }
    Ok(playlist_path)
}

pub fn delete_playlist(
    music_dir: &Path,
    cache_path: &Path,
    playlist_path: &Path,
) -> Result<PathBuf, PlaylistError> {
    delete_playlist_with_refresh(music_dir, playlist_path, || {
        refresh_library(music_dir, cache_path)
    })
}

pub fn execute_playlist_command(
    command: &str,
    args: &[String],
    music_dir: &Path,
    cache_path: &Path,
) -> Option<serde_json::Value> {
    let result = match command {
        "playlist-create" => match args {
            [name] => create_playlist(music_dir, cache_path, name)
                .map(|playlist| playlist_result(&playlist)),
            _ => Err(PlaylistError::new("Usage: playlist-create <display-name>")),
        },
        "playlist-add" => match args {
            [playlist_path, track_path] => add_track_to_playlist(
                music_dir,
                cache_path,
                Path::new(playlist_path),
                Path::new(track_path),
            )
            .map(|playlist| playlist_result(&playlist)),
            _ => Err(PlaylistError::new(
                "Usage: playlist-add <playlist-path> <track-path>",
            )),
        },
        "playlist-remove" => match args {
            [playlist_path, track_path] => remove_track_from_playlist(
                music_dir,
                cache_path,
                Path::new(playlist_path),
                Path::new(track_path),
            )
            .map(|playlist| playlist_result(&playlist)),
            _ => Err(PlaylistError::new(
                "Usage: playlist-remove <playlist-path> <track-path>",
            )),
        },
        "playlist-rename" => match args {
            [playlist_path, display_name] => rename_playlist(
                music_dir,
                cache_path,
                Path::new(playlist_path),
                display_name,
            )
            .map(|playlist| playlist_result(&playlist)),
            _ => Err(PlaylistError::new(
                "Usage: playlist-rename <playlist-path> <display-name>",
            )),
        },
        "playlist-delete" => match args {
            [playlist_path] => delete_playlist(music_dir, cache_path, Path::new(playlist_path))
                .map(|path| serde_json::json!({ "ok": true, "path": path.to_string_lossy() })),
            _ => Err(PlaylistError::new("Usage: playlist-delete <playlist-path>")),
        },
        _ => return None,
    };

    Some(match result {
        Ok(value) => value,
        Err(err) => command_error(err.to_string()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::models::LibraryData;
    use std::fs;
    use std::os::unix::fs::symlink;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new() -> Self {
            let output = Command::new("mktemp")
                .arg("-d")
                .output()
                .expect("mktemp -d should be available");
            assert!(output.status.success(), "mktemp -d failed");
            let path = PathBuf::from(
                String::from_utf8(output.stdout)
                    .expect("valid temp path")
                    .trim()
                    .to_string(),
            );
            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn isolated_paths() -> (TempDir, PathBuf, PathBuf) {
        let temp = TempDir::new();
        let music_dir = temp.path().join("Music");
        fs::create_dir(&music_dir).expect("music directory should be created");
        let cache_path = temp.path().join("cache").join("library.json");
        (temp, music_dir, cache_path)
    }

    fn write_file(path: &Path, contents: &str) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("parent should be created");
        }
        fs::write(path, contents).expect("file should be written");
    }

    fn read_cached_library(cache_path: &Path) -> LibraryData {
        let contents = fs::read_to_string(cache_path).expect("cache should be written");
        serde_json::from_str(&contents).expect("cache should contain library data")
    }

    #[test]
    fn creates_empty_playlist_and_refreshes_library_index() {
        let (_temp, music_dir, cache_path) = isolated_paths();

        let playlist = create_playlist(&music_dir, &cache_path, "Road Trip").unwrap();
        let stored_path = music_dir.join("Road Trip.m3u");

        assert_eq!(playlist.name, "Road Trip");
        assert_eq!(
            playlist.path,
            stored_path
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .to_string()
        );
        assert_eq!(playlist.track_count, 0);
        assert!(playlist.track_paths.is_empty());
        assert_eq!(fs::read_to_string(&stored_path).unwrap(), "");

        let cached = read_cached_library(&cache_path);
        assert_eq!(cached.playlist_count, 1);
        assert_eq!(cached.playlists[0].path, playlist.path);

        let sanitized = create_playlist(&music_dir, &cache_path, "Mix: Vol. 2").unwrap();
        assert_eq!(sanitized.name, "Mix_ Vol. 2");
        assert!(music_dir.join("Mix_ Vol. 2.m3u").exists());
    }

    #[test]
    fn rejects_invalid_and_traversal_playlist_names_without_changing_files() {
        let (_temp, music_dir, cache_path) = isolated_paths();

        for name in [
            "",
            "   ",
            ".",
            "..",
            "../escape",
            "/absolute/escape",
            "nested/name",
            "nested\\name",
            "control\nname",
        ] {
            let result = create_playlist(&music_dir, &cache_path, name);
            assert!(result.is_err(), "name should be rejected: {name:?}");
        }

        assert_eq!(fs::read_dir(&music_dir).unwrap().count(), 0);
    }

    #[test]
    fn rejects_dot_prefixed_playlist_names_without_creating_hidden_files() {
        let (_temp, music_dir, cache_path) = isolated_paths();

        for name in [".favorites", ".hidden", " .private "] {
            let result = create_playlist(&music_dir, &cache_path, name);
            assert!(result.is_err(), "name should be rejected: {name:?}");
            let error = result.unwrap_err().to_string();
            assert!(
                error.contains("cannot start with a dot"),
                "error should explain the rule: {error}"
            );
        }

        assert_eq!(fs::read_dir(&music_dir).unwrap().count(), 0);
    }

    #[test]
    fn rejects_dot_prefixed_playlist_rename_without_changing_the_file() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let source = music_dir.join("Source.m3u");
        write_file(&source, "source");

        let result = rename_playlist(&music_dir, &cache_path, &source, ".hidden");

        assert!(result.is_err());
        let error = result.unwrap_err().to_string();
        assert!(
            error.contains("cannot start with a dot"),
            "error should explain the rule: {error}"
        );
        assert_eq!(fs::read_to_string(&source).unwrap(), "source");
        assert!(!music_dir.join(".hidden.m3u").exists());
    }

    #[test]
    fn accepts_playlist_names_with_internal_dots() {
        let (_temp, music_dir, cache_path) = isolated_paths();

        let playlist = create_playlist(&music_dir, &cache_path, "Radio 101.5").unwrap();

        assert_eq!(playlist.name, "Radio 101.5");
        assert!(music_dir.join("Radio 101.5.m3u").exists());
    }

    #[test]
    fn rejects_playlist_creation_collision_without_overwriting_file() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let stored_path = music_dir.join("Mix.m3u");
        write_file(&stored_path, "original");

        let result = create_playlist(&music_dir, &cache_path, "Mix");

        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&stored_path).unwrap(), "original");
    }

    #[test]
    fn adds_track_persisting_comments_and_ordering() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let first = music_dir.join("first.mp3");
        let second = music_dir.join("second.mp3");
        write_file(&first, "first");
        write_file(&second, "second");
        let playlist_path = music_dir.join("Set.m3u");
        write_file(&playlist_path, "#EXTM3U\n#EXTINF:1,First\nfirst.mp3\n");

        let playlist =
            add_track_to_playlist(&music_dir, &cache_path, &playlist_path, &second).unwrap();

        let expected = format!(
            "#EXTM3U\n#EXTINF:1,First\nfirst.mp3\n{}\n",
            second.canonicalize().unwrap().to_string_lossy()
        );
        assert_eq!(fs::read_to_string(&playlist_path).unwrap(), expected);
        assert_eq!(playlist.track_count, 2);
        assert_eq!(playlist.track_paths.len(), 2);
        assert_eq!(
            playlist.track_paths[0],
            first.canonicalize().unwrap().to_string_lossy()
        );
        assert_eq!(
            playlist.track_paths[1],
            second.canonicalize().unwrap().to_string_lossy()
        );
        assert_eq!(
            read_cached_library(&cache_path).playlists[0].path,
            playlist.path
        );
    }

    #[test]
    fn staging_symlink_cannot_redirect_playlist_write_outside_music() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let track_path = music_dir.join("song.mp3");
        let victim_path = music_dir.parent().unwrap().join("victim.txt");
        let playlist_path = music_dir.join("Set.m3u");
        write_file(&track_path, "song");
        write_file(&victim_path, "victim");
        write_file(&playlist_path, "#EXTM3U\n");

        let occupied_staging_path = music_dir.join(format!("Set.m3u.{}.tmp", std::process::id()));
        symlink(&victim_path, &occupied_staging_path).unwrap();

        let result = add_track_to_playlist(&music_dir, &cache_path, &playlist_path, &track_path);

        assert!(result.is_ok());
        assert_eq!(fs::read_to_string(&victim_path).unwrap(), "victim");
        assert!(fs::symlink_metadata(&playlist_path)
            .unwrap()
            .file_type()
            .is_file());
        assert_eq!(
            fs::read_to_string(&playlist_path).unwrap(),
            format!(
                "#EXTM3U\n{}\n",
                track_path.canonicalize().unwrap().to_string_lossy()
            )
        );
    }

    #[test]
    fn removes_track_and_persists_remaining_order() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let first = music_dir.join("first.mp3");
        let second = music_dir.join("second.mp3");
        write_file(&first, "first");
        write_file(&second, "second");
        let playlist_path = music_dir.join("Set.m3u");
        write_file(&playlist_path, "#EXTM3U\nfirst.mp3\nsecond.mp3\n");

        let playlist =
            remove_track_from_playlist(&music_dir, &cache_path, &playlist_path, &first).unwrap();

        assert_eq!(
            fs::read_to_string(&playlist_path).unwrap(),
            "#EXTM3U\nsecond.mp3\n"
        );
        assert_eq!(playlist.track_count, 1);
        assert_eq!(
            playlist.track_paths,
            vec![second.canonicalize().unwrap().to_string_lossy().to_string()]
        );
        assert_eq!(
            read_cached_library(&cache_path).playlists[0].path,
            playlist.path
        );
    }

    #[test]
    fn renames_playlist_and_refreshes_stored_path() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let old_path = music_dir.join("Old Name.m3u");
        write_file(&old_path, "#EXTM3U\n");

        let playlist = rename_playlist(&music_dir, &cache_path, &old_path, "New Name").unwrap();
        let new_path = music_dir.join("New Name.m3u");

        assert!(!old_path.exists());
        assert_eq!(fs::read_to_string(&new_path).unwrap(), "#EXTM3U\n");
        assert_eq!(
            fs::read_dir(&music_dir)
                .unwrap()
                .filter_map(Result::ok)
                .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "m3u"))
                .count(),
            1
        );
        assert_eq!(playlist.name, "New Name");
        assert_eq!(
            playlist.path,
            new_path
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .to_string()
        );
        assert_eq!(
            read_cached_library(&cache_path).playlists[0].path,
            playlist.path
        );
    }

    #[test]
    fn deletes_playlist_and_refreshes_library_index() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let playlist_path = music_dir.join("Disposable.m3u");
        write_file(&playlist_path, "#EXTM3U\n");

        let canonical_path = playlist_path.canonicalize().unwrap();
        let deleted_path = delete_playlist(&music_dir, &cache_path, &playlist_path).unwrap();

        assert_eq!(deleted_path, canonical_path);
        assert!(!playlist_path.exists());
        assert_eq!(read_cached_library(&cache_path).playlist_count, 0);
    }

    #[test]
    fn preserves_lexical_relative_track_paths() {
        let (_temp, music_dir, _cache_path) = isolated_paths();
        let outside_track = music_dir.parent().unwrap().join("outside.mp3");
        let playlist_path = music_dir.join("Relative.m3u");
        write_file(&outside_track, "outside");
        write_file(&playlist_path, "../outside.mp3\n");

        let playlist = read_playlist(&playlist_path).unwrap();

        assert_eq!(
            playlist.track_paths,
            vec![music_dir
                .join("../outside.mp3")
                .to_string_lossy()
                .to_string()]
        );
    }

    #[test]
    fn mutates_m3u8_playlists_and_preserves_extension_on_rename() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let track_path = music_dir.join("song.mp3");
        let playlist_path = music_dir.join("List.M3U8");
        write_file(&track_path, "song");
        write_file(&playlist_path, "#EXTM3U\n");

        let playlist =
            add_track_to_playlist(&music_dir, &cache_path, &playlist_path, &track_path).unwrap();
        assert_eq!(playlist.track_count, 1);

        let renamed = rename_playlist(&music_dir, &cache_path, &playlist_path, "Renamed").unwrap();
        assert_eq!(
            renamed.path,
            music_dir
                .join("Renamed.M3U8")
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .to_string()
        );
        assert!(music_dir.join("Renamed.M3U8").exists());
        assert!(!playlist_path.exists());
    }

    #[test]
    fn rejects_playlist_path_outside_music_library_without_changing_file() {
        let temp = TempDir::new();
        let music_dir = temp.path().join("Music");
        fs::create_dir(&music_dir).unwrap();
        let cache_path = temp.path().join("cache").join("library.json");
        let outside_path = temp.path().join("outside.m3u");
        let track_path = music_dir.join("song.mp3");
        write_file(&outside_path, "#EXTM3U\n");
        write_file(&track_path, "song");

        let result = add_track_to_playlist(&music_dir, &cache_path, &outside_path, &track_path);

        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&outside_path).unwrap(), "#EXTM3U\n");
    }

    #[test]
    fn rejects_unrecognized_playlist_path_without_changing_file() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let notes_path = music_dir.join("notes.txt");
        let track_path = music_dir.join("song.mp3");
        write_file(&notes_path, "notes");
        write_file(&track_path, "song");

        let result = add_track_to_playlist(&music_dir, &cache_path, &notes_path, &track_path);

        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&notes_path).unwrap(), "notes");
    }

    #[test]
    fn rejects_missing_track_without_changing_playlist() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let playlist_path = music_dir.join("Set.m3u");
        write_file(&playlist_path, "#EXTM3U\n");

        let result = add_track_to_playlist(
            &music_dir,
            &cache_path,
            &playlist_path,
            &music_dir.join("missing.mp3"),
        );

        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&playlist_path).unwrap(), "#EXTM3U\n");
    }

    #[test]
    fn delete_refresh_failure_restores_playlist_and_reports_error_envelope() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let playlist_path = music_dir.join("Disposable.m3u");
        write_file(&playlist_path, "#EXTM3U\n");
        let blocked_cache_parent = cache_path.parent().unwrap();
        write_file(blocked_cache_parent, "not a directory");

        let envelope = execute_playlist_command(
            "playlist-delete",
            &[playlist_path.to_string_lossy().to_string()],
            &music_dir,
            &cache_path,
        )
        .unwrap();

        assert_eq!(envelope["ok"], false);
        assert!(envelope["error"]
            .as_str()
            .is_some_and(|error| error.contains("restored")));
        assert_eq!(fs::read_to_string(&playlist_path).unwrap(), "#EXTM3U\n");
    }

    #[test]
    fn delete_refresh_failure_reports_when_restoration_is_impossible() {
        let (_temp, music_dir, _cache_path) = isolated_paths();
        let playlist_path = music_dir.join("Disposable.m3u");
        write_file(&playlist_path, "#EXTM3U\n");
        let occupied_path = playlist_path.clone();

        let error = delete_playlist_with_refresh(&music_dir, &playlist_path, || {
            fs::create_dir(&occupied_path).unwrap();
            Err(PlaylistError::new("forced cache refresh failure"))
        })
        .unwrap_err();

        assert!(error.to_string().contains("Playlist could not be restored"));
        assert!(occupied_path.is_dir());
    }

    #[test]
    fn rejects_rename_collision_without_changing_either_file() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let source = music_dir.join("Source.m3u");
        let destination = music_dir.join("Target.m3u");
        write_file(&source, "source");
        write_file(&destination, "target");

        let result = rename_playlist(&music_dir, &cache_path, &source, "Target");

        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&source).unwrap(), "source");
        assert_eq!(fs::read_to_string(&destination).unwrap(), "target");
    }

    #[test]
    fn rejects_rename_path_outside_music_library_without_changing_file() {
        let temp = TempDir::new();
        let music_dir = temp.path().join("Music");
        fs::create_dir(&music_dir).unwrap();
        let cache_path = temp.path().join("cache").join("library.json");
        let outside_path = temp.path().join("outside.m3u");
        write_file(&outside_path, "#EXTM3U\n");

        let result = rename_playlist(&music_dir, &cache_path, &outside_path, "Renamed");

        assert!(result.is_err());
        assert_eq!(fs::read_to_string(&outside_path).unwrap(), "#EXTM3U\n");
        assert!(!temp.path().join("Renamed.m3u").exists());
    }

    #[test]
    fn cli_playlist_commands_manage_persistent_files() {
        let (_temp, music_dir, cache_path) = isolated_paths();
        let track_path = music_dir.join("song.mp3");
        write_file(&track_path, "song");

        let created = execute_playlist_command(
            "playlist-create",
            &["Road Trip".to_string()],
            &music_dir,
            &cache_path,
        )
        .unwrap();
        assert_eq!(created["ok"], true);
        let playlist_path = PathBuf::from(created["playlist"]["path"].as_str().unwrap());

        let added = execute_playlist_command(
            "playlist-add",
            &[
                playlist_path.to_string_lossy().to_string(),
                track_path.to_string_lossy().to_string(),
            ],
            &music_dir,
            &cache_path,
        )
        .unwrap();
        assert_eq!(added["ok"], true);
        assert_eq!(added["playlist"]["track_count"], 1);

        let removed = execute_playlist_command(
            "playlist-remove",
            &[
                playlist_path.to_string_lossy().to_string(),
                track_path.to_string_lossy().to_string(),
            ],
            &music_dir,
            &cache_path,
        )
        .unwrap();
        assert_eq!(removed["ok"], true);
        assert_eq!(removed["playlist"]["track_count"], 0);

        let renamed = execute_playlist_command(
            "playlist-rename",
            &[
                playlist_path.to_string_lossy().to_string(),
                "Renamed".to_string(),
            ],
            &music_dir,
            &cache_path,
        )
        .unwrap();
        assert_eq!(renamed["ok"], true);
        let renamed_path = PathBuf::from(renamed["playlist"]["path"].as_str().unwrap());
        assert!(music_dir.join("Renamed.m3u").exists());

        let deleted = execute_playlist_command(
            "playlist-delete",
            &[renamed_path.to_string_lossy().to_string()],
            &music_dir,
            &cache_path,
        )
        .unwrap();
        assert_eq!(deleted["ok"], true);
        assert!(!music_dir.join("Renamed.m3u").exists());

        let rejected =
            execute_playlist_command("playlist-add", &[], &music_dir, &cache_path).unwrap();
        assert_eq!(rejected["ok"], false);
        assert!(rejected["error"]
            .as_str()
            .is_some_and(|error| !error.is_empty()));
    }
}
