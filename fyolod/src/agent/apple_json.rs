//! Foundation-compatible JSON output.
//!
//! The hook installers merge into files the user also owns, and until Stage 4 of
//! `docs/design/20260825-agent-integration-moves-to-fyolod.md` the Swift
//! installer is still writing the same files with
//! `JSONSerialization.data(options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])`.
//! Two writers with different spellings would rewrite a user's
//! `~/.claude/settings.json` on every launch, each undoing the other's layout —
//! churn in a file somebody edits by hand. So this reproduces Foundation's
//! output byte for byte:
//!
//! - two-space indent, `"key" : value` with a space on each side of the colon,
//!   and an empty container spelled `{\n\n}`;
//! - `/` left unescaped, control characters escaped the way `\b\t\n\f\r` and
//!   `\u00xx` say, everything else emitted as UTF-8;
//! - keys ordered by `.sortedKeys`, which is **not** byte order: it is ICU root
//!   collation, where punctuation sorts before digits before letters, case is a
//!   tie-break rather than a primary difference, and runs of digits compare
//!   numerically. `hooks` sorts before `Hooks_x` before `hooksy`.
//!
//! Two limits, stated because they are the ones that would show up as a single
//! spurious rewrite (never as a lost setting): an integer larger than 64 bits is
//! re-emitted through `f64`, where Foundation keeps it exact; and a key
//! containing a non-ASCII character sorts after every ASCII key here, where
//! Foundation would fold an accent onto its base letter. Neither appears in any
//! agent's config format.

use serde_json::{Map, Value};

/// Parse the bytes the way `JSONSerialization.jsonObject` would: strict JSON,
/// no comments and no trailing commas. `None` means "do not touch this file".
pub fn parse(bytes: &[u8]) -> Option<Value> {
    serde_json::from_slice(bytes).ok()
}

/// Serialize the way Foundation would, for a top-level object.
pub fn to_bytes(value: &Value) -> Vec<u8> {
    let mut out = String::new();
    write_value(value, 0, &mut out);
    out.into_bytes()
}

fn write_value(value: &Value, indent: usize, out: &mut String) {
    match value {
        Value::Null => out.push_str("null"),
        Value::Bool(true) => out.push_str("true"),
        Value::Bool(false) => out.push_str("false"),
        Value::Number(number) => out.push_str(&format_number(number)),
        Value::String(text) => write_string(text, out),
        Value::Array(items) => write_array(items, indent, out),
        Value::Object(entries) => write_object(entries, indent, out),
    }
}

fn write_array(items: &[Value], indent: usize, out: &mut String) {
    out.push_str("[\n");
    for (index, item) in items.iter().enumerate() {
        if index > 0 {
            out.push_str(",\n");
        }
        pad(indent + 2, out);
        write_value(item, indent + 2, out);
    }
    out.push('\n');
    pad(indent, out);
    out.push(']');
}

fn write_object(entries: &Map<String, Value>, indent: usize, out: &mut String) {
    let mut keys: Vec<&String> = entries.keys().collect();
    keys.sort_by(|a, b| compare_keys(a, b));
    out.push_str("{\n");
    for (index, key) in keys.iter().enumerate() {
        if index > 0 {
            out.push_str(",\n");
        }
        pad(indent + 2, out);
        write_string(key, out);
        out.push_str(" : ");
        if let Some(value) = entries.get(*key) {
            write_value(value, indent + 2, out);
        }
    }
    out.push('\n');
    pad(indent, out);
    out.push('}');
}

fn pad(width: usize, out: &mut String) {
    for _ in 0..width {
        out.push(' ');
    }
}

fn write_string(text: &str, out: &mut String) {
    out.push_str(&string_literal(text, false));
}

/// A JSON string literal, quotes included, escaped the way Foundation escapes.
///
/// `escape_slashes` is the `withoutEscapingSlashes` option inverted, and it is
/// not cosmetic: the hook files this module writes are produced *without*
/// slash escaping, and the plugin sources in [`super::plugin`] are produced
/// *with* it, because Swift builds those through a plain
/// `JSONSerialization.data(withJSONObject:)` that has no such option. Both
/// spellings are on disk in a user's home right now, so both have to exist here.
pub fn string_literal(text: &str, escape_slashes: bool) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for character in text.chars() {
        match character {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '/' if escape_slashes => out.push_str("\\/"),
            '\u{8}' => out.push_str("\\b"),
            '\t' => out.push_str("\\t"),
            '\n' => out.push_str("\\n"),
            '\u{c}' => out.push_str("\\f"),
            '\r' => out.push_str("\\r"),
            character if (character as u32) < 0x20 => {
                out.push_str(&format!("\\u{:04x}", character as u32));
            }
            character => out.push(character),
        }
    }
    out.push('"');
    out
}

