//! The agent manifest schema, and the catalog that merges the bundled manifests
//! with the user's own.
//!
//! This is a deliberate second implementation of
//! `Sources/fyolo/Agents/AgentDefinition.swift`. The format is user-extensible —
//! a user drops a JSON manifest into `~/.fyolo/config/agents` and it becomes a
//! real agent — so the two parsers disagreeing is a bug the user sees as "my
//! agent works in the list but gets no hooks". `agent_manifest_fixture.rs` and
//! `Tests/fyoloTests/AgentManifestFixtureTests.swift` parse the same files and
//! assert the same values against one golden record, in CI, on both sides.
//!
//! What is deliberately *not* duplicated is anything that is a rendering
//! decision rather than a fact in the file: the icon is carried as the reference
//! the manifest wrote (a vector name, a bundled asset name, a path, an SF
//! Symbol), never resolved to pixels, and status patterns are carried as the raw
//! strings, never compiled — the daemon installs hooks, it does not scrape
//! screens.

use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The default `order` for a manifest that declares none — high, so unspecified
/// agents (typically user-dropped ones) sort after every ranked built-in.
pub const UNORDERED_RANK: i64 = 1_000_000;

/// A manifest that could not become a definition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ManifestError {
    /// The file is not JSON, or not the shape a manifest has (a missing `id`, a
    /// `name` of the wrong type). Carries serde's own message.
    Malformed(String),
    /// The file decoded, but says something the schema does not allow. The text
    /// is the same sentence the Swift side raises, so a user reading a log gets
    /// one wording regardless of which end refused.
    Invalid(String),
}

impl std::fmt::Display for ManifestError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ManifestError::Malformed(message) => write!(f, "{message}"),
            ManifestError::Invalid(message) => write!(f, "{message}"),
        }
    }
}

impl std::error::Error for ManifestError {}

type Result<T> = std::result::Result<T, ManifestError>;

fn invalid(message: impl Into<String>) -> ManifestError {
    ManifestError::Invalid(message.into())
}

// MARK: - The resolved definition

/// What a new session launches, resolved from one manifest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AgentDefinition {
    pub id: String,
    pub order: i64,
    pub display_name: String,
    /// Program launched in the session, or `None` for the user's login shell.
    pub command: Option<String>,
    pub permission_bypass_flag: Option<String>,
    pub resume: ResumeSpec,
    pub icon: IconReference,
    /// Portable six-digit sRGB tint. `None` means adaptive monochrome ink.
    pub tint_hex: Option<String>,
    pub install_url: Option<String>,
    /// The token this agent is named by on the companion (phone) wire protocol.
    pub wire_name: String,
    /// Screen-scrape rules, for agents that ship no hook system. `None` whenever
    /// `hooks` is present: hooks are the session's status authority, and two
    /// sources of truth per pane is how a dot starts flickering.
    pub status_rules: Option<StatusRules>,
    /// Rules over the agent's live `OSC 0/2` title. Unlike `status_rules` this
    /// coexists with hooks — the title is a correction channel, not a competing
    /// authority — so it is not gated the same way.
    pub title_rules: Option<StatusRules>,
    pub emits_progress_status: bool,
    pub hooks: Option<HookSpec>,
    /// The agent's user-level skills directory as the manifest declared it,
    /// unexpanded. `None` when the agent has no skills ecosystem.
    pub skill_dir: Option<String>,
    /// The environment variable that moves this agent's config tree, and the
    /// prefix it replaces. `None` for an agent that documents none.
    pub config_home: Option<ConfigHome>,
}

/// A documented per-agent config-home override.
///
/// Every manifest path here names a fixed directory — `~/.claude`,
/// `~/.codex` — and an agent that lets its owner move that directory reads a
/// variable to find it. Without this, a user who moved their config gets an
/// install into a directory the agent never reads, and every hook form ends in
/// `2>/dev/null || true`, so nothing says a word. It is the same silent miss as
/// the XDG one and it is more common, because people set these to keep
/// profiles apart.
///
/// The prefix is stated rather than derived. It is usually the obvious one, but
/// not always: Pi's variable names `~/.pi/agent`, not `~/.pi`. Deriving it from
/// the manifest's own paths would be guesswork, and guessing wrong moves an
/// install somewhere nothing looks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigHome {
    /// The variable the agent documents, e.g. `CLAUDE_CONFIG_DIR`.
    pub env: String,
    /// The path prefix it replaces, unexpanded, e.g. `~/.claude`. Every other
    /// path the manifest declares must sit under it.
    pub path: String,
}

/// The icon a manifest points at, carried as the reference rather than the
/// image. Resolving it — locating a bundled asset, rasterizing a user's PNG for
/// the phone — is the app's job and needs the app's resource bundle.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IconReference {
    /// One of the shipped brand vectors, by name.
    Vector(String),
    /// A bundled asset, by name. Unlike the Swift side this does not verify the
    /// asset exists: the assets are in the app bundle, which a daemon on a VPS
    /// does not have. A manifest naming a missing asset is therefore a
    /// definition here and an error there — the one field where the two ends
    /// cannot agree, recorded rather than papered over.
    Asset(String),
    /// A path, absolute or relative to the manifest's own directory.
    Path(String),
    /// An SF Symbol name.
    Symbol(String),
    /// Nothing declared: the plain terminal glyph.
    TerminalGlyph,
}

