//! Who is running in the session's terminal, and where.
//!
//! This answers "which agent is in there" — a question whose answer changes
//! when a human starts or stops a program, not per frame. It knows nothing
//! about clients, snapshots or the protocol; it needs a tty and a child pid,
//! and everything else it learns from the kernel.
//!
//! Split deliberately along what each half costs. `tcgetpgrp` is one syscall
//! and runs on the session actor; reading argv is a `KERN_PROCARGS2` sysctl on
//! macOS and a file read on Linux, and finding *which* pid to read it for can
//! mean walking every process on the box when a pipeline's leader has exited.
//! None of that may happen on the actor: that task also runs the PTY read and
//! the fan-out, so a process-table walk there is time the byte path spends
//! waiting — the anti-100× invariant, which is about more than the VT parse.

use crate::proc::ExecutableIdentity;
use crate::pty::Pty;
use tokio::sync::mpsc;

/// How often the session asks the kernel what is running in its terminal.
/// Slow on purpose, for the reason in the module note above.
pub(crate) const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(2);

/// What the session believes about its foreground right now.
#[derive(Default, Clone, PartialEq, Eq)]
pub(crate) struct ForegroundSample {
    /// The foreground process *group*, exactly as `tcgetpgrp` reported it.
    /// Kept even when no member of it could be read, because "is a job
    /// running?" is answered by comparing this against the session's own child
    /// and must not turn into "no" the moment a pipeline's leader exits.
    pgid: Option<i32>,
    /// The member of that group whose argv is reported below. Equal to `pgid`
    /// whenever the group leader is still usable, which is the common case.
    pub(super) pid: Option<i32>,
    pub(super) argv: Option<Vec<String>>,
    pub(super) job: bool,
    pub(super) cwd: Option<String>,
    /// The root of the git checkout `cwd` sits inside, or `None` outside one.
    /// Derived here, on the blocking thread, so the roster can group a session
    /// nobody named a project for — a shell started by hand on this box — under
    /// the checkout it is actually standing in, without `info()` touching the
    /// filesystem.
    pub(super) repo_root: Option<String>,
}

/// The expensive half of a foreground sample, computed on a blocking thread and
/// handed back to the actor.
pub(crate) struct ForegroundResolution {
    /// The group this answer describes. The foreground can move while the
    /// resolution is in flight, and an answer about a group that has since lost
    /// the terminal is not a stale version of the truth — it is the answer to a
    /// different question, and gets dropped.
    pgid: Option<i32>,
    pid: Option<i32>,
    argv: Option<Vec<String>>,
    cwd: Option<String>,
    repo_root: Option<String>,
    /// Only set when the session had not pinned its binary yet, or when this
    /// answer is the first job that can replace a pin taken off a wrapper shell.
    executable: Option<ExecutableIdentity>,
    /// Whether `executable` was read off a foreground job rather than the direct
    /// child — what lets [`Foreground::apply`] re-pin over a wrapper shell once.
    executable_is_job: bool,
}

/// The session's foreground knowledge and the machinery that keeps it current.
///
/// The three pieces live together because they are only meaningful together:
/// `pending` guards the dispatch that fills `sample`, and `executable` is
/// pinned by the same resolution. They are not a state machine — a resolution
/// in flight says nothing about what `sample` currently holds, which is exactly
/// why [`Foreground::apply`] re-checks the group before believing an answer.
#[derive(Default)]
pub(crate) struct Foreground {
    sample: ForegroundSample,
    /// A resolution is in flight on a blocking thread. One at a time: the poll
    /// is slower than the work, and piling up would only queue answers about
    /// groups that have already lost the terminal.
    pending: bool,
    /// The binary the session is running, pinned on the first sample that finds
    /// it. This is the *launch* baseline `was_replaced()` compares against, so
    /// resampling would paper over the in-place upgrade it exists to notice —
    /// it is taken at most twice, and only ever to correct the target.
    executable: Option<ExecutableIdentity>,
    /// Whether `executable` names a foreground **job** rather than the direct
    /// child. A launch line the shell could not `exec` into leaves that shell as
    /// the child, and the agent — the binary a self-update replaces — runs as a
    /// job under it, so the first job to hold the terminal re-pins over the
    /// shell. Set once and never cleared, which is what keeps the baseline fixed
    /// from then on.
    pinned_job: bool,
}

