//! `fs.references`: what a name in a file refers to, where that is defined,
//! and every other place in the tree that refers to the same thing.
//!
//! The walk is `fs.search`'s (`files::text_files`) — the same files, the same
//! ignore rules, the same "files to include" filter — so a reference search
//! can never see a different tree from a text search. What it adds is reading:
//! a cheap whole-word scan decides which files can matter, and only those are
//! parsed, bound and classified. A file that never mentions the name costs one
//! pass of a literal matcher and nothing else.
//!
//! Understood as code: TypeScript and JavaScript (`javascript`, `modules`).
//! Every other language is answered as whole-word name matches in files of
//! its own kind, and says so — a match is never presented as a resolved
//! reference.

pub(crate) mod javascript;
mod modules;

use crate::files::{SearchFilter, SearchOutcome, SEARCH_CONTEXT_LINES};
use crate::protocol::SearchMatch;
use javascript::{Analysis, BindingKind, Export, Imported, Role};
use modules::{Resolution, Resolver};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

/// Past this a file is generated or minified, not read: parsing it costs more
/// than any answer inside it is worth, and the search thread shares the box
/// with live sessions.
const PARSE_LIMIT: usize = 2 * 1024 * 1024;

/// How many definition candidates a name-only answer lists before it stops
/// pretending they help.
const NAME_DEFINITION_LIMIT: usize = 50;

/// The symbol a click resolved to, sent before any reference so a client can
/// jump to a definition without waiting for the tree to be read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub name: String,
    /// `export`, `local`, `package`, `module`, or `name` — the last meaning the
    /// results are name matches, not resolved references.
    pub kind: &'static str,
    pub definitions: Vec<SearchMatch>,
    /// Whether the click was on the definition itself.
    pub at_definition: bool,
    pub note: Option<String>,
}

/// What a reference is to the symbol — the `kind` a client groups by.
pub mod kind {
    pub const DEFINITION: &str = "definition";
    pub const USAGE: &str = "usage";
    pub const IMPORT: &str = "import";
    pub const REEXPORT: &str = "reexport";
    /// A whole-word occurrence nothing could tie to a declaration.
    pub const MATCH: &str = "match";
    /// The same text, but provably not this symbol: another declaration, or
    /// prose in a string or comment.
    pub const UNRELATED: &str = "unrelated";
}

fn kind_rank(kind: &str) -> usize {
    [kind::DEFINITION, kind::USAGE, kind::IMPORT, kind::REEXPORT, kind::MATCH, kind::UNRELATED]
        .iter()
        .position(|known| *known == kind)
        .unwrap_or(usize::MAX)
}

/// What a click is about.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum Target {
    /// A top-level declaration (or an anonymous default export), anywhere a
    /// module can import it from. `start` is the declaring identifier's.
    Declared { file: PathBuf, start: usize },
    /// A declaration no other file can see.
    Local { file: PathBuf, start: usize },
    /// Something imported from a package outside the tree.
    Package { package: String, imported: Imported },
    /// A module as a whole: a click on a specifier, or a namespace import.
    Module(PathBuf),
    /// A name nothing could resolve: a member, a global, another language.
    Name(String),
}

struct Parsed {
    source: String,
    analysis: Analysis,
}

struct Workspace {
    root: PathBuf,
    resolver: Resolver,
    parsed: HashMap<PathBuf, Option<Rc<Parsed>>>,
    /// The clicked file's unsaved text, which wins over the disk.
    overlay: Option<(PathBuf, String)>,
}

impl Workspace {
    fn source(&self, path: &Path) -> Option<String> {
        if let Some((overlay, text)) = &self.overlay {
            if overlay == path {
                return Some(text.clone());
            }
        }
        let metadata = std::fs::metadata(path).ok()?;
        if metadata.len() as usize > PARSE_LIMIT {
            return None;
        }
        let bytes = std::fs::read(path).ok()?;
        if bytes.iter().take(8000).any(|byte| *byte == 0) {
            return None;
        }
        Some(String::from_utf8_lossy(&bytes).into_owned())
    }

    fn parsed(&mut self, path: &Path) -> Option<Rc<Parsed>> {
        if let Some(found) = self.parsed.get(path) {
            return found.clone();
        }
        let source = self.source(path);
        self.parse_source(path, source)
    }

