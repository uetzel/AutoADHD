#!/usr/bin/env python3
"""Parse structured Advisor agent output into JSON.

Input:  Claude's raw output on stdin
Output: JSON on stdout with keys "response" (str) and "triggers" (list of {type, value})

Protocol delimiters: ---RESPONSE--- / ---TRIGGERS--- / ---END---
Delimiters inside code blocks (``` ... ```) are ignored.

Supported trigger types:
  RESEARCH: <topic>              — spawn researcher agent
  DECOMPOSE: <action file path>  — spawn task-enricher --decompose
  LOG_DECISION: title | decided | why | rejected | check_later
  CREATE_ACTION: name | priority | due | output
  EXTRACT: <file path>           — run extractor on a file
  MODE_SWITCH: deep              — upgrade triage to full conversation
  END_CONVERSATION: <reason>     — end active session
  UPDATE_KNOWLEDGE: section | learning  — append to advisor-knowledge.md
"""

import json
import os
import re
import sys

# Valid trigger types — anything else is logged but ignored
VALID_TRIGGERS = {
    "RESEARCH", "DECOMPOSE", "LOG_DECISION", "CREATE_ACTION",
    "EXTRACT", "MODE_SWITCH", "END_CONVERSATION", "UPDATE_KNOWLEDGE",
}


def parse(raw: str) -> dict:
    # Strip code blocks so delimiters inside them don't confuse the parser
    # Work on the stripped version for all delimiter finding
    stripped = re.sub(r"```[\s\S]*?```", "", raw)

    resp_idx = stripped.find("---RESPONSE---")
    trig_idx = stripped.find("---TRIGGERS---")
    end_idx = stripped.find("---END---")

    # No delimiters found — entire output is the response
    if resp_idx == -1:
        return {"response": raw.strip(), "triggers": []}

    response = ""
    triggers = []

    if resp_idx != -1 and trig_idx != -1:
        response = stripped[resp_idx + len("---RESPONSE---"):trig_idx].strip()
    elif resp_idx != -1:
        end = end_idx if end_idx != -1 else len(stripped)
        response = stripped[resp_idx + len("---RESPONSE---"):end].strip()

    if trig_idx != -1:
        end = end_idx if end_idx != -1 else len(stripped)
        block = stripped[trig_idx + len("---TRIGGERS---"):end].strip()
        for line in block.splitlines():
            line = line.strip()
            if not line:
                continue
            if ":" in line:
                t, v = line.split(":", 1)
                t = t.strip()
                v = v.strip()
                if t in VALID_TRIGGERS:
                    triggers.append({"type": t, "value": v})
                else:
                    # Log unknown trigger to stderr, don't crash
                    print(f"Warning: unknown trigger type '{t}'", file=sys.stderr)

    return {"response": response, "triggers": triggers}


def handle_update_knowledge(value: str, vault_dir: str = None):
    """Append a learning to the appropriate section of advisor-knowledge.md.

    Value format: "section | learning text"
    Uses file I/O instead of shell string interpolation to avoid quote injection.
    """
    if "|" not in value:
        print(f"Warning: UPDATE_KNOWLEDGE missing '|' separator: {value}", file=sys.stderr)
        return False

    section, learning = value.split("|", 1)
    section = section.strip()
    learning = learning.strip()

    if not section or not learning:
        return False

    if vault_dir is None:
        vault_dir = os.path.join(os.path.dirname(__file__), "..", "..")
        vault_dir = os.path.normpath(vault_dir)

    knowledge_file = os.path.join(vault_dir, "Meta", "Agents", "advisor-knowledge.md")
    if not os.path.exists(knowledge_file):
        print(f"Warning: knowledge file not found: {knowledge_file}", file=sys.stderr)
        return False

    with open(knowledge_file, "r") as f:
        content = f.read()

    marker = f"## {section}"
    if marker not in content:
        print(f"Warning: section '{section}' not found in knowledge file", file=sys.stderr)
        return False

    # Find the section and append before the next ## header (or end of file)
    parts = content.split(marker, 1)
    rest = parts[1]
    next_header = rest.find("\n## ")
    if next_header == -1:
        insert_at = len(rest)
    else:
        insert_at = next_header

    new_content = parts[0] + marker + rest[:insert_at].rstrip() + "\n- " + learning + "\n" + rest[insert_at:]

    with open(knowledge_file, "w") as f:
        f.write(new_content)

    # Update the last_updated and update_count in frontmatter
    import datetime
    today = datetime.date.today().isoformat()
    new_content = re.sub(r"^last_updated:.*$", f"last_updated: {today}", new_content, flags=re.MULTILINE)
    # Increment update_count
    count_match = re.search(r"^update_count:\s*(\d+)", new_content, re.MULTILINE)
    if count_match:
        old_count = int(count_match.group(1))
        new_content = re.sub(
            r"^update_count:\s*\d+",
            f"update_count: {old_count + 1}",
            new_content,
            flags=re.MULTILINE,
        )
    with open(knowledge_file, "w") as f:
        f.write(new_content)

    return True


if __name__ == "__main__":
    raw_input = sys.stdin.read()
    result = parse(raw_input)
    json.dump(result, sys.stdout, ensure_ascii=False)
    print()
