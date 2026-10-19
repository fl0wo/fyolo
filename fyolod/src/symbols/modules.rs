//! Where a TypeScript or JavaScript module specifier points, read the way the
//! TypeScript compiler's `bundler` resolution reads it: relative paths, the
//! nearest `tsconfig.json`/`jsconfig.json`'s `paths` and `baseUrl` (through
//! `extends`), extension and `index` probing, and the `.js`-names-a-`.ts`-file
//! convention of ESM TypeScript.
//!
//! Anything else is a package. Packages are named, never followed: the walk
//! that finds references does not read `node_modules`, so a definition there is
//! reported as "from package X" rather than opened.

use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Resolution {
    File(PathBuf),
    /// A bare specifier: the package name, without any subpath.
    Package(String),
    Unresolved,
}

const EXTENSIONS: &[&str] = &["ts", "tsx", "d.ts", "js", "jsx", "mts", "cts", "mjs", "cjs"];

#[derive(Debug, Clone, Default)]
struct Config {
    base_url: Option<PathBuf>,
    /// Pattern → substitutions, already absolute.
    paths: Vec<(String, Vec<String>)>,
    paths_base: Option<PathBuf>,
}

/// Resolves specifiers under one root, caching the config each directory sees.
pub(crate) struct Resolver {
    root: PathBuf,
    configs: HashMap<PathBuf, Option<Config>>,
    resolved: HashMap<(PathBuf, String), Resolution>,
}

impl Resolver {
    pub fn new(root: &Path) -> Resolver {
        Resolver { root: root.to_path_buf(), configs: HashMap::new(), resolved: HashMap::new() }
    }

    pub fn resolve(&mut self, importer: &Path, specifier: &str) -> Resolution {
        let directory = importer.parent().unwrap_or(&self.root).to_path_buf();
        let key = (directory.clone(), specifier.to_string());
        if let Some(found) = self.resolved.get(&key) {
            return found.clone();
        }
        let found = self.resolve_uncached(&directory, specifier);
        self.resolved.insert(key, found.clone());
        found
    }

    fn resolve_uncached(&mut self, directory: &Path, specifier: &str) -> Resolution {
        if specifier.starts_with("./") || specifier.starts_with("../") || specifier == "." || specifier == ".." {
            return probe(&normalize(&directory.join(specifier)))
                .map(Resolution::File)
                .unwrap_or(Resolution::Unresolved);
        }
        if specifier.starts_with('/') {
            return probe(Path::new(specifier)).map(Resolution::File).unwrap_or(Resolution::Unresolved);
        }
        if let Some(config) = self.config_for(directory) {
            if let Some(found) = resolve_with_paths(&config, specifier) {
                return Resolution::File(found);
            }
            if let Some(base) = &config.base_url {
                if let Some(found) = probe(&normalize(&base.join(specifier))) {
                    return Resolution::File(found);
                }
            }
        }
        Resolution::Package(package_name(specifier))
    }

    /// The config governing files in `directory`: the nearest
    /// `tsconfig.json` or `jsconfig.json` at or above it, stopping at the root.
    fn config_for(&mut self, directory: &Path) -> Option<Config> {
        if let Some(cached) = self.configs.get(directory) {
            return cached.clone();
        }
        let mut found = None;
        for name in ["tsconfig.json", "jsconfig.json"] {
            let candidate = directory.join(name);
            if candidate.is_file() {
                found = load_config(&candidate, 0);
                break;
            }
        }
        if found.is_none() && directory != self.root && directory.starts_with(&self.root) {
            if let Some(parent) = directory.parent() {
                found = self.config_for(&parent.to_path_buf());
            }
        }
        self.configs.insert(directory.to_path_buf(), found.clone());
        found
    }
}

/// `@scope/name/sub` → `@scope/name`; `name/sub` → `name`.
fn package_name(specifier: &str) -> String {
    let mut parts = specifier.split('/');
    let first = parts.next().unwrap_or_default();
    if first.starts_with('@') {
        match parts.next() {
            Some(second) => format!("{first}/{second}"),
            None => first.to_string(),
        }
    } else {
        first.to_string()
    }
}

