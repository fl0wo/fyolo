//! What one TypeScript or JavaScript file says about its names: which scopes it
//! opens, what each declares, what it imports and exports, and which
//! declaration every identifier in it refers to.
//!
//! Syntax only — no types. That is enough for everything a name can be tied to
//! without a checker: lexical scopes, imports, exports and re-exports. A
//! property (`value.name`) is the one thing it cannot tie to a declaration,
//! since that takes knowing the type of `value`; those are reported as member
//! references for the caller to treat as name matches.
//!
//! The TypeScript grammar extends the JavaScript one, so one binder reads both:
//! the node kinds it relies on are shared, and the TypeScript-only ones simply
//! never occur in a `.js` tree.

use std::collections::HashMap;
use tree_sitter::{Node, Tree};

/// Which grammar reads a file, from its extension. `None` for a file this
/// binder does not understand.
pub(crate) fn language_for(path: &str) -> Option<tree_sitter::Language> {
    let extension = path.rsplit_once('.').map(|(_, extension)| extension)?;
    match extension {
        "ts" | "mts" | "cts" => Some(tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()),
        "tsx" => Some(tree_sitter_typescript::LANGUAGE_TSX.into()),
        "js" | "jsx" | "mjs" | "cjs" => Some(tree_sitter_javascript::LANGUAGE.into()),
        _ => None,
    }
}

pub(crate) fn parse(path: &str, source: &str) -> Option<Tree> {
    let language = language_for(path)?;
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&language).ok()?;
    parser.parse(source, None)
}

/// What an import binding brings in from its module.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub(crate) enum Imported {
    Name(String),
    Default,
    /// `import * as name` — the module object itself.
    Namespace,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum BindingKind {
    Declaration,
    Import { specifier: String, imported: Imported },
}

#[derive(Debug, Clone)]
pub(crate) struct Binding {
    pub name: String,
    /// The declaring identifier. Its start is the binding's identity in a file.
    pub range: std::ops::Range<usize>,
    pub kind: BindingKind,
}

/// How an export of this file is produced.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Export {
    /// A binding of this file, named as it is declared at the top level.
    Local(String),
    /// `export default <expression>` with no name of its own: the expression is
    /// the definition.
    Anonymous(std::ops::Range<usize>),
    /// `export { name as alias } from "specifier"`.
    Forwarded { specifier: String, name: String },
    /// `export * as alias from "specifier"`.
    Namespace { specifier: String },
}

/// What an identifier in the file is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Role {
    /// The identifier that declares its binding.
    Declaration,
    /// A name inside an import statement.
    Import,
    /// A name inside an `export … from` statement — it forwards, it has no
    /// binding here.
    Forward,
    /// Any other use of a binding, or of a name nothing in the file declares.
    Read,
    /// `object.name`, or `Namespace.Type`: the binding is the object's, when the
    /// object is a plain identifier.
    Member,
    /// A member's own declaration: a method, a field, an object key.
    MemberDeclaration,
}

#[derive(Debug, Clone)]
pub(crate) struct Reference {
    pub range: std::ops::Range<usize>,
    pub role: Role,
    /// The binding the name refers to. For `Member`, the binding of the object
    /// the member is read from.
    pub binding: Option<usize>,
}

/// One file, read for its names.
#[derive(Debug, Default)]
pub(crate) struct Analysis {
    pub bindings: Vec<Binding>,
    pub references: Vec<Reference>,
    /// Export name → how it is produced.
    pub exports: HashMap<String, Export>,
    /// `export * from` specifiers, in order.
    pub stars: Vec<String>,
    /// Every module specifier string in the file, as the range of its text
    /// inside the quotes, so a click on one can open the module it names.
    pub specifiers: Vec<(std::ops::Range<usize>, String)>,
    /// Top-level bindings by name.
    top_level: HashMap<String, usize>,
}

impl Analysis {
    pub fn top_level(&self, name: &str) -> Option<usize> {
        self.top_level.get(name).copied()
    }