/// Foundation prints a double through `%.17g`, and an integer exactly.
fn format_number(number: &serde_json::Number) -> String {
    if let Some(value) = number.as_i64() {
        return value.to_string();
    }
    if let Some(value) = number.as_u64() {
        return value.to_string();
    }
    match number.as_f64() {
        Some(value) => format_double(value),
        None => number.to_string(),
    }
}

/// C's `%.17g`: seventeen significant digits, fixed notation unless the decimal
/// exponent is below -4 or at least 17, trailing zeros stripped, and a
/// two-digit-minimum signed exponent.
fn format_double(value: f64) -> String {
    if !value.is_finite() || value == 0.0 {
        return "0".to_string();
    }
    const PRECISION: i32 = 17;
    let scientific = format!("{:.*e}", (PRECISION - 1) as usize, value);
    let (mantissa, exponent) = match scientific.split_once('e') {
        Some(parts) => parts,
        None => return scientific,
    };
    let exponent: i32 = exponent.parse().unwrap_or(0);
    if exponent < -4 || exponent >= PRECISION {
        let sign = if exponent < 0 { '-' } else { '+' };
        return format!(
            "{}e{sign}{:02}",
            strip_trailing_zeros(mantissa),
            exponent.abs()
        );
    }
    let decimals = (PRECISION - 1 - exponent).max(0) as usize;
    strip_trailing_zeros(&format!("{value:.decimals$}"))
}

fn strip_trailing_zeros(text: &str) -> String {
    if !text.contains('.') {
        return text.to_string();
    }
    let trimmed = text.trim_end_matches('0');
    trimmed.strip_suffix('.').unwrap_or(trimmed).to_string()
}

// MARK: - `.sortedKeys` ordering

/// One collation element. The variant order *is* the class order: punctuation
/// and symbols first, then numbers, then letters, then everything else.
#[derive(PartialEq, Eq, PartialOrd, Ord)]
enum Primary {
    Symbol(u32),
    /// A run of digits, compared by value: `item2` before `item10`, and `09`
    /// equal in weight to `9`.
    Number(NumericRun),
    Letter(u32),
    Other(u32),
}

/// A digit run's significant digits. Longer is larger; same length compares
/// lexicographically, which for digits is the same as numerically — and works
/// for a run longer than any integer type.
#[derive(PartialEq, Eq)]
struct NumericRun(String);

impl Ord for NumericRun {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.0
            .len()
            .cmp(&other.0.len())
            .then_with(|| self.0.cmp(&other.0))
    }
}

