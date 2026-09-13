//! Trusted executable resolution for child processes.
//!
//! Mixarchy never resolves an external binary through the inherited `PATH`.
//! Required executables (currently `mpv`) are resolved from a fixed set of
//! root-owned system directories and validated before use:
//!
//! - the canonical (symlink-resolved) path is a regular file,
//! - owned by uid 0 (root),
//! - not writable by group or other (`mode & 0o022 == 0`),
//! - every directory on the chain up to `/` is root-owned and not
//!   group/world-writable.
//!
//! The child environment is then cleared and reconstructed from a fixed
//! allow-list ([`fixed_env`]) that matches the allow-list used on the QML
//! process boundaries in `Panel.qml`. This removes the pre-verification
//! execution window: a user-writable or shadowed executable (PATH entries,
//! `BASH_ENV`, `LD_PRELOAD`, shell startup files) can no longer run before
//! the downloaded binary's pinned SHA-256 is checked, because nothing is
//! resolved through the inherited environment.

use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::process::Command;

/// Fixed trusted system binary directories, in resolution order.
const TRUSTED_BIN_DIRS: &[&str] = &["/usr/bin", "/bin", "/usr/local/bin"];

/// Trusted PATH handed to every child process we start.
pub const TRUSTED_PATH: &str = "/usr/local/bin:/usr/bin:/bin";

/// True when the file is a regular file owned by root and not writable by
/// group or other (mode bits `0o022` clear).
fn is_root_owned_readonly_file(meta: &fs::Metadata) -> bool {
    meta.is_file() && meta.uid() == 0 && meta.mode() & 0o022 == 0
}

/// True when every directory from `path` up to `/` is a directory owned by
/// root and not writable by group or other.
fn dir_chain_trusted(path: &Path) -> bool {
    let canonical = match fs::canonicalize(path) {
        Ok(c) => c,
        Err(_) => return false,
    };
    let mut current = canonical.as_path();
    loop {
        let Ok(meta) = fs::metadata(current) else {
            return false;
        };
        if !meta.is_dir() || meta.uid() != 0 || meta.mode() & 0o022 != 0 {
            return false;
        }
        match current.parent() {
            Some(parent) if parent != current => current = parent,
            _ => return true,
        }
    }
}

/// Resolve `name` to a validated absolute executable path, or `None` when no
/// trusted candidate exists.
pub fn resolve_trusted(name: &str) -> Option<PathBuf> {
    for dir in TRUSTED_BIN_DIRS {
        let candidate = Path::new(dir).join(name);
        let Ok(canonical) = fs::canonicalize(&candidate) else {
            continue;
        };
        let Ok(meta) = fs::metadata(&canonical) else {
            continue;
        };
        if !is_root_owned_readonly_file(&meta) || !dir_chain_trusted(&canonical) {
            continue;
        }
        return Some(canonical);
    }
    None
}

/// Reconstruct a minimal fixed child environment instead of inheriting the
/// (possibly attacker-influenced) session environment. This is the same
/// allow-list applied to the QML process boundaries in `Panel.qml`.
pub fn fixed_env(cmd: &mut Command) {
    cmd.env_clear();
    if let Ok(home) = std::env::var("HOME") {
        cmd.env("HOME", home);
    }
    if let Ok(runtime) = std::env::var("XDG_RUNTIME_DIR") {
        cmd.env("XDG_RUNTIME_DIR", runtime);
    }
    cmd.env("PATH", TRUSTED_PATH);
    cmd.env("LANG", "C.UTF-8");
}

/// Build a `Command` for a trusted executable with the fixed child
/// environment applied. Returns `None` when the executable cannot be resolved
/// from a trusted location.
pub fn trusted_command(name: &str) -> Option<Command> {
    let path = resolve_trusted(name)?;
    let mut cmd = Command::new(path);
    fixed_env(&mut cmd);
    Some(cmd)
}