    /// `parsed`, for a file whose text the caller has already read — the scan
    /// reads every candidate once to decide whether it is worth parsing.
    fn parse_source(&mut self, path: &Path, source: Option<String>) -> Option<Rc<Parsed>> {
        if let Some(found) = self.parsed.get(path) {
            return found.clone();
        }
        let found = (|| {
            let name = path.to_str()?;
            let source = source?;
            // A minified bundle is shipped, not read: its names are mangled, and
            // parsing megabytes of one line is most of what a scan would cost.
            if name.contains(".min.") || source.len() / (source.lines().count() + 1) > 1000 {
                return None;
            }
            let tree = javascript::parse(name, &source)?;
            let analysis = javascript::analyze(&tree, &source);
            Some(Rc::new(Parsed { source, analysis }))
        })();
        self.parsed.insert(path.to_path_buf(), found.clone());
        found
    }

    fn resolve(&mut self, importer: &Path, specifier: &str) -> Resolution {
        self.resolver.resolve(importer, specifier)
    }

    /// What binding `binding` of `file` ultimately names.
    fn binding_target(&mut self, file: &Path, binding: usize) -> Option<Target> {
        let parsed = self.parsed(file)?;
        let found = parsed.analysis.bindings.get(binding)?.clone();
        match &found.kind {
            BindingKind::Declaration => {
                let start = found.range.start;
                let top_level = parsed.analysis.top_level(&found.name) == Some(binding);
                if top_level && !parsed.analysis.export_names(binding).is_empty() {
                    Some(Target::Declared { file: file.to_path_buf(), start })
                } else {
                    Some(Target::Local { file: file.to_path_buf(), start })
                }
            }
            BindingKind::Import { specifier, imported } => {
                match self.resolve(file, specifier) {
                    Resolution::File(module) => match imported {
                        Imported::Namespace => Some(Target::Module(module)),
                        Imported::Default => self.export_target(&module, "default", &mut HashSet::new()),
                        Imported::Name(name) => self.export_target(&module, name, &mut HashSet::new()),
                    },
                    Resolution::Package(package) => {
                        Some(Target::Package { package, imported: imported.clone() })
                    }
                    Resolution::Unresolved => None,
                }
            }
        }
    }

    /// What `module` hands out as `name`, following forwards and `export *`.
    fn export_target(
        &mut self,
        module: &Path,
        name: &str,
        visited: &mut HashSet<(PathBuf, String)>,
    ) -> Option<Target> {
        if !visited.insert((module.to_path_buf(), name.to_string())) {
            return None;
        }
        let parsed = self.parsed(module)?;
        match parsed.analysis.exports.get(name).cloned() {
            Some(Export::Local(local)) => {
                let binding = parsed.analysis.top_level(&local)?;
                match &parsed.analysis.bindings[binding].kind {
                    // `import { a } from "./x"; export { a }` hands out x's `a`.
                    BindingKind::Import { .. } => self.binding_target(module, binding),
                    BindingKind::Declaration => Some(Target::Declared {
                        file: module.to_path_buf(),
                        start: parsed.analysis.bindings[binding].range.start,
                    }),
                }
            }
            Some(Export::Anonymous(range)) => {
                Some(Target::Declared { file: module.to_path_buf(), start: range.start })
            }
            Some(Export::Forwarded { specifier, name: forwarded }) => {
                match self.resolve(module, &specifier) {
                    Resolution::File(next) => self.export_target(&next, &forwarded, visited),
                    Resolution::Package(package) => Some(Target::Package {
                        package,
                        imported: if forwarded == "default" {
                            Imported::Default
                        } else {
                            Imported::Name(forwarded)
                        },
                    }),
                    Resolution::Unresolved => None,
                }
            }
            Some(Export::Namespace { specifier }) => match self.resolve(module, &specifier) {
                Resolution::File(next) => Some(Target::Module(next)),
                _ => None,
            },
            None if name != "default" => {
                for specifier in parsed.analysis.stars.clone() {
                    if let Resolution::File(next) = self.resolve(module, &specifier) {
                        if let Some(found) = self.export_target(&next, name, visited) {
                            return Some(found);
                        }
                    }
                }
                None
            }
            None => None,
        }
    }

    fn relative(&self, path: &Path) -> Option<String> {
        path.strip_prefix(&self.root).ok()?.to_str().map(str::to_string)
    }
}