fn resolve_with_paths(config: &Config, specifier: &str) -> Option<PathBuf> {
    let base = config.paths_base.as_ref()?;
    // TypeScript picks the pattern with the longest prefix before its `*`.
    let mut best: Option<(usize, &str, &Vec<String>)> = None;
    for (pattern, targets) in &config.paths {
        let captured = match pattern.split_once('*') {
            Some((prefix, suffix)) => {
                if specifier.len() >= prefix.len() + suffix.len()
                    && specifier.starts_with(prefix)
                    && specifier.ends_with(suffix)
                {
                    Some((prefix.len(), &specifier[prefix.len()..specifier.len() - suffix.len()]))
                } else {
                    None
                }
            }
            None if pattern == specifier => Some((usize::MAX, "")),
            None => None,
        };
        if let Some((weight, star)) = captured {
            if best.is_none_or(|(current, _, _)| weight > current) {
                best = Some((weight, star, targets));
            }
        }
    }
    let (_, star, targets) = best?;
    targets.iter().find_map(|target| probe(&normalize(&base.join(target.replacen('*', star, 1)))))
}

fn load_config(path: &Path, depth: usize) -> Option<Config> {
    // A cycle of `extends` is a broken config, not a reason to spin.
    if depth > 8 {
        return None;
    }
    let text = std::fs::read_to_string(path).ok()?;
    let value: serde_json::Value = serde_json::from_str(&strip_json_comments(&text)).ok()?;
    let directory = path.parent()?.to_path_buf();
    let mut config = Config::default();
    let extends: Vec<String> = match value.get("extends") {
        Some(serde_json::Value::String(single)) => vec![single.clone()],
        Some(serde_json::Value::Array(many)) => {
            many.iter().filter_map(|item| item.as_str().map(str::to_string)).collect()
        }
        _ => Vec::new(),
    };
    // Later entries win; only a relative parent can be read here — a package
    // config lives in `node_modules`, and only sets compiler flags in practice.
    for parent in extends {
        if !(parent.starts_with("./") || parent.starts_with("../")) {
            continue;
        }
        // `"./tsconfig.base"` names `tsconfig.base.json`: the suffix is
        // appended, never swapped for whatever follows the last dot.
        let mut candidate = normalize(&directory.join(&parent));
        if !parent.ends_with(".json") {
            candidate = PathBuf::from(format!("{}.json", candidate.display()));
        }
        if let Some(inherited) = load_config(&candidate, depth + 1) {
            if inherited.base_url.is_some() {
                config.base_url = inherited.base_url;
            }
            if !inherited.paths.is_empty() {
                config.paths = inherited.paths;
                config.paths_base = inherited.paths_base;
            }
        }
    }
    let options = value.get("compilerOptions");
    if let Some(base) = options.and_then(|options| options.get("baseUrl")).and_then(|v| v.as_str()) {
        config.base_url = Some(normalize(&directory.join(base)));
    }
    if let Some(paths) = options.and_then(|options| options.get("paths")).and_then(|v| v.as_object()) {
        config.paths = paths
            .iter()
            .map(|(pattern, targets)| {
                let targets = targets
                    .as_array()
                    .map(|items| items.iter().filter_map(|item| item.as_str().map(str::to_string)).collect())
                    .unwrap_or_default();
                (pattern.clone(), targets)
            })
            .collect();
        config.paths_base = None;
    }
    // `paths` are relative to `baseUrl` when one is set, else to the config
    // that declared them.
    if !config.paths.is_empty() && config.paths_base.is_none() {
        config.paths_base = Some(config.base_url.clone().unwrap_or(directory));
    }
    Some(config)
}