    /// The identifier-like reference covering `offset`, if any.
    pub fn reference_at(&self, offset: usize) -> Option<&Reference> {
        // `end` is inclusive here so a click just past the last character —
        // where a caret lands after a double-click — still reads the name.
        self.references
            .iter()
            .find(|reference| reference.range.start <= offset && offset <= reference.range.end)
    }

    pub fn specifier_at(&self, offset: usize) -> Option<&str> {
        self.specifiers
            .iter()
            .find(|(range, _)| range.start <= offset && offset <= range.end)
            .map(|(_, specifier)| specifier.as_str())
    }

    /// Every export name that hands out `binding`.
    pub fn export_names(&self, binding: usize) -> Vec<String> {
        let mut names: Vec<String> = self
            .exports
            .iter()
            .filter(|(_, export)| match export {
                Export::Local(name) => self.top_level(name) == Some(binding),
                _ => false,
            })
            .map(|(name, _)| name.clone())
            .collect();
        names.sort();
        names
    }
}

const SCOPE_KINDS: &[&str] = &[
    "program",
    "statement_block",
    "function_declaration",
    "generator_function_declaration",
    "function_expression",
    "generator_function",
    "function",
    "arrow_function",
    "method_definition",
    "class_declaration",
    "abstract_class_declaration",
    "class",
    "interface_declaration",
    "type_alias_declaration",
    "for_statement",
    "for_in_statement",
    "catch_clause",
    "switch_body",
];

const FUNCTION_KINDS: &[&str] = &[
    "program",
    "function_declaration",
    "generator_function_declaration",
    "function_expression",
    "generator_function",
    "function",
    "arrow_function",
    "method_definition",
];

struct Scope {
    parent: Option<usize>,
    is_function: bool,
    names: HashMap<String, usize>,
}

pub(crate) fn analyze(tree: &Tree, source: &str) -> Analysis {
    let mut binder = Binder {
        source: source.as_bytes(),
        analysis: Analysis::default(),
        scopes: Vec::new(),
        declared_at: HashMap::new(),
    };
    binder.declare(tree.root_node());
    binder.resolve(tree.root_node());
    binder.analysis
}

struct Binder<'a> {
    source: &'a [u8],
    analysis: Analysis,
    scopes: Vec<Scope>,
    /// Declaring identifier's start byte → binding.
    declared_at: HashMap<usize, usize>,
}

/// Pre-order walk with an exit event, without recursion: a deeply nested
/// expression (generated code nests thousands deep) must not be able to
/// overflow the search thread's stack.
fn walk<'tree>(root: Node<'tree>, mut visit: impl FnMut(Node<'tree>, bool)) {
    let mut cursor = root.walk();
    loop {
        let node = cursor.node();
        visit(node, true);
        if cursor.goto_first_child() {
            continue;
        }
        loop {
            visit(cursor.node(), false);
            if cursor.node() == root {
                return;
            }
            if cursor.goto_next_sibling() {
                break;
            }
            if !cursor.goto_parent() {
                return;
            }
        }
    }
}

