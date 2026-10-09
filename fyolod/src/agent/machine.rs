//! What the daemon knows about its own box.
//!
//! Three bugs in the SSH arm existed only because the writer was on the wrong
//! machine, and none of them is ported here:
//!
//! - `$HOME` needed three escapings — raw, shell, and JavaScript — because the
//!   binary path was a shell *expression* the remote had to expand. A daemon
//!   knows its own executable's absolute path.
//! - `~/.config` had to be spelled `${XDG_CONFIG_HOME:-$HOME/.config}` so a
//!   remote shell would resolve it. Here it is one `std::env::var`.
//! - The CLI probe had to ask a login shell twice, because `ssh host cmd` gets a
//!   minimal `PATH`. A daemon *also* does not always inherit the user's `PATH`
//!   (it is auto-started from an SSH command or a launchd job, exactly as the Mac
//!   app is started from Finder), so the login-shell probe stays — but as the one
//!   mechanism it always was, asked once and cached, not as an SSH workaround.

use super::manifest::ConfigHome;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// The account's home directory. `$HOME` first, because that is what every
/// process on the box agrees the home is, then the password database for a
/// daemon started without an environment.
pub fn home_directory() -> Option<PathBuf> {
    if let Some(home) = std::env::var_os("HOME") {
        let home = PathBuf::from(home);
        if !home.as_os_str().is_empty() {
            return Some(home);
        }
    }
    passwd_home()
}

fn passwd_home() -> Option<PathBuf> {
    // SAFETY: `getpwuid` returns a pointer into a static buffer owned by libc;
    // the strings are read and copied before anything else can call it.
    unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if entry.is_null() {
            return None;
        }
        let dir = (*entry).pw_dir;
        if dir.is_null() {
            return None;
        }
        let dir = std::ffi::CStr::from_ptr(dir).to_string_lossy().into_owned();
        if dir.is_empty() {
            None
        } else {
            Some(PathBuf::from(dir))
        }
    }
}

/// The user's login shell, from the password database rather than the ambient
/// `SHELL` — a daemon started by launchd or by an SSH command may have neither,
/// or may have inherited someone else's.
pub fn login_shell() -> String {
    // SAFETY: same contract as `passwd_home`.
    let from_passwd = unsafe {
        let entry = libc::getpwuid(libc::getuid());
        if entry.is_null() || (*entry).pw_shell.is_null() {
            None
        } else {
            let shell = std::ffi::CStr::from_ptr((*entry).pw_shell)
                .to_string_lossy()
                .into_owned();
            if shell.is_empty() {
                None
            } else {
                Some(shell)
            }
        }
    };
    from_passwd
        .or_else(|| std::env::var("SHELL").ok())
        .unwrap_or_else(|| "/bin/sh".to_string())
}

/// The XDG bases, resolved against this box.
///
/// `~/.config` and `~/.local/share` are the spec's default *values*, not
/// directory names, and every agent fyolo files under them — OpenCode, Amp,
/// Crush — reads the variable. Writing to the literal default on a machine whose
/// owner moved their config puts a plugin where the agent never looks.
const XDG_BASES: [(&str, &str); 2] = [
    (".config", "XDG_CONFIG_HOME"),
    (".local/share", "XDG_DATA_HOME"),
];

/// Expand a manifest path (`~/.claude/settings.json`) against this box.
///
/// A manifest path always means the account the daemon runs as, so `~user` is
/// deliberately not honoured and a `~` anywhere but the front is an ordinary
/// character.
pub fn expand(path: &str) -> PathBuf {
    expand_with(path, home_directory(), &login_environment)
}

/// Resolve a manifest path against this box, honouring the agent's own
/// config-home variable when it declares one.
///
/// **Order: the agent's variable, then the XDG base, then `~`.** The two
/// overrides compose rather than race. An agent that documents its own variable
/// is saying "my whole tree is here", which is a more specific statement than
/// "my tree is under the config base", so it wins; the XDG base applies only
/// when the agent's variable is unset or empty. Nothing in the catalog needs
/// both today — no agent with a config-home variable keeps its tree under
/// `~/.config` — but the rule has to be decided somewhere rather than left to
/// whichever check happens to run first.
///
/// `Err` means *do not install*, with the sentence to show for it.
pub fn resolve(path: &str, home: Option<&ConfigHome>) -> std::result::Result<PathBuf, String> {
    resolve_with(path, home, &login_environment, home_directory())
}