/// Answers one `fs.references` request: resolve the name at `offset` in
/// `path` (relative to `root`), report it through `resolved`, then stream
/// every reference through `emit`.
///
/// `text` is the clicked file's unsaved content, when the client has edits the
/// disk has not seen; `offset` is a byte offset into whichever text is current.
#[allow(clippy::too_many_arguments)]
pub fn references(
    root: &Path,
    path: &str,
    offset: usize,
    text: Option<String>,
    filter: Option<Arc<SearchFilter>>,
    limit: u64,
    cancel: &AtomicBool,
    resolved: &mut dyn FnMut(Resolved),
    emit: &mut dyn FnMut(Vec<SearchMatch>),
) -> Result<SearchOutcome, String> {
    let clicked = confined(root, path)?;
    let mut workspace = Workspace {
        root: root.to_path_buf(),
        resolver: Resolver::new(root),
        parsed: HashMap::new(),
        overlay: text.map(|text| (clicked.clone(), text)),
    };
    let source = workspace
        .source(&clicked)
        .ok_or_else(|| format!("{path} is not a text file this host can read"))?;
    if offset > source.len() {
        return Err(format!("offset {offset} is past the end of {path}"));
    }

    let (target, name, at_definition) = match workspace.parsed(&clicked) {
        Some(parsed) => click_target(&mut workspace, &clicked, &parsed, offset),
        None => {
            let name = word_at(&source, offset).ok_or("there is no name at that position")?;
            (Target::Name(name.clone()), name, false)
        }
    };

    let mut report = Report::new(limit);
    let definitions = definitions_of(&mut workspace, &target);
    resolved(Resolved {
        name: name.clone(),
        kind: match &target {
            Target::Declared { .. } => "export",
            Target::Local { .. } => "local",
            Target::Package { .. } => "package",
            Target::Module(_) => "module",
            Target::Name(_) => "name",
        },
        definitions,
        at_definition,
        note: note_for(&mut workspace, &target, &name),
    });

    match &target {
        Target::Module(_) => {}
        Target::Local { file, start } => {
            let file = file.clone();
            classify_local(&mut workspace, &mut report, &file, *start);
        }
        Target::Name(_) => {
            scan_names(&mut workspace, &mut report, &clicked, &name, filter, cancel);
        }
        Target::Declared { .. } | Target::Package { .. } => {
            scan_symbol(&mut workspace, &mut report, &target, &name, filter, cancel);
        }
    }
    Ok(report.finish(cancel, emit))
}

/// `path` under `root`, refusing anything that would step outside it.
fn confined(root: &Path, path: &str) -> Result<PathBuf, String> {
    let joined = modules::normalize(&root.join(path));
    if !joined.starts_with(root) {
        return Err(format!("{path} is outside the workspace root"));
    }
    Ok(joined)
}

/// The identifier around `offset`, for a file no grammar reads.
fn word_at(source: &str, offset: usize) -> Option<String> {
    let bytes = source.as_bytes();
    let is_word = |at: usize| bytes.get(at).is_some_and(|byte| is_word_byte(*byte));
    let mut start = offset;
    if !is_word(start) && start > 0 && is_word(start - 1) {
        start -= 1;
    }
    if !is_word(start) {
        return None;
    }
    while start > 0 && is_word(start - 1) {
        start -= 1;
    }
    let mut end = start;
    while is_word(end) {
        end += 1;
    }
    let word = source.get(start..end)?;
    (!word.is_empty() && !word.as_bytes()[0].is_ascii_digit()).then(|| word.to_string())
}

fn is_word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'$' || byte >= 0x80
}

fn click_target(
    workspace: &mut Workspace,
    file: &Path,
    parsed: &Parsed,
    offset: usize,
) -> (Target, String, bool) {
    let analysis = &parsed.analysis;
    if let Some(specifier) = analysis.specifier_at(offset) {
        let target = match workspace.resolve(file, specifier) {
            Resolution::File(module) => Target::Module(module),
            Resolution::Package(package) => {
                Target::Package { package, imported: Imported::Namespace }
            }
            Resolution::Unresolved => Target::Name(specifier.to_string()),
        };
        return (target, specifier.to_string(), false);
    }
    let Some(reference) = analysis.reference_at(offset).cloned() else {
        let name = word_at(&parsed.source, offset).unwrap_or_default();
        return (Target::Name(name.clone()), name, false);
    };
    let name = parsed.source[reference.range.clone()].to_string();
    let fallback = || Target::Name(name.clone());
    let target = match reference.role {
        Role::Member => match reference.binding.and_then(|b| workspace.binding_target(file, b)) {
            Some(Target::Module(module)) => {
                workspace.export_target(&module, &name, &mut HashSet::new()).unwrap_or_else(fallback)
            }
            _ => fallback(),
        },
        Role::MemberDeclaration => fallback(),
        Role::Forward => {
            let forwarded = analysis.exports.values().find_map(|export| match export {
                Export::Forwarded { specifier, name: forwarded } if *forwarded == name => {
                    Some(specifier.clone())
                }
                _ => None,
            });
            match forwarded.map(|specifier| workspace.resolve(file, &specifier)) {
                Some(Resolution::File(module)) => {
                    workspace.export_target(&module, &name, &mut HashSet::new()).unwrap_or_else(fallback)
                }
                _ => fallback(),
            }
        }
        Role::Declaration | Role::Import | Role::Read => match reference.binding {
            Some(binding) => workspace.binding_target(file, binding).unwrap_or_else(fallback),
            None => fallback(),
        },
    };
    let at_definition = reference.role == Role::Declaration
        && matches!(&target, Target::Declared { file: defined, start } | Target::Local { file: defined, start }
            if defined == file && *start == reference.range.start);
    (target, name, at_definition)
}

