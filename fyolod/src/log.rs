//! Where the daemon's own diagnostics go.
//!
//! `fyolod serve` is normally started by the Mac app with stdio on `/dev/null`
//! (`FyolodClient.spawnDaemon`) or by launchd, whose plist names no
//! `StandardErrorPath`. Both discard stderr, so every `eprintln!` in the daemon —
//! and every panic message, since the release profile aborts — was unrecoverable
//! after the fact. A user reporting "fyolo froze" could hand over the app's
//! unified-log trail and nothing whatsoever from the process that owns the PTYs.
//!
//! The fix works at the file-descriptor level rather than by rewriting fifty-odd
//! call sites: `serve` opens the log file and points fd 1 and fd 2 at it. Nothing
//! in the daemon has to know it is being logged, and a panic message is captured
//! for free.
//!
//! **Why the file and not a pipe with a formatting thread.** Stamping each line
//! wants a pump thread between the daemon and the file, and the first version
//! here did that. It loses the lines that matter most: a daemon that fails during
//! startup exits before the pump is scheduled, and the error explaining why goes
//! down with the process — measured, not theorised. Worse, it makes every
//! `eprintln!` in the daemon that owns every PTY depend on a 64 KB pipe being
//! drained, and "a blocking write wedges the process" is the exact failure fyolo
//! already has a bug doc about. Writing straight to the file is synchronous in
//! the kernel: nothing is buffered in user space, so nothing is lost however the
//! process dies, and no writer can ever block on a reader.
//!
//! The cost is per-line timestamps, which need the call sites to change and so
//! belong with adopting `tracing` rather than with restoring the log at all.
//!
//! The daemon claims stderr only when it points at `/dev/null` — when the output
//! is provably going nowhere. Anything else means somebody chose that
//! destination: a terminal is a person watching, a pipe is a parent collecting
//! (`Command::output()` in the integration tests, a script reading the refusal
//! message), a file is a redirect the operator typed. Taking any of those over
//! would be a regression. "Not a terminal" was the first rule here and it was
//! too broad: it swallowed the piped case and broke a test that reads the
//! daemon's refusal off stderr.

use anyhow::{Context, Result};
use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

/// Rotate once the live file reaches this size, keeping `GENERATIONS` older
/// files — about six megabytes in total.
///
/// These are cmux's numbers for the same job (a per-user session daemon), and
/// they are the right order of magnitude: this file holds lifecycle events, not
/// traffic, so a cap this size is weeks of ordinary use and still bounds the
/// pathological case of a session in a crash loop. Zellij's 16 MiB is sized for
/// a log that swallows plugin stderr; tmux's unbounded file is the anti-pattern.
///
/// Rotation happens when the daemon starts, which is the only moment it holds
/// the file exclusively. A single very long-lived run can therefore exceed the
/// cap; bounding that needs the formatting layer this deliberately does without.
const ROTATE_BYTES: u64 = 2 * 1024 * 1024;
const GENERATIONS: usize = 3;

/// The log records session cwds, agent names, and the text of any error the
/// daemon hit — a description of what the user is working on. It is readable by
/// its owner and nobody else, matching the socket beside it.
const FILE_MODE: u32 = 0o600;
const DIRECTORY_MODE: u32 = 0o700;

/// Points stdout and stderr at the daemon's log file for the rest of the
/// process's life. Returns the path, or `None` when stderr is a terminal and the
/// caller is watching the output directly.
///
/// Call this first in `serve`, before anything that can fail: the errors worth
/// capturing most are the ones from starting up.
pub fn redirect() -> Result<Option<PathBuf>> {
    if !discarded(libc::STDERR_FILENO) {
        return Ok(None);
    }

    let path = crate::paths::log_path()?;
    if let Some(parent) = path.parent() {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(DIRECTORY_MODE)
            .create(parent)
            .with_context(|| format!("creating {}", parent.display()))?;
    }

    if oversized(&path) {
        rotate(&path);
    }

    let mut file = open_sink(&path).with_context(|| format!("opening {}", path.display()))?;
    // A run boundary, so a reader can tell one daemon's lines from the next.
    // Written before the redirect, while errors from it are still reportable.
    let _ = writeln!(
        file,
        "--- fyolod {} starting, pid {} ---",
        crate::lifecycle::BUILD_VERSION,
        std::process::id(),
    );

    // Both descriptors, not just stderr: a stray `println!` in the daemon is as
    // lost down /dev/null as a stray `eprintln!`, and there is no reason for the
    // two to land in different places.
    for target in [libc::STDOUT_FILENO, libc::STDERR_FILENO] {
        if unsafe { libc::dup2(file.as_raw_fd(), target) } < 0 {
            return Err(std::io::Error::last_os_error()).context("pointing stdio at the log");
        }
    }
    // fd 1 and 2 now hold their own references to the open file; this one has
    // done its job.
    drop(file);

    Ok(Some(path))
}

/// True when `descriptor` is the null device, i.e. whoever started this process
/// is throwing its output away.
fn discarded(descriptor: libc::c_int) -> bool {
    let mut current: libc::stat = unsafe { std::mem::zeroed() };
    if unsafe { libc::fstat(descriptor, &mut current) } != 0 {
        return false;
    }
    // `st_rdev` is meaningful only for a device, and comparing it on anything
    // else would match arbitrary files by coincidence.
    if current.st_mode & libc::S_IFMT != libc::S_IFCHR {
        return false;
    }
    let Ok(null) = std::fs::metadata("/dev/null") else {
        return false;
    };
    use std::os::unix::fs::MetadataExt;
    current.st_rdev as u64 == null.rdev()
}