impl Foreground {
    /// Pins the sampled argv so a test can ask what the size policy would do
    /// with a given program on screen, without a real process group.
    #[cfg(test)]
    pub(super) fn set_argv_for_tests(&mut self, argv: Option<Vec<String>>) {
        self.sample.argv = argv;
    }

    /// Pins the job bit the same way: whether the sampled group is something
    /// the child put in the foreground rather than the child itself.
    #[cfg(test)]
    pub(super) fn set_job_for_tests(&mut self, job: bool) {
        self.sample.job = job;
    }

    /// The foreground process group, for the one caller outside this file that
    /// needs the group itself rather than what is running in it: the kill path,
    /// which has to reach a job the shell put in a group of its own.
    pub(super) fn group(&self) -> Option<i32> {
        self.sample.pgid
    }

    pub(super) fn current(&self) -> &ForegroundSample {
        &self.sample
    }

    /// The path of the binary the session's child is running, as pinned at
    /// launch.
    pub(super) fn executable_path(&self) -> Option<String> {
        self.executable.as_ref().map(|identity| identity.path.clone())
    }

    /// Whether that binary has since been replaced on disk. A fresh read every
    /// time it is asked: the record that matters most is the one built on the
    /// exit path, and a binary swapped during the seconds before the child quit
    /// is exactly the case this answers.
    pub(super) fn executable_replaced(&self) -> bool {
        self.executable
            .as_ref()
            .is_some_and(|identity| identity.was_replaced())
    }

    /// The cheap half of the poll, and the only half that runs on the actor:
    /// one `tcgetpgrp` on the master. Returns whether anything moved, so a
    /// quiet session emits no roster traffic.
    ///
    /// The expensive half is dispatched to a blocking thread and applied later
    /// by [`Foreground::apply`]. Both halves have to exist because they answer
    /// different questions on different deadlines: "is a job running?" is read
    /// at close time and must be current, and it is answerable from the group
    /// id alone; "what is that job?" drives an icon and can be a beat late.
    pub(super) fn poll(
        &mut self,
        pty: &Pty,
        child: i32,
        resolved: &mpsc::UnboundedSender<ForegroundResolution>,
    ) -> bool {
        if child <= 0 {
            return false;
        }
        let pgid = pty.foreground_pgid();
        // Compared against the *group*: a foreground group that is not the
        // child's own is a running job whether or not any member of it could
        // be read.
        let job = pgid.is_some_and(|pgid| pgid != child);
        let mut changed = false;
        if self.sample.pgid != pgid {
            self.sample.pgid = pgid;
            // The cached identity described a group that no longer holds the
            // terminal. Dropping it is an honest gap the resolution below
            // fills; keeping it would name a program that has already exited.
            self.sample.pid = None;
            self.sample.argv = None;
            changed = true;
        }
        if self.sample.job != job {
            self.sample.job = job;
            changed = true;
        }
        self.request(pgid, child, resolved);
        changed
    }

