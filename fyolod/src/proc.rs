//! Who is actually running in a session's terminal.
//!
//! A session's `command` is what it was *created* with. That answers nothing
//! once a login shell has been sitting there for an hour: the program the user
//! is talking to is whatever holds the tty's foreground process group, and the
//! directory that matters is wherever the child `cd`'d to since. The kernel
//! knows both; nothing in the byte stream does.
//!
//! fyolo's macOS app reads this with `KERN_PROCARGS2` + `proc_pidinfo`
//! (`Sources/fyolo/Terminal/Ghostty/PTYProcess.swift`), which is why it has
//! never worked for a Linux host. The same questions have plain answers under
//! `/proc`, so this module asks them behind one interface and lets the target
//! pick the mechanism.
//!
//! What is *not* per-target is the shape of the answer. `tcgetpgrp` names a
//! process group and every argv lookup wants a pid, and the two only agree
//! while the group leader is alive. Both hosts therefore enumerate the group
//! and pick a live member — `proc_listpgrppids` on macOS, a `/proc` walk on
//! Linux — through one selection rule below.
//!
//! Every function here is a syscall against a pid, so three rules hold at every
//! call site:
//!
//! 1. **Never on the byte path.** Sampling is a poll, bounded and infrequent;
//!    PTY delivery must not wait on it (the anti-100× invariant). The session
//!    actor dispatches this work to a blocking thread for exactly that reason.
//! 2. **Never after the child is reaped.** A recycled pid answers confidently
//!    about a process that is not ours.
//! 3. **Never trust a pid without its group.** Every candidate is checked
//!    against the group it was asked about, because rule 2's recycled pid is
//!    reachable through a stale group id too.
//!
//! Failure is always `None`. A refusal by the kernel, a process that exited
//! mid-read, a short buffer — none of them are worth an error type, because
//! every caller does the same thing with all of them: keep the last known
//! answer and try again next tick.

/// The binary a process is running, pinned tightly enough to notice it being
/// swapped underneath. The inode is the discriminating half: an agent that
/// updates itself in place keeps its path and changes its file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExecutableIdentity {
    pub path: String,
    /// `None` when the file was already gone at sampling time, which reads as
    /// "replaced" for every later comparison.
    pub inode: Option<u64>,
}