/// Raw regex sources that classify a screen or a title. Kept uncompiled: the
/// daemon never matches them, and compiling here would mean choosing a regex
/// engine whose accepted language differs from `NSRegularExpression`'s.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StatusRules {
    pub working: Vec<String>,
    pub attention: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ResumeSpec {
    pub create: Option<String>,
    pub resume: Option<String>,
    pub store: Option<ResumeStore>,
    pub discover: Option<ResumeDiscover>,
    pub seed: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeStore {
    pub root: String,
    pub is_directory: bool,
    pub name: String,
    pub transcript_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResumeDiscover {
    pub root: String,
    pub format: DiscoverFormat,
    pub id: String,
    pub cwd: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoverFormat {
    Jsonl,
    Json,
}

impl DiscoverFormat {
    pub fn as_str(self) -> &'static str {
        match self {
            DiscoverFormat::Jsonl => "jsonl",
            DiscoverFormat::Json => "json",
        }
    }
}

/// The closed installer shape a manifest may select. Config describes where and
/// when to invoke the report contract; it never supplies executable contents.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookType {
    Json,
    Toml,
    Plugin,
    /// A directory of executables named after the lifecycle event (Cline).
    Scripts,
}

impl HookType {
    pub fn as_str(self) -> &'static str {
        match self {
            HookType::Json => "json",
            HookType::Toml => "toml",
            HookType::Plugin => "plugin",
            HookType::Scripts => "scripts",
        }
    }
}

/// The on-disk shape of a hook file. Agents that configure hooks via JSON still
/// disagree on structure, so the installer branches on this.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HookDialect {
    /// Claude Code / Codex: `{"hooks": {"<Event>": [{"matcher"?, "hooks": [{type, command}]}]}}`,
    /// and the agent ignores the hook's stdout.
    ClaudeNested,
    /// Cursor: a required top-level `version`, flat one-key entries, and the
    /// hook's stdout read back as its JSON reply.
    CursorFlat,
    /// Copilot CLI: Cursor's flat shape plus a `type` on each entry.
    CopilotFlat,
    /// Kimi's marker-delimited TOML array-of-tables block.
    KimiToml,
    OpenCodePlugin,
    /// OpenCode 2's rewritten plugin API: a default-exported `{ id, setup }`
    /// object consuming `ctx.event.subscribe`, with payloads under `data`.
    OpenCode2Plugin,
    PiPlugin,
    AmpPlugin,
    /// Cline: a directory of executables named after the lifecycle event.
    ClineScripts,
}

