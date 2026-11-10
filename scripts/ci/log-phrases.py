#!/usr/bin/env python3
"""Every literal log phrase in a Loki rule must exist in the code that logs it.

Usage: log-phrases.py <tool-source-dir> <repo-root> <rules.yaml>...

A Loki rule matches log TEXT. When the code that writes that text changes its
wording, the rule still parses and still passes its fixture tests, but it can
never fire again. This check closes that gap: it takes the literal parts of
each line filter, `message` filter, `regexp` pattern and `event` value, and
looks for them in the right source:

  tool stages (upload, assign, deidentify, group..., package)  -> the Python
      package inside the pinned image (<tool-source-dir>)
  our own components (data-policy, reclaimers, orthanc, ...)   -> this repo
  no component selector                                         -> either

Output: one line per check, tab separated: PASS|FAIL <alert> <detail>.
Exit 1 when any check fails.
"""
import os
import re
import sys

import yaml

TOOL_COMPONENTS = {
    "upload", "store", "assign", "label", "deidentify", "group", "group-fs",
    "group-orthanc", "collate", "collate-orthanc", "package",
}
MIN_LEN = 8  # shorter fragments match too much text to prove anything

FILTER = re.compile(r'(\|=|\|~)\s*("(?:[^"\\]|\\.)*"|`[^`]*`)')
FIELD = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*(=~|=)\s*("(?:[^"\\]|\\.)*"|`[^`]*`)')
SELECTOR = re.compile(r'\{[^{}]*\}')
# Stream labels and parser bookkeeping, not log text.
NOT_TEXT = {"namespace", "app", "component", "container", "pod", "job", "stream",
            "cluster", "level", "severity", "source", "__error__"}
# Text that is not in the tool's package or in this repo. Each entry says why.
KNOWN = {
    "traceback (most recent call last)":
        ("PASS", "printed by the Python interpreter for any uncaught exception"),
    "new stored instance":
        ("SKIP", "Orthanc server text. Orthanc 1.12.11 writes 'New instance stored', "
                 "and only with --verbose, so OrthancStorageGrowing cannot fire as written"),
}
REGEXP = re.compile(r'\|\s*regexp\s+("(?:[^"\\]|\\.)*"|`[^`]*`)')
COMPONENT = re.compile(r'component\s*(=~|=)\s*"([^"]+)"')


def unquote(tok):
    """A LogQL string: backtick strings are raw, double-quoted ones unescape."""
    if tok.startswith("`"):
        return tok[1:-1]
    return re.sub(r'\\(.)', r'\1', tok[1:-1])


def fragments(text, is_regex):
    """The literal runs of a pattern, and whether ANY one is enough (alternation)."""
    if not is_regex:
        return ([text] if len(text.strip()) >= MIN_LEN else []), False
    out, buf, i, alternation = [], "", 0, False
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt in "dDwWsSbB":
                out.append(buf); buf = ""
            else:
                buf += nxt
            i += 2
            continue
        if ch == "[":
            end = text.find("]", i + 1)
            out.append(buf); buf = ""
            i = end + 1 if end > 0 else i + 1
            continue
        if ch == "(" and text[i + 1:i + 2] == "?":
            end = text.find(">", i) if text[i + 2:i + 3] == "P" else text.find(")", i)
            out.append(buf); buf = ""
            i = end + 1
            continue
        if ch in "*+?":
            buf = buf[:-1]
            out.append(buf); buf = ""
            i += 1
            continue
        if ch == "{":
            end = text.find("}", i)
            buf = buf[:-1]
            out.append(buf); buf = ""
            i = end + 1 if end > 0 else i + 1
            continue
        if ch in "().^$|":
            if ch == "|":
                alternation = True
            out.append(buf); buf = ""
            i += 1
            continue
        buf += ch
        i += 1
    out.append(buf)
    return [s for s in out if len(s.strip()) >= MIN_LEN], alternation


def corpus(paths, skip):
    """Text of every file under the paths. Adjacent string literals are also
    joined, so a message built from two lines of source is found whole."""
    texts = []
    for base in paths:
        for root, dirs, files in os.walk(base):
            # CI scripts hold fixture log lines and this check's own list of
            # known text, so they never count as a source.
            dirs[:] = [d for d in dirs if d not in ("tests", ".git", "__pycache__")
                       and os.path.join(root, d) != os.path.join(base, "ci")]
            for name in files:
                path = os.path.join(root, name)
                if os.path.abspath(path) in skip or name.endswith((".pyc", ".png", ".tgz")):
                    continue
                try:
                    text = open(path, encoding="utf-8", errors="replace").read()
                except OSError:
                    continue
                texts.append(text)
                texts.append(re.sub(r'(?:[\'"])\s*\n\s*[rbfu]*(?:[\'"])', "", text))
    return "\n".join(texts)


def rules(node):
    if isinstance(node, dict):
        if "alert" in node and "expr" in node:
            yield node
        for value in node.values():
            yield from rules(value)
    elif isinstance(node, list):
        for value in node:
            yield from rules(value)


def main():
    tool_dir, repo_root, rule_files = sys.argv[1], sys.argv[2], sys.argv[3:]
    skip = {os.path.abspath(f) for f in rule_files}
    tool = corpus([tool_dir], skip)
    ours = corpus([os.path.join(repo_root, p) for p in ("charts", "scripts")], skip)
    failed = 0
    for rule_file in rule_files:
        for rule in rules(yaml.safe_load(open(rule_file))):
            expr, name = rule["expr"], rule["alert"]
            comps = set()
            for op, value in COMPONENT.findall(expr):
                comps |= set(value.split("|")) if op == "=~" else {value}
            if comps and comps <= TOOL_COMPONENTS:
                sources, where = [tool], "the pinned image"
            elif comps and not comps & TOOL_COMPONENTS:
                sources, where = [ours], "this repo"
            else:
                sources, where = [tool, ours], "the image or this repo"
            checks = [(unquote(t), op == "|~") for op, t in FILTER.findall(expr)]
            # Drop stream selectors and json extraction parameters
            # (`| json name="path"`): neither is log text.
            body = re.sub(r'\|\s*json\b[^|]*', '| json ', SELECTOR.sub(" ", expr))
            checks += [(unquote(t), op == "=~") for field, op, t in FIELD.findall(body)
                       if field not in NOT_TEXT]
            checks += [(unquote(t), True) for t in REGEXP.findall(expr)]
            for pattern, is_regex in checks:
                frags, any_one = fragments(pattern, is_regex)
                if not frags:
                    continue
                insensitive = "(?i)" in pattern
                def found(frag):
                    for src in sources:
                        hay = src.lower() if insensitive else src
                        if (frag.lower() if insensitive else frag) in hay:
                            return True
                    return False
                hits = [f for f in frags if found(f)]
                ok = bool(hits) if any_one else len(hits) == len(frags)
                missing = [f for f in frags if f not in hits]
                norm = lambda f: f.lower().strip().rstrip(":")
                known = [KNOWN[norm(f)] for f in missing if norm(f) in KNOWN]
                if ok:
                    print(f"PASS\t{name}\t'{frags[0][:60]}' found in {where}")
                elif known and len(known) == len(missing):
                    verdict, why = known[0]
                    print(f"{verdict}\t{name}\t'{missing[0][:50]}': {why}")
                else:
                    print(f"FAIL\t{name}\t'{missing[0][:70]}' is in the rule but not in {where}")
                    failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