impl ExecutableIdentity {
    /// Whether the recorded binary has since been replaced on disk: the file is
    /// gone (a package manager purging the old versioned directory on upgrade)
    /// or its inode changed (an in-place reinstall). This is how an exit that
    /// means "the agent updated itself and quit" is told from a plain quit,
    /// whose binary is untouched.
    pub fn was_replaced(&self) -> bool {
        let Some(inode) = self.inode else {
            return true;
        };
        match std::fs::metadata(&self.path) {
            Ok(metadata) => {
                use std::os::unix::fs::MetadataExt;
                metadata.ino() != inode
            }
            Err(_) => true,
        }
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use super::ExecutableIdentity;

    /// Reads a process's full argument vector from the kernel
    /// (`KERN_PROCARGS2`), whose buffer is laid out
    /// `[argc: i32][exec path]\0…\0[argv0]\0[argv1]\0…[env]`. Own-user
    /// processes only, which is exactly the scope here: the session child and
    /// its descendants.
    pub fn process_arguments(pid: i32) -> Option<Vec<String>> {
        let mut mib: [libc::c_int; 3] = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
        let mut size: libc::size_t = 0;
        let probe = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                mib.len() as libc::c_uint,
                std::ptr::null_mut(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if probe != 0 || size <= std::mem::size_of::<i32>() {
            return None;
        }
        let mut buffer = vec![0u8; size];
        let read = unsafe {
            libc::sysctl(
                mib.as_mut_ptr(),
                mib.len() as libc::c_uint,
                buffer.as_mut_ptr() as *mut libc::c_void,
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        if read != 0 {
            return None;
        }
        buffer.truncate(size);
        super::split_procargs2(&buffer)
    }

    /// The process's current working directory, read from the kernel
    /// (`PROC_PIDVNODEPATHINFO`). This is the fallback every terminal without
    /// shell integration relies on: macOS's stock zsh only emits OSC 7 under
    /// `TERM_PROGRAM=Apple_Terminal`, and fyolod injects no shell
    /// integration — but the kernel always knows.
    pub fn working_directory(pid: i32) -> Option<String> {
        let mut info: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
        let size = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDVNODEPATHINFO,
                0,
                &mut info as *mut _ as *mut libc::c_void,
                std::mem::size_of::<libc::proc_vnodepathinfo>() as libc::c_int,
            )
        };
        if size <= 0 {
            return None;
        }
        // `vip_path` is declared as nested arrays purely to sidestep a const
        // generics limit in libc; the bytes are one flat NUL-terminated path.
        let raw = &info.pvi_cdir.vip_path;
        let flat = unsafe {
            std::slice::from_raw_parts(raw.as_ptr() as *const u8, std::mem::size_of_val(raw))
        };
        super::string_until_nul(flat)
    }

    pub fn executable_path(pid: i32) -> Option<String> {
        let mut buffer = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
        let written = unsafe {
            libc::proc_pidpath(
                pid,
                buffer.as_mut_ptr() as *mut libc::c_void,
                buffer.len() as u32,
            )
        };
        if written <= 0 {
            return None;
        }
        buffer.truncate(written as usize);
        super::string_until_nul(&buffer)
    }

    pub fn executable_identity(pid: i32) -> Option<ExecutableIdentity> {
        let path = executable_path(pid)?;
        Some(super::identity_for(path))
    }

    /// Turn the tty's foreground process *group* into a process that can
    /// actually answer for it.
    ///
    /// The Swift app passed the pgid straight to `KERN_PROCARGS2` and this
    /// module copied it, on the assumption that a zombie leader still reports
    /// its argv. **It does not.** `KERN_PROCARGS2` fails outright for a zombie
    /// and for a reaped pid, so `find . | grep foo` loses its argv the instant
    /// `find` finishes — while `grep` is still the program holding the
    /// terminal. macOS needs the same live-member search Linux does; only the
    /// enumeration mechanism differs.
    ///
    /// `proc_listpgrppids` is that mechanism — libproc's own process-group
    /// enumeration, one call for the whole group rather than a directory walk,
    /// so there is no cheaper leader-only probe worth trying first. The shared
    /// selection prefers the leader from the enumerated set instead.
    pub fn foreground_member(pgid: i32) -> Option<i32> {
        super::select_foreground_member(pgid, &group_members(pgid), |pid| {
            process_arguments(pid).is_some()
        })
    }

    /// Every process the kernel currently counts in `pgid`.
    ///
    /// `proc_listpgrppids` answers with pids alone, so each one is read back
    /// through `PROC_PIDTBSDINFO` for its state and — the part that matters —
    /// its *own* idea of which group it is in. That second check is what keeps
    /// a recycled pid out of the answer: a pid reused since `tcgetpgrp` named
    /// this group reports a different `pbi_pgid`, and the shared rule drops it.
    ///
    /// Two things about `proc_listpgrppids` were established against the kernel
    /// rather than read in a header: it answers with a **count of pids**, not a
    /// byte length, and its `NULL`-buffer sizing call ignores the group filter
    /// entirely — it reports every pid on the machine. So there is no sizing
    /// call to make. Allocate, and grow only when the answer exactly filled the
    /// buffer, the one case a truncation cannot be told from a fit.
    fn group_members(pgid: i32) -> Vec<super::GroupMember> {
        if pgid <= 0 {
            return Vec::new();
        }
        let mut capacity = 64usize;
        loop {
            let mut pids = vec![0i32; capacity];
            let count = unsafe {
                libc::proc_listpgrppids(
                    pgid,
                    pids.as_mut_ptr() as *mut libc::c_void,
                    (capacity * std::mem::size_of::<i32>()) as libc::c_int,
                )
            };
            if count <= 0 {
                return Vec::new();
            }
            let count = (count as usize).min(capacity);
            // A pipeline wide enough to fill 4096 slots is not a shape this has
            // to serve exactly; taking the first 4096 members beats looping.
            if count < capacity || capacity >= 4096 {
                pids.truncate(count);
                return pids.into_iter().filter_map(read_member).collect();
            }
            capacity *= 4;
        }
    }

    /// One candidate's state and process group. A pid that vanished between the
    /// enumeration and this read is simply not a candidate.
    fn read_member(pid: i32) -> Option<super::GroupMember> {
        if pid <= 0 {
            return None;
        }
        let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
        let size = unsafe {
            libc::proc_pidinfo(
                pid,
                libc::PROC_PIDTBSDINFO,
                0,
                &mut info as *mut _ as *mut libc::c_void,
                std::mem::size_of::<libc::proc_bsdinfo>() as libc::c_int,
            )
        };
        if size as usize != std::mem::size_of::<libc::proc_bsdinfo>() {
            return None;
        }
        Some(super::GroupMember {
            pid,
            // A zombie is the one state that disqualifies a member outright. A
            // process still being created (`SIDL`) has no argv yet and is
            // filtered by the argv probe instead, which costs nothing extra
            // because that probe has to run for every candidate anyway.
            liveness: if info.pbi_status == SZOMB {
                super::Liveness::Dead
            } else {
                super::Liveness::Live
            },
            process_group: info.pbi_pgid as i32,
        })
    }

    /// `SZOMB` from `<sys/proc.h>`. Spelled out because the libc crate does not
    /// re-export the `p_stat` constants on this target.
    const SZOMB: u32 = 5;
}

#[cfg(target_os = "linux")]
mod imp {
    use super::ExecutableIdentity;

    /// `/proc/<pid>/cmdline` is argv verbatim, NUL-separated and NUL-
    /// terminated. Kernel threads have an empty one; so does a process caught
    /// mid-exec, and both are correctly "no answer yet".
    pub fn process_arguments(pid: i32) -> Option<Vec<String>> {
        let raw = std::fs::read(format!("/proc/{pid}/cmdline")).ok()?;
        let arguments: Vec<String> = raw
            .split(|byte| *byte == 0)
            .filter(|part| !part.is_empty())
            .map(|part| String::from_utf8_lossy(part).into_owned())
            .collect();
        (!arguments.is_empty()).then_some(arguments)
    }

    /// `/proc/<pid>/cwd` is a symlink the kernel resolves on read, so this is
    /// the live directory rather than the one the process started in.
    pub fn working_directory(pid: i32) -> Option<String> {
        let path = std::fs::read_link(format!("/proc/{pid}/cwd")).ok()?;
        let path = path.to_str()?.to_string();
        (!path.is_empty()).then_some(path)
    }

    /// `/proc/<pid>/exe` gains a literal " (deleted)" suffix once the binary is
    /// unlinked — an upgrade caught in the act. The suffix is stripped so the
    /// path stays usable, and the missing inode carries the fact forward.
    pub fn executable_path(pid: i32) -> Option<String> {
        let path = std::fs::read_link(format!("/proc/{pid}/exe")).ok()?;
        let path = path.to_str()?;
        let path = path.strip_suffix(" (deleted)").unwrap_or(path).to_string();
        (!path.is_empty()).then_some(path)
    }

    pub fn executable_identity(pid: i32) -> Option<ExecutableIdentity> {
        let path = executable_path(pid)?;
        Some(super::identity_for(path))
    }

    /// Turn the tty's foreground process *group* into a process that can
    /// actually answer for it.
    ///
    /// `tcgetpgrp` names a group, and every argv lookup wants a pid. Reading
    /// `/proc/<pgid>/cmdline` gets away with the confusion right up until the
    /// group leader is gone: in `find . | grep foo` the leader is `find`, and
    /// the moment it finishes, its `cmdline` is a zero-length file while `grep`
    /// is still the program holding the terminal. Reported straight through,
    /// the pane would claim nothing is running — the sidebar icon reverts, the
    /// close confirmation half-disagrees with itself — while the user watches
    /// output arrive. tmux scans for a live member instead (`osdep-linux.c`),
    /// and so does this.
    ///
    /// The leader is preferred whenever it is usable, which is every simple
    /// command and therefore nearly every sample: that path is one `stat` read
    /// and no directory walk. The walk is the exception, not the cadence.
    pub fn foreground_member(pgid: i32) -> Option<i32> {
        super::resolve_foreground_member(pgid, read_member(pgid), || group_members(pgid), has_argv)
    }

    /// Every process currently in `pgid`, by walking `/proc`. Only reached when
    /// the leader could not answer, so the walk's cost is paid on the rare
    /// sample rather than on the cadence — and even then it reads one `stat`
    /// per process and no `cmdline` at all. Argv is the expensive half and it
    /// is resolved afterwards, for candidates that already passed this filter,
    /// in preference order until one answers.
    fn group_members(pgid: i32) -> Vec<super::GroupMember> {
        let Ok(entries) = std::fs::read_dir("/proc") else {
            return Vec::new();
        };
        let mut members = Vec::new();
        for entry in entries.flatten() {
            let Some(pid) = entry
                .file_name()
                .to_str()
                .and_then(|name| name.parse::<i32>().ok())
            else {
                continue;
            };
            if let Some(member) = read_member(pid) {
                if member.process_group == pgid {
                    members.push(member);
                }
            }
        }
        members
    }

    /// One candidate's state and process group, from `/proc/<pid>/stat` alone.
    /// The read can lose the race with the process exiting, and a vanished
    /// candidate is simply not a candidate.
    fn read_member(pid: i32) -> Option<super::GroupMember> {
        let raw = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        let (liveness, process_group) = super::parse_process_stat(&raw)?;
        Some(super::GroupMember {
            pid,
            liveness,
            process_group,
        })
    }

    /// A zombie or a process caught mid-exec answers with a zero-length
    /// `cmdline`, which is the whole failure the member search routes around.
    fn has_argv(pid: i32) -> bool {
        std::fs::read(format!("/proc/{pid}/cmdline")).is_ok_and(|raw| raw.iter().any(|b| *b != 0))
    }
}

/// Anything that is neither macOS nor Linux compiles and answers "unknown"
/// rather than failing the build. fyolod has no third host today; when it does,
/// this is the one place that needs a mechanism.
#[cfg(not(any(target_os = "macos", target_os = "linux")))]
mod imp {
    use super::ExecutableIdentity;

    pub fn process_arguments(_pid: i32) -> Option<Vec<String>> {
        None
    }

    pub fn working_directory(_pid: i32) -> Option<String> {
        None
    }

    pub fn executable_identity(_pid: i32) -> Option<ExecutableIdentity> {
        None
    }

    /// No enumeration mechanism means no answer. Returning the pgid instead
    /// would name a pid this host cannot read an argv for anyway, and a pid
    /// with no argv behind it is worse than an absent field — the skew rule
    /// already gives an absent field a defined meaning.
    pub fn foreground_member(_pgid: i32) -> Option<i32> {
        None
    }
}

pub use imp::{executable_identity, foreground_member, process_arguments, working_directory};

/// Whether a candidate can still answer, or is on its way out. The hosts spell
/// process state differently — a letter in `/proc/<pid>/stat`, a `p_stat` in
/// `proc_bsdinfo` — and this is all of it the selection needs, so each host maps
/// its own spelling on the way in rather than the rule learning both.
#[cfg_attr(
    not(any(target_os = "macos", target_os = "linux", test)),
    allow(dead_code)
)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Liveness {
    Live,
    Dead,
}

/// A process considered as a member of the foreground group, reduced to what
/// both hosts can enumerate cheaply: one `/proc/<pid>/stat` read on Linux, one
/// `PROC_PIDTBSDINFO` call on macOS. Argv is deliberately *not* here — it is the
/// expensive read on both, and the selection resolves it lazily.
#[cfg_attr(
    not(any(target_os = "macos", target_os = "linux", test)),
    allow(dead_code)
)]
#[derive(Debug, Clone, PartialEq, Eq)]
struct GroupMember {
    pid: i32,
    liveness: Liveness,
    process_group: i32,
}