    /// Hand the process-table work to a blocking thread.
    fn request(
        &mut self,
        pgid: Option<i32>,
        child: i32,
        resolved: &mpsc::UnboundedSender<ForegroundResolution>,
    ) {
        if self.pending {
            return;
        }
        self.pending = true;
        // A group that is not the child's own is a job, and the job is what is
        // worth pinning: the child may be a wrapper shell that has not reached
        // the agent yet, or may never have been the agent at all. Recomputed
        // only until the first job is pinned, so a plain terminal that never
        // runs one does not read the process table for this on every poll.
        let job = pgid.is_some_and(|group| group != child);
        let pin_executable = self.executable.is_none() || (job && !self.pinned_job);
        let resolved = resolved.clone();
        tokio::task::spawn_blocking(move || {
            // A group id is not a pid. The shell names each job's group after
            // its leader, so the two agree for as long as that leader is alive
            // — and stop agreeing in a pipeline the moment it is not, which is
            // why the pid comes from the host rather than from that assumption.
            let pid = pgid.and_then(crate::proc::foreground_member);
            let cwd = crate::proc::working_directory(child);
            let repo_root = cwd.as_deref().and_then(repo_root);
            let _ = resolved.send(ForegroundResolution {
                pgid,
                pid,
                argv: pid.and_then(crate::proc::process_arguments),
                cwd,
                repo_root,
                executable: pin_executable
                    .then(|| {
                        crate::proc::executable_identity(match pid {
                            Some(pid) if job => pid,
                            _ => child,
                        })
                    })
                    .flatten(),
                executable_is_job: job && pid.is_some(),
            });
        });
    }

    /// Take a resolution the blocking thread finished, unless the foreground
    /// moved while it was in flight. Returns whether anything moved.
    pub(super) fn apply(&mut self, resolution: ForegroundResolution) -> bool {
        self.pending = false;
        if resolution.pgid != self.sample.pgid {
            return false;
        }
        // The first job to hold the terminal replaces a pin taken off the child,
        // because that pin named a wrapper shell rather than the agent. Every
        // later sample leaves it alone: re-pinning after a self-update replaced
        // the binary is exactly what would hide the replacement.
        if resolution.executable.is_some()
            && (self.executable.is_none() || (resolution.executable_is_job && !self.pinned_job))
        {
            self.executable = resolution.executable;
            self.pinned_job = resolution.executable_is_job;
        }
        let mut changed = false;
        if self.sample.pid != resolution.pid {
            self.sample.pid = resolution.pid;
            changed = true;
        }
        if self.sample.argv != resolution.argv {
            self.sample.argv = resolution.argv;
            changed = true;
        }
        if self.sample.cwd != resolution.cwd {
            self.sample.cwd = resolution.cwd;
            changed = true;
        }
        if self.sample.repo_root != resolution.repo_root {
            self.sample.repo_root = resolution.repo_root;
            changed = true;
        }
        changed
    }
}

/// The nearest ancestor of `cwd` holding a `.git` entry — a directory for a
/// checkout, a file for a worktree. Walks *up* only, never down: descending
/// from a home directory is what fires the macOS TCC prompts, and the upward
/// walk is the repo-detection rule `20260713-loose-terminal-entity.md` set. A
/// cwd outside any checkout answers `None`, which is what keeps a plain shell
/// in `$HOME` a loose terminal.
fn repo_root(cwd: &str) -> Option<String> {
    let mut directory = std::path::Path::new(cwd);
    loop {
        if directory.join(".git").exists() {
            return Some(directory.to_string_lossy().into_owned());
        }
        directory = directory.parent()?;
    }
}

#[cfg(test)]
mod tests {
    use super::{Foreground, ForegroundResolution, repo_root};
    use crate::proc::ExecutableIdentity;

    #[test]
    fn repo_root_walks_up_to_the_checkout() {
        let scratch =
            std::env::temp_dir().join(format!("fyolod-repo-root-{}", std::process::id()));
        let checkout = scratch.join("checkout");
        let nested = checkout.join("src").join("deep");
        std::fs::create_dir_all(&nested).expect("scratch tree");
        std::fs::create_dir_all(checkout.join(".git")).expect("git dir");

        let root = repo_root(nested.to_str().expect("utf-8 path"));
        assert_eq!(root.as_deref(), checkout.to_str());

        std::fs::remove_dir_all(&scratch).expect("scratch cleanup");
    }

