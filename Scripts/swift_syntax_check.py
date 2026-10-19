#!/usr/bin/env python3
"""Syntax-only check of Swift sources with tree-sitter (no type checking).

Usage: swift_syntax_check.py <dir-or-file> [...]
Requires: pip install tree-sitter tree-sitter-swift
Exit code 1 if any file contains a syntax error node.
"""
import sys
import pathlib

import tree_sitter_swift
from tree_sitter import Language, Parser

LANGUAGE = Language(tree_sitter_swift.language())
PARSER = Parser(LANGUAGE)


def error_nodes(node):
    stack = [node]
    while stack:
        current = stack.pop()
        if current.type == "ERROR" or current.is_missing:
            yield current
        stack.extend(current.children)


def check(path: pathlib.Path) -> int:
    source = path.read_bytes()
    tree = PARSER.parse(source)
    problems = list(error_nodes(tree.root_node))
    for node in problems[:5]:
        line = node.start_point[0] + 1
        snippet = source.splitlines()[node.start_point[0]].decode("utf-8", "replace").strip()[:100]
        print(f"{path}:{line}: syntax error near: {snippet}")
    return len(problems)


def main(argv):
    files = []
    for arg in argv[1:]:
        p = pathlib.Path(arg)
        files.extend(sorted(p.rglob("*.swift")) if p.is_dir() else [p])
    total = 0
    for f in files:
        total += check(f)
    print(f"checked {len(files)} files, {total} syntax problem(s)")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
