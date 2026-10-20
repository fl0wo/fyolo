//! Recorded test runs, per project, kept on the box the tests ran on.
//!
//! A run arrives from the test-runner integration inside a session
//! (`crate::node_integration`) as a stream of `report_test_run` controls. The
//! store keeps live runs in memory, and the finished ones across restarts. It
//! files each run under its project's repository root, so a client watching a
//! checkout sees every run anywhere inside it, a monorepo package included.
//!
//! On disk, each root has a directory named by a hash of the root. It holds
//! `index.json`, the finished summaries oldest first, plus one `<id>.json`
//! detail file per run. Listing a project reads only the index. A run's
//! per-file results and failures are read when a client expands it.

use crate::id::ClientId;
use crate::protocol::{TestRunDetail, TestRunSummary};
use anyhow::{Context, Result};
use serde::{de::DeserializeOwned, Serialize};
use sha2::Digest;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Finished runs kept per project. The oldest beyond this are deleted: the pane
/// looks back this far and no further, so older runs would only take up disk.
const RUNS_PER_ROOT: usize = 6;
const DEFAULT_LIMIT: u64 = RUNS_PER_ROOT as u64;

pub const RUNNING: &str = "running";
/// A run whose reporter went away before it said how the run ended: the
/// process was killed, or the daemon lost the connection.
pub const INTERRUPTED: &str = "interrupted";

pub struct TestRunStore {
    /// `None` keeps runs in memory only, when the daemon has no state dir.
    directory: Option<PathBuf>,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    /// Runs per root, oldest first, loaded from disk on a root's first use.
    roots: HashMap<String, Vec<TestRunSummary>>,
    /// Which connection reports each live run, so that connection closing can
    /// end the run instead of leaving it `running` forever.
    owners: HashMap<String, ClientId>,
}

impl TestRunStore {
    pub fn new(directory: Option<PathBuf>) -> TestRunStore {
        TestRunStore {
            directory,
            inner: Mutex::new(Inner::default()),
        }
    }

    pub fn open_default() -> TestRunStore {
        match crate::paths::durable_state_dir() {
            Ok(state) => TestRunStore::new(Some(state.join("test-runs"))),
            Err(error) => {
                eprintln!("fyolod: test runs kept in memory only, no state dir: {error:#}");
                TestRunStore::new(None)
            }
        }
    }

    /// Record one report. Returns the summary to publish on the root's `tests:`
    /// resource, or `None` when the report is refused: an id that cannot name
    /// a file, or a report for a run that has already ended.
    pub fn report(
        &self,
        owner: &ClientId,
        mut summary: TestRunSummary,
        detail: Option<TestRunDetail>,
    ) -> Option<TestRunSummary> {
        if !valid_id(&summary.id) {
            return None;
        }
        summary.root = key_root(&summary.root);
        let mut inner = self.inner.lock().unwrap();
        let runs = self.runs_locked(&mut inner, &summary.root);
        match runs.iter_mut().find(|run| run.id == summary.id) {
            Some(existing) if existing.state != RUNNING => return None,
            Some(existing) => *existing = summary.clone(),
            None => runs.push(summary.clone()),
        }
        if summary.state == RUNNING {
            inner.owners.insert(summary.id.clone(), owner.clone());
        } else {
            inner.owners.remove(&summary.id);
            self.finish_locked(&mut inner, &summary, &detail.unwrap_or_default());
        }
        Some(summary)
    }

    /// End every live run `owner` was reporting, as interrupted. Returns them
    /// for publishing.
    pub fn connection_closed(&self, owner: &ClientId) -> Vec<TestRunSummary> {
        let mut inner = self.inner.lock().unwrap();
        let orphaned: Vec<String> = inner
            .owners
            .iter()
            .filter(|(_, reporter)| *reporter == owner)
            .map(|(id, _)| id.clone())
            .collect();
        let mut ended = Vec::new();
        for id in orphaned {
            inner.owners.remove(&id);
            let Some(run) = inner
                .roots
                .values_mut()
                .flat_map(|runs| runs.iter_mut())
                .find(|run| run.id == id && run.state == RUNNING)
            else {
                continue;
            };
            run.state = INTERRUPTED.to_string();
            let run = run.clone();
            self.finish_locked(&mut inner, &run, &TestRunDetail::default());
            ended.push(run);
        }
        ended
    }

