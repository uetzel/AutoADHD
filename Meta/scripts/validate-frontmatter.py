#!/usr/bin/env python3
"""
validate-frontmatter.py — Frontmatter schema validator for the vault.

Schema: Core + Extensions (Option B)
  - Universal core fields required for ALL typed notes
  - Type-specific required fields per entity type
  - Free extension fields allowed (no restriction on extras)
  - Catches: missing required fields, typos (fuzzy match), duplicate fields, bad dates

Usage:
  python3 validate-frontmatter.py                    # validate all Canon/ + Inbox/ files
  python3 validate-frontmatter.py Canon/People/       # validate one directory
  python3 validate-frontmatter.py Canon/Actions/X.md  # validate one file
  python3 validate-frontmatter.py --fix               # auto-fix what's fixable (add missing updated:, etc.)

Exit code: 0 if clean, 1 if issues found.
"""

import os
import re
import sys
import json
from datetime import datetime, date
from pathlib import Path
from typing import Dict, List, Optional, Tuple
from collections import Counter

VAULT_DIR = os.environ.get(
    "VAULT_DIR",
    "${VAULT_DIR:-$HOME/VaultSandbox}",
)

# ── Schema Definition ──────────────────────────────────────────────────

# Universal core fields — required for ALL notes with frontmatter
CORE_FIELDS = {
    "type": {"required": True, "type": "string"},
    "name": {"required": True, "type": "string"},
    "source": {"required": True, "type": "string"},
    "created": {"required": True, "type": "date"},
}

# Optional universal fields (not required, but tracked)
CORE_OPTIONAL = {
    "updated": {"type": "date"},
    "status": {"type": "string"},
    "linked": {"type": "list"},
}

# Type-specific required fields (on top of core)
TYPE_SCHEMAS = {
    "person": {
        "required": ["relationship"],
        "optional": [
            "relationship_to", "born", "role", "city", "phone", "email",
            "employer", "aliases", "locked", "tags", "birthday",
            "pronouns", "met_at", "nationality",
        ],
    },
    "action": {
        "required": ["status", "first_mentioned", "owner"],
        "optional": [
            "priority", "due", "start", "output", "mentions",
            "enrichment_status", "research", "parent_action",
            "sequence", "execution_type", "blocking", "depends_on",
            "agent_hint", "input_question", "target_state",
            "decomposed", "sub_steps_total", "sub_steps_completed",
        ],
    },
    "event": {
        "required": ["date"],
        "optional": [
            "participants", "location", "date_start", "date_end",
            "format", "topic", "organizer",
        ],
    },
    "concept": {
        "required": [],
        "optional": ["aliases", "tags"],
    },
    "decision": {
        "required": ["status", "decided"],
        "optional": [
            "alternatives", "outcome", "revisit", "context",
        ],
    },
    "project": {
        "required": ["status"],
        "optional": [
            "goal", "deadline", "team", "repo",
        ],
    },
    "place": {
        "required": [],
        "optional": [
            "city", "country", "district", "location", "address",
        ],
    },
    "organization": {
        "required": [],
        "optional": [
            "industry", "website", "city", "founded",
        ],
    },
    "group": {
        "required": [],
        "optional": ["members"],
    },
    "hub": {
        "required": [],
        "optional": [],
    },
    "agent-spec": {
        "required": [],
        "optional": [
            "script", "trigger", "schedule", "runtime",
            "design_principle",
        ],
    },
    "ai-reflection": {
        "required": [],
        "optional": ["agent", "description", "focus"],
    },
    "briefing": {
        "required": ["date"],
        "optional": [],
        "skip_core": ["name", "created"],  # briefings use date instead
    },
    "note": {
        "required": [],
        "optional": ["date"],
        "skip_core": ["name", "created"],
    },
    "advisor-knowledge": {
        "required": [],
        "optional": ["last_updated", "update_count"],
        "skip_core": ["name", "source", "created"],
    },
}

# Known field names across all types (for typo detection)
ALL_KNOWN_FIELDS = set()
ALL_KNOWN_FIELDS.update(CORE_FIELDS.keys())
ALL_KNOWN_FIELDS.update(CORE_OPTIONAL.keys())
for schema in TYPE_SCHEMAS.values():
    ALL_KNOWN_FIELDS.update(schema.get("required", []))
    ALL_KNOWN_FIELDS.update(schema.get("optional", []))