/// Whether this member is still a candidate: the kernel counts it in the group
/// we asked about, and has not marked it dead.
///
/// The group check is not redundant with having enumerated the group. It is
/// what stops a recycled pid being reported: between `tcgetpgrp` naming a group
/// and this running, that pid can belong to something else entirely, and a pid
/// whose own process group no longer matches is not the process we were asked
/// about no matter what its number is.
#[cfg_attr(
    not(any(target_os = "macos", target_os = "linux", test)),
    allow(dead_code)
)]
fn member_is_live(member: &GroupMember, pgid: i32) -> bool {
    member.process_group == pgid && member.liveness == Liveness::Live
}

/// The Linux decision, with both `/proc` reads handed in so the shape of the
/// answer can be tested on a host that has no `/proc` to read.
///
/// `leader` is `None` in two different situations that must not be told apart
/// here: a group whose leader has been reaped outright — it is not in `/proc`
/// at all — and a read that lost the race with it exiting. Neither is a reason
/// to stop, and treating a missing leader as the end of the answer would erase
/// the argv of a pipeline that is still running, which is the case the fallback
/// is for.
///
/// `scan` is lazy because the leader answers on nearly every sample, and a
/// `/proc` walk per poll per session is not a cost worth paying by default.
/// macOS has no equivalent shortcut — one sysctl already returns the whole
/// group — so it calls [`select_foreground_member`] directly.
#[cfg(any(target_os = "linux", test))]
fn resolve_foreground_member(
    pgid: i32,
    leader: Option<GroupMember>,
    scan: impl FnOnce() -> Vec<GroupMember>,
    mut has_argv: impl FnMut(i32) -> bool,
) -> Option<i32> {
    if pgid <= 0 {
        return None;
    }
    if leader.is_some_and(|member| member_is_live(&member, pgid)) && has_argv(pgid) {
        return Some(pgid);
    }
    select_foreground_member(pgid, &scan(), has_argv)
}