impl HookDialect {
    pub fn as_str(self) -> &'static str {
        match self {
            HookDialect::ClaudeNested => "claudeNested",
            HookDialect::CursorFlat => "cursorFlat",
            HookDialect::CopilotFlat => "copilotFlat",
            HookDialect::KimiToml => "kimiTOML",
            HookDialect::OpenCodePlugin => "openCodePlugin",
            HookDialect::OpenCode2Plugin => "openCode2Plugin",
            HookDialect::PiPlugin => "piPlugin",
            HookDialect::AmpPlugin => "ampPlugin",
            HookDialect::ClineScripts => "clineScripts",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookEvent {
    pub name: String,
    pub state: String,
    pub matcher: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HookSpec {
    pub hook_type: HookType,
    /// Exact destination for JSON/TOML, unexpanded.
    pub file: Option<String>,
    /// Plugin or script directory, unexpanded.
    pub directory: Option<String>,
    pub dialect: HookDialect,
    pub captures_transcript: bool,
    /// Where the hook host exposes the live conversation id. Dialect-interpreted.
    pub conversation: Option<String>,
    /// The stdin JSON field naming the tool a hook event fires for.
    pub tool: Option<String>,
    /// The stdin JSON field carrying the user's prompt.
    pub prompt_title: Option<String>,
    pub events: Vec<HookEvent>,
}

// MARK: - The on-disk shape

/// The single on-disk shape for both bundled and user agents. A DTO: manifests
/// are data that select closed fyolo behaviours, never code fyolo executes.
#[derive(Debug, Clone, Deserialize)]
pub struct AgentManifest {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub order: Option<i64>,
    #[serde(default)]
    pub wire: Option<String>,
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default, rename = "permissionBypassFlag")]
    pub permission_bypass_flag: Option<String>,
    #[serde(default)]
    pub resume: Option<ResumeConfig>,
    #[serde(default)]
    pub install: Option<String>,
    /// Accepted while manifests written against the earlier RFC migrate.
    #[serde(default, rename = "installURL")]
    pub install_url: Option<String>,
    #[serde(default)]
    pub icon: Option<IconSpec>,
    #[serde(default)]
    pub status: Option<StatusSpec>,
    #[serde(default, rename = "titleStatus")]
    pub title_status: Option<StatusSpec>,
    #[serde(default, rename = "progressStatus")]
    pub progress_status: Option<bool>,
    #[serde(default)]
    pub hooks: Option<HookConfig>,
    #[serde(default)]
    pub skills: Option<SkillsSpec>,
    #[serde(default, rename = "configHome")]
    pub config_home: Option<ConfigHomeSpec>,
}

/// The manifest's `configHome` — a variable name and the prefix it replaces.
#[derive(Debug, Clone, Deserialize)]
pub struct ConfigHomeSpec {
    #[serde(default)]
    pub env: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SkillsSpec {
    #[serde(default)]
    pub dir: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct IconSpec {
    #[serde(default)]
    pub vector: Option<String>,
    #[serde(default)]
    pub asset: Option<String>,
    #[serde(default)]
    pub symbol: Option<String>,
    #[serde(default)]
    pub tint: Option<String>,
    #[serde(default)]
    pub path: Option<String>,
}

/// The manifest's `resume`. The flat object is the interface; a bare string is
/// accepted only as backward compatibility for manifests written against the
/// older preset names.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum ResumeConfig {
    LegacyPreset(String),
    Spec(ResumeFields),
}

#[derive(Debug, Clone, Deserialize)]
pub struct ResumeFields {
    #[serde(default)]
    pub create: Option<String>,
    #[serde(default)]
    pub resume: Option<String>,
    #[serde(default, rename = "storeRoot")]
    pub store_root: Option<String>,
    #[serde(default, rename = "storeMatch")]
    pub store_match: Option<String>,
    #[serde(default, rename = "transcriptName")]
    pub transcript_name: Option<String>,
    #[serde(default)]
    pub discover: Option<DiscoverFields>,
    #[serde(default)]
    pub seed: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DiscoverFields {
    pub root: String,
    pub format: String,
    pub id: String,
    pub cwd: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct StatusSpec {
    #[serde(default)]
    pub working: Option<Vec<String>>,
    #[serde(default)]
    pub attention: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HookConfig {
    #[serde(default, rename = "type")]
    pub hook_type: Option<String>,
    #[serde(default)]
    pub file: Option<String>,
    #[serde(default)]
    pub dir: Option<String>,
    #[serde(default)]
    pub dialect: Option<String>,
    #[serde(default, rename = "capturesTranscript")]
    pub captures_transcript: Option<bool>,
    #[serde(default)]
    pub conversation: Option<String>,
    #[serde(default)]
    pub tool: Option<String>,
    #[serde(default, rename = "promptTitle")]
    pub prompt_title: Option<String>,
    pub events: Vec<HookEventConfig>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct HookEventConfig {
    #[serde(default)]
    pub on: Option<String>,
    /// Accepted for manifests written against the earlier user-agent RFC.
    #[serde(default)]
    pub event: Option<String>,
    pub state: String,
    #[serde(default)]
    pub matcher: Option<String>,
}

impl AgentManifest {
    pub fn parse(bytes: &[u8]) -> Result<AgentManifest> {
        serde_json::from_slice(bytes).map_err(|error| ManifestError::Malformed(error.to_string()))
    }

    /// Resolve into the runtime definition, applying the defaults and raising
    /// the validation errors the Swift side raises, word for word.
    pub fn definition(&self) -> Result<AgentDefinition> {
        if self.id.is_empty() {
            return Err(invalid("agent id is empty"));
        }
        if self.name.is_empty() {
            return Err(invalid(format!("{}: name is empty", self.id)));
        }

        let icon = self.resolved_icon()?;
        let hooks = self.resolved_hooks()?;
        let skill_dir = self.resolved_skill_dir()?;
        let config_home = self.resolved_config_home(hooks.as_ref(), skill_dir.as_deref())?;
        // Hooks are the session's status authority, so an agent that has them
        // never also carries screen-scrape rules — one source of truth per pane.
        let screen_rules = if hooks.is_none() {
            status_rules(self.status.as_ref())
        } else {
            None
        };
        let title_rules = status_rules(self.title_status.as_ref());

        Ok(AgentDefinition {
            id: self.id.clone(),
            order: self.order.unwrap_or(UNORDERED_RANK),
            display_name: self.name.clone(),
            command: self.command.clone(),
            permission_bypass_flag: self.permission_bypass_flag.clone(),
            resume: self.resolved_resume()?,
            tint_hex: self.resolved_tint_hex(&icon),
            icon,
            install_url: self
                .install
                .clone()
                .or_else(|| self.install_url.clone())
                .filter(|value| is_url(value)),
            wire_name: self.wire.clone().unwrap_or_else(|| self.id.clone()),
            status_rules: screen_rules,
            title_rules,
            emits_progress_status: self.progress_status.unwrap_or(false),
            hooks,
            skill_dir,
            config_home,
        })
    }

    /// Validate the `configHome` block, and check that it actually is the home
    /// the rest of the manifest hangs off.
    ///
    /// A prefix that does not cover the paths it claims to is the failure worth
    /// catching here: the install would keep working while the variable is
    /// unset and silently move to the wrong place the day somebody sets it,
    /// which is the whole class of bug this field exists to close.
    fn resolved_config_home(
        &self,
        hooks: Option<&HookSpec>,
        skill_dir: Option<&str>,
    ) -> Result<Option<ConfigHome>> {
        let Some(spec) = &self.config_home else {
            return Ok(None);
        };
        let Some(env) = spec.env.as_deref().map(trim_spaces).filter(|v| !v.is_empty()) else {
            return Err(invalid(format!("{}: configHome requires 'env'", self.id)));
        };
        let Some(path) = spec.path.as_deref().map(trim_spaces).filter(|v| !v.is_empty()) else {
            return Err(invalid(format!("{}: configHome requires 'path'", self.id)));
        };
        if !env.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_') {
            return Err(invalid(format!(
                "{}: configHome env must name an environment variable, not '{env}'",
                self.id
            )));
        }
        if !path.starts_with("~/") {
            return Err(invalid(format!(
                "{}: configHome path must start with '~/', not '{path}'",
                self.id
            )));
        }
        let declared = hooks
            .into_iter()
            .flat_map(|hooks| hooks.file.iter().chain(hooks.directory.iter()))
            .map(String::as_str)
            .chain(skill_dir);
        for candidate in declared {
            if !is_under(candidate, path) {
                return Err(invalid(format!(
                    "{}: configHome path '{path}' does not contain '{candidate}'",
                    self.id
                )));
            }
        }
        Ok(Some(ConfigHome {
            env: env.to_string(),
            path: path.to_string(),
        }))
    }

    fn resolved_icon(&self) -> Result<IconReference> {
        let icon = match &self.icon {
            Some(icon) => icon,
            None => return Ok(IconReference::TerminalGlyph),
        };
        if let Some(vector) = non_empty(&icon.vector) {
            return match vector.to_lowercase().as_str() {
                "claude" | "codex" | "grok" => Ok(IconReference::Vector(vector.to_lowercase())),
                _ => Err(invalid(format!(
                    "{}: unknown icon vector '{vector}'",
                    self.id
                ))),
            };
        }
        if let Some(asset) = non_empty(&icon.asset) {
            return Ok(IconReference::Asset(asset.to_string()));
        }
        if let Some(path) = non_empty(&icon.path) {
            return Ok(IconReference::Path(path.to_string()));
        }
        if let Some(symbol) = non_empty(&icon.symbol) {
            return Ok(IconReference::Symbol(symbol.to_string()));
        }
        Ok(IconReference::TerminalGlyph)
    }

    /// The explicit `icon.tint` normalized to `#RRGGBB`, or the one default a
    /// brand vector carries. An unparseable tint is ignored rather than fatal,
    /// exactly as `Color(hex:)` returning nil is.
    fn resolved_tint_hex(&self, icon: &IconReference) -> Option<String> {
        if let Some(raw) = self.icon.as_ref().and_then(|icon| icon.tint.as_deref()) {
            let value = raw.strip_prefix('#').unwrap_or(raw);
            if value.len() == 6 && value.chars().all(|c| c.is_ascii_hexdigit()) {
                return Some(format!("#{}", value.to_uppercase()));
            }
        }
        match icon {
            IconReference::Vector(name) if name == "claude" => Some("#D97757".to_string()),
            _ => None,
        }
    }

    fn resolved_skill_dir(&self) -> Result<Option<String>> {
        let skills = match &self.skills {
            Some(skills) => skills,
            None => return Ok(None),
        };
        match skills
            .dir
            .as_deref()
            .map(trim_spaces)
            .filter(|dir| !dir.is_empty())
        {
            Some(dir) => Ok(Some(dir.to_string())),
            None => Err(invalid(format!("{}: skills require 'dir'", self.id))),
        }
    }

    fn resolved_resume(&self) -> Result<ResumeSpec> {
        let resume = match &self.resume {
            Some(resume) => resume,
            None => return Ok(ResumeSpec::default()),
        };
        let fields = match resume {
            ResumeConfig::LegacyPreset(preset) => return legacy_resume(&self.id, preset),
            ResumeConfig::Spec(fields) => fields,
        };

        let store = match (&fields.store_root, &fields.store_match) {
            (None, None) => None,
            (Some(root), Some(pattern)) => {
                let (kind, name) = pattern.split_once(':').ok_or_else(|| {
                    invalid(format!(
                        "{}: storeMatch must be 'dir:<pattern>' or 'file:<pattern>'",
                        self.id
                    ))
                })?;
                if name.is_empty() {
                    return Err(invalid(format!(
                        "{}: storeMatch must be 'dir:<pattern>' or 'file:<pattern>'",
                        self.id
                    )));
                }
                let is_directory = match kind {
                    "dir" => true,
                    "file" => false,
                    _ => {
                        return Err(invalid(format!(
                            "{}: storeMatch must start with 'dir:' or 'file:'",
                            self.id
                        )))
                    }
                };
                if !name.contains("{id}") {
                    return Err(invalid(format!(
                        "{}: storeMatch pattern must contain '{{id}}'",
                        self.id
                    )));
                }
                Some(ResumeStore {
                    root: root.clone(),
                    is_directory,
                    name: name.to_string(),
                    transcript_name: fields.transcript_name.clone(),
                })
            }
            _ => {
                return Err(invalid(format!(
                    "{}: storeRoot and storeMatch must be set together",
                    self.id
                )))
            }
        };

        let discover = match &fields.discover {
            None => None,
            Some(discover) => {
                let format = match discover.format.to_lowercase().as_str() {
                    "jsonl" => DiscoverFormat::Jsonl,
                    "json" => DiscoverFormat::Json,
                    _ => {
                        return Err(invalid(format!(
                            "{}: discover format must be 'jsonl' or 'json', not '{}'",
                            self.id, discover.format
                        )))
                    }
                };
                if discover.root.is_empty() || discover.id.is_empty() || discover.cwd.is_empty() {
                    return Err(invalid(format!(
                        "{}: discover requires root, format, id, cwd",
                        self.id
                    )));
                }
                Some(ResumeDiscover {
                    root: discover.root.clone(),
                    format,
                    id: discover.id.clone(),
                    cwd: discover.cwd.clone(),
                })
            }
        };

        if let Some(seed) = &fields.seed {
            if seed != "session-file" {
                return Err(invalid(format!(
                    "{}: unknown resume seed mechanism '{seed}'",
                    self.id
                )));
            }
        }
        if fields.create.is_some() && discover.is_some() {
            return Err(invalid(format!(
                "{}: resume 'create' (pinned id) and 'discover' (found id) are mutually exclusive",
                self.id
            )));
        }

        Ok(ResumeSpec {
            create: fields.create.clone(),
            resume: fields.resume.clone(),
            store,
            discover,
            seed: fields.seed.clone(),
        })
    }

    fn resolved_hooks(&self) -> Result<Option<HookSpec>> {
        let hooks = match &self.hooks {
            Some(hooks) => hooks,
            None => return Ok(None),
        };
        let type_name = hooks
            .hook_type
            .as_deref()
            .map(str::to_lowercase)
            .unwrap_or_else(|| "json".to_string());
        let hook_type = match type_name.as_str() {
            "json" => HookType::Json,
            "toml" => HookType::Toml,
            "plugin" => HookType::Plugin,
            "scripts" => HookType::Scripts,
            _ => {
                return Err(invalid(format!(
                    "{}: unknown hook type '{type_name}'",
                    self.id
                )))
            }
        };
        let dialect_name = hooks.dialect.as_deref().map(str::to_lowercase);
        let dialect = match (hook_type, dialect_name.as_deref()) {
            (HookType::Json, None | Some("claude") | Some("codex") | Some("grok")) => {
                HookDialect::ClaudeNested
            }
            (HookType::Json, Some("cursor")) => HookDialect::CursorFlat,
            (HookType::Json, Some("copilot")) => HookDialect::CopilotFlat,
            (HookType::Toml, None | Some("kimi")) => HookDialect::KimiToml,
            (HookType::Plugin, Some("opencode")) => HookDialect::OpenCodePlugin,
            (HookType::Plugin, Some("opencode2")) => HookDialect::OpenCode2Plugin,
            (HookType::Plugin, Some("pi")) => HookDialect::PiPlugin,
            (HookType::Plugin, Some("amp")) => HookDialect::AmpPlugin,
            (HookType::Scripts, None | Some("cline")) => HookDialect::ClineScripts,
            _ => {
                return Err(invalid(format!(
                    "{}: hook dialect '{}' does not match type '{type_name}'",
                    self.id,
                    dialect_name.as_deref().unwrap_or("")
                )))
            }
        };

        let needs_directory = matches!(hook_type, HookType::Plugin | HookType::Scripts);
        if needs_directory && non_empty(&hooks.dir).is_none() {
            return Err(invalid(format!(
                "{}: {type_name} hooks require 'dir'",
                self.id
            )));
        }
        if !needs_directory && non_empty(&hooks.file).is_none() {
            return Err(invalid(format!(
                "{}: {type_name} hooks require 'file'",
                self.id
            )));
        }

        // Locators are embedded in generated hook commands and plugin source, so
        // each must be a bare token: a JSON field name for shell hooks, a dot
        // path of JS identifiers for the OpenCode plugin, or the one named
        // mechanism (`context`) for the Pi plugin. Anything else is a manifest
        // error, never rendered.
        let mut conversation = None;
        if let Some(raw) = trimmed_non_empty(&hooks.conversation) {
            match dialect {
                HookDialect::ClaudeNested | HookDialect::CursorFlat | HookDialect::CopilotFlat => {
                    if !is_identifier(raw) {
                        return Err(invalid(format!(
                            "{}: hook conversation must name a stdin JSON field, not '{raw}'",
                            self.id
                        )));
                    }
                }
                HookDialect::OpenCodePlugin | HookDialect::OpenCode2Plugin => {
                    let components: Vec<&str> = raw.split('.').collect();
                    if components.is_empty() || !components.iter().all(|c| is_identifier(c)) {
                        return Err(invalid(format!(
                            "{}: hook conversation must be a dot key path, not '{raw}'",
                            self.id
                        )));
                    }
                }
                HookDialect::PiPlugin => {
                    if raw != "context" {
                        return Err(invalid(format!(
                            "{}: hook conversation for this dialect must be 'context', not '{raw}'",
                            self.id
                        )));
                    }
                }
                HookDialect::KimiToml | HookDialect::AmpPlugin | HookDialect::ClineScripts => {
                    return Err(invalid(format!(
                        "{}: hook conversation is not supported for this dialect",
                        self.id
                    )))
                }
            }
            conversation = Some(raw.to_string());
        }

        let mut tool = None;
        if let Some(raw) = trimmed_non_empty(&hooks.tool) {
            match dialect {
                HookDialect::ClaudeNested | HookDialect::CursorFlat | HookDialect::CopilotFlat => {
                    if !is_identifier(raw) {
                        return Err(invalid(format!(
                            "{}: hook tool must name a stdin JSON field, not '{raw}'",
                            self.id
                        )));
                    }
                }
                _ => {
                    return Err(invalid(format!(
                        "{}: hook tool is not supported for this dialect",
                        self.id
                    )))
                }
            }
            tool = Some(raw.to_string());
        }

        let mut prompt_title = None;
        if let Some(raw) = trimmed_non_empty(&hooks.prompt_title) {
            match dialect {
                HookDialect::ClaudeNested | HookDialect::CursorFlat | HookDialect::CopilotFlat => {
                    if !is_identifier(raw) {
                        return Err(invalid(format!(
                            "{}: hook promptTitle must name a stdin JSON field, not '{raw}'",
                            self.id
                        )));
                    }
                }
                _ => {
                    return Err(invalid(format!(
                        "{}: hook promptTitle is not supported for this dialect",
                        self.id
                    )))
                }
            }
            prompt_title = Some(raw.to_string());
        }

        const VALID_STATES: [&str; 4] = ["working", "attention", "done", "idle"];
        let mut events = Vec::with_capacity(hooks.events.len());
        for event in &hooks.events {
            let name = event
                .on
                .as_deref()
                .or(event.event.as_deref())
                .filter(|name| !name.is_empty())
                .ok_or_else(|| invalid(format!("{}: hook event is missing 'on'", self.id)))?;
            if !VALID_STATES.contains(&event.state.as_str()) {
                return Err(invalid(format!(
                    "{}: invalid hook state '{}'",
                    self.id, event.state
                )));
            }
            events.push(HookEvent {
                name: name.to_string(),
                state: event.state.clone(),
                matcher: event.matcher.clone(),
            });
        }

        Ok(Some(HookSpec {
            hook_type,
            file: hooks.file.clone(),
            directory: hooks.dir.clone(),
            dialect,
            captures_transcript: hooks.captures_transcript.unwrap_or(false),
            conversation,
            tool,
            prompt_title,
            events,
        }))
    }
}

fn legacy_resume(id: &str, preset: &str) -> Result<ResumeSpec> {
    match preset.to_lowercase().as_str() {
        "none" => Ok(ResumeSpec::default()),
        "claude" => Ok(ResumeSpec {
            create: Some("--session-id {id}".into()),
            resume: Some("--resume {id}".into()),
            store: Some(ResumeStore {
                root: "~/.claude/projects".into(),
                is_directory: false,
                name: "{id}.jsonl".into(),
                transcript_name: None,
            }),
            ..ResumeSpec::default()
        }),
        "pi" => Ok(ResumeSpec {
            create: Some("--session-id {id}".into()),
            resume: Some("--session-id {id}".into()),
            store: Some(ResumeStore {
                root: "~/.pi/agent/sessions".into(),
                is_directory: false,
                name: "*_{id}.jsonl".into(),
                transcript_name: None,
            }),
            seed: Some("session-file".into()),
            ..ResumeSpec::default()
        }),
        "codex" => Ok(ResumeSpec {
            resume: Some("resume {id}".into()),
            discover: Some(ResumeDiscover {
                root: "~/.codex/sessions".into(),
                format: DiscoverFormat::Jsonl,
                id: "payload.id".into(),
                cwd: "payload.cwd".into(),
            }),
            ..ResumeSpec::default()
        }),
        "opencode" => Ok(ResumeSpec {
            resume: Some("--session {id}".into()),
            discover: Some(ResumeDiscover {
                root: "~/.local/share/opencode/storage/session".into(),
                format: DiscoverFormat::Json,
                id: "id".into(),
                cwd: "directory".into(),
            }),
            ..ResumeSpec::default()
        }),
        other => Err(invalid(format!("{id}: unknown resume preset '{other}'"))),
    }
}

fn status_rules(spec: Option<&StatusSpec>) -> Option<StatusRules> {
    let spec = spec?;
    let working = spec.working.clone().unwrap_or_default();
    let attention = spec.attention.clone().unwrap_or_default();
    if working.is_empty() && attention.is_empty() {
        return None;
    }
    Some(StatusRules { working, attention })
}

/// Whether `install` names something `URL(string:)` would accept. Swift's
/// initializer is the gate on the other side; the manifests that reach it are
/// absolute `https://` links, and anything with a space or a control character
/// is what it turns down.
fn is_url(value: &str) -> bool {
    !value.is_empty()
        && !value
            .chars()
            .any(|c| c.is_whitespace() || c.is_control() || c == '"' || c == '<' || c == '>')
}

fn non_empty(value: &Option<String>) -> Option<&str> {
    value.as_deref().filter(|value| !value.is_empty())
}

/// Trim what Foundation's `.whitespaces` set trims — horizontal space only, so
/// a newline inside a locator stays the manifest error it is.
fn trim_spaces(value: &str) -> &str {
    value.trim_matches(|c: char| c == '\t' || (c.is_whitespace() && !matches!(c, '\n' | '\r')))
}

fn trimmed_non_empty(value: &Option<String>) -> Option<&str> {
    value
        .as_deref()
        .map(trim_spaces)
        .filter(|value| !value.is_empty())
}

/// Whether `candidate` sits at or under `prefix`, as path components rather
/// than as text — `~/.pi/agent` contains `~/.pi/agent/skills` but not
/// `~/.pi/agentic`.
pub fn is_under(candidate: &str, prefix: &str) -> bool {
    let candidate = candidate.trim_end_matches('/');
    let prefix = prefix.trim_end_matches('/');
    candidate == prefix
        || candidate
            .strip_prefix(prefix)
            .map(|rest| rest.starts_with('/'))
            .unwrap_or(false)
}

/// A bare JavaScript/JSON identifier: a letter or `_` then letters, digits, `_`.
fn is_identifier(value: &str) -> bool {
    let mut chars = value.chars();
    match chars.next() {
        Some(first) if first.is_alphabetic() || first == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_alphanumeric() || c == '_')
}

// MARK: - The catalog

/// The bundled manifests, embedded at build time from the same files the Mac app
/// ships. One directory, two readers — copying them here is what would let the
/// two drift.
pub const BUNDLED_MANIFESTS: &[(&str, &str)] = &[
    ("terminal.json", include_str!("../../../Sources/fyolo/Resources/terminal.json")),
    ("agents/amp.json", include_str!("../../../Sources/fyolo/Resources/agents/amp.json")),
    ("agents/antigravity.json", include_str!("../../../Sources/fyolo/Resources/agents/antigravity.json")),
    ("agents/claude.json", include_str!("../../../Sources/fyolo/Resources/agents/claude.json")),
    ("agents/cline.json", include_str!("../../../Sources/fyolo/Resources/agents/cline.json")),
    ("agents/codex.json", include_str!("../../../Sources/fyolo/Resources/agents/codex.json")),
    ("agents/copilot.json", include_str!("../../../Sources/fyolo/Resources/agents/copilot.json")),
    ("agents/crush.json", include_str!("../../../Sources/fyolo/Resources/agents/crush.json")),
    ("agents/cursor.json", include_str!("../../../Sources/fyolo/Resources/agents/cursor.json")),
    ("agents/droid.json", include_str!("../../../Sources/fyolo/Resources/agents/droid.json")),
    ("agents/grok.json", include_str!("../../../Sources/fyolo/Resources/agents/grok.json")),
    ("agents/hermes.json", include_str!("../../../Sources/fyolo/Resources/agents/hermes.json")),
    ("agents/kimi.json", include_str!("../../../Sources/fyolo/Resources/agents/kimi.json")),
    ("agents/opencode.json", include_str!("../../../Sources/fyolo/Resources/agents/opencode.json")),
    ("agents/opencode2.json", include_str!("../../../Sources/fyolo/Resources/agents/opencode2.json")),
    ("agents/pi.json", include_str!("../../../Sources/fyolo/Resources/agents/pi.json")),
    ("agents/qwen.json", include_str!("../../../Sources/fyolo/Resources/agents/qwen.json")),
];

/// The merged set of agent definitions: the bundled roster, overridden by the
/// user's own manifests, sorted by declared `order` then id so the roster is the
/// same regardless of the order the directory enumerated in.
pub struct AgentCatalog {
    pub all: Vec<AgentDefinition>,
    /// The bundled definitions alone, so a user override that removes or
    /// redirects a shipped hook can still clean the old managed wiring.
    pub bundled: Vec<AgentDefinition>,
}

impl AgentCatalog {
    /// Load the bundled roster plus every manifest in the user's agents
    /// directory. Unparseable manifests are skipped with a line on stderr, the
    /// same don't-take-the-roster-down-with-you rule the app follows.
    pub fn load() -> AgentCatalog {
        Self::load_from(user_agents_directory().as_deref())
    }

    pub fn load_from(user_directory: Option<&Path>) -> AgentCatalog {
        let mut bundled = Vec::new();
        for (name, source) in BUNDLED_MANIFESTS {
            match AgentManifest::parse(source.as_bytes()).and_then(|m| m.definition()) {
                Ok(definition) => bundled.push(definition),
                Err(error) => log(&format!("ignoring unparseable bundled {name}: {error}")),
            }
        }
        let user = match user_directory {
            Some(directory) => load_directory(directory),
            None => Vec::new(),
        };
        let mut all = merge(bundled.clone(), user);
        all.sort_by(|a, b| (a.order, &a.id).cmp(&(b.order, &b.id)));
        bundled.sort_by(|a, b| (a.order, &a.id).cmp(&(b.order, &b.id)));
        AgentCatalog { all, bundled }
    }

    pub fn find(&self, id: &str) -> Option<&AgentDefinition> {
        self.all.iter().find(|definition| definition.id == id)
    }

    /// Bundled hook specs removed or redirected by full user overrides — the
    /// old managed wiring an install has to clean before writing the new.
    ///
    /// Each comes back with the bundled definition it belongs to, because the
    /// paths have to be resolved against *that* definition's config home: a
    /// user override may have changed the variable along with the paths.
    pub fn stale_bundled_hooks(&self) -> Vec<(AgentDefinition, HookSpec)> {
        self.bundled
            .iter()
            .filter_map(|definition| {
                let bundled = definition.hooks.as_ref()?;
                match self.find(&definition.id).and_then(|live| live.hooks.as_ref()) {
                    Some(live) if live == bundled => None,
                    _ => Some((definition.clone(), bundled.clone())),
                }
            })
            .collect()
    }
}

/// `~/.fyolo[-dev]/config/agents` — the channel-scoped flat manifest directory
/// the app's custom-agent editor writes into. The format is untouched by this
/// migration: a format migration and a language migration at once is how both
/// fail.
pub fn user_agents_directory() -> Option<PathBuf> {
    let home = crate::agent::machine::home_directory()?;
    Some(
        home.join(format!(".fyolo{}", crate::paths::channel_suffix()))
            .join("config")
            .join("agents"),
    )
}

fn load_directory(directory: &Path) -> Vec<AgentDefinition> {
    let mut names: Vec<PathBuf> = match std::fs::read_dir(directory) {
        Ok(entries) => entries
            .filter_map(|entry| entry.ok())
            .map(|entry| entry.path())
            .filter(|path| {
                path.extension()
                    .and_then(|ext| ext.to_str())
                    .map(|ext| ext.eq_ignore_ascii_case("json"))
                    .unwrap_or(false)
            })
            .collect(),
        Err(_) => return Vec::new(),
    };
    // Filename-sorted, so a duplicate id resolves the same way on both ends.
    names.sort();
    names
        .into_iter()
        .filter_map(|path| match std::fs::read(&path) {
            Ok(bytes) => match AgentManifest::parse(&bytes).and_then(|m| m.definition()) {
                Ok(definition) => Some(definition),
                Err(error) => {
                    log(&format!("ignoring unparseable {}: {error}", path.display()));
                    None
                }
            },
            Err(error) => {
                log(&format!("could not read {}: {error}", path.display()));
                None
            }
        })
        .collect()
}

/// Preserve a bundled agent's position when it is overridden, then append new
/// user ids.
fn merge(base: Vec<AgentDefinition>, user: Vec<AgentDefinition>) -> Vec<AgentDefinition> {
    let mut merged: Vec<AgentDefinition> = Vec::new();
    let mut positions: BTreeMap<String, usize> = BTreeMap::new();
    for definition in base.into_iter().chain(user) {
        match positions.get(&definition.id) {
            Some(&position) => merged[position] = definition,
            None => {
                positions.insert(definition.id.clone(), merged.len());
                merged.push(definition);
            }
        }
    }
    merged
}

pub fn log(message: &str) {
    eprintln!("fyolod: agent catalog {message}");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn definition(json: &str) -> Result<AgentDefinition> {
        AgentManifest::parse(json.as_bytes())?.definition()
    }

    #[test]
    fn every_bundled_manifest_resolves() {
        for (name, source) in BUNDLED_MANIFESTS {
            let manifest = AgentManifest::parse(source.as_bytes())
                .unwrap_or_else(|e| panic!("{name} did not parse: {e}"));
            manifest
                .definition()
                .unwrap_or_else(|e| panic!("{name} did not resolve: {e}"));
        }
    }

    #[test]
    fn catalog_sorts_by_declared_order() {
        let catalog = AgentCatalog::load_from(None);
        assert_eq!(catalog.all.first().map(|d| d.id.as_str()), Some("terminal"));
        assert!(catalog
            .all
            .windows(2)
            .all(|pair| (pair[0].order, &pair[0].id) <= (pair[1].order, &pair[1].id)));
    }

    #[test]
    fn a_missing_order_sorts_last() {
        let agent = definition(r#"{"id":"x","name":"X"}"#).expect("resolves");
        assert_eq!(agent.order, UNORDERED_RANK);
        assert_eq!(agent.wire_name, "x");
    }

    #[test]
    fn hooks_suppress_screen_scrape_rules() {
        let agent = definition(
            r#"{"id":"x","name":"X","status":{"working":["a"]},
                "hooks":{"file":"~/.x.json","events":[{"on":"Stop","state":"done"}]}}"#,
        )
        .expect("resolves");
        assert!(agent.status_rules.is_none());
        assert!(agent.hooks.is_some());
    }

    #[test]
    fn a_title_rule_survives_hooks() {
        let agent = definition(
            r#"{"id":"x","name":"X","titleStatus":{"attention":["Action Required"]},
                "hooks":{"file":"~/.x.json","events":[{"on":"Stop","state":"done"}]}}"#,
        )
        .expect("resolves");
        assert_eq!(
            agent.title_rules.map(|rules| rules.attention),
            Some(vec!["Action Required".to_string()])
        );
    }

    #[test]
    fn a_pinned_id_and_a_discovered_one_are_exclusive() {
        let error = definition(
            r#"{"id":"x","name":"X","resume":{"create":"--id {id}",
                "discover":{"root":"~/x","format":"json","id":"id","cwd":"cwd"}}}"#,
        )
        .expect_err("must refuse");
        assert_eq!(
            error,
            ManifestError::Invalid(
                "x: resume 'create' (pinned id) and 'discover' (found id) are mutually exclusive"
                    .into()
            )
        );
    }