# Common typo mappings
KNOWN_TYPOS = {
    "pdated": "updated",
    "udpated": "updated",
    "upated": "updated",
    "creatd": "created",
    "crated": "created",
    "stauts": "status",
    "staus": "status",
    "pirority": "priority",
    "priorty": "priority",
    "realtionship": "relationship",
    "relationsip": "relationship",
    "fist_mentioned": "first_mentioned",
    "firsr_mentioned": "first_mentioned",
    "ower": "owner",
    "owenr": "owner",
    "souce": "source",
    "soruce": "source",
    "lnked": "linked",
    "linekd": "linked",
    "aliass": "aliases",
    "alaises": "aliases",
    "enrichment_staus": "enrichment_status",
    "reserach": "research",
    "relatioship_to": "relationship_to",
    "last_updated": "updated",  # normalize to standard name
}

# ── Frontmatter Parser ─────────────────────────────────────────────────

def parse_frontmatter(filepath: str) -> Tuple[Optional[Dict], List[str]]:
    """Parse YAML frontmatter from a markdown file.

    Returns (fields_dict, raw_lines) where raw_lines is the frontmatter
    lines for duplicate detection.
    """
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return None, []

    if not content.startswith("---"):
        return None, []

    # Find closing ---
    end_idx = content.find("\n---", 3)
    if end_idx == -1:
        return None, []

    fm_text = content[4:end_idx]  # Skip opening ---\n
    lines = fm_text.strip().split("\n")

    fields = {}
    raw_lines = []
    for line in lines:
        raw_lines.append(line)
        # Simple YAML key: value parsing (handles most vault cases)
        match = re.match(r'^(\w[\w_-]*)\s*:\s*(.*)', line)
        if match:
            key = match.group(1).strip()
            value = match.group(2).strip()
            # Strip quotes
            if value.startswith('"') and value.endswith('"'):
                value = value[1:-1]
            elif value.startswith("'") and value.endswith("'"):
                value = value[1:-1]
            fields[key] = value

    return fields, raw_lines


def find_duplicates(raw_lines: List[str]) -> List[str]:
    """Find duplicate field names in frontmatter."""
    keys = []
    for line in raw_lines:
        match = re.match(r'^(\w[\w_-]*)\s*:', line)
        if match:
            keys.append(match.group(1).strip())

    counts = Counter(keys)
    return [k for k, v in counts.items() if v > 1]


# ── Validation ─────────────────────────────────────────────────────────

class Issue:
    def __init__(self, filepath: str, level: str, message: str, fixable: bool = False):
        self.filepath = filepath
        self.level = level  # "error", "warning", "info"
        self.message = message
        self.fixable = fixable

    def __str__(self):
        icon = {"error": "❌", "warning": "⚠️", "info": "ℹ️"}[self.level]
        rel = os.path.relpath(self.filepath, VAULT_DIR)
        fix = " [auto-fixable]" if self.fixable else ""
        return f"{icon} {rel}: {self.message}{fix}"


def validate_date(value: str) -> bool:
    """Check if a value looks like a valid date."""
    # Accept YYYY-MM-DD, YYYY-MM, or YYYY
    patterns = [
        r'^\d{4}-\d{2}-\d{2}$',
        r'^\d{4}-\d{2}$',
        r'^\d{4}$',
    ]
    return any(re.match(p, value) for p in patterns)