/// Where the target is defined, as excerpts.
fn definitions_of(workspace: &mut Workspace, target: &Target) -> Vec<SearchMatch> {
    match target {
        Target::Declared { file, start } | Target::Local { file, start } => {
            let Some(parsed) = workspace.parsed(file) else { return Vec::new() };
            let Some(relative) = workspace.relative(file) else { return Vec::new() };
            let end = parsed
                .analysis
                .references
                .iter()
                .find(|reference| reference.range.start == *start)
                .map(|reference| reference.range.end)
                .unwrap_or(*start);
            vec![excerpt(&relative, &parsed.source, &[*start..end], kind::DEFINITION)]
        }
        Target::Module(module) => {
            let Some(relative) = workspace.relative(module) else { return Vec::new() };
            let source = workspace.source(module).unwrap_or_default();
            vec![excerpt(&relative, &source, &[0..0], kind::DEFINITION)]
        }
        Target::Package { .. } | Target::Name(_) => Vec::new(),
    }
}

/// What a client should say beside the definition: where a package symbol
/// comes from, or which framework reads an export nothing in the tree imports.
fn note_for(workspace: &mut Workspace, target: &Target, name: &str) -> Option<String> {
    match target {
        Target::Package { package, .. } => Some(format!("From package {package}")),
        Target::Declared { file, start } => {
            let relative = workspace.relative(file)?;
            let parsed = workspace.parsed(file)?;
            let binding = parsed.analysis.bindings.iter().position(|b| b.range.start == *start);
            let mut exports = binding.map(|b| parsed.analysis.export_names(b)).unwrap_or_default();
            if matches!(parsed.analysis.exports.get("default"), Some(Export::Anonymous(range)) if range.start == *start) {
                exports.push("default".into());
            }
            if exports.is_empty() {
                exports.push(name.to_string());
            }
            framework_note(&relative, &exports)
        }
        _ => None,
    }
}

/// Exports a framework reads by convention, so "no usages" does not read as
/// "dead code". Deliberately a short, explicit table: Next.js's App Router
/// files and their documented exports.
fn framework_note(relative: &str, exports: &[String]) -> Option<String> {
    let file = relative.rsplit('/').next()?;
    let stem = file.split('.').next()?;
    let in_app = relative.starts_with("app/") || relative.contains("/app/");
    let in_pages = relative.starts_with("pages/") || relative.contains("/pages/");
    const APP_FILES: &[&str] = &[
        "page", "layout", "template", "default", "loading", "error", "not-found", "global-error",
        "route", "opengraph-image", "twitter-image", "icon", "apple-icon", "sitemap", "robots",
        "manifest",
    ];
    const APP_EXPORTS: &[&str] = &[
        "default", "metadata", "generateMetadata", "viewport", "generateViewport",
        "generateStaticParams", "generateImageMetadata", "generateSitemaps", "revalidate", "dynamic",
        "dynamicParams", "fetchCache", "runtime", "preferredRegion", "maxDuration", "alt", "size",
        "contentType", "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS",
    ];
    const PAGES_EXPORTS: &[&str] =
        &["default", "getStaticProps", "getStaticPaths", "getServerSideProps", "config"];
    let read = (in_app && APP_FILES.contains(&stem) && exports.iter().any(|e| APP_EXPORTS.contains(&e.as_str())))
        || (in_pages && exports.iter().any(|e| PAGES_EXPORTS.contains(&e.as_str())))
        || (matches!(stem, "middleware" | "instrumentation")
            && exports.iter().any(|e| matches!(e.as_str(), "default" | "middleware" | "config" | "register")));
    read.then(|| "Read by Next.js".to_string())
}

