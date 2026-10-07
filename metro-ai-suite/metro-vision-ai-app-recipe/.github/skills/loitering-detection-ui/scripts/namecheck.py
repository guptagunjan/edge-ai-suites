#!/usr/bin/env python3
# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Static undefined-name checker for the generated console package.

Rationale
---------
Splitting the backend into modules introduces a failure mode that neither a
syntax check nor an import check detects: a name used only inside a function
body, whose defining import was left behind in another module. The module
imports cleanly and the fault surfaces only when that route is exercised,
as a 500 at runtime.

This checker resolves, per module, every global name an expression reads
against the names that module actually binds (imports, assignments, function
and class definitions, and the Python builtins). Anything unresolved is
reported with its file and line.

It uses only the standard library, so it runs in the deployment container and
in the acceptance gate without adding a dependency.

Usage:
    python3 namecheck.py <directory-or-file> [...]

Exit status: 0 when no unresolved name is found, 1 otherwise.
"""

import ast
import builtins
import os
import sys

_BUILTINS = set(dir(builtins)) | {"__file__", "__name__", "__doc__", "__package__"}


class _ModuleScope(ast.NodeVisitor):
    """Collect the module-level names a module binds."""

    def __init__(self):
        self.bound = set()

    def _bind_target(self, node):
        if isinstance(node, ast.Name):
            self.bound.add(node.id)
        elif isinstance(node, (ast.Tuple, ast.List)):
            for elt in node.elts:
                self._bind_target(elt)
        elif isinstance(node, ast.Starred):
            self._bind_target(node.value)

    def visit_Import(self, node):
        for alias in node.names:
            self.bound.add(alias.asname or alias.name.split(".")[0])

    def visit_ImportFrom(self, node):
        for alias in node.names:
            if alias.name == "*":
                # A star import makes the module's namespace unanalysable;
                # record it so the caller can skip rather than mis-report.
                self.bound.add("*")
            else:
                self.bound.add(alias.asname or alias.name)

    def visit_Assign(self, node):
        for t in node.targets:
            self._bind_target(t)
        self.generic_visit(node)

    def visit_AnnAssign(self, node):
        self._bind_target(node.target)
        self.generic_visit(node)

    def visit_AugAssign(self, node):
        self._bind_target(node.target)
        self.generic_visit(node)

    def visit_For(self, node):
        self._bind_target(node.target)
        self.generic_visit(node)

    def visit_With(self, node):
        for item in node.items:
            if item.optional_vars is not None:
                self._bind_target(item.optional_vars)
        self.generic_visit(node)

    def visit_FunctionDef(self, node):
        self.bound.add(node.name)
        # Do not descend: inner names are local to the function.

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_ClassDef(self, node):
        self.bound.add(node.name)

    def visit_Try(self, node):
        for handler in node.handlers:
            if handler.name:
                self.bound.add(handler.name)
        self.generic_visit(node)

    def visit_Global(self, node):
        self.bound.update(node.names)


class _Locals(ast.NodeVisitor):
    """Collect names bound inside one function body, including nested scopes."""

    def __init__(self, fn):
        self.bound = set()
        for arg in list(fn.args.args) + list(fn.args.kwonlyargs) + list(fn.args.posonlyargs):
            self.bound.add(arg.arg)
        if fn.args.vararg:
            self.bound.add(fn.args.vararg.arg)
        if fn.args.kwarg:
            self.bound.add(fn.args.kwarg.arg)
        for stmt in fn.body:
            self.visit(stmt)

    def _bind_target(self, node):
        if isinstance(node, ast.Name):
            self.bound.add(node.id)
        elif isinstance(node, (ast.Tuple, ast.List)):
            for elt in node.elts:
                self._bind_target(elt)
        elif isinstance(node, ast.Starred):
            self._bind_target(node.value)

    def visit_Assign(self, node):
        for t in node.targets:
            self._bind_target(t)
        self.generic_visit(node)

    def visit_AnnAssign(self, node):
        self._bind_target(node.target)
        self.generic_visit(node)

    def visit_AugAssign(self, node):
        self._bind_target(node.target)
        self.generic_visit(node)

    def visit_For(self, node):
        self._bind_target(node.target)
        self.generic_visit(node)

    visit_AsyncFor = visit_For

    def visit_With(self, node):
        for item in node.items:
            if item.optional_vars is not None:
                self._bind_target(item.optional_vars)
        self.generic_visit(node)

    visit_AsyncWith = visit_With

    def visit_Import(self, node):
        for alias in node.names:
            self.bound.add(alias.asname or alias.name.split(".")[0])

    def visit_ImportFrom(self, node):
        for alias in node.names:
            self.bound.add(alias.asname or alias.name)

    def visit_Try(self, node):
        for handler in node.handlers:
            if handler.name:
                self.bound.add(handler.name)
        self.generic_visit(node)

    def visit_FunctionDef(self, node):
        self.bound.add(node.name)
        self.generic_visit(node)

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_ClassDef(self, node):
        self.bound.add(node.name)
        self.generic_visit(node)

    def visit_comprehension(self, node):
        self._bind_target(node.target)
        self.generic_visit(node)

    def visit_Lambda(self, node):
        for arg in list(node.args.args) + list(node.args.kwonlyargs):
            self.bound.add(arg.arg)
        self.generic_visit(node)

    def visit_ExceptHandler(self, node):
        if node.name:
            self.bound.add(node.name)
        self.generic_visit(node)


def _comprehension_targets(fn):
    """Names bound by comprehensions anywhere inside a function."""
    names = set()
    for node in ast.walk(fn):
        if isinstance(node, ast.comprehension):
            tgt = node.target
            if isinstance(tgt, ast.Name):
                names.add(tgt.id)
            else:
                for sub in ast.walk(tgt):
                    if isinstance(sub, ast.Name):
                        names.add(sub.id)
    return names


def check_file(path):
    """Return a list of "path:line: name" strings for unresolved reads."""
    try:
        tree = ast.parse(open(path, encoding="utf-8").read(), filename=path)
    except SyntaxError as exc:
        return ["%s:%s: syntax error: %s" % (path, exc.lineno, exc.msg)]

    scope = _ModuleScope()
    scope.visit(tree)
    if "*" in scope.bound:
        return []  # star import: namespace not statically analysable
    module_names = scope.bound | _BUILTINS

    problems = []
    for node in ast.walk(tree):
        if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        local = _Locals(node).bound | _comprehension_targets(node)
        known = module_names | local
        for sub in ast.walk(node):
            if isinstance(sub, ast.Name) and isinstance(sub.ctx, ast.Load):
                if sub.id not in known:
                    problems.append("%s:%d: undefined name '%s'" % (path, sub.lineno, sub.id))
    # Deterministic, de-duplicated output.
    return sorted(set(problems))


def main(argv):
    targets = argv[1:] or ["."]
    files = []
    for t in targets:
        if os.path.isdir(t):
            for root, _dirs, names in os.walk(t):
                if "__pycache__" in root:
                    continue
                files.extend(os.path.join(root, n) for n in sorted(names) if n.endswith(".py"))
        elif t.endswith(".py"):
            files.append(t)
    problems = []
    for f in sorted(set(files)):
        problems.extend(check_file(f))
    if problems:
        for p in problems:
            sys.stderr.write(p + "\n")
        sys.stderr.write("namecheck: %d problem(s) in %d file(s)\n" % (len(problems), len(files)))
        return 1
    sys.stdout.write("namecheck: %d file(s) clean\n" % len(files))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