def validate_file(filepath: str) -> List[Issue]:
    """Validate frontmatter for a single file."""
    issues = []
    fields, raw_lines = parse_frontmatter(filepath)

    if fields is None:
        # No frontmatter — only flag if in Canon/
        if "/Canon/" in filepath:
            issues.append(Issue(filepath, "warning", "No frontmatter found"))
        return issues

    # --- Check for duplicate fields ---
    dupes = find_duplicates(raw_lines)
    for d in dupes:
        issues.append(Issue(filepath, "error", f"Duplicate field: '{d}'"))

    # --- Check for typos ---
    for key in fields:
        if key in KNOWN_TYPOS:
            correct = KNOWN_TYPOS[key]
            issues.append(Issue(
                filepath, "error",
                f"Typo: '{key}' → should be '{correct}'",
                fixable=True,
            ))

    # --- Unknown fields (fuzzy match) ---
    note_type = fields.get("type", "")
    type_schema = TYPE_SCHEMAS.get(note_type, {})
    type_fields = set(type_schema.get("required", []) + type_schema.get("optional", []))
    known = ALL_KNOWN_FIELDS | type_fields

    for key in fields:
        if key not in known and key not in KNOWN_TYPOS:
            # Check if it's close to a known field (Levenshtein-like)
            close = _find_close_match(key, known)
            if close:
                issues.append(Issue(
                    filepath, "warning",
                    f"Unknown field '{key}' — did you mean '{close}'?",
                ))

    # --- Check type field ---
    if "type" not in fields:
        if "/Canon/" in filepath:
            issues.append(Issue(filepath, "error", "Missing required field: 'type'", fixable=False))
        return issues  # Can't validate type-specific fields without type

    # --- Core field validation ---
    skip_core = set(type_schema.get("skip_core", []))
    for field, spec in CORE_FIELDS.items():
        if field in skip_core:
            continue
        if spec["required"] and field not in fields:
            issues.append(Issue(
                filepath, "error",
                f"Missing required core field: '{field}'",
                fixable=(field == "updated"),
            ))
        elif field in fields and spec.get("type") == "date":
            if fields[field] and not validate_date(fields[field]):
                issues.append(Issue(
                    filepath, "warning",
                    f"Field '{field}' has invalid date format: '{fields[field]}' (expected YYYY-MM-DD)",
                ))

    # --- Type-specific required fields ---
    for field in type_schema.get("required", []):
        if field not in fields:
            issues.append(Issue(
                filepath, "warning",
                f"Missing type-specific field: '{field}' (required for type: {note_type})",
                fixable=False,
            ))

    # --- Validate date fields ---
    date_fields = ["created", "updated", "date", "due", "start", "born",
                    "decided", "date_start", "date_end", "first_mentioned"]
    for df in date_fields:
        if df in fields and fields[df]:
            val = fields[df].strip()
            if val and not validate_date(val):
                issues.append(Issue(
                    filepath, "warning",
                    f"Field '{df}' has invalid date: '{val}'",
                ))

    # --- Check updated field exists (common miss) ---
    if "updated" not in fields and "updated" not in skip_core and "/Canon/" in filepath:
        issues.append(Issue(
            filepath, "info",
            "Missing 'updated' field (recommended for Canon entries)",
            fixable=True,
        ))

    return issues


def _find_close_match(word: str, candidates: set, max_dist: int = 2) -> Optional[str]:
    """Simple edit distance check for typo detection."""
    word_lower = word.lower()
    for c in candidates:
        c_lower = c.lower()
        if word_lower == c_lower:
            continue
        # Simple Levenshtein approximation: check if strings differ by 1-2 chars
        if abs(len(word) - len(c)) > max_dist:
            continue
        dist = _levenshtein(word_lower, c_lower)
        if 0 < dist <= max_dist:
            return c
    return None


def _levenshtein(s1: str, s2: str) -> int:
    """Compute Levenshtein distance between two strings."""
    if len(s1) < len(s2):
        return _levenshtein(s2, s1)
    if len(s2) == 0:
        return len(s1)

    prev_row = range(len(s2) + 1)
    for i, c1 in enumerate(s1):
        curr_row = [i + 1]
        for j, c2 in enumerate(s2):
            insertions = prev_row[j + 1] + 1
            deletions = curr_row[j] + 1
            substitutions = prev_row[j] + (c1 != c2)
            curr_row.append(min(insertions, deletions, substitutions))
        prev_row = curr_row

    return prev_row[-1]


# ── Auto-fix ───────────────────────────────────────────────────────────