/// Hits gathered for one request, emitted sorted once the reading is done:
/// definitions, then usages, imports and re-exports, then the rest.
struct Report {
    limit: u64,
    hits: Vec<(String, usize, Vec<std::ops::Range<usize>>, &'static str, Rc<str>)>,
    /// (file, byte offset) already reported, so one occurrence is one hit.
    seen: HashSet<(String, usize)>,
    count: u64,
    limit_hit: bool,
}

impl Report {
    fn new(limit: u64) -> Report {
        Report { limit, hits: Vec::new(), seen: HashSet::new(), count: 0, limit_hit: false }
    }

    fn full(&self) -> bool {
        self.limit_hit
    }

    /// Records one occurrence. Returns false once the limit is reached.
    fn add(&mut self, relative: &str, source: &Rc<str>, range: std::ops::Range<usize>, kind: &'static str) -> bool {
        if !self.seen.insert((relative.to_string(), range.start)) {
            return true;
        }
        if self.count >= self.limit {
            self.limit_hit = true;
            return false;
        }
        self.count += 1;
        let line_start = source[..range.start].rfind('\n').map_or(0, |at| at + 1);
        self.hits.push((relative.to_string(), line_start, vec![range], kind, source.clone()));
        true
    }

    fn finish(mut self, cancel: &AtomicBool, emit: &mut dyn FnMut(Vec<SearchMatch>)) -> SearchOutcome {
        if cancel.load(Ordering::Relaxed) {
            return SearchOutcome { matches: 0, limit_hit: false, canceled: true };
        }
        // One row per line and kind: two usages on a line are one row with two
        // spans, as `fs.search` reports them.
        self.hits.sort_by(|a, b| {
            (kind_rank(a.3), &a.0, a.1, a.2[0].start).cmp(&(kind_rank(b.3), &b.0, b.1, b.2[0].start))
        });
        let mut merged: Vec<(String, usize, Vec<std::ops::Range<usize>>, &'static str, Rc<str>)> = Vec::new();
        for hit in self.hits {
            if let Some(last) = merged.last_mut() {
                if last.0 == hit.0 && last.1 == hit.1 && last.3 == hit.3 {
                    last.2.extend(hit.2);
                    continue;
                }
            }
            merged.push(hit);
        }
        let matches: Vec<SearchMatch> = merged
            .iter()
            .map(|(relative, _, spans, kind, source)| excerpt(relative, source, spans, kind))
            .collect();
        let total = self.count;
        for batch in matches.chunks(crate::files::SEARCH_BATCH) {
            emit(batch.to_vec());
        }
        SearchOutcome { matches: total, limit_hit: self.limit_hit, canceled: false }
    }
}

/// A hit as the wire carries it: the line holding `spans` (all on one line),
/// windowed if long, with its context.
fn excerpt(relative: &str, source: &str, spans: &[std::ops::Range<usize>], kind: &str) -> SearchMatch {
    let first = spans.first().map_or(0, |span| span.start).min(source.len());
    let line_start = source[..first].rfind('\n').map_or(0, |at| at + 1);
    let line_end = source[first..].find('\n').map_or(source.len(), |at| first + at);
    let line_text = source[line_start..line_end].trim_end_matches('\r');
    let line = source[..line_start].matches('\n').count() as u64 + 1;
    let (offset, text) = crate::files::window(line_text, first - line_start);
    let spans = spans
        .iter()
        .filter(|span| span.start >= line_start && span.end <= line_start + line_text.len())
        .map(|span| (span.start - line_start, span.end - line_start))
        .filter(|(start, end)| *start >= offset && *end <= offset + text.len())
        .map(|(start, end)| [(start - offset) as u32, (end - offset) as u32])
        .collect();
    let lines: Vec<&str> = source.split('\n').map(|line| line.trim_end_matches('\r')).collect();
    let index = (line - 1) as usize;
    let before = lines[index.saturating_sub(SEARCH_CONTEXT_LINES)..index]
        .iter()
        .map(|line| line.to_string())
        .collect();
    let after = lines
        .get(index + 1..(index + 1 + SEARCH_CONTEXT_LINES).min(lines.len()))
        .unwrap_or_default()
        .iter()
        .map(|line| line.to_string())
        .collect();
    SearchMatch {
        path: relative.to_string(),
        line,
        text,
        text_offset: offset as u64,
        spans,
        before,
        after,
        kind: Some(kind.to_string()),
    }
}

fn classify_local(workspace: &mut Workspace, report: &mut Report, file: &Path, start: usize) {
    let (Some(parsed), Some(relative)) = (workspace.parsed(file), workspace.relative(file)) else {
        return;
    };
    let Some(binding) = parsed.analysis.bindings.iter().position(|b| b.range.start == start) else {
        return;
    };
    let source: Rc<str> = Rc::from(parsed.source.as_str());
    for reference in &parsed.analysis.references {
        if reference.binding != Some(binding) || reference.role == Role::Member {
            continue;
        }
        if reference.range.start == start {
            continue;
        }
        if !report.add(&relative, &source, reference.range.clone(), kind::USAGE) {
            return;
        }
    }
}

/// Whole-word occurrences of any of `finder`'s patterns in `text`, as
/// (start, end, pattern index).
fn whole_words(finder: &aho_corasick::AhoCorasick, text: &[u8]) -> Vec<(usize, usize, usize)> {
    finder
        .find_overlapping_iter(text)
        .filter(|found| {
            let before = found.start().checked_sub(1).map(|at| text[at]);
            let after = text.get(found.end()).copied();
            !before.is_some_and(is_word_byte) && !after.is_some_and(is_word_byte)
        })
        .map(|found| (found.start(), found.end(), found.pattern().as_usize()))
        .collect()
}

/// What an importer of `path`'s default export must contain: the module's
/// name as the last segment of a specifier (`"./site-nav"`, `'@/lib/nav.js'`).
/// A default export is imported under any name at all, so the module path is
/// the only word its importers are sure to share — and only as a path
/// segment: as a bare word, `page` or `layout` is in every file of a Next.js
/// app, and every one of them would be parsed for nothing. An `index` file is
/// imported by its directory's name.
fn specifier_needles(path: &Path) -> Vec<String> {
    let stem = (|| {
        let file = path.file_name()?.to_str()?;
        let stem = file.split('.').next()?;
        if stem == "index" {
            return path.parent()?.file_name()?.to_str().map(str::to_string);
        }
        Some(stem.to_string())
    })();
    let Some(stem) = stem else { return Vec::new() };
    ["\"", "'", ".", "`"].iter().map(|end| format!("/{stem}{end}")).collect()
}

/// The declared or package symbol's references across the tree.
///
/// Rounds of: whole-word scan for the terms known so far → parse the files
/// that hit → classify. A file that re-exports the symbol under another name,
/// or as a default, adds the words its importers would use, and the next
/// round finds them. Most symbols settle in one round.
fn scan_symbol(
    workspace: &mut Workspace,
    report: &mut Report,
    target: &Target,
    name: &str,
    filter: Option<Arc<SearchFilter>>,
    cancel: &AtomicBool,
) {
    let files: Vec<(String, PathBuf)> = crate::files::text_files(&workspace.root, filter)
        .filter(|(relative, _)| javascript::language_for(relative).is_some())
        .collect();
    let mut terms: Vec<String> = vec![name.to_string()];
    let mut needles: Vec<String> = Vec::new();
    // The name the symbol is declared under, which is what "the same text,
    // something else" means — not the alias the click happened to land on.
    let mut canonical = name.to_string();
    if let Target::Package { imported: Imported::Name(imported), .. } = target {
        terms.push(imported.clone());
        canonical = imported.clone();
    }
    if let Target::Declared { file, start } = target {
        // The definition file names the symbol however it exports it.
        if let Some(parsed) = workspace.parsed(file) {
            if let Some(binding) = parsed.analysis.bindings.iter().position(|b| b.range.start == *start) {
                canonical = parsed.analysis.bindings[binding].name.clone();
                terms.push(canonical.clone());
                for exported in parsed.analysis.export_names(binding) {
                    terms.push(exported);
                }
            }
            if terms.iter().any(|term| term == "default")
                || matches!(parsed.analysis.exports.get("default"), Some(Export::Anonymous(range)) if range.start == *start)
            {
                needles.extend(specifier_needles(file));
            }
        }
    }
    terms.retain(|term| term != "default" && !term.is_empty());
    let mut searched: BTreeSet<String> = BTreeSet::new();
    let mut searched_needles: BTreeSet<String> = BTreeSet::new();
    let mut classified: HashSet<PathBuf> = HashSet::new();

    loop {
        let fresh: Vec<String> = terms.iter().filter(|term| !searched.contains(*term)).cloned().collect();
        let fresh_needles: Vec<String> =
            needles.iter().filter(|needle| !searched_needles.contains(*needle)).cloned().collect();
        if (fresh.is_empty() && fresh_needles.is_empty()) || report.full() {
            break;
        }
        searched.extend(fresh.iter().cloned());
        searched_needles.extend(fresh_needles.iter().cloned());
        let Ok(finder) = aho_corasick::AhoCorasick::new(&fresh) else { break };
        let Ok(path_finder) = aho_corasick::AhoCorasick::new(&fresh_needles) else { break };
        for (relative, path) in &files {
            if cancel.load(Ordering::Relaxed) || report.full() {
                return;
            }
            if classified.contains(path) {
                continue;
            }
            // Read, then scanned as bytes; only a file that mentions a term is
            // ever parsed.
            let Some(source) = workspace.source(path) else { continue };
            let mentions = !whole_words(&finder, source.as_bytes()).is_empty()
                || (!fresh_needles.is_empty() && path_finder.is_match(source.as_bytes()));
            if !mentions {
                continue;
            }
            let Some(parsed) = workspace.parse_source(path, Some(source)) else { continue };
            classified.insert(path.clone());
            let (forwarded, forwarded_needles) =
                classify_file(workspace, report, target, &canonical, relative, path, &parsed);
            for term in forwarded {
                if !terms.contains(&term) {
                    terms.push(term);
                }
            }
            for needle in forwarded_needles {
                if !needles.contains(&needle) {
                    needles.push(needle);
                }
            }
        }
    }
}

/// Classifies every occurrence of the symbol in one file and returns what a
/// further round should look for: the names this file re-exports it under,
/// and — when it re-exports it as a default — the specifier needles that find
/// this file's importers.
fn classify_file(
    workspace: &mut Workspace,
    report: &mut Report,
    target: &Target,
    name: &str,
    relative: &str,
    path: &Path,
    parsed: &Parsed,
) -> (Vec<String>, Vec<String>) {
    let analysis = &parsed.analysis;
    let source: Rc<str> = Rc::from(parsed.source.as_str());
    let mut forwarded = Vec::new();
    let mut needles = Vec::new();

    // Which bindings of this file are the symbol — decided per binding, not per
    // occurrence, so an aliased import (`import { a as b }`) is found by `b`
    // even though `b` was never searched for.
    let mut matching: HashSet<usize> = HashSet::new();
    let mut namespaces: HashSet<usize> = HashSet::new();
    for (index, binding) in analysis.bindings.iter().enumerate() {
        let candidate = match &binding.kind {
            BindingKind::Declaration => {
                matches!(target, Target::Declared { file, start } if file == path && *start == binding.range.start)
            }
            BindingKind::Import { .. } => {
                let names = workspace.binding_target(path, index);
                // `ns.name` is the symbol when `ns` is the module that exports
                // it; the member decides, so remember the namespace.
                if let Some(Target::Module(_)) = names {
                    namespaces.insert(index);
                }
                names.as_ref() == Some(target)
            }
        };
        if candidate {
            matching.insert(index);
        }
    }

    let mut covered: HashSet<usize> = HashSet::new();
    for reference in &analysis.references {
        let text = &parsed.source[reference.range.clone()];
        let hit_kind = match reference.role {
            Role::Member => {
                let through_namespace = reference.binding.is_some_and(|b| namespaces.contains(&b));
                if !through_namespace {
                    continue;
                }
                let module = reference.binding.and_then(|b| workspace.binding_target(path, b));
                let Some(Target::Module(module)) = module else { continue };
                if workspace.export_target(&module, text, &mut HashSet::new()).as_ref() != Some(target) {
                    continue;
                }
                kind::USAGE
            }
            Role::Forward => {
                let specifier = analysis.exports.values().find_map(|export| match export {
                    Export::Forwarded { specifier, name } if name == text => Some(specifier.clone()),
                    _ => None,
                });
                let Some(Resolution::File(module)) = specifier.map(|s| workspace.resolve(path, &s)) else {
                    continue;
                };
                if workspace.export_target(&module, text, &mut HashSet::new()).as_ref() != Some(target) {
                    continue;
                }
                kind::REEXPORT
            }
            Role::MemberDeclaration => continue,
            Role::Declaration | Role::Import | Role::Read => {
                let Some(binding) = reference.binding else { continue };
                if !matching.contains(&binding) {
                    continue;
                }
                match (reference.role, &analysis.bindings[binding].kind) {
                    (Role::Import, _) | (Role::Declaration, BindingKind::Import { .. }) => kind::IMPORT,
                    // The definition is reported once, up front.
                    (Role::Declaration, BindingKind::Declaration) => {
                        covered.insert(reference.range.start);
                        continue;
                    }
                    _ => kind::USAGE,
                }
            }
        };
        covered.insert(reference.range.start);
        if !report.add(relative, &source, reference.range.clone(), hit_kind) {
            return (forwarded, needles);
        }
    }

    // Names this file hands the symbol on under.
    for (exported, export) in &analysis.exports {
        let hands_on = match export {
            Export::Local(local) => analysis.top_level(local).is_some_and(|b| matching.contains(&b)),
            Export::Forwarded { .. } | Export::Namespace { .. } => {
                workspace.export_target(path, exported, &mut HashSet::new()).as_ref() == Some(target)
            }
            Export::Anonymous(_) => false,
        };
        // `default` is a keyword, never a name an importer writes: its
        // importers are found by this module's path instead.
        if hands_on && exported == "default" {
            needles.extend(specifier_needles(path));
        } else if hands_on {
            forwarded.push(exported.clone());
        }
    }

    // The same word anywhere else in the file is something else: another
    // declaration of the name, a member, prose in a string or a comment.
    if let Ok(finder) = aho_corasick::AhoCorasick::new([name]) {
        for (start, end, _) in whole_words(&finder, parsed.source.as_bytes()) {
            if covered.contains(&start) {
                continue;
            }
            if !report.add(relative, &source, start..end, kind::UNRELATED) {
                break;
            }
        }
    }
    (forwarded, needles)
}

/// Whole-word matches of `name` in files of the clicked file's kind, for a
/// name nothing could resolve. In files a grammar reads, the code-or-prose
/// split still holds: an occurrence in a string or a comment is unrelated.
fn scan_names(
    workspace: &mut Workspace,
    report: &mut Report,
    clicked: &Path,
    name: &str,
    filter: Option<Arc<SearchFilter>>,
    cancel: &AtomicBool,
) {
    if name.is_empty() {
        return;
    }
    let family = extension_family(clicked);
    let Ok(finder) = aho_corasick::AhoCorasick::new([name]) else { return };
    let definition = regex::Regex::new(&format!(
        r"\b(?:func|fn|function|def|class|struct|enum|protocol|actor|trait|interface|type|typealias|impl|extension|let|var|const|case|static)\s+{}\b",
        regex::escape(name)
    ))
    .ok();
    let files: Vec<(String, PathBuf)> = crate::files::text_files(&workspace.root, filter)
        .filter(|(_, path)| extension_family(path) == family)
        .collect();
    let mut definitions = 0;
    for (relative, path) in files {
        if cancel.load(Ordering::Relaxed) || report.full() {
            return;
        }
        let Some(text) = workspace.source(&path) else { continue };
        let hits = whole_words(&finder, text.as_bytes());
        if hits.is_empty() {
            continue;
        }
        if javascript::language_for(&relative).is_some() {
            let Some(parsed) = workspace.parse_source(&path, Some(text)) else { continue };
            let source: Rc<str> = Rc::from(parsed.source.as_str());
            let code: HashMap<usize, Role> = parsed
                .analysis
                .references
                .iter()
                .map(|reference| (reference.range.start, reference.role))
                .collect();
            for (start, end, _) in hits {
                let hit_kind = match code.get(&start) {
                    Some(Role::Declaration | Role::MemberDeclaration) if definitions < NAME_DEFINITION_LIMIT => {
                        definitions += 1;
                        kind::DEFINITION
                    }
                    Some(_) => kind::MATCH,
                    None => kind::UNRELATED,
                };
                if !report.add(&relative, &source, start..end, hit_kind) {
                    return;
                }
            }
            continue;
        }
        let source: Rc<str> = Rc::from(text.as_str());
        let declared: HashSet<usize> = definition
            .as_ref()
            .map(|pattern| {
                pattern
                    .find_iter(&text)
                    .map(|found| found.end() - name.len())
                    .collect()
            })
            .unwrap_or_default();
        for (start, end, _) in hits {
            let hit_kind = if declared.contains(&start) && definitions < NAME_DEFINITION_LIMIT {
                definitions += 1;
                kind::DEFINITION
            } else {
                kind::MATCH
            };
            if !report.add(&relative, &source, start..end, hit_kind) {
                return;
            }
        }
    }
}

/// Files that can mention each other's names: one language, by extension.
fn extension_family(path: &Path) -> String {
    let extension = path.extension().and_then(|e| e.to_str()).unwrap_or_default().to_ascii_lowercase();
    match extension.as_str() {
        "ts" | "tsx" | "mts" | "cts" | "js" | "jsx" | "mjs" | "cjs" => "javascript".into(),
        "c" | "h" | "cc" | "cpp" | "cxx" | "hpp" | "hh" | "m" | "mm" => "c".into(),
        _ => extension,
    }
}

#[cfg(test)]
mod tests;