fn resolve_with(
    path: &str,
    home: Option<&ConfigHome>,
    lookup: &dyn Fn(&str) -> Option<String>,
    home_directory: Option<PathBuf>,
) -> std::result::Result<PathBuf, String> {
    let Some(config_home) = home else {
        return Ok(expand_with(path, home_directory, lookup));
    };
    // An unset or empty variable is the default, not an error: it is what every
    // account that never moved its config has.
    let Some(moved) = lookup(&config_home.env).filter(|value| !value.trim().is_empty()) else {
        return Ok(expand_with(path, home_directory, lookup));
    };
    // A comma is ambiguous and this refuses rather than guesses — see
    // `AMBIGUOUS_CONFIG_HOME`.
    if moved.contains(',') {
        return Err(format!(
            "{} names more than one directory ({moved}); \
             set it to a single directory to install here",
            config_home.env
        ));
    }
    if !crate::agent::manifest::is_under(path, &config_home.path) {
        // The manifest validated this at load, so reaching it means a manifest
        // changed underneath a running daemon. Fall back rather than write
        // somewhere the prefix does not describe.
        return Ok(expand_with(path, home_directory, lookup));
    }
    let tail = path[config_home.path.len()..].trim_start_matches('/');
    let moved = expand_with(moved.trim(), home_directory, lookup);
    Ok(if tail.is_empty() {
        moved
    } else {
        moved.join(tail)
    })
}

fn expand_with(
    path: &str,
    home: Option<PathBuf>,
    lookup: &dyn Fn(&str) -> Option<String>,
) -> PathBuf {
    let home = match home {
        Some(home) => home,
        None => return PathBuf::from(path),
    };
    if path == "~" {
        return home;
    }
    let rest = match path.strip_prefix("~/") {
        Some(rest) => rest,
        None => return PathBuf::from(path),
    };
    for (prefix, variable) in XDG_BASES {
        let tail = if rest == prefix {
            Some("")
        } else {
            rest.strip_prefix(prefix)
                .and_then(|tail| tail.strip_prefix('/'))
        };
        let Some(tail) = tail else { continue };
        let Some(base) = lookup(variable) else { break };
        let base = PathBuf::from(base);
        return if tail.is_empty() { base } else { base.join(tail) };
    }
    home.join(rest)
}

/// A variable the daemon's own environment may be missing because of how it was
/// started. The daemon's own value wins where it has one — a user who exported
/// `XDG_CONFIG_HOME` for the process meant it — and the login shell answers for
/// the rest. Both XDG bases ride one probe because a second login shell would
/// pay for another rc that can take seconds.
pub fn login_environment(name: &str) -> Option<String> {
    if let Ok(value) = std::env::var(name) {
        if !value.is_empty() {
            return Some(value);
        }
    }
    probe().get(name).filter(|value| !value.is_empty()).cloned()
}

/// Where a command could be found from this box, login shell first.
///
/// `PATH` is the one variable whose *inherited* value must not win. A daemon
/// auto-started from `ssh host fyolod stdio` inherits ssh's minimal `PATH`, and
/// a Mac one started by launchd inherits almost nothing — while the agents worth
/// finding are exactly the ones outside a default `PATH`. On a stock Ubuntu box
/// `claude` installs to `~/.local/bin`, which only `~/.profile` adds; trusting
/// the inherited value answers "not installed" for an agent sitting right there,
/// and then no skill is installed anywhere. That failure is silent, and it was
/// the blocker in front of everything else in the device arm.
///
/// The inherited value is kept as a second source rather than dropped: it is
/// still a real place this daemon can exec from, and a union can only ever find
/// more.
pub fn login_path() -> Vec<String> {
    let mut directories = Vec::new();
    let from_login = probe().get("PATH").cloned().unwrap_or_default();
    let inherited = std::env::var("PATH").unwrap_or_default();
    for source in [from_login, inherited] {
        for directory in source.split(':').filter(|d| !d.is_empty()) {
            if !directories.iter().any(|seen| seen == directory) {
                directories.push(directory.to_string());
            }
        }
    }
    directories
}

