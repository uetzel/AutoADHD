#!/usr/bin/env python3
"""Pytest tests for parse-advisor-output.py"""
import subprocess
import os
import json

SCRIPT = os.path.join(os.path.dirname(__file__), "parse-advisor-output.py")


def run_parser(input_text):
    result = subprocess.run(
        ["python3", SCRIPT],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=5,
    )
    parsed = json.loads(result.stdout) if result.stdout.strip() else {}
    return parsed, result.returncode


def test_happy_path():
    """Full structured output with response and triggers."""
    text = """---RESPONSE---
This is the advisor's answer.
It has multiple lines.
---TRIGGERS---
RESEARCH: Hamburg AI market
LOG_DECISION: Title | Decided | Why | Rejected | 2026-05-01
CREATE_ACTION: New Task | high | 2026-04-15 | Something done
---END---"""
    parsed, rc = run_parser(text)
    assert rc == 0
    assert "advisor's answer" in parsed["response"]
    assert len(parsed["triggers"]) == 3
    assert parsed["triggers"][0]["type"] == "RESEARCH"
    assert parsed["triggers"][0]["value"] == "Hamburg AI market"


def test_no_triggers():
    """Response section only, no triggers."""
    text = """---RESPONSE---
Just a simple answer.
---END---"""
    parsed, rc = run_parser(text)
    assert rc == 0
    assert "simple answer" in parsed["response"]
    assert parsed["triggers"] == []


def test_raw_output():
    """No delimiters at all, treat as pure response."""
    text = "This is plain output with no delimiters."
    parsed, rc = run_parser(text)
    assert rc == 0
    assert "plain output" in parsed["response"]
    assert parsed["triggers"] == []


def test_empty_input():
    """Empty input should not crash."""
    parsed, rc = run_parser("")
    assert rc == 0


def test_triggers_in_code_block():
    """Delimiters inside code blocks should not confuse parser."""
    text = """---RESPONSE---
Here's an example:
```
---TRIGGERS---
RESEARCH: this is inside a code block
---END---
```
The real content continues here.
---TRIGGERS---
RESEARCH: Real topic
---END---"""
    parsed, rc = run_parser(text)
    assert rc == 0
    # Should contain real trigger, not the code block one
    trigger_values = [t["value"] for t in parsed["triggers"]]
    assert "Real topic" in trigger_values


def test_missing_end_delimiter():
    """Missing ---END--- should still parse what's available."""
    text = """---RESPONSE---
Answer without end delimiter.
---TRIGGERS---
RESEARCH: Some topic"""
    parsed, rc = run_parser(text)
    assert rc == 0
    assert "without end delimiter" in parsed["response"]
    assert len(parsed["triggers"]) >= 1


def test_needs_input():
    """NEEDS_INPUT trigger should be extractable."""
    text = """---RESPONSE---
I need more information.
---TRIGGERS---
NEEDS_INPUT: What's your budget for this?
---END---"""
    parsed, rc = run_parser(text)
    assert rc == 0
    assert "need more information" in parsed["response"]
    assert parsed["triggers"][0]["type"] == "NEEDS_INPUT"


if __name__ == "__main__":
    import sys
    failures = 0
    for name, func in sorted(globals().items()):
        if name.startswith("test_") and callable(func):
            try:
                func()
                print(f"  ✅ {name}")
            except AssertionError as e:
                print(f"  ❌ {name}: {e}")
                failures += 1
            except Exception as e:
                print(f"  ❌ {name}: {e}")
                failures += 1
    print(f"\n{'All passed!' if failures == 0 else f'{failures} failed'}")
    sys.exit(failures)