/// Pick the process whose argv describes the foreground group.
///
/// The leader is tried first, so a session's reported foreground does not drift
/// to some later stage of a pipeline while the stage that names it is still
/// running. The rest are tried in ascending pid order — arbitrary, but
/// *stable*, and a choice that flapped between two survivors would push a
/// roster event every poll for no new information.
///
/// `has_argv` is a closure and the search stops at the first process that
/// answers, because reading argv is a sysctl on macOS and a file read on Linux
/// and a wide pipeline should not pay for one per member.
#[cfg_attr(
    not(any(target_os = "macos", target_os = "linux", test)),
    allow(dead_code)
)]
fn select_foreground_member(
    pgid: i32,
    members: &[GroupMember],
    mut has_argv: impl FnMut(i32) -> bool,
) -> Option<i32> {
    if pgid <= 0 {
        return None;
    }
    let mut candidates: Vec<i32> = members
        .iter()
        .filter(|member| member_is_live(member, pgid))
        .map(|member| member.pid)
        .collect();
    candidates.sort_unstable();
    candidates.dedup();
    candidates
        .contains(&pgid)
        .then_some(pgid)
        .into_iter()
        .chain(candidates.iter().copied().filter(|pid| *pid != pgid))
        .find(|pid| has_argv(*pid))
}

