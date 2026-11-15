#!/usr/bin/env python3
"""Verify an .xcresult bundle really executed the required tests.

xcodebuild's exit status alone is not proof of coverage: a suite filtered out by a
typo, a runner restart ("Executed 0 tests") or a skipped test can still look green in
a partial log. This reads Xcode's structured results (xcresulttool, Xcode 16+) and
fails unless:

  * at least --min-tests test cases ran,
  * every --require'd suite (Bundle/Suite or Bundle) ran at least one test case,
  * no test case failed and none was skipped (unless --allow-skips),
  * the overall result is Passed.

It also appends a count table to $GITHUB_STEP_SUMMARY and records the commit SHA.
Usage: check-test-results.py LABEL RESULT.xcresult [--min-tests N] [--require B/S ...]
       check-test-results.py --report RESULT.xcresult ...   (summary only, never fails)
"""
import argparse
import json
import os
import pathlib
import re
import subprocess
import sys


def xcresult(kind, path):
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", kind, "--path", path],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out)


def cases(nodes, bundle=None, suite=None):
    """Yield (bundle, suite, name, result) for every test case."""
    for node in nodes or []:
        kind = node.get("nodeType", "")
        b, s = bundle, suite
        if kind in ("Unit test bundle", "UI test bundle"):
            b = node.get("name")
        elif kind == "Test Suite":
            s = node.get("name")
        if kind == "Test Case":
            yield b, s, node.get("name"), node.get("result", "unknown")
            continue
        yield from cases(node.get("children"), b, s)


def suites_in_sources(spec, exclusions):
    """`DIR:BUNDLE` -> {"BUNDLE/Suite"} for every XCTestCase subclass declaring a test."""
    directory, _, bundle = spec.partition(":")
    found = set()
    for source in pathlib.Path(directory).rglob("*.swift"):
        text = source.read_text(encoding="utf-8")
        for match in re.finditer(r"class\s+(\w+)\s*:\s*XCTestCase\s*\{", text):
            rest = text[match.end():]
            nxt = re.search(r"\n(?:@MainActor\s+)?(?:final\s+)?class\s+\w+\s*:\s*XCTestCase", rest)
            if re.search(r"func\s+test\w*\s*\(", rest[:nxt.start()] if nxt else rest):
                found.add(f"{bundle}/{match.group(1)}")
    return found - set(exclusions)


def summarize(label, path):
    summary = xcresult("summary", path)
    found = list(cases(xcresult("tests", path).get("testNodes")))
    counts = {}
    for *_, result in found:
        counts[result] = counts.get(result, 0) + 1
    return summary, found, counts


def write_summary(label, path, summary, found, counts, problems):
    line = (f"| {label} | {len(found)} | {counts.get('Passed', 0)} | {counts.get('Failed', 0)} | "
            f"{counts.get('Skipped', 0)} | {summary.get('result', '?')} | {'OK' if not problems else 'FAIL'} |")
    print(line)
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if target:
        new = not os.path.exists(target) or os.path.getsize(target) == 0
        with open(target, "a", encoding="utf-8") as handle:
            if new:
                sha = os.environ.get("GITHUB_SHA_TESTED") or os.environ.get("GITHUB_SHA", "?")
                handle.write(f"Tested commit: `{sha}`\n\n| Bundle | Cases | Passed | Failed | Skipped | Xcode result | Gate |\n|---|---|---|---|---|---|---|\n")
            handle.write(line + "\n")
            for problem in problems:
                handle.write(f"- {label}: {problem}\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("label", nargs="?")
    parser.add_argument("paths", nargs="*")
    parser.add_argument("--min-tests", type=int, default=1)
    parser.add_argument("--require", action="append", default=[])
    parser.add_argument("--allow-skips", action="store_true")
    parser.add_argument("--expect-suites-in", action="append", default=[], metavar="DIR:BUNDLE",
                        help="require every test class declared under DIR (counts nothing)")
    parser.add_argument("--except", dest="exclusions", action="append", default=[], metavar="BUNDLE/SUITE")
    parser.add_argument("--report", action="store_true", help="summarize bundles; never fail")
    args = parser.parse_args()

    if args.report:
        for path in ([args.label] if args.label else []) + args.paths:
            if not os.path.exists(os.path.join(path, "Info.plist")):
                print(f"{path}: no finalized result bundle")
                continue
            try:
                summary, found, counts = summarize(os.path.basename(path), path)
                write_summary(os.path.basename(path), path, summary, found, counts, [])
            except Exception as error:  # Reporting must not mask the real failure.
                print(f"{path}: could not be read: {error}")
        return 0

    if not args.label or len(args.paths) != 1:
        parser.error("LABEL and exactly one RESULT.xcresult are required")
    path = args.paths[0]
    if not os.path.exists(os.path.join(path, "Info.plist")):
        print(f"::error::{args.label}: result bundle {path} missing or not finalized")
        return 1
    summary, found, counts = summarize(args.label, path)
    problems = []
    if len(found) < args.min_tests:
        problems.append(f"executed {len(found)} test cases, expected at least {args.min_tests}")
    requirements = list(args.require)
    for spec in args.expect_suites_in:
        requirements += sorted(suites_in_sources(spec, args.exclusions))
    for requirement in requirements:
        bundle, _, suite = requirement.partition("/")
        ran = [c for c in found if c[0] == bundle and (not suite or c[1] == suite)]
        if not ran:
            problems.append(f"required {requirement} executed no test cases")
    failed = [f"{b}/{s}/{n}" for b, s, n, r in found if r == "Failed"]
    if failed:
        problems.append(f"{len(failed)} failed: " + ", ".join(failed[:20]))
    skipped = [f"{b}/{s}/{n}" for b, s, n, r in found if r == "Skipped"]
    if skipped and not args.allow_skips:
        problems.append(f"{len(skipped)} skipped: " + ", ".join(skipped[:20]))
    unknown = [f"{b}/{s}/{n}" for b, s, n, r in found if r not in ("Passed", "Failed", "Skipped", "Expected Failure")]
    if unknown:
        problems.append(f"{len(unknown)} without a final result (crash or restart?): " + ", ".join(unknown[:20]))
    if summary.get("result") != "Passed":
        problems.append(f"Xcode reported {summary.get('result')!r}")
    write_summary(args.label, path, summary, found, counts, problems)
    for problem in problems:
        print(f"::error::{args.label}: {problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