/// Whether `command`'s binary can be run on this box.
///
/// Answers `true` when it could not look, so a probe that fails never reads as
/// "not installed" — the don't-cry-wolf rule the app follows locally, and the
/// one that stops a broken environment from quietly uninstalling everything.
pub fn is_command_installed(command: &str) -> bool {
    let Some(binary) = first_word(command).filter(|b| !b.is_empty()) else {
        return true;
    };
    let binary = binary.as_str();
    // A path answers for itself. Whether the login shell could be asked has no
    // bearing on whether a named file exists, and letting the probe's failure
    // speak here reported an absent agent as present — and then installed its
    // integration, while the app correctly showed it missing.
    if binary.starts_with('/') || binary.starts_with('~') {
        return is_executable(&expand(binary));
    }
    // Only a `PATH` search needs the probe, and this is the don't-cry-wolf rule
    // stated where it holds. It used to rest on `login_path()` coming back
    // empty, which it never does when the daemon inherited *some* `PATH` — so an
    // rc that timed out left the inherited directories answering for the whole
    // box, and every agent outside them read as missing rather than as unknown.
    // Cached for the process, too, so one slow rc silently stripped hooks for as
    // long as the daemon lived.
    if probe().is_empty() {
        return true;
    }
    let directories = login_path();
    if directories.is_empty() {
        return true;
    }
    directories
        .iter()
        .any(|directory| is_executable(&Path::new(directory).join(binary)))
}

/// The binary a command line names: its first shell word, with quoting honoured.
///
/// A bare `split(' ')` is wrong for the one case that most needs a path typed by
/// hand — `"/Users/me/Agent Tools/codex"` — where it yields `"/Users/me/Agent`
/// and answers "not installed" for a CLI sitting right there. The app resolves
/// the same string the same way (`AgentAvailability.firstWord`); the two must
/// agree, or one side reports an agent available and the other refuses to write
/// its config.
pub fn first_word(command: &str) -> Option<String> {
    let mut word = String::new();
    let mut quote: Option<char> = None;
    let mut chars = command.trim_start().chars();
    while let Some(c) = chars.next() {
        match c {
            // Not inside single quotes, where the shell takes a backslash
            // literally — `'/opt/agent\tools/cli'` names a path that really has
            // one, and eating it looks for a file that does not exist.
            '\\' if quote != Some('\'') => match chars.next() {
                // A line continuation: the shell removes both.
                Some('\n') => {}
                // Inside double quotes a backslash is special only before these.
                // `"/opt/a\tools/cli"` names a path that keeps its backslash.
                Some(next) if quote == Some('"') && !matches!(next, '$' | '`' | '"' | '\\' | '\n') => {
                    word.push('\\');
                    word.push(next);
                }
                Some(next) => word.push(next),
                None => {}
            },
            '\'' | '"' => match quote {
                Some(open) if open == c => quote = None,
                Some(_) => word.push(c),
                None => quote = Some(c),
            },
            c if c.is_whitespace() && quote.is_none() => break,
            c => word.push(c),
        }
    }
    (!word.is_empty()).then_some(word)
}

fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    match std::fs::metadata(path) {
        Ok(metadata) => metadata.is_file() && metadata.permissions().mode() & 0o111 != 0,
        Err(_) => false,
    }
}

/// One login-shell spawn answers for everything the daemon's own environment
/// cannot see. Bounded and cached for the process: an rc that blocks must not
/// wedge an install, and a shell that never returns must not be asked twice.
fn probe() -> HashMap<String, String> {
    let cache = probe_cache();
    if let Some(answer) = cache.lock().ok().and_then(|held| held.clone()) {
        return answer;
    }
    let answer = probe_login_shell();
    if let Ok(mut held) = cache.lock() {
        *held = Some(answer.clone());
    }
    answer
}

fn probe_cache() -> &'static std::sync::Mutex<Option<HashMap<String, String>>> {
    static PROBED: OnceLock<std::sync::Mutex<Option<HashMap<String, String>>>> = OnceLock::new();
    PROBED.get_or_init(|| std::sync::Mutex::new(None))
}