/// The two fields of `/proc/<pid>/stat` that matter here: state and process
/// group. Everything before them has to be skipped past rather than split on,
/// because field 2 is the executable name in parentheses and a program is free
/// to be called `sleep 1) 0 (evil`. The kernel writes the name verbatim, so the
/// only reliable anchor is the *last* `)` in the line.
///
/// `Z`, `X` and `x` are the states a process cannot come back from; everything
/// else — sleeping, stopped, traced — is a process that still answers.
#[cfg(any(target_os = "linux", test))]
fn parse_process_stat(raw: &str) -> Option<(Liveness, i32)> {
    let tail = &raw[raw.rfind(')')? + 1..];
    let mut fields = tail.split_whitespace();
    let state = fields.next()?.chars().next()?;
    // state, ppid, then pgrp.
    let process_group = fields.nth(1)?.parse().ok()?;
    let liveness = match state {
        'Z' | 'X' | 'x' => Liveness::Dead,
        _ => Liveness::Live,
    };
    Some((liveness, process_group))
}

#[cfg(any(target_os = "macos", test))]
fn split_procargs2(buffer: &[u8]) -> Option<Vec<String>> {
    let header = std::mem::size_of::<i32>();
    if buffer.len() <= header {
        return None;
    }
    let mut argc_bytes = [0u8; 4];
    argc_bytes.copy_from_slice(&buffer[..header]);
    let argc = i32::from_ne_bytes(argc_bytes);
    if argc <= 0 {
        return None;
    }
    let mut index = header;
    // Skip the executable path that precedes argv[0], then the NUL padding
    // between it and argv[0].
    while index < buffer.len() && buffer[index] != 0 {
        index += 1;
    }
    while index < buffer.len() && buffer[index] == 0 {
        index += 1;
    }
    let mut arguments = Vec::new();
    let mut current = Vec::new();
    while index < buffer.len() && arguments.len() < argc as usize {
        let byte = buffer[index];
        index += 1;
        if byte == 0 {
            arguments.push(String::from_utf8_lossy(&current).into_owned());
            current.clear();
        } else {
            current.push(byte);
        }
    }
    (!arguments.is_empty()).then_some(arguments)
}

#[cfg(target_os = "macos")]
fn string_until_nul(bytes: &[u8]) -> Option<String> {
    let end = bytes
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(bytes.len());
    let text = String::from_utf8_lossy(&bytes[..end]).into_owned();
    (!text.is_empty()).then_some(text)
}