impl Binder<'_> {
    fn text(&self, node: Node) -> String {
        node.utf8_text(self.source).unwrap_or_default().to_string()
    }

    /// The text of a string literal without its quotes, and where that text is.
    fn string_content(&self, node: Node) -> Option<(std::ops::Range<usize>, String)> {
        if node.kind() != "string" {
            return None;
        }
        let range = node.byte_range();
        if range.len() < 2 {
            return None;
        }
        let inner = range.start + 1..range.end - 1;
        let text = std::str::from_utf8(self.source.get(inner.clone())?).ok()?.to_string();
        Some((inner, text))
    }

    fn bind(&mut self, scope: usize, node: Node, kind: BindingKind) {
        let name = self.text(node);
        if name.is_empty() {
            return;
        }
        let id = self.analysis.bindings.len();
        self.analysis.bindings.push(Binding { name: name.clone(), range: node.byte_range(), kind });
        self.declared_at.insert(node.start_byte(), id);
        // The first declaration wins: overloads and declaration merging repeat a
        // name, and the first is where a reader expects to land.
        self.scopes[scope].names.entry(name.clone()).or_insert(id);
        if scope == 0 {
            self.analysis.top_level.entry(name).or_insert(id);
        }
    }

    fn function_scope(&self, mut scope: usize) -> usize {
        while !self.scopes[scope].is_function {
            match self.scopes[scope].parent {
                Some(parent) => scope = parent,
                None => break,
            }
        }
        scope
    }

    /// Binds every name a destructuring pattern introduces.
    fn bind_pattern(&mut self, scope: usize, pattern: Node) {
        let mut pending = vec![pattern];
        while let Some(node) = pending.pop() {
            match node.kind() {
                "identifier" | "shorthand_property_identifier_pattern" => {
                    self.bind(scope, node, BindingKind::Declaration)
                }
                "pair_pattern" => pending.extend(node.child_by_field_name("value")),
                "assignment_pattern" | "object_assignment_pattern" => {
                    pending.extend(node.child_by_field_name("left"))
                }
                "required_parameter" | "optional_parameter" => {
                    pending.extend(node.child_by_field_name("pattern"))
                }
                "object_pattern" | "array_pattern" | "rest_pattern" | "formal_parameters" => {
                    let mut cursor = node.walk();
                    pending.extend(node.named_children(&mut cursor));
                }
                _ => {}
            }
        }
    }

    fn declare(&mut self, root: Node) {
        let mut stack: Vec<usize> = Vec::new();
        let mut entered: Vec<bool> = Vec::new();
        let mut events: Vec<(Node, bool)> = Vec::new();
        walk(root, |node, entering| events.push((node, entering)));
        for (node, entering) in events {
            let kind = node.kind();
            if !entering {
                if entered.pop() == Some(true) {
                    stack.pop();
                }
                continue;
            }
            let current = stack.last().copied();
            // The node's own name belongs to the scope it sits in — except a
            // named function or class *expression*, whose name is visible only
            // inside it.
            if let Some(scope) = current {
                self.declare_own_name(scope, node);
                self.declare_in_place(scope, node);
            }
            let opens = SCOPE_KINDS.contains(&kind);
            entered.push(opens);
            if opens {
                let id = self.scopes.len();
                self.scopes.push(Scope {
                    parent: current,
                    is_function: FUNCTION_KINDS.contains(&kind),
                    names: HashMap::new(),
                });
                stack.push(id);
                self.declare_inside(id, node);
            }
        }
    }

    /// Declarations a node makes in the scope that contains it.
    fn declare_own_name(&mut self, scope: usize, node: Node) {
        match node.kind() {
            "function_declaration"
            | "generator_function_declaration"
            | "class_declaration"
            | "abstract_class_declaration"
            | "interface_declaration"
            | "type_alias_declaration"
            | "enum_declaration"
            | "internal_module"
            | "module" => {
                if let Some(name) = node.child_by_field_name("name") {
                    if matches!(name.kind(), "identifier" | "type_identifier") {
                        self.bind(scope, name, BindingKind::Declaration);
                    }
                }
            }
            _ => {}
        }
    }

    /// Declarations made by a node that is not itself a scope.
    fn declare_in_place(&mut self, scope: usize, node: Node) {
        match node.kind() {
            "variable_declarator" => {
                let hoisted = node.parent().is_some_and(|parent| parent.kind() == "variable_declaration");
                let target = if hoisted { self.function_scope(scope) } else { scope };
                if let Some(name) = node.child_by_field_name("name") {
                    self.bind_pattern(target, name);
                }
            }
            "type_parameter" => {
                if let Some(name) = node.child_by_field_name("name") {
                    self.bind(scope, name, BindingKind::Declaration);
                }
            }
            "import_statement" => self.declare_import(scope, node),
            "export_statement" => self.declare_export(node),
            _ => {}
        }
    }

    /// Declarations a scope makes inside itself: parameters, and the name of a
    /// named function or class expression.
    fn declare_inside(&mut self, scope: usize, node: Node) {
        match node.kind() {
            "function_expression" | "function" | "generator_function" | "class" => {
                if let Some(name) = node.child_by_field_name("name") {
                    self.bind(scope, name, BindingKind::Declaration);
                }
            }
            "catch_clause" => {
                if let Some(parameter) = node.child_by_field_name("parameter") {
                    self.bind_pattern(scope, parameter);
                }
            }
            "for_in_statement" => {
                // `for (const key in …)` declares; `for (key in …)` assigns.
                if node.child_by_field_name("kind").is_some() {
                    if let Some(left) = node.child_by_field_name("left") {
                        self.bind_pattern(scope, left);
                    }
                }
            }
            _ => {}
        }
        if let Some(parameters) = node.child_by_field_name("parameters") {
            self.bind_pattern(scope, parameters);
        }
        if let Some(parameter) = node.child_by_field_name("parameter") {
            if node.kind() == "arrow_function" {
                self.bind_pattern(scope, parameter);
            }
        }
    }

    fn declare_import(&mut self, scope: usize, node: Node) {
        let Some((range, specifier)) =
            node.child_by_field_name("source").and_then(|source| self.string_content(source))
        else {
            return;
        };
        self.analysis.specifiers.push((range, specifier.clone()));
        let mut cursor = node.walk();
        let Some(clause) = node.named_children(&mut cursor).find(|child| child.kind() == "import_clause")
        else {
            return;
        };
        let mut cursor = clause.walk();
        for part in clause.named_children(&mut cursor) {
            match part.kind() {
                "identifier" => self.bind(
                    scope,
                    part,
                    BindingKind::Import { specifier: specifier.clone(), imported: Imported::Default },
                ),
                "namespace_import" => {
                    let mut inner = part.walk();
                    let name = part.named_children(&mut inner).find(|child| child.kind() == "identifier");
                    if let Some(name) = name {
                        self.bind(
                            scope,
                            name,
                            BindingKind::Import {
                                specifier: specifier.clone(),
                                imported: Imported::Namespace,
                            },
                        );
                    }
                }
                "named_imports" => {
                    let mut inner = part.walk();
                    for item in part.named_children(&mut inner) {
                        if item.kind() != "import_specifier" {
                            continue;
                        }
                        let Some(name) = item.child_by_field_name("name") else { continue };
                        let local = item.child_by_field_name("alias").unwrap_or(name);
                        let imported = self.text(name).trim_matches(['"', '\'']).to_string();
                        let imported = if imported == "default" {
                            Imported::Default
                        } else {
                            Imported::Name(imported)
                        };
                        self.bind(
                            scope,
                            local,
                            BindingKind::Import { specifier: specifier.clone(), imported },
                        );
                    }
                }
                _ => {}
            }
        }
    }

    /// Records what an `export` statement exports. Only top-level statements
    /// export, and only they reach here with a meaning, so no scope is needed.
    fn declare_export(&mut self, node: Node) {
        let source =
            node.child_by_field_name("source").and_then(|source| self.string_content(source));
        if let Some((range, specifier)) = &source {
            self.analysis.specifiers.push((range.clone(), specifier.clone()));
        }
        let is_default = {
            let mut cursor = node.walk();
            let found = node.children(&mut cursor).any(|child| child.kind() == "default");
            found
        };

        if let Some(declaration) = node.child_by_field_name("declaration") {
            for name in self.declared_names(declaration) {
                if is_default {
                    self.analysis.exports.insert("default".into(), Export::Local(name.clone()));
                } else {
                    self.analysis.exports.insert(name.clone(), Export::Local(name));
                }
            }
            return;
        }
        if let Some(value) = node.child_by_field_name("value") {
            let export = if value.kind() == "identifier" {
                Export::Local(self.text(value))
            } else {
                Export::Anonymous(value.byte_range())
            };
            self.analysis.exports.insert("default".into(), export);
            return;
        }

        let mut cursor = node.walk();
        for child in node.named_children(&mut cursor) {
            match child.kind() {
                "export_clause" => {
                    let mut inner = child.walk();
                    for item in child.named_children(&mut inner) {
                        if item.kind() != "export_specifier" {
                            continue;
                        }
                        let Some(name) = item.child_by_field_name("name") else { continue };
                        let local = self.text(name).trim_matches(['"', '\'']).to_string();
                        let exported = item
                            .child_by_field_name("alias")
                            .map(|alias| self.text(alias).trim_matches(['"', '\'']).to_string())
                            .unwrap_or_else(|| local.clone());
                        let export = match &source {
                            Some((_, specifier)) => {
                                Export::Forwarded { specifier: specifier.clone(), name: local }
                            }
                            None => Export::Local(local),
                        };
                        self.analysis.exports.insert(exported, export);
                    }
                }
                "namespace_export" => {
                    let mut inner = child.walk();
                    let name = child
                        .named_children(&mut inner)
                        .find(|part| matches!(part.kind(), "identifier" | "string"));
                    if let (Some(name), Some((_, specifier))) = (name, &source) {
                        let alias = self.text(name).trim_matches(['"', '\'']).to_string();
                        self.analysis
                            .exports
                            .insert(alias, Export::Namespace { specifier: specifier.clone() });
                    }
                }
                _ => {}
            }
        }
        // `export * from "…"` has no clause, only the star.
        let mut cursor = node.walk();
        let star = node.children(&mut cursor).any(|child| child.kind() == "*");
        let named_namespace = {
            let mut cursor = node.walk();
            let found = node.named_children(&mut cursor).any(|child| child.kind() == "namespace_export");
            found
        };
        if star && !named_namespace {
            if let Some((_, specifier)) = source {
                self.analysis.stars.push(specifier);
            }
        }
    }

    /// The names an exported declaration introduces.
    fn declared_names(&self, declaration: Node) -> Vec<String> {
        match declaration.kind() {
            "lexical_declaration" | "variable_declaration" => {
                let mut names = Vec::new();
                let mut cursor = declaration.walk();
                for declarator in declaration.named_children(&mut cursor) {
                    if declarator.kind() != "variable_declarator" {
                        continue;
                    }
                    let Some(pattern) = declarator.child_by_field_name("name") else { continue };
                    let mut pending = vec![pattern];
                    while let Some(node) = pending.pop() {
                        match node.kind() {
                            "identifier" | "shorthand_property_identifier_pattern" => {
                                names.push(self.text(node))
                            }
                            "pair_pattern" => pending.extend(node.child_by_field_name("value")),
                            "assignment_pattern" | "object_assignment_pattern" => {
                                pending.extend(node.child_by_field_name("left"))
                            }
                            "object_pattern" | "array_pattern" | "rest_pattern" => {
                                let mut inner = node.walk();
                                pending.extend(node.named_children(&mut inner));
                            }
                            _ => {}
                        }
                    }
                }
                names
            }
            _ => declaration
                .child_by_field_name("name")
                .map(|name| vec![self.text(name)])
                .unwrap_or_default(),
        }
    }

    fn lookup(&self, mut scope: usize, name: &str) -> Option<usize> {
        loop {
            if let Some(&binding) = self.scopes[scope].names.get(name) {
                return Some(binding);
            }
            scope = self.scopes[scope].parent?;
        }
    }

    /// Second pass: every identifier, tied to what it names. Runs after every
    /// declaration is known, so a function called above its declaration still
    /// resolves.
    fn resolve(&mut self, root: Node) {
        let mut stack: Vec<usize> = Vec::new();
        let mut entered: Vec<bool> = Vec::new();
        let mut next_scope = 0;
        let mut events: Vec<(Node, bool)> = Vec::new();
        walk(root, |node, entering| events.push((node, entering)));
        for (node, entering) in events {
            if !entering {
                if entered.pop() == Some(true) {
                    stack.pop();
                }
                continue;
            }
            let opens = SCOPE_KINDS.contains(&node.kind());
            entered.push(opens);
            if opens {
                stack.push(next_scope);
                next_scope += 1;
            }
            let Some(&scope) = stack.last() else { continue };
            // A scope's own name was declared outside it, but resolves the same
            // either way: it is a declaration, found through `declared_at`.
            if let Some(reference) = self.reference(scope, node) {
                self.analysis.references.push(reference);
            }
        }
    }

    fn reference(&self, scope: usize, node: Node) -> Option<Reference> {
        let kind = node.kind();
        if !matches!(
            kind,
            "identifier"
                | "type_identifier"
                | "shorthand_property_identifier"
                | "shorthand_property_identifier_pattern"
                | "property_identifier"
        ) {
            return None;
        }
        let range = node.byte_range();
        if let Some(&binding) = self.declared_at.get(&node.start_byte()) {
            let role = if self.inside(node, "import_statement") { Role::Import } else { Role::Declaration };
            return Some(Reference { range, role, binding: Some(binding) });
        }
        let parent = node.parent()?;
        let name = self.text(node);
        match parent.kind() {
            // `import { name as alias }`: `name` is the imported name, bound
            // through the alias.
            "import_specifier" => {
                let local = parent.child_by_field_name("alias").unwrap_or(node);
                let binding = self.declared_at.get(&local.start_byte()).copied();
                return Some(Reference { range, role: Role::Import, binding });
            }
            "export_specifier" => {
                let forwarded = self.inside(node, "export_statement")
                    && parent
                        .parent()
                        .and_then(|clause| clause.parent())
                        .and_then(|statement| statement.child_by_field_name("source"))
                        .is_some();
                if forwarded {
                    return Some(Reference { range, role: Role::Forward, binding: None });
                }
                // `export { local as alias }`: only `local` names a binding.
                let is_alias = parent.child_by_field_name("alias") == Some(node);
                if is_alias {
                    return None;
                }
                return Some(Reference { range, role: Role::Read, binding: self.lookup(scope, &name) });
            }
            "namespace_export" => return None,
            "member_expression" if parent.child_by_field_name("property") == Some(node) => {
                let object = parent.child_by_field_name("object");
                let binding = object
                    .filter(|object| object.kind() == "identifier")
                    .and_then(|object| self.lookup(scope, &self.text(object)));
                return Some(Reference { range, role: Role::Member, binding });
            }
            "nested_type_identifier" | "nested_identifier"
                if parent.child_by_field_name("name") == Some(node)
                    || parent.child_by_field_name("property") == Some(node) =>
            {
                let module = parent
                    .child_by_field_name("module")
                    .or_else(|| parent.child_by_field_name("object"))
                    .filter(|module| module.kind() == "identifier");
                let binding = module.and_then(|module| self.lookup(scope, &self.text(module)));
                return Some(Reference { range, role: Role::Member, binding });
            }
            "labeled_statement" | "break_statement" | "continue_statement" => return None,
            _ => {}
        }
        if kind == "property_identifier" {
            // A key, a method or field name, a JSX attribute: a member being
            // declared, not a variable being read.
            return Some(Reference { range, role: Role::MemberDeclaration, binding: None });
        }
        Some(Reference { range, role: Role::Read, binding: self.lookup(scope, &name) })
    }

    fn inside(&self, node: Node, kind: &str) -> bool {
        let mut current = node.parent();
        while let Some(parent) = current {
            if parent.kind() == kind {
                return true;
            }
            current = parent.parent();
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn analyzed(path: &str, source: &str) -> Analysis {
        let tree = parse(path, source).expect("parses");
        analyze(&tree, source)
    }

    fn binding_of(analysis: &Analysis, source: &str, needle: &str, nth: usize) -> Option<usize> {
        let at = source.match_indices(needle).nth(nth).expect("needle").0;
        analysis.reference_at(at).and_then(|reference| reference.binding)
    }

    #[test]
    fn a_shadowing_local_is_a_different_binding() {
        let source = "const value = 1;\nfunction f(value) { return value; }\nvalue;\n";
        let analysis = analyzed("a.ts", source);
        let outer = binding_of(&analysis, source, "value", 0);
        assert!(outer.is_some());
        assert_ne!(binding_of(&analysis, source, "value", 2), outer);
        assert_eq!(binding_of(&analysis, source, "value", 1), binding_of(&analysis, source, "value", 2));
        assert_eq!(binding_of(&analysis, source, "value", 3), outer);
    }

    #[test]
    fn imports_record_their_module_and_name() {
        let source = "import Def, { a as b, c } from \"./x\";\nimport * as ns from '@/y';\nb(); ns.thing;\n";
        let analysis = analyzed("a.tsx", source);
        let kinds: Vec<_> = analysis.bindings.iter().map(|b| (b.name.as_str(), &b.kind)).collect();
        assert!(kinds.contains(&(
            "Def",
            &BindingKind::Import { specifier: "./x".into(), imported: Imported::Default }
        )));
        assert!(kinds.contains(&(
            "b",
            &BindingKind::Import { specifier: "./x".into(), imported: Imported::Name("a".into()) }
        )));
        assert!(kinds.contains(&(
            "ns",
            &BindingKind::Import { specifier: "@/y".into(), imported: Imported::Namespace }
        )));
        let at = source.find("thing").unwrap();
        let member = analysis.reference_at(at).unwrap();
        assert_eq!(member.role, Role::Member);
        assert_eq!(analysis.bindings[member.binding.unwrap()].name, "ns");
    }

    #[test]
    fn exports_cover_declarations_clauses_defaults_and_forwards() {
        let source = "export const metadata = {};\nfunction Page() {}\nexport default Page;\n\
                      const x = 1; export { x as y };\nexport { z as w } from './z';\nexport * from './all';\n\
                      export * as space from './space';\nexport function named() {}\n";
        let analysis = analyzed("page.tsx", source);
        assert_eq!(analysis.exports.get("metadata"), Some(&Export::Local("metadata".into())));
        assert_eq!(analysis.exports.get("default"), Some(&Export::Local("Page".into())));
        assert_eq!(analysis.exports.get("y"), Some(&Export::Local("x".into())));
        assert_eq!(
            analysis.exports.get("w"),
            Some(&Export::Forwarded { specifier: "./z".into(), name: "z".into() })
        );
        assert_eq!(analysis.exports.get("space"), Some(&Export::Namespace { specifier: "./space".into() }));
        assert_eq!(analysis.exports.get("named"), Some(&Export::Local("named".into())));
        assert_eq!(analysis.stars, vec!["./all".to_string()]);
    }

    #[test]
    fn text_in_strings_comments_and_jsx_is_not_a_reference() {
        let source = "export const metadata = 1;\n// metadata here\nconst s = \"metadata\";\n\
                      const el = <p>session metadata</p>;\nconst v = <video preload=\"metadata\" />;\n";
        let analysis = analyzed("page.tsx", source);
        let named: Vec<_> = analysis
            .references
            .iter()
            .filter(|reference| &source[reference.range.clone()] == "metadata")
            .collect();
        assert_eq!(named.len(), 1);
        assert_eq!(named[0].role, Role::Declaration);
    }

    #[test]
    fn a_function_used_before_it_is_declared_still_resolves() {
        let source = "run();\nfunction run() {}\n";
        let analysis = analyzed("a.js", source);
        assert_eq!(binding_of(&analysis, source, "run", 0), binding_of(&analysis, source, "run", 1));
        assert!(binding_of(&analysis, source, "run", 0).is_some());
    }

    #[test]
    fn types_and_jsx_components_resolve_like_values() {
        let source = "import type { Metadata } from \"next\";\nimport { SiteNav } from \"@/components/site-nav\";\n\
                      export const metadata: Metadata = {};\nexport default function Page() { return <SiteNav />; }\n";
        let analysis = analyzed("page.tsx", source);
        let metadata_type = binding_of(&analysis, source, "Metadata", 1).expect("type resolves");
        assert_eq!(analysis.bindings[metadata_type].name, "Metadata");
        let nav = binding_of(&analysis, source, "SiteNav", 1).expect("jsx resolves");
        assert_eq!(analysis.bindings[nav].name, "SiteNav");
        assert_eq!(analysis.exports.get("default"), Some(&Export::Local("Page".into())));
    }
}