    /// A project's runs, newest first, and the root they are filed under.
    pub fn list(&self, root: &str, before: Option<u64>, limit: Option<u64>) -> (String, Vec<TestRunSummary>) {
        let key = key_root(root);
        let limit = limit.unwrap_or(DEFAULT_LIMIT).min(RUNS_PER_ROOT as u64) as usize;
        let mut inner = self.inner.lock().unwrap();
        let runs = self
            .runs_locked(&mut inner, &key)
            .iter()
            .rev()
            .filter(|run| before.is_none_or(|before| run.started_at < before))
            .take(limit)
            .cloned()
            .collect();
        (key, runs)
    }

    pub fn detail(&self, root: &str, id: &str) -> Option<TestRunDetail> {
        if !valid_id(id) {
            return None;
        }
        let directory = self.root_directory(&key_root(root))?;
        read_json(&directory.join(format!("{id}.json")))
    }

    fn runs_locked<'a>(&self, inner: &'a mut Inner, key: &str) -> &'a mut Vec<TestRunSummary> {
        inner.roots.entry(key.to_string()).or_insert_with(|| {
            self.root_directory(key)
                .and_then(|directory| read_json(&directory.join("index.json")))
                .unwrap_or_default()
        })
    }

    /// Write a finished run's detail and the root's index, and drop the runs
    /// past the cap. A failed write is logged and the run stays in memory: the
    /// user still sees it until the daemon restarts.
    fn finish_locked(&self, inner: &mut Inner, run: &TestRunSummary, detail: &TestRunDetail) {
        let Some(runs) = inner.roots.get_mut(&run.root) else {
            return;
        };
        let finished = runs.iter().filter(|run| run.state != RUNNING).count();
        let mut expired = Vec::new();
        if finished > RUNS_PER_ROOT {
            let mut excess = finished - RUNS_PER_ROOT;
            runs.retain(|candidate| {
                if excess > 0 && candidate.state != RUNNING {
                    excess -= 1;
                    expired.push(candidate.id.clone());
                    return false;
                }
                true
            });
        }
        let Some(directory) = self.root_directory(&run.root) else {
            return;
        };
        let index: Vec<&TestRunSummary> = runs.iter().filter(|run| run.state != RUNNING).collect();
        let written = std::fs::create_dir_all(&directory)
            .with_context(|| format!("creating {}", directory.display()))
            .and_then(|()| write_json(&directory.join(format!("{}.json", run.id)), detail))
            .and_then(|()| write_json(&directory.join("index.json"), &index));
        if let Err(error) = written {
            eprintln!("fyolod: could not record test run {}: {error:#}", run.id);
        }
        for id in expired {
            if let Err(error) = std::fs::remove_file(directory.join(format!("{id}.json"))) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    eprintln!("fyolod: could not remove expired test run {id}: {error}");
                }
            }
        }
    }

    fn root_directory(&self, key: &str) -> Option<PathBuf> {
        let digest = sha2::Sha256::digest(key.as_bytes());
        let name: String = digest.iter().take(8).map(|byte| format!("{byte:02x}")).collect();
        Some(self.directory.as_ref()?.join(name))
    }
}

/// The root runs are filed under: the repository containing `path`, or `path`
/// itself outside a repository. The reporter and every client go through this,
/// so a run and the checkout showing it agree on the key whichever directory
/// either one started from.
pub fn key_root(path: &str) -> String {
    let start = std::fs::canonicalize(path).unwrap_or_else(|_| PathBuf::from(path));
    start
        .ancestors()
        .find(|directory| directory.join(".git").exists())
        .unwrap_or(&start)
        .display()
        .to_string()
}

/// Run ids become file names, so only the reporter's UUID shape is accepted.
fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn read_json<T: DeserializeOwned>(path: &Path) -> Option<T> {
    let text = std::fs::read(path).ok()?;
    match serde_json::from_slice(&text) {
        Ok(value) => Some(value),
        Err(error) => {
            // A corrupt file loses its runs rather than failing the daemon.
            eprintln!("fyolod: ignoring unreadable {}: {error}", path.display());
            None
        }
    }
}

