use super::*;

/// A directory of files that removes itself.
pub(super) struct Scratch(PathBuf);

impl Scratch {
    pub(super) fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub(super) fn tree(files: &[(&str, &str)]) -> Scratch {
    static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let unique = NEXT.fetch_add(1, Ordering::Relaxed);
    let directory = std::env::temp_dir()
        .join(format!("fyolod-symbols-test-{}-{unique}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    for (path, text) in files {
        let full = directory.join(path);
        std::fs::create_dir_all(full.parent().unwrap()).unwrap();
        std::fs::write(full, text).unwrap();
    }
    std::fs::create_dir_all(&directory).unwrap();
    Scratch(directory)
}

struct Answer {
    resolved: Resolved,
    hits: Vec<SearchMatch>,
}

impl Answer {
    /// (path, line, kind) for every hit, in the order the host sent them.
    fn rows(&self) -> Vec<(String, u64, String)> {
        self.hits
            .iter()
            .map(|hit| (hit.path.clone(), hit.line, hit.kind.clone().unwrap_or_default()))
            .collect()
    }

    fn of_kind(&self, kind: &str) -> Vec<(String, u64)> {
        self.hits
            .iter()
            .filter(|hit| hit.kind.as_deref() == Some(kind))
            .map(|hit| (hit.path.clone(), hit.line))
            .collect()
    }

    fn definition(&self) -> Option<(String, u64)> {
        self.resolved.definitions.first().map(|hit| (hit.path.clone(), hit.line))
    }
}

/// The references for the `nth` occurrence of `needle` in `path`.
fn ask(root: &Path, path: &str, needle: &str, nth: usize) -> Answer {
    let source = std::fs::read_to_string(root.join(path)).unwrap();
    let offset = source.match_indices(needle).nth(nth).expect("needle in file").0;
    let root = root.canonicalize().unwrap();
    let mut resolved = None;
    let mut hits = Vec::new();
    let cancel = AtomicBool::new(false);
    references(
        &root,
        path,
        offset,
        None,
        None,
        1000,
        &cancel,
        &mut |symbol| resolved = Some(symbol),
        &mut |batch| hits.extend(batch),
    )
    .expect("answers");
    Answer { resolved: resolved.expect("resolved first"), hits }
}

fn landing() -> Scratch {
    tree(&[
        ("web/tsconfig.json", "{ \"compilerOptions\": { \"paths\": { \"@/*\": [\"./src/*\"] } } }"),
        (
            "web/src/app/privacy/page.tsx",
            "import type { Metadata } from \"next\";\n\
             import { SiteNav } from \"@/components/site-nav\";\n\
             \n\
             export const metadata: Metadata = {\n  title: \"Privacy\",\n};\n\
             \n\
             export default function PrivacyPage() {\n\
             \x20 return <main><SiteNav /><p>Settings and session metadata are stored locally.</p></main>;\n\
             }\n",
        ),
        (
            "web/src/app/terms/page.tsx",
            "import type { Metadata } from \"next\";\n\
             import { SiteNav as Nav } from \"@/components/site-nav\";\n\
             export const metadata: Metadata = { title: \"Terms\" };\n\
             export default function TermsPage() { return <Nav />; }\n",
        ),
        (
            "web/src/components/site-nav.tsx",
            "// SiteNav renders the top bar.\nexport function SiteNav() {\n  return <nav />;\n}\n",
        ),
        ("web/src/mdx-components.tsx", "export const Video = () => <video preload=\"metadata\" />;\n"),
        (
            "web/src/lib/index.ts",
            "export * from \"./format\";\nexport { shout as yell } from \"./format\";\n",
        ),
        (
            "web/src/lib/format.ts",
            "export function shout(text: string) { return text.toUpperCase(); }\n\
             export function quiet(text: string) { const shout = text; return shout.toLowerCase(); }\n",
        ),
        (
            "web/src/app/use-lib.ts",
            "import { shout, yell } from \"@/lib\";\nimport * as lib from \"../lib/format\";\n\
             shout(\"a\"); yell(\"b\"); lib.shout(\"c\");\n",
        ),
    ])
}

#[test]
fn metadata_is_defined_here_read_by_next_and_the_others_are_unrelated() {
    let directory = landing();
    let answer = ask(directory.path(), "web/src/app/privacy/page.tsx", "metadata", 0);
    assert_eq!(answer.resolved.kind, "export");
    assert!(answer.resolved.at_definition);
    assert_eq!(answer.definition(), Some(("web/src/app/privacy/page.tsx".into(), 4)));
    assert_eq!(answer.resolved.note.as_deref(), Some("Read by Next.js"));
    assert!(answer.of_kind(kind::USAGE).is_empty(), "{:?}", answer.rows());
    assert!(answer.of_kind(kind::IMPORT).is_empty(), "{:?}", answer.rows());
    let unrelated = answer.of_kind(kind::UNRELATED);
    // The JSX prose here, the other page's own `metadata`, the attribute value.
    assert!(unrelated.contains(&("web/src/app/privacy/page.tsx".into(), 9)), "{unrelated:?}");
    assert!(unrelated.contains(&("web/src/app/terms/page.tsx".into(), 3)), "{unrelated:?}");
    assert!(unrelated.contains(&("web/src/mdx-components.tsx".into(), 1)), "{unrelated:?}");
}

#[test]
fn a_usage_resolves_to_its_definition_through_a_tsconfig_path_and_an_alias() {
    let directory = landing();
    let answer = ask(directory.path(), "web/src/app/privacy/page.tsx", "SiteNav", 1);
    assert_eq!(answer.resolved.kind, "export");
    assert!(!answer.resolved.at_definition);
    assert_eq!(answer.definition(), Some(("web/src/components/site-nav.tsx".into(), 2)));
    let usages = answer.of_kind(kind::USAGE);
    assert!(usages.contains(&("web/src/app/privacy/page.tsx".into(), 9)), "{:?}", answer.rows());
    // `<Nav />` is the same component under an alias it was never searched by.
    assert!(usages.contains(&("web/src/app/terms/page.tsx".into(), 4)), "{:?}", answer.rows());
    let imports = answer.of_kind(kind::IMPORT);
    assert!(imports.contains(&("web/src/app/privacy/page.tsx".into(), 2)));
    assert!(imports.contains(&("web/src/app/terms/page.tsx".into(), 2)));
    // The comment naming it is prose.
    assert!(answer.of_kind(kind::UNRELATED).contains(&("web/src/components/site-nav.tsx".into(), 1)));

    // Asked from the alias, the answer is the same symbol and the same prose.
    let aliased = ask(directory.path(), "web/src/app/terms/page.tsx", "Nav", 1);
    assert_eq!(aliased.definition(), Some(("web/src/components/site-nav.tsx".into(), 2)));
    assert!(aliased.of_kind(kind::UNRELATED).contains(&("web/src/components/site-nav.tsx".into(), 1)));
    assert!(aliased.of_kind(kind::USAGE).contains(&("web/src/app/privacy/page.tsx".into(), 9)));
    // Usages come before imports, imports before the unrelated.
    let kinds: Vec<_> = answer.rows().into_iter().map(|row| row.2).collect();
    let last_usage = kinds.iter().rposition(|kind| kind == kind::USAGE).unwrap();
    let first_import = kinds.iter().position(|kind| kind == kind::IMPORT).unwrap();
    assert!(last_usage < first_import);
}

#[test]
fn a_barrel_re_export_and_a_namespace_reach_the_same_function_but_a_shadow_does_not() {
    let directory = landing();
    let answer = ask(directory.path(), "web/src/lib/format.ts", "shout", 0);
    assert!(answer.resolved.at_definition);
    let usages = answer.of_kind(kind::USAGE);
    // `shout(…)` via `export *`, `yell(…)` via the renaming forward, `lib.shout`.
    assert_eq!(
        usages.iter().filter(|(path, _)| path == "web/src/app/use-lib.ts").count(),
        1,
        "one row holding three spans: {:?}",
        answer.rows()
    );
    let row = answer
        .hits
        .iter()
        .find(|hit| hit.path == "web/src/app/use-lib.ts" && hit.kind.as_deref() == Some(kind::USAGE))
        .unwrap();
    assert_eq!(row.spans.len(), 3, "{row:?}");
    assert!(answer.of_kind(kind::REEXPORT).contains(&("web/src/lib/index.ts".into(), 2)));
    // `quiet`'s local `shout` shadows the function.
    let unrelated = answer.of_kind(kind::UNRELATED);
    assert!(unrelated.contains(&("web/src/lib/format.ts".into(), 2)), "{:?}", answer.rows());
    assert!(!usages.contains(&("web/src/lib/format.ts".into(), 2)));
}

#[test]
fn a_local_stays_in_its_file() {
    let directory = landing();
    let answer = ask(directory.path(), "web/src/lib/format.ts", "shout", 1);
    assert_eq!(answer.resolved.kind, "local");
    assert!(answer.resolved.at_definition);
    assert_eq!(answer.of_kind(kind::USAGE), vec![("web/src/lib/format.ts".into(), 2)]);
    assert!(answer.of_kind(kind::UNRELATED).is_empty());
}

#[test]
fn a_package_type_lists_every_file_importing_it() {
    let directory = landing();
    let answer = ask(directory.path(), "web/src/app/privacy/page.tsx", "Metadata", 1);
    assert_eq!(answer.resolved.kind, "package");
    assert_eq!(answer.resolved.note.as_deref(), Some("From package next"));
    let usages = answer.of_kind(kind::USAGE);
    assert!(usages.contains(&("web/src/app/privacy/page.tsx".into(), 4)));
    assert!(usages.contains(&("web/src/app/terms/page.tsx".into(), 3)));
}

#[test]
fn a_click_on_a_specifier_names_the_module() {
    let directory = landing();
    let answer = ask(directory.path(), "web/src/app/privacy/page.tsx", "components/site-nav", 0);
    assert_eq!(answer.resolved.kind, "module");
    assert_eq!(answer.definition(), Some(("web/src/components/site-nav.tsx".into(), 1)));
}

#[test]
fn another_language_gets_name_matches_in_its_own_files() {
    let directory = tree(&[
        ("Sources/A.swift", "struct Widget {}\nlet w = Widget()\n"),
        ("Sources/B.swift", "func make() -> Widget { Widget() }\n"),
        ("docs/notes.md", "Widget is mentioned here.\n"),
    ]);
    let answer = ask(directory.path(), "Sources/B.swift", "Widget", 0);
    assert_eq!(answer.resolved.kind, "name");
    assert_eq!(answer.of_kind(kind::DEFINITION), vec![("Sources/A.swift".into(), 1)]);
    assert!(answer.rows().iter().all(|row| row.0.ends_with(".swift")));
}

#[test]
fn the_unsaved_text_wins_and_the_root_cannot_be_escaped() {
    let directory = landing();
    let root = directory.path().canonicalize().unwrap();
    let cancel = AtomicBool::new(false);
    let text = "export const fresh = 1;\nfresh;\n".to_string();
    let mut resolved = None;
    let mut hits = Vec::new();
    references(
        &root,
        "web/src/app/use-lib.ts",
        13,
        Some(text),
        None,
        100,
        &cancel,
        &mut |symbol| resolved = Some(symbol),
        &mut |batch| hits.extend(batch),
    )
    .unwrap();
    assert_eq!(resolved.unwrap().name, "fresh");
    assert_eq!(hits.len(), 1);
    let escaped = references(
        &root, "../outside.ts", 0, None, None, 100, &cancel, &mut |_| {}, &mut |_| {},
    );
    assert!(escaped.is_err());
}

/// Every exported top-level symbol under `FYOLOD_REFERENCES_ROOT`, asked from
/// its own declaration: prints each answer as JSON lines to
/// `FYOLOD_REFERENCES_OUT` (for an outside oracle to score) and the latency
/// distribution to stderr. Run with
/// `FYOLOD_REFERENCES_ROOT=… cargo test --release --lib references_over_a_real_tree -- --ignored --nocapture`.
#[test]
#[ignore]
fn references_over_a_real_tree() {
    let Some(root) = std::env::var_os("FYOLOD_REFERENCES_ROOT") else { return };
    let root = PathBuf::from(root).canonicalize().unwrap();
    let mut out = std::env::var_os("FYOLOD_REFERENCES_OUT")
        .map(|path| std::fs::File::create(path).unwrap());
    let files: Vec<(String, PathBuf)> = crate::files::text_files(&root, None)
        .filter(|(relative, _)| javascript::language_for(relative).is_some())
        .collect();
    let mut timings = Vec::new();
    for (relative, path) in &files {
        let source = std::fs::read_to_string(path).unwrap_or_default();
        let Some(tree) = javascript::parse(relative, &source) else { continue };
        let analysis = javascript::analyze(&tree, &source);
        let mut asked: Vec<(String, usize)> = analysis
            .bindings
            .iter()
            .enumerate()
            .filter(|(index, binding)| {
                binding.kind == BindingKind::Declaration
                    && analysis.top_level(&binding.name) == Some(*index)
                    && !analysis.export_names(*index).is_empty()
            })
            .map(|(_, binding)| (binding.name.clone(), binding.range.start))
            .collect();
        asked.dedup();
        for (name, offset) in asked {
            let cancel = AtomicBool::new(false);
            let mut hits = Vec::new();
            let mut resolved = None;
            let started = std::time::Instant::now();
            let answered = references(
                &root, relative, offset, None, None, 5000, &cancel,
                &mut |symbol| resolved = Some(symbol),
                &mut |batch| hits.extend(batch),
            );
            timings.push(started.elapsed());
            if started.elapsed() > std::time::Duration::from_millis(100) {
                eprintln!("slow {:?} {relative} {name} hits={}", started.elapsed(), hits.len());
            }
            if answered.is_err() {
                continue;
            }
            if let Some(out) = out.as_mut() {
                use std::io::Write;
                let found: Vec<serde_json::Value> = hits
                    .iter()
                    .filter(|hit| matches!(hit.kind.as_deref(), Some("usage" | "import" | "reexport")))
                    .flat_map(|hit| {
                        hit.spans.iter().map(move |span| {
                            serde_json::json!({
                                "path": hit.path,
                                "line": hit.line,
                                "column": hit.text_offset + u64::from(span[0]),
                            })
                        })
                    })
                    .collect();
                let line = serde_json::json!({
                    "file": relative, "name": name, "offset": offset,
                    "kind": resolved.map(|r| r.kind), "references": found,
                });
                writeln!(out, "{line}").unwrap();
            }
        }
    }
    timings.sort();
    let at = |q: f64| timings[((timings.len() as f64 - 1.0) * q) as usize];
    eprintln!(
        "{} symbols in {} files: p50 {:?}, p95 {:?}, max {:?}",
        timings.len(),
        files.len(),
        at(0.5),
        at(0.95),
        timings.last().unwrap()
    );
}
