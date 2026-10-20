#!/usr/bin/env python3
"""Strict-type-check the plugin's Luau sources against tern.d.luau.

`luau-analyze` cannot load a definitions file, so this script translates
tern.d.luau into a plain Luau prelude (the `declare tern` global becomes a
typed local, `declare extern type` becomes a table type alias, `export type`
becomes `type`), pastes it above a copy of each source file under a temp dir
that mirrors the repo layout, runs `luau-analyze --mode=strict` on the copies
and maps every diagnostic back to the original file and line.

Usage:  python3 test/luau_check.py [--keep] [--prelude] [FILE.luau ...]

  With no FILE: host.luau, window.luau and lib/**/*.luau
  (those that exist). Modules reached through relative `require("./x")` from
  the listed files are checked too, so requires resolve to checked copies.

  --keep      keep the temp dir (path printed) for inspection
  --prelude   print the translated prelude and exit

Output is `path:line:col: message`. Exit status: 0 no errors in sources,
1 errors in sources, 2 errors inside the prelude (a translator bug), 3 the
analyzer could not run or its output could not be parsed.

Source files get the prelude's declarations as file-local types; a body that
declares a type of the same name keeps its own (the prelude's is skipped).
Lint warnings are printed as `warning:` and do not affect the exit status;
the prelude is lint-exempt.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFS = ROOT / "tern.d.luau"

# ---------------------------------------------------------------------------
# tern.d.luau -> prelude
# ---------------------------------------------------------------------------

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
RESERVED = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while", "continue",
}


class TranslateError(Exception):
    pass


def strip_comments(text: str) -> str:
    """Remove `--` comments (line and long form), respecting string literals."""
    out: list[str] = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c in "\"'":
            j = i + 1
            while j < n and text[j] != c and text[j] != "\n":
                j += 2 if text[j] == "\\" else 1
            out.append(text[i : j + 1])
            i = j + 1
        elif text.startswith("--", i):
            m = re.match(r"--\[(=*)\[", text[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = text.find(close, i)
                j = n if j < 0 else j + len(close)
                out.append("\n" * text.count("\n", i, j))
                i = j
            else:
                j = text.find("\n", i)
                i = n if j < 0 else j
        else:
            out.append(c)
            i += 1
    return "".join(out)


def scan_depth(s: str):
    """Yield (index, char, depth) for chars of `s` outside strings, where depth
    counts ()/{}/[]/<> nesting *before* the char; `->` is not an angle bracket."""
    depth = 0
    i, n = 0, len(s)
    while i < n:
        c = s[i]
        if c in "\"'":
            j = i + 1
            while j < n and s[j] != c:
                j += 2 if s[j] == "\\" else 1
            i = j + 1
            continue
        if c == "-" and s.startswith("->", i):
            yield i, "-", depth
            yield i + 1, ">", depth
            i += 2
            continue
        yield i, c, depth
        if c in "({[<":
            depth += 1
        elif c in ")}]>":
            depth -= 1
        i += 1


def split_top(s: str, sep: str) -> list[str]:
    parts, start = [], 0
    for i, c, d in scan_depth(s):
        if c == sep and d == 0:
            parts.append(s[start:i])
            start = i + 1
    parts.append(s[start:])
    return parts


def has_top(s: str, chars: str) -> bool:
    return any(c in chars and d == 0 for _, c, d in scan_depth(s))


def match_close(s: str, open_idx: int) -> int:
    """Index of the bracket closing the one at `open_idx`."""
    for i, c, d in scan_depth(s[open_idx:]):
        if d == 1 and c in ")}]>":
            return open_idx + i
    raise TranslateError(f"unbalanced bracket in {s[open_idx:open_idx + 60]!r}")


def ret_type(r: str) -> str:
    r = r.strip()
    if has_top(r, "|&"):
        return f"({r})"
    return r


def read_type(b: str, i: int) -> tuple[str, int]:
    """Read a type starting at b[i] up to a newline at depth 0 that does not
    continue with `|`/`&`; returns (type text, index after it)."""
    n = len(b)
    for k, c, d in scan_depth(b[i:]):
        j = i + k
        if c == "\n" and d == 0:
            rest = b[j:].lstrip()
            if not rest.startswith(("|", "&")):
                return b[i:j].strip().rstrip(","), j
    return b[i:n].strip().rstrip(","), n


def translate_members(name: str, body: str) -> list[str]:
    """Translate the members of a `declare extern type` body to table-type
    entries (without trailing commas)."""
    members: list[str] = []
    b = body
    i, n = 0, len(b)
    while True:
        while i < n and b[i] in " \t\r\n,":
            i += 1
        if i >= n:
            return members
        if re.match(r"function\b", b[i:]):
            i += len("function")
            while b[i] in " \t":
                i += 1
            m = IDENT.match(b, i)
            if not m:
                raise TranslateError(f"{name}: bad method name at {b[i:i+40]!r}")
            mname = m.group(0)
            i = m.end()
            generics = ""
            if b[i] == "<":
                j = match_close(b, i)
                generics = b[i : j + 1]
                i = j + 1
            if b[i] != "(":
                raise TranslateError(f"{name}.{mname}: expected ( got {b[i:i+20]!r}")
            j = match_close(b, i)
            params = [p.strip() for p in split_top(b[i + 1 : j], ",") if p.strip()]
            i = j + 1
            while i < n and b[i] in " \t":
                i += 1
            if i < n and b[i] == ":":
                ret, i = read_type(b, i + 1)
            else:
                ret = "()"
            if params and params[0] == "self":
                params[0] = f"self: {name}"
            members.append(
                f"{field_key(mname)}: {generics}({', '.join(params)}) -> {ret_type(ret)}"
            )
            continue
        # field: `ident: type` or `[key]: type`
        if b[i] == "[":
            j = match_close(b, i)
            key = b[i : j + 1]
            i = j + 1
        else:
            m = IDENT.match(b, i)
            if not m:
                raise TranslateError(f"{name}: cannot parse member at {b[i:i+60]!r}")
            key = field_key(m.group(0))
            i = m.end()
        while i < n and b[i] in " \t":
            i += 1
        if b[i] != ":":
            raise TranslateError(f"{name}: expected ':' after {key} at {b[i:i+40]!r}")
        typ, i = read_type(b, i + 1)
        members.append(f"{key}: {typ}")


def field_key(name: str) -> str:
    return f'["{name}"]' if name in RESERVED else name


def translate(defs_text: str, skip_types: frozenset[str] = frozenset()) -> str:
    """Translate tern.d.luau text to a Luau prelude (comment-free)."""
    text = strip_comments(defs_text)
    lines = text.split("\n")
    out: list[tuple[str, str]] = []  # (alias name, Luau text)
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"declare\s+extern\s+type\s+(\w+)(?:\s+extends\s+(\w+))?\s+with\b(.*)$", line)
        if m:
            name, parent, rest = m.groups()
            if rest.strip() == "end":
                body = ""
            else:
                chunk = [rest]
                i += 1
                while i < len(lines) and lines[i].strip() != "end":
                    chunk.append(lines[i])
                    i += 1
                if i >= len(lines):
                    raise TranslateError(f"unterminated extern type {name}")
                body = "\n".join(chunk)
            members = translate_members(name, body)
            if not members:
                # opaque handle: keep it distinct from every other table
                members = [f'__extern: "{name}"']
            table = "{\n" + "".join(f"\t{mm},\n" for mm in members) + "}"
            if name not in skip_types:
                out.append((name, f"type {name} = {parent + ' & ' if parent else ''}{table}"))
            i += 1
            continue
        m = re.match(r"declare\s+(\w+)\s*:\s*(.*)$", line)
        if m:
            name = m.group(1)
            first = line[line.index(":") + 1 :].lstrip()
            chunk, i = collect_statement(lines, i, first)
            out.append(("", f"local {name}: {chunk} = (nil :: any)"))
            continue
        if line.startswith("declare"):
            raise TranslateError(f"unsupported declaration: {line!r}")
        m = re.match(r"(?:export\s+)?type\s+(\w+)", line)
        if m:
            chunk, i = collect_statement(lines, i, line)
            if m.group(1) not in skip_types:
                out.append((m.group(1), re.sub(r"^export\s+", "", chunk)))
            continue
        if line.strip():
            raise TranslateError(f"unexpected top-level text: {line!r}")
        i += 1
    return "\n".join(t for _, t in break_generic_cycles(out)) + "\n"


def break_generic_cycles(entries: list[tuple[str, str]]) -> list[tuple[str, str]]:
    """Luau rejects a generic alias that sits in a reference cycle with another
    instantiation of itself ("Recursive type being used with different
    parameters"), e.g. `Awaitable<T>` -> `WindowCx` -> `Awaitable<string>`.
    luau-lsp's nominal extern types don't have this problem; here, inside such
    a generic alias, references to the types that lead back to it become `any`."""
    names = {n for n, _ in entries if n}
    refs: dict[str, set[str]] = {}
    for n, t in entries:
        if n:
            refs[n] = (set(re.findall(r"\b[A-Za-z_]\w*\b", t.split("=", 1)[1])) & names) - {n}

    def reaches(src: str, dst: str) -> bool:
        seen, stack = set(), [src]
        while stack:
            x = stack.pop()
            if x == dst:
                return True
            if x not in seen:
                seen.add(x)
                stack.extend(refs.get(x, ()))
        return False

    result = []
    for n, t in entries:
        if n and re.match(rf"type {n}<", t):
            head, body = t.split("=", 1)
            for r in sorted(refs[n]):
                if reaches(r, n):
                    body = re.sub(rf"\b{r}\b(?!<)", "any", body)
                    APPROXIMATIONS.append(f"{n}: references to {r} replaced by any")
            t = head + "=" + body
        result.append((n, t))
    return result


APPROXIMATIONS: list[str] = []


def collect_statement(lines: list[str], i: int, first: str) -> tuple[str, int]:
    """Gather a possibly multi-line type expression starting at lines[i] (whose
    text is `first`): continues while brackets are open, the line ends in an
    operator, or the next non-blank line starts with `|`/`&`. Returns
    (text, index of the next line)."""
    chunk = [first]
    i += 1
    while True:
        text = "\n".join(chunk)
        depth = 0
        for _, c, d in scan_depth(text):
            depth = d + (1 if c in "({[<" else -1 if c in ")}]>" else 0)
        stripped = text.rstrip()
        if depth > 0 or stripped.endswith(("=", "|", "&")):
            if i >= len(lines):
                raise TranslateError(f"unterminated statement: {first!r}")
            chunk.append(lines[i])
            i += 1
            continue
        j = i
        while j < len(lines) and not lines[j].strip():
            j += 1
        if j < len(lines) and lines[j].lstrip().startswith(("|", "&")):
            chunk.append(lines[j])
            i = j + 1
            continue
        return text, i


# ---------------------------------------------------------------------------
# Source preparation
# ---------------------------------------------------------------------------

REQUIRE = re.compile(r"""require\(\s*(["'])(\.{1,2}/[^"']+)\1\s*\)""")
BODY_TYPE = re.compile(r"^(?:export\s+)?type\s+(\w+)", re.M)
MODE = re.compile(r"^--!(strict|nonstrict|nocheck)\b.*$")


def default_files() -> list[Path]:
    files = [p for p in (ROOT / "host.luau", ROOT / "window.luau") if p.is_file()]
    return files + sorted((ROOT / "lib").rglob("*.luau"))


def resolve_require(src: Path, target: str) -> Path | None:
    base = (src.parent / target).resolve()
    for cand in (base.with_name(base.name + ".luau"), base / "init.luau", base):
        if cand.is_file() and cand.suffix == ".luau":
            return cand
    return None


def closure(files: list[Path]) -> list[Path]:
    seen: dict[Path, None] = {}
    stack = [f.resolve() for f in files]
    while stack:
        f = stack.pop(0)
        if f in seen:
            continue
        seen[f] = None
        for m in REQUIRE.finditer(strip_comments(f.read_text())):
            dep = resolve_require(f, m.group(2))
            if dep:
                stack.append(dep)
    return list(seen)


def rel_in_tmp(p: Path) -> Path:
    try:
        return p.relative_to(ROOT)
    except ValueError:
        return Path("_ext") / str(p).lstrip("/")


def build_copy(src: Path, prelude_for) -> tuple[str, int]:
    """Return (checked copy text, prelude line count)."""
    body = src.read_text()
    first, sep, rest = body.partition("\n")
    m = MODE.match(first)
    header = first if m else "--!strict"
    body_lines = ("" + sep + rest) if m else body
    own_types = frozenset(BODY_TYPE.findall(strip_comments(body)))
    prelude = prelude_for(own_types)
    n = prelude.count("\n")
    return f"{header}\n{prelude}{body_lines}", n


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*")
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--prelude", action="store_true")
    args = ap.parse_args()

    defs = DEFS.read_text()
    try:
        full_prelude = translate(defs)
    except TranslateError as e:
        print(f"prelude translation failed: {e}", file=sys.stderr)
        return 2
    if args.prelude:
        sys.stdout.write(full_prelude)
        return 0

    files = [Path(f).resolve() for f in args.files] if args.files else default_files()
    for f in files:
        if not f.is_file():
            print(f"{f}: no such file", file=sys.stderr)
            return 3
    if not files:
        print("luau_check: no source files found (host.luau, window.luau, lib/**)")
        return 0
    sources = closure(files)

    cache: dict[frozenset[str], str] = {}

    def prelude_for(skip: frozenset[str]) -> str:
        if not skip:
            return full_prelude
        if skip not in cache:
            cache[skip] = translate(defs, skip)
        return cache[skip]

    tmp = Path(tempfile.mkdtemp(prefix="luau_check_"))
    try:
        # copy path (as analyzer prints it) -> (original, prelude line count)
        info: dict[str, tuple[Path, int]] = {}
        copies: list[str] = []
        for src in sources:
            text, n = build_copy(src, prelude_for)
            dst = tmp / rel_in_tmp(src)
            dst.parent.mkdir(parents=True, exist_ok=True)
            dst.write_text(text)
            info[str(dst)] = (src, n)
            copies.append(str(dst))
        (tmp / "_prelude.luau").write_text(full_prelude)

        proc = subprocess.run(
            ["luau-analyze", "--mode=strict", "--formatter=plain", *copies],
            capture_output=True,
            text=True,
            cwd=tmp,
        )
        return report(proc, info, tmp, full_prelude)
    finally:
        if args.keep:
            print(f"kept {tmp}", file=sys.stderr)
        else:
            shutil.rmtree(tmp, ignore_errors=True)


# `path:line:col-col: (W0) TypeError: message`; `Kind` ends in `Error` for
# type/syntax errors, anything else (`LocalUnused`, ...) is a lint warning.
# Messages may continue on following lines (`caused by:` ...).
DIAG = re.compile(
    r"^(?P<path>.+?):(?P<line>\d+):(?P<col>\d+)(?:-\d+)?: \(\w+\) (?P<kind>\w+): (?P<msg>.*)$"
)


def report(proc, info, tmp, prelude) -> int:
    prelude_lines = prelude.split("\n")
    resolved = {str(Path(k).resolve()): k for k in info}
    # diagnostics: [target, line, col, kind, message lines]
    diags: list[list] = []
    other: list[str] = []
    for raw in (proc.stdout + proc.stderr).splitlines():
        m = DIAG.match(raw)
        if m:
            path = m["path"]
            key = path if path in info else resolved.get(str(Path(tmp, path).resolve()))
            if key is not None:
                diags.append([key, int(m["line"]), int(m["col"]), m["kind"], [m["msg"]]])
                continue
        if diags and raw.strip() and diags[-1] is not None and (raw[:1] in " \t" or not m):
            if not m:
                diags[-1][4].append(raw)
                continue
        if raw.strip():
            other.append(raw)

    src_errors = 0
    printed: list[str] = []
    prelude_errors: dict[tuple[int, str], None] = {}
    for key, line, col, kind, msg in diags:
        src, n = info[key]
        is_error = kind.endswith("Error")
        if line <= n + 1:
            if is_error:
                prelude_errors[(line - 1, f"{kind}: " + " | ".join(msg))] = None
            continue
        where = f"{_display(src)}:{line - (n + 1)}:{col}"
        text = "\n".join(msg)
        if is_error:
            src_errors += 1
            printed.append(f"{where}: {text}")
        else:
            printed.append(f"{where}: warning: {kind}: {text}")
    for p in printed:
        print(p)
    for o in other:
        print(o, file=sys.stderr)
    if prelude_errors:
        print("PRELUDE ERRORS (translator bug; see `--prelude` output):", file=sys.stderr)
        for (pl, msg) in prelude_errors:
            text = prelude_lines[pl - 1] if 1 <= pl <= len(prelude_lines) else ""
            print(f"  prelude:{pl}: {msg}\n    | {text[:160]}", file=sys.stderr)
        return 2
    if other and not src_errors:
        print("luau_check: unparsed analyzer output above", file=sys.stderr)
        return 3
    if src_errors:
        print(f"{src_errors} error(s)", file=sys.stderr)
        return 1
    return 0


def _display(p: Path) -> str:
    try:
        return str(p.relative_to(ROOT))
    except ValueError:
        return str(p)


if __name__ == "__main__":
    sys.exit(main())