/// Written through a temp file and a rename, so a daemon killed mid-write
/// leaves the previous file intact.
fn write_json<T: Serialize + ?Sized>(path: &Path, value: &T) -> Result<()> {
    let text = serde_json::to_vec(value)?;
    let temporary = path.with_extension("tmp");
    std::fs::write(&temporary, &text).with_context(|| format!("writing {}", temporary.display()))?;
    std::fs::rename(&temporary, path).with_context(|| format!("replacing {}", path.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{TestCounts, TestFailure};

    fn scratch(name: &str) -> PathBuf {
        let directory = std::env::temp_dir().join(format!("fyolod-test-runs-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(directory.join("repo/.git")).expect("scratch repo");
        std::fs::create_dir_all(directory.join("repo/packages/app")).expect("scratch package");
        directory
    }

    fn summary(id: &str, root: &Path, state: &str, started_at: u64) -> TestRunSummary {
        TestRunSummary {
            id: id.to_string(),
            root: root.display().to_string(),
            state: state.to_string(),
            started_at,
            duration_ms: 0,
            counts: TestCounts::default(),
            files_total: 1,
            files_done: 0,
            package: None,
            session: None,
            command_id: None,
            command: None,
            argv: Vec::new(),
        }
    }

    #[test]
    fn runs_are_filed_under_the_repository_root() {
        let scratch = scratch("key");
        let package = scratch.join("repo/packages/app");
        let repo = std::fs::canonicalize(scratch.join("repo")).expect("canonical repo");
        assert_eq!(key_root(&package.display().to_string()), repo.display().to_string());
        let outside = std::fs::canonicalize(&scratch).expect("canonical scratch");
        assert_eq!(key_root(&scratch.display().to_string()), outside.display().to_string());
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[test]
    fn a_finished_run_survives_a_restart_with_its_detail() {
        let scratch = scratch("persist");
        let package = scratch.join("repo/packages/app");
        let owner = ClientId::new("reporter");
        let store = TestRunStore::new(Some(scratch.join("store")));
        store.report(&owner, summary("run-1", &package, RUNNING, 10), None);
        let detail = TestRunDetail {
            files: Vec::new(),
            failures: vec![TestFailure {
                kind: "test".into(),
                file: Some("a.test.ts".into()),
                test: Some("adds".into()),
                message: Some("expected 1 to be 2".into()),
                diff: None,
                location: Some("a.test.ts:3".into()),
            }],
        };
        store.report(&owner, summary("run-1", &package, "failed", 10), Some(detail.clone()));

        let reopened = TestRunStore::new(Some(scratch.join("store")));
        let (_, runs) = reopened.list(&scratch.join("repo").display().to_string(), None, None);
        assert_eq!(runs.len(), 1);
        assert_eq!(runs[0].state, "failed");
        assert_eq!(reopened.detail(&package.display().to_string(), "run-1"), Some(detail));
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[test]
    fn a_closed_connection_interrupts_its_live_runs_only() {
        let scratch = scratch("interrupt");
        let repo = scratch.join("repo");
        let store = TestRunStore::new(Some(scratch.join("store")));
        let gone = ClientId::new("gone");
        let staying = ClientId::new("staying");
        store.report(&gone, summary("run-a", &repo, RUNNING, 1), None);
        store.report(&staying, summary("run-b", &repo, RUNNING, 2), None);

        let ended = store.connection_closed(&gone);
        assert_eq!(ended.iter().map(|run| run.id.as_str()).collect::<Vec<_>>(), ["run-a"]);
        assert_eq!(ended[0].state, INTERRUPTED);
        let (_, runs) = store.list(&repo.display().to_string(), None, None);
        assert_eq!(runs.iter().map(|run| (run.id.as_str(), run.state.as_str())).collect::<Vec<_>>(), [
            ("run-b", RUNNING),
            ("run-a", INTERRUPTED)
        ]);
        // A late report for an ended run cannot reopen it.
        assert!(store.report(&gone, summary("run-a", &repo, RUNNING, 1), None).is_none());
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[test]
    fn history_is_capped_and_expired_details_are_deleted() {
        let scratch = scratch("cap");
        let repo = scratch.join("repo");
        let store = TestRunStore::new(Some(scratch.join("store")));
        let owner = ClientId::new("reporter");
        for index in 0..RUNS_PER_ROOT + 3 {
            store.report(&owner, summary(&format!("run-{index}"), &repo, "passed", index as u64), None);
        }
        let root = repo.display().to_string();
        let (_, runs) = store.list(&root, None, Some(1000));
        assert_eq!(runs.len(), RUNS_PER_ROOT);
        assert_eq!(runs.last().map(|run| run.id.as_str()), Some("run-3"));
        assert!(store.detail(&root, "run-2").is_none());
        assert!(store.detail(&root, "run-3").is_some());
        let newest = (RUNS_PER_ROOT + 2) as u64;
        let (_, page) = store.list(&root, Some(newest), Some(2));
        assert_eq!(page.iter().map(|run| run.started_at).collect::<Vec<_>>(), [newest - 1, newest - 2]);
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[test]
    fn ids_that_could_escape_the_directory_are_refused() {
        let store = TestRunStore::new(None);
        let owner = ClientId::new("reporter");
        for id in ["", "../index", "a/b", "run.json"] {
            assert!(store.report(&owner, summary(id, Path::new("/"), RUNNING, 0), None).is_none(), "{id}");
        }
    }
}