fn oversized(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|metadata| metadata.len() >= ROTATE_BYTES)
        .unwrap_or(false)
}

fn open_sink(path: &Path) -> std::io::Result<File> {
    use std::os::unix::fs::PermissionsExt;
    // `mode` applies only when this call creates the file, so a log left by an
    // older build keeps whatever mode it had. Re-assert rather than trust it.
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(FILE_MODE)
        .open(path)?;
    let mut permissions = file.metadata()?.permissions();
    if permissions.mode() & 0o777 != FILE_MODE {
        permissions.set_mode(FILE_MODE);
        let _ = file.set_permissions(permissions);
    }
    Ok(file)
}

/// Shifts `fyolod.log` to `fyolod.log.1`, `.1` to `.2`, and so on, dropping
/// the oldest. Renames rather than truncating, so a report someone is already
/// reading keeps its contents.
///
/// Generational suffixes rather than Nomad's `nomad-<unix-nanos>.log`: that
/// scheme is a long-standing complaint against it, because the newest file is
/// not identifiable by eye.
fn rotate(path: &Path) {
    let generation = |index: usize| -> PathBuf {
        let mut name = path.as_os_str().to_os_string();
        name.push(format!(".{index}"));
        PathBuf::from(name)
    };
    let _ = std::fs::remove_file(generation(GENERATIONS));
    for index in (1..GENERATIONS).rev() {
        let _ = std::fs::rename(generation(index), generation(index + 1));
    }
    let _ = std::fs::rename(path, generation(1));
}

/// `fyolod logs` — the answer to "where are the logs?", which until now was
/// "there aren't any". Reading the file directly works too; this exists so the
/// answer is one command rather than a path the user has to be told.
pub async fn show(path_only: bool, follow: bool, lines: usize) -> Result<()> {
    let path = crate::paths::log_path()?;
    if path_only {
        println!("{}", path.display());
        return Ok(());
    }
    if !path.exists() {
        // Two very different situations, and guessing between them wastes the
        // reader's time, so name both.
        println!(
            "no log yet at {}\n\
             The daemon writes one only when its stderr goes to /dev/null, the \
             way the app and launchd start it. Run in a terminal, or with its \
             output piped or redirected, it prints there instead.",
            path.display()
        );
        return Ok(());
    }

    let text = std::fs::read_to_string(&path)
        .with_context(|| format!("reading {}", path.display()))?;
    let all: Vec<&str> = text.lines().collect();
    let start = if lines == 0 {
        0
    } else {
        all.len().saturating_sub(lines)
    };
    for line in &all[start..] {
        println!("{line}");
    }

    if !follow {
        return Ok(());
    }

    let mut offset = text.len() as u64;
    loop {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        let Ok(metadata) = std::fs::metadata(&path) else {
            continue;
        };
        // A shrinking file means the daemon restarted and rotated underneath us;
        // start again from the top rather than seeking past the new file's end.
        if metadata.len() < offset {
            offset = 0;
        }
        if metadata.len() == offset {
            continue;
        }
        use std::io::{Read, Seek, SeekFrom};
        let mut file = File::open(&path)?;
        file.seek(SeekFrom::Start(offset))?;
        let mut fresh = String::new();
        file.read_to_string(&mut fresh)?;
        print!("{fresh}");
        std::io::stdout().flush()?;
        offset = metadata.len();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rotate_shifts_generations_and_drops_the_oldest() {
        let root = std::env::temp_dir().join(format!("fyolod-log-rotate-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp dir");
        let path = root.join("fyolod.log");

        std::fs::write(&path, "newest").expect("write live file");
        for index in 1..=GENERATIONS {
            std::fs::write(
                root.join(format!("fyolod.log.{index}")),
                format!("gen{index}"),
            )
            .expect("write generation");
        }

        rotate(&path);

        assert!(!path.exists(), "the live file is renamed, not left behind");
        assert_eq!(
            std::fs::read_to_string(root.join("fyolod.log.1")).expect("newest generation"),
            "newest"
        );
        assert_eq!(
            std::fs::read_to_string(root.join(format!("fyolod.log.{GENERATIONS}")))
                .expect("oldest kept generation"),
            format!("gen{}", GENERATIONS - 1),
            "each generation shifts down one"
        );
        assert_eq!(
            std::fs::read_dir(&root).expect("listing").count(),
            GENERATIONS,
            "the oldest generation is dropped rather than accumulating"
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn only_a_discarded_stderr_is_claimed() {
        use std::os::unix::io::AsRawFd;

        let null = File::open("/dev/null").expect("/dev/null");
        assert!(discarded(null.as_raw_fd()), "the null device is claimed");

        // A pipe is what `Command::output()` hands a child: a parent collecting
        // the output, which must keep reaching it.
        let mut ends = [0 as libc::c_int; 2];
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        assert!(!discarded(ends[1]), "a pipe means a parent is reading");
        unsafe {
            libc::close(ends[0]);
            libc::close(ends[1]);
        }

        // So is a plain file, which is what a shell redirect produces.
        let path = std::env::temp_dir().join(format!("fyolod-discard-{}", std::process::id()));
        let file = File::create(&path).expect("temp file");
        assert!(!discarded(file.as_raw_fd()), "a redirect names a destination");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn a_new_log_is_private_to_its_owner() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir().join(format!("fyolod-log-mode-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).expect("temp dir");
        let path = root.join("fyolod.log");

        let file = open_sink(&path).expect("open");
        let mode = file.metadata().expect("metadata").permissions().mode() & 0o777;
        assert_eq!(mode, FILE_MODE, "the log names what the user is working on");

        let _ = std::fs::remove_dir_all(&root);
    }
}