/// `tsconfig.json` is JSON with comments and trailing commas.
fn strip_json_comments(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    let mut in_string = false;
    while index < bytes.len() {
        let byte = bytes[index];
        if in_string {
            out.push(byte as char);
            if byte == b'\\' && index + 1 < bytes.len() {
                out.push(bytes[index + 1] as char);
                index += 2;
                continue;
            }
            if byte == b'"' {
                in_string = false;
            }
            index += 1;
            continue;
        }
        match byte {
            b'"' => {
                in_string = true;
                out.push('"');
                index += 1;
            }
            b'/' if bytes.get(index + 1) == Some(&b'/') => {
                while index < bytes.len() && bytes[index] != b'\n' {
                    index += 1;
                }
            }
            b'/' if bytes.get(index + 1) == Some(&b'*') => {
                index += 2;
                while index + 1 < bytes.len() && !(bytes[index] == b'*' && bytes[index + 1] == b'/') {
                    index += 1;
                }
                index += 2;
            }
            b',' => {
                let rest = text[index + 1..].trim_start();
                let next = rest.chars().next();
                if !matches!(next, Some('}') | Some(']')) {
                    out.push(',');
                }
                index += 1;
            }
            _ => {
                // Copy the whole character, not a byte reinterpreted as one.
                let character = text[index..].chars().next().unwrap_or(' ');
                out.push(character);
                index += character.len_utf8();
            }
        }
    }
    out
}

/// The file a module path names, trying it as written, with each extension,
/// as `.js`-for-`.ts`, and as a directory's `index`.
fn probe(base: &Path) -> Option<PathBuf> {
    if base.is_file() {
        return Some(base.to_path_buf());
    }
    let text = base.to_string_lossy();
    for extension in EXTENSIONS {
        let candidate = PathBuf::from(format!("{text}.{extension}"));
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    for (written, sources) in [("js", &["ts", "tsx"][..]), ("jsx", &["tsx"][..]), ("mjs", &["mts"][..]), ("cjs", &["cts"][..])] {
        if let Some(stem) = text.strip_suffix(&format!(".{written}")) {
            for source in sources {
                let candidate = PathBuf::from(format!("{stem}.{source}"));
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
    }
    if base.is_dir() {
        for extension in EXTENSIONS {
            let candidate = base.join(format!("index.{extension}"));
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Lexical `.`/`..` folding: a specifier names a path, and symlinks are the
/// walk's business, not the resolver's.
pub(crate) fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::symbols::tests::tree;

    #[test]
    fn relative_index_and_extension_probing() {
        let directory = tree(&[("src/a.ts", ""), ("src/lib/index.tsx", ""), ("src/esm.ts", "")]);
        let root = &directory.path().canonicalize().unwrap();
        let mut resolver = Resolver::new(root);
        let importer = root.join("src/a.ts");
        assert_eq!(resolver.resolve(&importer, "./lib"), Resolution::File(root.join("src/lib/index.tsx")));
        assert_eq!(resolver.resolve(&importer, "./esm.js"), Resolution::File(root.join("src/esm.ts")));
        assert_eq!(resolver.resolve(&importer, "./missing"), Resolution::Unresolved);
        assert_eq!(resolver.resolve(&importer, "@scope/pkg/sub"), Resolution::Package("@scope/pkg".into()));
    }

    #[test]
    fn tsconfig_paths_with_comments_and_extends() {
        let directory = tree(&[
            ("web/tsconfig.base.json", "{ \"compilerOptions\": { \"paths\": { \"@/*\": [\"./src/*\"], } } }"),
            ("web/tsconfig.json", "// top\n{ \"extends\": \"./tsconfig.base\", /* x */ \"compilerOptions\": {} }"),
            ("web/src/components/site-nav.tsx", ""),
            ("web/src/app/page.tsx", ""),
        ]);
        let root = &directory.path().canonicalize().unwrap();
        let mut resolver = Resolver::new(root);
        let importer = root.join("web/src/app/page.tsx");
        assert_eq!(
            resolver.resolve(&importer, "@/components/site-nav"),
            Resolution::File(root.join("web/src/components/site-nav.tsx"))
        );
        assert_eq!(resolver.resolve(&importer, "next"), Resolution::Package("next".into()));
    }
}