#[cfg(any(target_os = "macos", target_os = "linux", test))]
fn identity_for(path: String) -> ExecutableIdentity {
    use std::os::unix::fs::MetadataExt;
    let inode = std::fs::metadata(&path).ok().map(|metadata| metadata.ino());
    ExecutableIdentity { path, inode }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::process::{Command, Stdio};
    use std::rc::Rc;
    use std::time::{Duration, Instant};

    /// Spawn a real child and wait until the kernel agrees it has exec'd — the
    /// window between `fork` and `exec` is real, and a test that reads through
    /// it asserts against the parent's argv instead of the child's.
    struct Sleeper(std::process::Child);

    fn sleep_binary() -> &'static str {
        ["/bin/sleep", "/usr/bin/sleep"]
            .into_iter()
            .find(|path| std::path::Path::new(path).exists())
            .expect("no sleep binary on this host")
    }

    impl Sleeper {
        fn spawn(cwd: &str) -> Sleeper {
            // Absolute on purpose: the test asserts on the executable path the
            // kernel reports, and a PATH lookup would make that unpredictable.
            let child = Command::new(sleep_binary())
                .arg("30")
                .current_dir(cwd)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .expect("spawning /bin/sleep");
            let sleeper = Sleeper(child);
            let deadline = Instant::now() + Duration::from_secs(5);
            while Instant::now() < deadline {
                if let Some(argv) = process_arguments(sleeper.pid()) {
                    if argv.first().is_some_and(|arg| arg.ends_with("sleep")) {
                        return sleeper;
                    }
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            panic!("child never showed up in the kernel's process table");
        }

        fn pid(&self) -> i32 {
            self.0.id() as i32
        }
    }

    impl Drop for Sleeper {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    #[test]
    fn reads_a_live_child_argv() {
        let child = Sleeper::spawn("/");
        let argv = process_arguments(child.pid()).expect("argv for a live child");
        assert_eq!(argv.len(), 2, "argv was {argv:?}");
        assert!(argv[0].ends_with("sleep"), "argv[0] was {:?}", argv[0]);
        assert_eq!(argv[1], "30");
    }

    #[test]
    fn reads_a_live_child_working_directory() {
        let temp = std::env::temp_dir().join(format!("fyolod-proc-{}", std::process::id()));
        std::fs::create_dir_all(&temp).expect("creating the test directory");
        // The kernel answers with the resolved path; macOS's /tmp is a symlink,
        // so the expectation has to be resolved too.
        let expected = std::fs::canonicalize(&temp).expect("canonicalizing the test directory");
        let child = Sleeper::spawn(temp.to_str().expect("utf-8 temp path"));

        let cwd = working_directory(child.pid()).expect("cwd for a live child");
        assert_eq!(std::path::Path::new(&cwd), expected);

        drop(child);
        let _ = std::fs::remove_dir_all(&temp);
    }

    #[test]
    fn pins_the_child_executable_and_sees_it_intact() {
        let child = Sleeper::spawn("/");
        let identity = executable_identity(child.pid()).expect("identity for a live child");
        // Resolved, not spelled: on a busybox host /bin/sleep is a symlink and
        // the kernel correctly names /bin/busybox as what is running. Asserting
        // the literal path would encode one distro's layout as the contract.
        let expected = std::fs::canonicalize(sleep_binary()).expect("canonical sleep binary");
        assert_eq!(std::path::Path::new(&identity.path), expected);
        assert!(identity.inode.is_some(), "no inode for an on-disk binary");
        assert!(
            !identity.was_replaced(),
            "an untouched binary must not read as replaced"
        );
    }

    /// The whole point of pinning the inode: a path that still exists but is a
    /// different file is a replacement, and a path that is gone is one too.
    #[test]
    fn notices_a_replaced_executable() {
        let dir = std::env::temp_dir().join(format!("fyolod-exe-{}", std::process::id()));
        std::fs::create_dir_all(&dir).expect("creating the test directory");
        let path = dir.join("agent");
        std::fs::write(&path, b"#!/bin/sh\n").expect("writing the fake binary");
        let identity = identity_for(path.to_string_lossy().into_owned());
        assert!(!identity.was_replaced());

        // The upgrade shape, and deterministic about it: the replacement exists
        // alongside the original before the rename, so the two inodes cannot
        // collide. Deleting and rewriting in place can hand back the same inode
        // number on some filesystems, which would prove nothing.
        let upgrade = dir.join("agent.new");
        std::fs::write(&upgrade, b"#!/bin/sh\n# v2\n").expect("writing the replacement");
        std::fs::rename(&upgrade, &path).expect("swapping the replacement in");
        assert!(identity.was_replaced(), "a new inode is a replacement");

        std::fs::remove_file(&path).expect("removing the fake binary");
        assert!(identity.was_replaced(), "a missing file is a replacement");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn refuses_a_pid_that_is_not_running() {
        // pid 0 is never a queryable user process on either host.
        assert!(process_arguments(0).is_none());
        assert!(working_directory(0).is_none());
        assert!(executable_identity(0).is_none());
    }

    /// The macOS buffer layout, asserted without the kernel: argc, the exec
    /// path, NUL padding, then argv.
    #[test]
    fn parses_the_procargs2_layout() {
        let mut buffer = Vec::new();
        buffer.extend_from_slice(&2i32.to_ne_bytes());
        buffer.extend_from_slice(b"/usr/local/bin/claude\0\0\0");
        buffer.extend_from_slice(b"claude\0--resume\0");
        buffer.extend_from_slice(b"PATH=/usr/bin\0");
        let argv = split_procargs2(&buffer).expect("argv from a well-formed buffer");
        assert_eq!(argv, vec!["claude".to_string(), "--resume".to_string()]);
    }

    #[test]
    fn rejects_a_truncated_procargs2_buffer() {
        assert!(split_procargs2(&[]).is_none());
        assert!(split_procargs2(&0i32.to_ne_bytes()).is_none());
        assert!(split_procargs2(&(-1i32).to_ne_bytes()).is_none());
    }

    fn live(pid: i32) -> GroupMember {
        GroupMember {
            pid,
            liveness: Liveness::Live,
            process_group: 100,
        }
    }

    fn dead(pid: i32) -> GroupMember {
        GroupMember {
            liveness: Liveness::Dead,
            ..live(pid)
        }
    }

    /// Stand-in for the per-host argv read, which also records the order the
    /// selection probed in — the cost this closure exists to bound.
    fn argv_of(answering: &[i32]) -> (impl FnMut(i32) -> bool + '_, Rc<RefCell<Vec<i32>>>) {
        let probed = Rc::new(RefCell::new(Vec::new()));
        let seen = Rc::clone(&probed);
        let has_argv = move |pid: i32| {
            seen.borrow_mut().push(pid);
            answering.contains(&pid)
        };
        (has_argv, probed)
    }

    /// The ordinary case, and the one the Linux fast path short-circuits on: a
    /// single command, alive, named after itself. Nothing else is even probed.
    #[test]
    fn prefers_the_group_leader_while_it_is_usable() {
        let (has_argv, probed) = argv_of(&[100, 101]);
        let members = [live(100), live(101)];
        assert_eq!(select_foreground_member(100, &members, has_argv), Some(100));
        assert_eq!(*probed.borrow(), vec![100]);
    }

    /// `find . | grep foo`: `find` finishes first and sits reaped or zombied
    /// while `grep` is still the program the user is talking to. Reporting the
    /// leader's empty argv here is how the pane would claim nothing is running
    /// mid-pipeline.
    #[test]
    fn falls_back_to_a_live_member_when_the_leader_is_gone() {
        let (has_argv, _) = argv_of(&[103]);
        let zombie = [dead(100), live(103)];
        assert_eq!(select_foreground_member(100, &zombie, has_argv), Some(103));

        // Reaped outright: the leader is not enumerable at all, so it is not
        // even a candidate.
        let (has_argv, probed) = argv_of(&[103]);
        let reaped = [live(103)];
        assert_eq!(select_foreground_member(100, &reaped, has_argv), Some(103));
        assert_eq!(
            *probed.borrow(),
            vec![103],
            "a dead leader must not cost an argv read"
        );
    }

    /// A leader that is alive but caught between fork and exec has no argv yet.
    /// Preferring it would report nothing while a sibling can answer.
    #[test]
    fn skips_a_live_leader_with_no_argv() {
        let (has_argv, probed) = argv_of(&[104]);
        let members = [live(100), live(104)];
        assert_eq!(select_foreground_member(100, &members, has_argv), Some(104));
        assert_eq!(
            *probed.borrow(),
            vec![100, 104],
            "the leader is tried first, then the rest in order"
        );
    }

    /// Stable, not merely correct: two survivors must not take turns being the
    /// answer, or every poll would push a roster event that says nothing new.
    #[test]
    fn picks_the_same_survivor_every_time() {
        let (has_argv, _) = argv_of(&[105, 107]);
        let ascending = [live(107), live(105)];
        assert_eq!(
            select_foreground_member(100, &ascending, has_argv),
            Some(105)
        );
        let (has_argv, _) = argv_of(&[105, 107]);
        let descending = [live(105), live(107)];
        assert_eq!(
            select_foreground_member(100, &descending, has_argv),
            Some(105)
        );
    }

    #[test]
    fn refuses_a_group_with_nobody_left_in_it() {
        let (has_argv, _) = argv_of(&[]);
        assert_eq!(select_foreground_member(100, &[], has_argv), None);
        let (has_argv, probed) = argv_of(&[100, 103]);
        let all_dead = [dead(100), dead(103)];
        assert_eq!(select_foreground_member(100, &all_dead, has_argv), None);
        assert!(
            probed.borrow().is_empty(),
            "a dead group must not cost an argv read"
        );
    }

    /// The membership check is what keeps a recycled pid out of the answer: a
    /// pid that has since been moved into another group is not the process we
    /// were asked about, whatever its number is.
    #[test]
    fn ignores_processes_from_another_group() {
        let (has_argv, probed) = argv_of(&[100]);
        let mut stranger = live(100);
        stranger.process_group = 200;
        assert_eq!(select_foreground_member(100, &[stranger], has_argv), None);
        assert!(probed.borrow().is_empty());
    }

    /// `/proc/<pid>/stat` puts the executable name in parentheses as field 2,
    /// unescaped. A parser that splits on whitespace, or that finds the *first*
    /// `)`, reads the wrong process group for anything whose name contains a
    /// space or a bracket — which a user is free to arrange.
    #[test]
    fn parses_the_proc_stat_layout() {
        let plain = "4242 (grep) R 4200 4100 4100 34816 4242 0 0 0 0 0 0 0 20 0";
        assert_eq!(parse_process_stat(plain), Some((Liveness::Live, 4100)));

        let awkward = "4242 (a (b) c) Z 4200 4100 4100 34816 0 0 0 0 0 0 0 0 20 0";
        assert_eq!(parse_process_stat(awkward), Some((Liveness::Dead, 4100)));
    }

    #[test]
    fn rejects_an_unparseable_proc_stat() {
        assert_eq!(parse_process_stat(""), None);
        assert_eq!(parse_process_stat("4242 (grep"), None);
        assert_eq!(parse_process_stat("4242 (grep) R"), None);
        assert_eq!(parse_process_stat("4242 (grep) R 4200 nonsense"), None);
    }

    /// A group id is never a pid, and 0 is not a group this daemon can be
    /// looking at.
    #[test]
    fn refuses_a_nonsense_process_group() {
        assert_eq!(foreground_member(0), None);
        assert_eq!(foreground_member(-1), None);
        let (has_argv, _) = argv_of(&[]);
        assert_eq!(
            resolve_foreground_member(
                0,
                None,
                || panic!("must not walk /proc for pgid 0"),
                has_argv
            ),
            None
        );
    }

    /// The Linux entry point's regression. A reaped leader is absent from
    /// `/proc` entirely, so the leader read hands back `None` — and an entry
    /// point that propagated that would answer "nothing is running" while the
    /// rest of the pipeline still holds the terminal.
    #[test]
    fn a_reaped_leader_falls_through_to_the_scan() {
        let (has_argv, _) = argv_of(&[103]);
        let survivors = vec![live(103)];
        assert_eq!(
            resolve_foreground_member(100, None, || survivors.clone(), has_argv),
            Some(103)
        );
    }

    /// Same fall-through when the leader is present but past answering, and it
    /// still ends at `None` when the scan finds nobody either — an empty group
    /// is an honest "no answer", not a fabricated pid.
    #[test]
    fn an_unusable_leader_falls_through_to_the_scan() {
        let zombie = dead(100);
        let (has_argv, _) = argv_of(&[104]);
        assert_eq!(
            resolve_foreground_member(
                100,
                Some(zombie.clone()),
                || vec![zombie.clone(), live(104)],
                has_argv
            ),
            Some(104)
        );
        let (has_argv, _) = argv_of(&[]);
        assert_eq!(
            resolve_foreground_member(100, Some(zombie), Vec::new, has_argv),
            None
        );
    }

    /// The cadence argument, asserted rather than asserted-in-a-comment: a
    /// usable leader must answer without walking `/proc`, because this feeds
    /// the poll for every session on the host.
    #[test]
    fn a_usable_leader_never_walks_proc() {
        let (has_argv, _) = argv_of(&[100]);
        let answer = resolve_foreground_member(
            100,
            Some(live(100)),
            || panic!("the leader answered; nothing should have scanned /proc"),
            has_argv,
        );
        assert_eq!(answer, Some(100));
    }

    /// Two real processes in one real group, against the real kernel — the test
    /// that would have caught the macOS identity mapping.
    ///
    /// `leader` is spawned into its own process group and `member` joins it, so
    /// this reproduces `leader | member` without a shell arbitrating. Killing
    /// and reaping the leader leaves a group whose id names a pid that no
    /// longer exists, which is precisely the state `find . | grep foo` reaches
    /// the moment `find` finishes.
    #[test]
    fn a_reaped_group_leader_does_not_erase_the_group() {
        use std::os::unix::process::CommandExt;

        let mut leader = Command::new(sleep_binary())
            .arg("30")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0)
            .spawn()
            .expect("spawning the group leader");
        let pgid = leader.id() as i32;

        let follower = Command::new(sleep_binary())
            .arg("30")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(pgid)
            .spawn()
            .expect("spawning a second member of that group");
        let follower = Sleeper(follower);
        // Both must have exec'd before the group means anything.
        wait_for(|| {
            process_arguments(pgid).is_some() && process_arguments(follower.pid()).is_some()
        });

        assert_eq!(
            foreground_member(pgid),
            Some(pgid),
            "a live leader answers for its own group"
        );

        let _ = leader.kill();
        let _ = leader.wait();
        wait_for(|| process_arguments(pgid).is_none());

        // The probe that settles it: the leader's argv is unreadable once it is
        // reaped, on both hosts. Reporting the pgid straight through here is
        // what produced an empty foreground for a live pipeline.
        assert!(
            process_arguments(pgid).is_none(),
            "a reaped leader must not still answer for argv"
        );
        assert_eq!(
            foreground_member(pgid),
            Some(follower.pid()),
            "the surviving member answers for the group"
        );
        let argv = process_arguments(follower.pid()).expect("argv for the survivor");
        assert!(argv[0].ends_with("sleep"), "argv was {argv:?}");
    }

    /// A group with nothing left in it has no answer, and the enumeration must
    /// say so rather than handing back the group id as if it were a pid.
    #[test]
    fn an_empty_group_has_no_foreground_member() {
        let child = Sleeper::spawn("/");
        let pid = child.pid();
        drop(child);
        wait_for(|| process_arguments(pid).is_none());
        assert_eq!(foreground_member(pid), None);
    }

    fn wait_for(mut ready: impl FnMut() -> bool) {
        let deadline = Instant::now() + Duration::from_secs(5);
        while Instant::now() < deadline {
            if ready() {
                return;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        panic!("the kernel never reached the expected process state");
    }
}
