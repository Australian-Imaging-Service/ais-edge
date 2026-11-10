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

# Negative filters count too: a stale exclusion lets the wrong lines through.
FILTER = re.compile(r'(\|=|\|~|!=|!~)\s*("(?:[^"\\]|\\.)*"|`[^`]*`)')
FIELD = re.compile(r'\b([A-Za-z_][A-Za-z0-9_]*)\s*(=~|!~|!=|=)\s*("(?:[^"\\]|\\.)*"|`[^`]*`)')
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


class Unsupported(ValueError):
    """A regex shape the extraction does not read. It fails the check: a
    skipped shape would pass without a check."""


# Inline flags with no content: (?i), (?s), (?is), (?-i).
FLAGS_ONLY = re.compile(r"\(\?[aiLmsux-]+\)")
# Flags for a group whose content is a pattern: (?i:...).
FLAGS_SCOPED = re.compile(r"\(\?[aiLmsux-]+:")
INSENSITIVE = re.compile(r"\(\?[aLmsux]*i[aLmsux-]*[:)]")


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
            # Read the group prefix, then the content as usual: a whole-group
            # skip dropped every literal inside (?:...) and passed with no check.
            out.append(buf); buf = ""
            if text.startswith("(?:", i):            # non-capturing group
                i += 3
            elif text.startswith("(?P<", i):         # named group
                end = text.find(">", i)
                if end < 0:
                    raise Unsupported(f"unterminated group name at {text[i:i + 12]!r}")
                i = end + 1
            elif FLAGS_ONLY.match(text, i):          # inline flags, no content
                i = FLAGS_ONLY.match(text, i).end()
            elif FLAGS_SCOPED.match(text, i):        # flags with content
                i = FLAGS_SCOPED.match(text, i).end()
            else:                                    # lookaround, back-reference, other
                raise Unsupported(f"group {text[i:i + 6]!r} is not read by this check")
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


def evaluate(pattern, is_regex, sources):
    """(frags, missing): the literals of a pattern and those no source holds."""
    frags, _ = fragments(pattern, is_regex)
    insensitive = bool(is_regex and INSENSITIVE.search(pattern))
    def found(frag):
        for src in sources:
            hay = src.lower() if insensitive else src
            if (frag.lower() if insensitive else frag) in hay:
                return True
        return False
    return frags, [f for f in frags if not found(f)]


# CONTROLS. Each pattern names text that no source holds, so each must be
# reported missing. If one passes, the check no longer tells found from
# missing. The last shape must be refused, not skipped.
CONTROLS = (
    ("NEVER_LOGGED_SENTINEL_1f3a", True),
    ("(?:NEVER_LOGGED_SENTINEL_1f3a|ALSO_NEVER_LOGGED_9c2e)", True),
    ("(?i:never_logged_sentinel_1f3a)", True),
    ("(?P<x>NEVER_LOGGED_SENTINEL_1f3a)", True),
)
REFUSED = "(?=NEVER_LOGGED_SENTINEL_1f3a)"


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
    failed = checked = 0
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
            checks = [(unquote(t), op in ("|~", "!~")) for op, t in FILTER.findall(expr)]
            # Drop stream selectors and json extraction parameters
            # (`| json name="path"`): neither is log text.
            body = re.sub(r'\|\s*json\b[^|]*', '| json ', SELECTOR.sub(" ", expr))
            checks += [(unquote(t), op in ("=~", "!~")) for field, op, t in FIELD.findall(body)
                       if field not in NOT_TEXT]
            checks += [(unquote(t), True) for t in REGEXP.findall(expr)]
            # A field filter can also match the line-filter pattern: check each once.
            for pattern, is_regex in dict.fromkeys(checks):
                try:
                    frags, missing = evaluate(pattern, is_regex, sources)
                except Unsupported as exc:
                    print(f"FAIL\t{name}\tcannot read '{pattern[:60]}': {exc}")
                    failed += 1
                    continue
                if not frags:
                    continue
                checked += 1
                # Each long branch of an alternation names its own message, so
                # every one must exist; short ones were dropped above.
                ok = not missing
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
    if not checked:
        print("FAIL\t(all rules)\tno rule gave a phrase to check: the extraction looks for the wrong shape")
        failed += 1
    for pattern, is_regex in CONTROLS:
        frags, missing = evaluate(pattern, is_regex, [tool, ours])
        if frags and missing == frags:
            print(f"PASS\tcontrol\t'{pattern}' is reported missing")
        else:
            print(f"FAIL\tcontrol\t'{pattern}' is not reported missing (literals {frags}): the check no longer discriminates")
            failed += 1
    try:
        evaluate(REFUSED, True, [tool, ours])
        print(f"FAIL\tcontrol\t'{REFUSED}' was read, not refused: an unread shape would pass")
        failed += 1
    except Unsupported:
        print(f"PASS\tcontrol\t'{REFUSED}' is refused")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