/// Runs `operation` against a login-shell answer taken fresh for it, and held
/// still for its whole duration.
///
/// The cache exists because an rc can take seconds and a hot path must not pay
/// for it twice. It needs refreshing, though — a user who installs an agent and
/// adds its directory to `.zshrc` must not read as not having it until the
/// daemon restarts, and a same-version setup does not restart the daemon.
///
/// Refreshing and *using* have to be one operation. Clearing the cache at the
/// top and then reading it as we went let a second caller clear it mid-flight:
/// an install decided an agent was present against one answer and resolved
/// where its config lives against another, so a plugin landed in the default
/// directory while the one `XDG_CONFIG_HOME` names stayed empty — and the reply
/// still said installed, so nothing ever asked again. Freezing presence was not
/// enough; the environment has to be frozen too, and the honest way to say that
/// is one lock around the whole thing.
pub fn with_fresh_login_shell<T>(operation: impl FnOnce() -> T) -> T {
    static IN_FLIGHT: OnceLock<std::sync::Mutex<()>> = OnceLock::new();
    let guard = IN_FLIGHT.get_or_init(|| std::sync::Mutex::new(()));
    // Poisoning only means some earlier caller panicked; the cache is still a
    // cache, and refusing to install over it would be worse than proceeding.
    let _held = guard.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Ok(mut held) = probe_cache().lock() {
        *held = None;
    }
    operation()
}

fn probe_login_shell() -> HashMap<String, String> {
    let names = ["PATH", "XDG_CONFIG_HOME", "XDG_DATA_HOME"];
    // `${VAR-}` rather than `$VAR`, so an unset variable is an empty line and
    // the lines stay positional under `set -u`.
    //
    // Led by a marker, because the lines are only positional *relative to it*.
    // An interactive shell runs the user's `.zshrc`, and rc files print things —
    // a banner, a version notice, a fortune. Counting from line zero would read
    // that as `PATH`, and a plausible-looking wrong `PATH` is the worst possible
    // answer: every agent reads as missing and every hook is skipped, silently.
    let script = format!(
        "printf '%s\\n' {PROBE_MARKER} {}",
        names
            .iter()
            .map(|name| format!("\"${{{name}-}}\""))
            .collect::<Vec<_>>()
            .join(" ")
    );
    let mut child = match std::process::Command::new(login_shell())
        // `-i` as well as `-l`, because a session gets both. The shell a session
        // runs sits on a PTY with `argv[0] = "-zsh"`, so it is a login shell
        // *and* an interactive one and sources `.zshrc` — where an agent's
        // directory is very often the only place it is added. Asking a
        // non-interactive shell answered "not installed" for an agent every
        // session on this box can run, and the app, which asks `-ilc`, reported
        // it available: the two sides judging differently is the whole bug class
        // this file keeps hitting.
        .args(["-ilc", &script])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            crate::agent::manifest::log(&format!("could not probe the login shell: {error}"));
            return HashMap::new();
        }
    };

    // Bound the whole thing, *reading included*, without a thread to strand.
    //
    // Waiting for the shell to exit is not enough: an rc that starts a
    // background job hands the stdout pipe to a process that outlives the shell,
    // so a blocking read waits on a writer nobody will close. Reading it on a
    // detached thread bounded the *wait* but not the thread — and once the cache
    // became refreshable, every install leaked another one. The pipe is read
    // non-blocking instead, so the deadline is the only thing that ends this and
    // nothing is left behind.
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return HashMap::new();
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let output = read_until(stdout, deadline);
    let _ = child.kill();
    let _ = child.wait();
    let Some(output) = output else {
        crate::agent::manifest::log("the login shell did not answer in time");
        return HashMap::new();
    };
    read_probe(&output, &names)
}

/// Reads a pipe to EOF, or until `deadline`, without blocking on it.
///
/// `None` when the deadline passed or the stream overflowed `PROBE_READ_LIMIT`:
/// a banner long enough to push the cap into the middle of `PATH` would hand
/// back half a directory list as if it were the whole one, and that gets cached.
fn read_until(stdout: std::process::ChildStdout, deadline: std::time::Instant) -> Option<String> {
    use std::io::Read;
    use std::os::unix::io::AsRawFd;

    let fd = stdout.as_raw_fd();
    // Safety: `stdout` owns this descriptor for the whole call.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0 {
            return None;
        }
    }
    let mut stdout = stdout;
    let mut collected: Vec<u8> = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match stdout.read(&mut chunk) {
            Ok(0) => return String::from_utf8(collected).ok(),
            Ok(read) => {
                collected.extend_from_slice(&chunk[..read]);
                if collected.len() as u64 > PROBE_READ_LIMIT {
                    return None;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                if std::time::Instant::now() >= deadline {
                    return None;
                }
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => return None,
        }
    }
}