    #[test]
    fn a_worktree_checkout_is_a_repo_too() {
        // A linked worktree marks its root with a `.git` *file*, not a
        // directory, and it is its own project root rather than the main
        // checkout's.
        let scratch =
            std::env::temp_dir().join(format!("fyolod-worktree-root-{}", std::process::id()));
        let worktree = scratch.join("worktree");
        std::fs::create_dir_all(&worktree).expect("scratch tree");
        std::fs::write(worktree.join(".git"), "gitdir: elsewhere\n").expect("git file");

        let root = repo_root(worktree.to_str().expect("utf-8 path"));
        assert_eq!(root.as_deref(), worktree.to_str());

        std::fs::remove_dir_all(&scratch).expect("scratch cleanup");
    }

    #[test]
    fn a_directory_outside_any_checkout_is_loose() {
        let scratch =
            std::env::temp_dir().join(format!("fyolod-loose-root-{}", std::process::id()));
        std::fs::create_dir_all(&scratch).expect("scratch dir");

        // temp_dir sits outside any checkout on every host this runs on, so
        // the walk reaches the filesystem root and answers nothing.
        assert_eq!(repo_root(scratch.to_str().expect("utf-8 path")), None);

        std::fs::remove_dir_all(&scratch).expect("scratch cleanup");
    }

    /// The pin has to name the **agent**, not the shell that started it. A
    /// launch line the shell could not `exec` into leaves that shell as the
    /// direct child, and pinning it meant a replaced agent binary reported
    /// `child_executable_replaced: false` — so the pane reverted to a shell
    /// instead of relaunching the upgraded agent.
    #[test]
    fn the_first_job_repins_over_a_wrapper_shell() {
        let mut foreground = Foreground::default();
        let shell = ExecutableIdentity { path: "/bin/zsh".to_string(), inode: Some(1) };
        let agent = ExecutableIdentity { path: "/opt/bin/agy".to_string(), inode: Some(2) };

        // First sample: the wrapper shell still holds the terminal.
        foreground.sample.pgid = Some(100);
        assert!(foreground.apply(ForegroundResolution {
            pgid: Some(100), pid: Some(100), argv: None, cwd: None, repo_root: None,
            executable: Some(shell.clone()), executable_is_job: false,
        }));
        assert_eq!(foreground.executable_path().as_deref(), Some("/bin/zsh"));

        // The agent takes the terminal as a job of its own.
        foreground.sample.pgid = Some(200);
        foreground.apply(ForegroundResolution {
            pgid: Some(200), pid: Some(200), argv: None, cwd: None, repo_root: None,
            executable: Some(agent), executable_is_job: true,
        });
        assert_eq!(foreground.executable_path().as_deref(), Some("/opt/bin/agy"));
        assert!(foreground.pinned_job);
    }

    /// Once a job is pinned the baseline is fixed. Re-pinning after an upgrade
    /// swapped the binary is exactly what would hide the replacement that
    /// `executable_replaced()` exists to notice.
    #[test]
    fn a_pinned_job_is_never_repinned() {
        let mut foreground = Foreground::default();
        let first = ExecutableIdentity { path: "/opt/bin/agy".to_string(), inode: Some(2) };
        let upgraded = ExecutableIdentity { path: "/opt/bin/agy".to_string(), inode: Some(9) };

        foreground.sample.pgid = Some(200);
        foreground.apply(ForegroundResolution {
            pgid: Some(200), pid: Some(200), argv: None, cwd: None, repo_root: None,
            executable: Some(first), executable_is_job: true,
        });
        foreground.apply(ForegroundResolution {
            pgid: Some(200), pid: Some(200), argv: None, cwd: None, repo_root: None,
            executable: Some(upgraded), executable_is_job: true,
        });
        assert_eq!(foreground.executable.as_ref().and_then(|e| e.inode), Some(2));
    }
}