impl PartialOrd for NumericRun {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

/// ICU root collation order for the printable ASCII symbols, read off
/// Foundation itself rather than guessed. Digits and letters follow, as their
/// own classes.
const SYMBOL_ORDER: [char; 33] = [
    ' ', '_', '-', ',', ';', ':', '!', '?', '.', '\'', '"', '(', ')', '[', ']', '{', '}', '@', '*',
    '/', '\\', '&', '#', '%', '`', '^', '+', '<', '=', '>', '|', '~', '$',
];

fn compare_keys(left: &str, right: &str) -> std::cmp::Ordering {
    let (left_primary, left_case) = collation_key(left);
    let (right_primary, right_case) = collation_key(right);
    left_primary
        .cmp(&right_primary)
        .then_with(|| left_case.cmp(&right_case))
}

/// Split a key into its primary weights and its case weights. Case is a
/// tie-break level, not part of the primary comparison, which is why `ab` sorts
/// before `abc` even though `Ab` sorts after `ab`.
fn collation_key(key: &str) -> (Vec<Primary>, Vec<u8>) {
    let mut primary = Vec::new();
    let mut case = Vec::new();
    let mut characters = key.chars().peekable();
    while let Some(character) = characters.next() {
        if character.is_ascii_digit() {
            let mut digits = String::from(character);
            while let Some(next) = characters.peek() {
                if next.is_ascii_digit() {
                    digits.push(*next);
                    characters.next();
                } else {
                    break;
                }
            }
            let significant = digits.trim_start_matches('0');
            primary.push(Primary::Number(NumericRun(significant.to_string())));
            case.push(0);
        } else if character.is_ascii_alphabetic() {
            primary.push(Primary::Letter(
                character.to_ascii_lowercase() as u32 - 'a' as u32,
            ));
            case.push(if character.is_ascii_uppercase() { 1 } else { 0 });
        } else if let Some(index) = SYMBOL_ORDER.iter().position(|s| *s == character) {
            primary.push(Primary::Symbol(index as u32));
            case.push(0);
        } else {
            primary.push(Primary::Other(character as u32));
            case.push(0);
        }
    }
    (primary, case)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rendered(source: &str) -> String {
        String::from_utf8(to_bytes(&parse(source.as_bytes()).expect("valid JSON")))
            .expect("utf-8")
    }

    /// The exact bytes Foundation produces for this input, captured from
    /// `JSONSerialization` on macOS. If this ever fails, the Swift installer and
    /// this one have started writing different files.
    #[test]
    fn matches_foundations_layout() {
        let source = r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x"}]}],
            "PostToolUse":[]},"version":1,"empty":{},"path":"https://x/y"}"#;
        assert_eq!(
            rendered(source),
            "{\n  \"empty\" : {\n\n  },\n  \"hooks\" : {\n    \"PostToolUse\" : [\n\n    ],\n    \
             \"Stop\" : [\n      {\n        \"hooks\" : [\n          {\n            \
             \"command\" : \"x\",\n            \"type\" : \"command\"\n          }\n        ]\n      \
             }\n    ]\n  },\n  \"path\" : \"https://x/y\",\n  \"version\" : 1\n}"
        );
    }

    #[test]
    fn sorted_keys_is_icu_collation_not_byte_order() {
        let mut keys = vec![
            "$schema", "_under", "-dash", ".dot", "~tilde", "1", "1abc", "2", "09", "10", "a", "A",
            "a b", "a_b", "a-b", "ab", "aB", "Ab", "abc1", "hooks", "Hooks", "statusLine", "Z",
            "zz", "x2y", "x10y",
        ];
        keys.sort_by(|a, b| compare_keys(a, b));
        assert_eq!(
            keys,
            vec![
                "_under", "-dash", ".dot", "~tilde", "$schema", "1", "1abc", "2", "09", "10", "a",
                "A", "a b", "a_b", "a-b", "ab", "aB", "Ab", "abc1", "hooks", "Hooks", "statusLine",
                "x2y", "x10y", "Z", "zz",
            ]
        );
    }

    #[test]
    fn strings_escape_the_way_foundation_escapes() {
        assert_eq!(
            rendered("{\"k\":\"a\\\"b\\\\c/d\\b\\t\\n\\f\\r\\u0001\\u001f\"}"),
            "{\n  \"k\" : \"a\\\"b\\\\c/d\\b\\t\\n\\f\\r\\u0001\\u001f\"\n}"
        );
        // Non-ASCII travels as UTF-8, not as an escape.
        assert_eq!(rendered(r#"{"k":"é中"}"#), "{\n  \"k\" : \"é中\"\n}");
    }

    #[test]
    fn doubles_print_through_the_same_seventeen_digits() {
        for (source, expected) in [
            ("1.0", "1"),
            ("1e3", "1000"),
            ("0.1", "0.10000000000000001"),
            ("1.5e-7", "1.4999999999999999e-07"),
            ("1e20", "1e+20"),
            ("1e17", "1e+17"),
            ("1e16", "10000000000000000"),
            ("1e-4", "0.0001"),
            ("1e-5", "1.0000000000000001e-05"),
            ("2.5", "2.5"),
            ("-1.25", "-1.25"),
            ("3.14159265358979", "3.14159265358979"),
            ("9007199254740993", "9007199254740993"),
        ] {
            assert_eq!(
                rendered(&format!("{{\"k\":{source}}}")),
                format!("{{\n  \"k\" : {expected}\n}}"),
                "for {source}"
            );
        }
    }

    #[test]
    fn a_file_that_is_not_json_is_not_touched() {
        assert!(parse(b"{ // a comment\n }").is_none());
        assert!(parse(b"{\"a\": 1,}").is_none());
        assert!(parse(b"not json").is_none());
    }
}