/// Leads the probe's own output, so whatever an rc printed stays behind it.
const PROBE_MARKER: &str = "__fyolo_probe__";

/// How much of a chatty rc's output the probe will read before giving up on it.
const PROBE_READ_LIMIT: u64 = 64 * 1024;

/// The values the probe printed, taken from after the **last** marker.
///
/// No marker means the shell never reached the `printf` — an rc that exec'd
/// away, or output we cannot trust. Answering with nothing is right: an empty
/// map makes `is_command_installed` say "true", which installs for everything
/// rather than silently skipping every agent on a box whose shell talked over
/// the question.
fn read_probe(output: &str, names: &[&str]) -> HashMap<String, String> {
    let lines: Vec<&str> = output.lines().collect();
    let Some(start) = lines.iter().rposition(|line| *line == PROBE_MARKER) else {
        crate::agent::manifest::log("the login shell answered without the probe marker");
        return HashMap::new();
    };
    let mut resolved = HashMap::new();
    for (index, name) in names.iter().enumerate() {
        if let Some(value) = lines.get(start + 1 + index) {
            if !value.is_empty() {
                resolved.insert(name.to_string(), value.to_string());
            }
        }
    }
    resolved
}

/// This daemon's own executable, as an absolute path, for stamping into a hook
/// command. The SSH arm had to emit `$HOME/.local/bin/fyolod` and escape it
/// three ways; the process that will be exec'd knows where it lives.
pub fn daemon_binary() -> String {
    if let Ok(path) = std::env::current_exe() {
        // A daemon started through a symlink still reports the link's path here,
        // which is the path the user's own `PATH` resolves — the right one to
        // stamp. Canonicalizing would replace it with a build artefact's path
        // that a later upgrade renames out from under every hook.
        if let Some(path) = path.to_str() {
            return path.to_string();
        }
    }
    match home_directory() {
        Some(home) => home.join(".local/bin/fyolod").display().to_string(),
        None => "fyolod".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expand_resolves_a_leading_tilde_against_this_home() {
        let home = home_directory().expect("a home");
        assert_eq!(expand("~/.claude/settings.json"), home.join(".claude/settings.json"));
        assert_eq!(expand("~"), home);
    }

    #[test]
    fn expand_leaves_an_absolute_path_alone() {
        assert_eq!(expand("/etc/hosts"), PathBuf::from("/etc/hosts"));
        // A tilde that is not the first segment is an ordinary character.
        assert_eq!(
            expand("/tmp/~/x"),
            PathBuf::from("/tmp/~/x")
        );
    }

    #[test]
    fn xdg_config_home_is_a_variable_not_a_directory_name() {
        let home = Some(PathBuf::from("/home/u"));
        let moved = |name: &str| (name == "XDG_CONFIG_HOME").then(|| "/home/u/cfg".to_string());
        assert_eq!(
            expand_with("~/.config/opencode/plugin", home.clone(), &moved),
            PathBuf::from("/home/u/cfg/opencode/plugin")
        );
        assert_eq!(
            expand_with("~/.config", home.clone(), &moved),
            PathBuf::from("/home/u/cfg")
        );
        // Unset: the spec's own default, which is what every default account has.
        let unset = |_: &str| None;
        assert_eq!(
            expand_with("~/.config/amp/plugins", home.clone(), &unset),
            PathBuf::from("/home/u/.config/amp/plugins")
        );
        // `.claude` is not an XDG base and must never be rerouted by one.
        assert_eq!(
            expand_with("~/.claude/settings.json", home, &moved),
            PathBuf::from("/home/u/.claude/settings.json")
        );
    }

    #[test]
    fn an_absent_binary_is_not_installed_and_a_present_one_is() {
        // An rc that prints a banner must not be read as the answer.
        let names = ["PATH", "XDG_CONFIG_HOME", "XDG_DATA_HOME"];
        let chatty = format!("Welcome!\nnode v20 is available\n{PROBE_MARKER}\n/usr/bin\n\n/data");
        let read = read_probe(&chatty, &names);
        assert_eq!(read.get("PATH").map(String::as_str), Some("/usr/bin"));
        assert_eq!(read.get("XDG_CONFIG_HOME"), None);
        assert_eq!(read.get("XDG_DATA_HOME").map(String::as_str), Some("/data"));
        // No marker at all is "we could not look", not "nothing is installed".
        assert!(read_probe("Welcome!\n/nonsense", &names).is_empty());
        assert!(is_command_installed("/bin/sh"));
        // A path answers for itself even when the shell could not be asked.
        assert!(!is_command_installed("/nonexistent/agent-cli"));
        // A path typed by hand is exactly where spaces turn up, and splitting on
        // a bare space answers "not installed" for a CLI sitting right there.
        // These cases are pinned identically in the app
        // (`AgentAvailabilityFirstWordTests`). The two must agree, or one side
        // reports an agent available and this one refuses to write its config.
        assert_eq!(first_word("\"/Agent Tools/codex\" --flag").as_deref(), Some("/Agent Tools/codex"));
        assert_eq!(first_word("'/Agent Tools/codex'").as_deref(), Some("/Agent Tools/codex"));
        assert_eq!(first_word("/Agent\\ Tools/codex x").as_deref(), Some("/Agent Tools/codex"));
        assert_eq!(first_word("  claude --dangerously").as_deref(), Some("claude"));
        assert_eq!(first_word("   "), None);
        // A backslash is literal inside single quotes and an escape outside.
        assert_eq!(first_word("'/opt/a\\tools/cli'").as_deref(), Some("/opt/a\\tools/cli"));
        assert_eq!(first_word("\"/opt/a\\tools/cli\"").as_deref(), Some("/opt/a\\tools/cli"));
        assert_eq!(first_word("\"/opt/a\\\"b/cli\"").as_deref(), Some("/opt/a\"b/cli"));
        assert_eq!(first_word("/opt/a\\tools/cli").as_deref(), Some("/opt/atools/cli"));
        // A line continuation is removed, quoted or not.
        assert_eq!(first_word("/usr/bin/tru\\\ne").as_deref(), Some("/usr/bin/true"));
        assert_eq!(first_word("\"/usr/bin/tru\\\ne\"").as_deref(), Some("/usr/bin/true"));
        // An unterminated quote takes the rest of the line rather than nothing.
        assert_eq!(first_word("'/opt/a b").as_deref(), Some("/opt/a b"));
        // A combining mark right after the closing quote belongs to the word.
        assert_eq!(first_word("'/tmp/cafe'\u{301} --flag").as_deref(), Some("/tmp/cafe\u{301}"));
        assert!(!is_command_installed("/nonexistent/agent-cli"));
        // The empty command is the plain login shell, which is always available.
        assert!(is_command_installed(""));
    }

    fn home(env: &str, path: &str) -> ConfigHome {
        ConfigHome {
            env: env.to_string(),
            path: path.to_string(),
        }
    }

    /// Resolution with a stated environment, so these assert the rule rather
    /// than whatever this machine happens to export.
    fn at(path: &str, home: Option<&ConfigHome>, env: &[(&str, &str)]) -> Result<String, String> {
        let env: Vec<(String, String)> = env
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        let lookup = move |name: &str| {
            env.iter()
                .find(|(key, _)| key == name)
                .map(|(_, value)| value.clone())
        };
        resolve_with(path, home, &lookup, Some(PathBuf::from("/home/u")))
            .map(|path| path.display().to_string())
    }

    /// The four states the field has to survive, and the reason it exists: an
    /// agent whose owner moved its config gets the install where the agent
    /// actually reads, and one who did not is unaffected.
    #[test]
    fn a_config_home_variable_moves_the_install() {
        let claude = home("CLAUDE_CONFIG_DIR", "~/.claude");

        // Unset: the documented default, which is every account that never
        // touched it.
        assert_eq!(
            at("~/.claude/settings.json", Some(&claude), &[]),
            Ok("/home/u/.claude/settings.json".into())
        );
        // Set: the whole tree moves, prefix replaced and tail kept.
        assert_eq!(
            at("~/.claude/settings.json", Some(&claude), &[("CLAUDE_CONFIG_DIR", "/srv/work")]),
            Ok("/srv/work/settings.json".into())
        );
        assert_eq!(
            at("~/.claude/skills/fyolo/SKILL.md", Some(&claude), &[("CLAUDE_CONFIG_DIR", "/srv/work")]),
            Ok("/srv/work/skills/fyolo/SKILL.md".into())
        );
        // Empty: not a directory named "", the default.
        assert_eq!(
            at("~/.claude/settings.json", Some(&claude), &[("CLAUDE_CONFIG_DIR", "   ")]),
            Ok("/home/u/.claude/settings.json".into())
        );
        // The variable may itself be `~`-relative.
        assert_eq!(
            at("~/.claude/settings.json", Some(&claude), &[("CLAUDE_CONFIG_DIR", "~/work")]),
            Ok("/home/u/work/settings.json".into())
        );
    }

    /// A comma is ambiguous. Claude Code's own entry describes one directory;
    /// the comma-separated form is ccusage's convention for *reading* across
    /// profiles. Installing into the first would wire up one profile and leave
    /// the others silent, which reads as an agent that reports sometimes.
    #[test]
    fn more_than_one_directory_is_refused_rather_than_guessed() {
        let claude = home("CLAUDE_CONFIG_DIR", "~/.claude");
        let outcome = at(
            "~/.claude/settings.json",
            Some(&claude),
            &[("CLAUDE_CONFIG_DIR", "~/.claude-work,~/.claude-personal")],
        );
        let error = outcome.expect_err("must refuse");
        assert!(error.contains("CLAUDE_CONFIG_DIR"), "{error}");
        assert!(error.contains("more than one directory"), "{error}");
    }

    /// The two overrides compose in a stated order rather than racing. Nothing
    /// in the catalog needs both today, but the rule has to be decided
    /// somewhere.
    #[test]
    fn an_agents_own_variable_outranks_the_xdg_base() {
        let under_xdg = home("SOME_AGENT_HOME", "~/.config/some-agent");
        let env = [
            ("XDG_CONFIG_HOME", "/xdg"),
            ("SOME_AGENT_HOME", "/agent-home"),
        ];
        assert_eq!(
            at("~/.config/some-agent/hooks.json", Some(&under_xdg), &env),
            Ok("/agent-home/hooks.json".into())
        );
        // With only the XDG base set, the XDG base applies.
        assert_eq!(
            at("~/.config/some-agent/hooks.json", Some(&under_xdg), &env[..1]),
            Ok("/xdg/some-agent/hooks.json".into())
        );
        // And an agent that declares no variable is untouched by this at all.
        assert_eq!(
            at("~/.config/some-agent/hooks.json", None, &env),
            Ok("/xdg/some-agent/hooks.json".into())
        );
    }

    /// A prefix that is a text prefix but not a path prefix must not match, or
    /// `~/.pi/agent` would claim `~/.pi/agentic`.
    #[test]
    fn the_prefix_is_matched_by_path_component() {
        let pi = home("PI_DIR", "~/.pi/agent");
        assert_eq!(
            at("~/.pi/agent/extensions", Some(&pi), &[("PI_DIR", "/elsewhere")]),
            Ok("/elsewhere/extensions".into())
        );
        // Outside the declared prefix: fall back rather than write somewhere
        // the prefix does not describe.
        assert_eq!(
            at("~/.pi/agentic/x", Some(&pi), &[("PI_DIR", "/elsewhere")]),
            Ok("/home/u/.pi/agentic/x".into())
        );
        // The home itself resolves to the moved directory, with no stray slash.
        assert_eq!(
            at("~/.pi/agent", Some(&pi), &[("PI_DIR", "/elsewhere")]),
            Ok("/elsewhere".into())
        );
    }

    /// The probe has to look past the `PATH` this process inherited. A daemon
    /// auto-started over SSH gets a minimal one, and the agents worth finding
    /// live outside it.
    #[test]
    fn the_login_shell_path_is_consulted_even_when_one_was_inherited() {
        assert!(
            !std::env::var("PATH").unwrap_or_default().is_empty(),
            "this test is meaningless without an inherited PATH"
        );
        let login = probe().get("PATH").cloned().unwrap_or_default();
        for directory in login.split(':').filter(|d| !d.is_empty()) {
            assert!(
                login_path().iter().any(|seen| seen == directory),
                "{directory} came from the login shell and must be searched"
            );
        }
    }
}