    #[test]
    fn a_store_pattern_must_carry_the_id_placeholder() {
        let error = definition(
            r#"{"id":"x","name":"X","resume":{"storeRoot":"~/x","storeMatch":"file:log.jsonl"}}"#,
        )
        .expect_err("must refuse");
        assert_eq!(
            error,
            ManifestError::Invalid("x: storeMatch pattern must contain '{id}'".into())
        );
    }

    #[test]
    fn a_conversation_locator_must_suit_its_dialect() {
        let error = definition(
            r#"{"id":"x","name":"X","hooks":{"type":"scripts","dir":"~/x",
                "conversation":"session_id","events":[{"on":"Stop","state":"done"}]}}"#,
        )
        .expect_err("must refuse");
        assert_eq!(
            error,
            ManifestError::Invalid("x: hook conversation is not supported for this dialect".into())
        );
    }

    #[test]
    fn a_user_manifest_overrides_a_bundled_id_in_place() {
        let directory = tempdir("override");
        std::fs::write(
            directory.join("claudeCode.json"),
            r#"{"id":"claudeCode","name":"Mine","skills":{"dir":"~/mine"}}"#,
        )
        .expect("fixture written");
        let catalog = AgentCatalog::load_from(Some(&directory));
        let agent = catalog.find("claudeCode").expect("still present");
        assert_eq!(agent.display_name, "Mine");
        assert!(agent.hooks.is_none());
        // The bundled hook wiring is now stale and has to be swept.
        assert_eq!(catalog.stale_bundled_hooks().len(), 1);
        let _ = std::fs::remove_dir_all(&directory);
    }

    fn tempdir(label: &str) -> PathBuf {
        let base = std::env::temp_dir().join(format!(
            "fyolod-agent-{label}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).expect("temp dir");
        base
    }
}
