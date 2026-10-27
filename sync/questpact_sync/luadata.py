"""Reads WoW SavedVariables files and writes Lua data files.

Only the data subset the client emits is supported: tables, strings, numbers,
booleans and nil. Tables keyed exactly 1..n become lists; others become dicts
with string keys (numeric keys such as quest IDs are restored on write).
"""

import math
import re

_NUMBER = re.compile(r"-?(0[xX][0-9a-fA-F]+|(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?|inf|nan)")
_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "a": "\x07", "b": "\b", "f": "\f", "v": "\v", "\n": "\n"}


class LuaParseError(ValueError):
    pass


def parse_saved_variables(text):
    """Returns {global_name: value} for every top-level assignment."""
    p = _Parser(text)
    return p.parse_file()


class _Parser:
    def __init__(self, text):
        self.s = text
        self.i = 0
        self.n = len(text)

    def fail(self, msg):
        line = self.s.count("\n", 0, self.i) + 1
        raise LuaParseError(f"Lua parse error at line {line}: {msg}")

    def skip(self):
        s, n = self.s, self.n
        while self.i < n:
            c = s[self.i]
            if c in " \t\r\n﻿":
                self.i += 1
            elif s.startswith("--", self.i):
                if s.startswith("[[", self.i + 2):
                    end = s.find("]]", self.i + 4)
                    self.i = n if end < 0 else end + 2
                else:
                    end = s.find("\n", self.i)
                    self.i = n if end < 0 else end
            else:
                break

    def peek(self):
        return self.s[self.i] if self.i < self.n else ""

    def parse_file(self):
        out = {}
        while True:
            self.skip()
            if self.i >= self.n:
                return out
            name = self.ident()
            self.skip()
            if self.peek() != "=":
                self.fail("expected '=' after global name")
            self.i += 1
            out[name] = self.value()

    def ident(self):
        m = _IDENT.match(self.s, self.i)
        if not m:
            self.fail(f"unexpected character {self.peek()!r}")
        self.i = m.end()
        return m.group(0)

    def string(self):
        quote = self.s[self.i]
        self.i += 1
        out = []
        s = self.s
        while self.i < self.n:
            c = s[self.i]
            self.i += 1
            if c == quote:
                return "".join(out)
            if c != "\\":
                out.append(c)
                continue
            e = s[self.i]
            self.i += 1
            if e in _ESCAPES:
                out.append(_ESCAPES[e])
            elif e.isdigit():
                digits = e
                while len(digits) < 3 and self.peek().isdigit():
                    digits += s[self.i]
                    self.i += 1
                out.append(chr(int(digits)))
            else:
                out.append(e)  # \\ \" \'
        self.fail("unterminated string")

    def number(self):
        m = _NUMBER.match(self.s, self.i)
        if not m:
            self.fail("bad number")
        self.i = m.end()
        t = m.group(0)
        if t.endswith("inf"):
            return -math.inf if t.startswith("-") else math.inf
        if t.endswith("nan"):
            return math.nan
        if "x" in t.lower():
            return int(t, 16)
        v = float(t)
        return int(v) if v.is_integer() and not re.search(r"[.eE]", t) else v

    def table(self):
        self.i += 1  # {
        entries = []
        next_index = 1
        while True:
            self.skip()
            if self.peek() == "}":
                self.i += 1
                break
            key = None
            if self.peek() == "[":
                self.i += 1
                key = self.value()
                self.skip()
                if self.peek() != "]":
                    self.fail("expected ']'")
                self.i += 1
                self.skip()
                if self.peek() != "=":
                    self.fail("expected '='")
                self.i += 1
            elif _IDENT.match(self.s, self.i):
                save = self.i
                name = self.ident()
                self.skip()
                if self.peek() == "=" and not self.s.startswith("==", self.i):
                    self.i += 1
                    key = name
                else:
                    self.i = save
            value = self.value()
            if key is None:
                key = next_index
                next_index += 1
            if value is not None:
                entries.append((key, value))
            self.skip()
            if self.peek() in (",", ";"):
                self.i += 1
                continue
            if self.peek() == "}":
                self.i += 1
                break
            self.fail("expected ',' or '}'")
        if entries and all(k == idx + 1 and not isinstance(k, bool) for idx, (k, _) in enumerate(entries)):
            return [v for _, v in entries]
        return {_key_str(k): v for k, v in entries}

    def value(self):
        self.skip()
        c = self.peek()
        if c == "{":
            return self.table()
        if c in ('"', "'"):
            return self.string()
        if c == "-" or c == "." or c.isdigit():
            return self.number()
        word = self.ident()
        if word == "true":
            return True
        if word == "false":
            return False
        if word == "nil":
            return None
        self.fail(f"unexpected identifier {word!r}")


def _key_str(k):
    if isinstance(k, bool):
        return "true" if k else "false"
    if isinstance(k, float) and k.is_integer():
        return str(int(k))
    return str(k)


def lua_string(s):
    out = ['"']
    for ch in str(s):
        code = ord(ch)
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif code < 32 or code == 127:
            out.append("\\%03d" % code)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


_INT_KEY = re.compile(r"-?\d+")


def _lua_key(k):
    # Numeric keys (quest IDs) arrive as strings from JSON; write them back as numbers
    if _INT_KEY.fullmatch(k) and str(int(k)) == k:
        return f"[{k}]"
    return f"[{lua_string(k)}]"


def to_lua(value, indent=""):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        if not math.isfinite(value):
            return "0"
        return str(int(value)) if value.is_integer() else repr(value)
    if isinstance(value, str):
        return lua_string(value)
    inner = indent + "\t"
    if isinstance(value, (list, tuple)):
        if not value:
            return "{}"
        return "{\n" + "".join(f"{inner}{to_lua(v, inner)},\n" for v in value) + indent + "}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        return "{\n" + "".join(f"{inner}{_lua_key(str(k))} = {to_lua(v, inner)},\n" for k, v in value.items()) + indent + "}"
    raise TypeError(f"cannot serialize {type(value).__name__}")