def fix_file(filepath: str, issues: List[Issue]) -> int:
    """Apply auto-fixes for fixable issues. Returns count of fixes applied."""
    if not any(i.fixable for i in issues):
        return 0

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError):
        return 0

    fixes = 0

    for issue in issues:
        if not issue.fixable:
            continue

        if "Typo:" in issue.message:
            # Extract typo and correct field name
            match = re.search(r"'(\w+)' → should be '(\w+)'", issue.message)
            if match:
                typo, correct = match.group(1), match.group(2)
                # Check if the correct field already exists
                if re.search(rf'^{correct}\s*:', content, re.MULTILINE):
                    # Correct field already exists — just remove the typo line
                    content = re.sub(rf'^{typo}\s*:.*\n', '', content, count=1, flags=re.MULTILINE)
                else:
                    # Replace the typo with the correct name
                    content = re.sub(
                        rf'^{typo}(\s*:)',
                        f'{correct}\\1',
                        content,
                        count=1,
                        flags=re.MULTILINE,
                    )
                fixes += 1

        elif "Missing 'updated'" in issue.message or "Missing required core field: 'updated'" in issue.message:
            # Add updated field with today's date
            today = date.today().isoformat()
            # Insert before the closing ---
            content = re.sub(
                r'^(---)\s*$',
                f'updated: {today}\n\\1',
                content,
                count=1,
                flags=re.MULTILINE,
            )
            # Only add if we're replacing the SECOND ---
            # Actually, safer approach: find the frontmatter block and insert before closing ---
            if content.startswith("---"):
                end_idx = content.find("\n---", 3)
                if end_idx != -1:
                    # Check if updated already present (might have been added)
                    fm = content[4:end_idx]
                    if "updated:" not in fm:
                        content = content[:end_idx] + f"\nupdated: {today}" + content[end_idx:]
                        fixes += 1

    if fixes > 0:
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(content)

    return fixes


# ── Main ───────────────────────────────────────────────────────────────

def collect_files(target: str) -> List[str]:
    """Collect .md files to validate."""
    target_path = Path(target)

    if target_path.is_file():
        return [str(target_path)]

    if target_path.is_dir():
        files = []
        for f in sorted(target_path.rglob("*.md")):
            # Skip hidden dirs and special files
            parts = f.relative_to(target_path).parts
            if any(p.startswith(".") for p in parts):
                continue
            files.append(str(f))
        return files

    return []


def main():
    args = sys.argv[1:]
    do_fix = "--fix" in args
    args = [a for a in args if a != "--fix"]
    json_output = "--json" in args
    args = [a for a in args if a != "--json"]

    # Default: validate Canon/ and Inbox/
    if not args:
        targets = [
            os.path.join(VAULT_DIR, "Canon"),
            os.path.join(VAULT_DIR, "Inbox"),
            os.path.join(VAULT_DIR, "Meta", "Agents"),
            os.path.join(VAULT_DIR, "Meta", "AI-Reflections"),
        ]
    else:
        targets = [os.path.join(VAULT_DIR, a) if not os.path.isabs(a) else a for a in args]

    all_files = []
    for t in targets:
        all_files.extend(collect_files(t))

    all_issues = []
    files_checked = 0
    files_with_issues = 0
    fixes_applied = 0

    for filepath in all_files:
        files_checked += 1
        issues = validate_file(filepath)

        if do_fix and issues:
            fixes_applied += fix_file(filepath, issues)
            # Re-validate after fix
            issues = validate_file(filepath)

        if issues:
            files_with_issues += 1
            all_issues.extend(issues)

    if json_output:
        result = {
            "files_checked": files_checked,
            "files_with_issues": files_with_issues,
            "total_issues": len(all_issues),
            "fixes_applied": fixes_applied,
            "issues": [
                {
                    "file": os.path.relpath(i.filepath, VAULT_DIR),
                    "level": i.level,
                    "message": i.message,
                    "fixable": i.fixable,
                }
                for i in all_issues
            ],
        }
        print(json.dumps(result, indent=2))
    else:
        # Group by severity
        errors = [i for i in all_issues if i.level == "error"]
        warnings = [i for i in all_issues if i.level == "warning"]
        infos = [i for i in all_issues if i.level == "info"]

        print(f"\n📋 Frontmatter Validation Report")
        print(f"   Files checked: {files_checked}")
        print(f"   Files with issues: {files_with_issues}")
        print(f"   Errors: {len(errors)} | Warnings: {len(warnings)} | Info: {len(infos)}")
        if fixes_applied:
            print(f"   Fixes applied: {fixes_applied}")
        print()

        if errors:
            print("❌ ERRORS (must fix):")
            for i in errors:
                print(f"   {i}")
            print()

        if warnings:
            print("⚠️  WARNINGS (should fix):")
            for i in warnings:
                print(f"   {i}")
            print()

        if infos:
            print("ℹ️  INFO (nice to have):")
            for i in infos:
                print(f"   {i}")
            print()

        if not all_issues:
            print("✅ All frontmatter is clean!")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
