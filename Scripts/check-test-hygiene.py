#!/usr/bin/env python3
"""Level A static checks for the test suites and workflows (no simulator needed).

Catches, in seconds, the classes of mistake that previously cost full CI runs:
  1. `for _ in 0..<n where !condition { swipe }` in UI tests. `where` only skips the
     body; the loop keeps snapshotting the accessibility tree for every remaining
     iteration, which pushed UI tests past their execution-time allowance.
  2. -only-testing / -skip-testing / --require selectors naming a class or method that
     does not exist (xcodebuild then silently runs nothing for it).
  3. Phase 10 migration suites missing from the feature workflow, so a stale assertion
     would only surface in the complete regression.
"""
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
problems = []

# 1. Unbounded `where` loops in UI tests.
for path in sorted((ROOT / "Tests/UITests").glob("*.swift")):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        code = line.split("//", 1)[0]
        if re.search(r"\bfor\s+\w+\s+in\s+[^{]*\bwhere\b", code):
            problems.append(f"{path.relative_to(ROOT)}:{number}: `for … where` loop in a UI test; use scroll(_:toReveal:) or break explicitly")

# 2. Every workflow selector resolves to a real test class / method.
classes = {}
for path in (ROOT / "Tests").rglob("*.swift"):
    text = path.read_text(encoding="utf-8")
    bundle = "OFFLINEUITests" if "UITests" in path.parts else "OFFLINETests"
    for match in re.finditer(r"class\s+(\w+)\s*:\s*XCTestCase\s*\{", text):
        body_start = match.end()
        nxt = re.search(r"\n(?:@MainActor\s+)?(?:final\s+)?class\s+\w+\s*:\s*XCTestCase", text[body_start:])
        body = text[body_start: body_start + nxt.start()] if nxt else text[body_start:]
        methods = set(re.findall(r"func\s+(test\w*)\s*\(", body))
        classes[(bundle, match.group(1))] = methods
bundles = {"OFFLINETests", "OFFLINEUITests"}
selector = re.compile(r"(?:-only-testing:|-skip-testing:|--require\s+)(OFFLINE(?:UI)?Tests)(?:/(\w+))?(?:/(\w+))?")
workflows = sorted((ROOT / ".github/workflows").glob("*.yml"))
for path in workflows:
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for bundle, suite, method in selector.findall(line):
            if bundle not in bundles:
                problems.append(f"{path.name}:{number}: unknown bundle {bundle}")
            elif suite and (bundle, suite) not in classes:
                problems.append(f"{path.name}:{number}: {bundle}/{suite} does not exist")
            elif method and method not in classes[(bundle, suite)]:
                problems.append(f"{path.name}:{number}: {bundle}/{suite}/{method} does not exist")

# Suites listed in bash arrays (SUITES=(...) / SUITES+=(...)); the bundle is the one the
# following `-only-testing:<bundle>/$suite` expands them into.
array_suites = {}
for path in workflows:
    text = path.read_text(encoding="utf-8")
    for match in re.finditer(r"SUITES\+?=\(([^)]*)\)", text):
        expansion = re.search(r"-only-testing:(OFFLINE(?:UI)?Tests)/\$suite", text[match.end():])
        if not expansion:
            problems.append(f"{path.name}: SUITES array without an -only-testing expansion")
            continue
        for suite in match.group(1).split():
            array_suites.setdefault(path.name, set()).add((expansion.group(1), suite))
            if (expansion.group(1), suite) not in classes:
                problems.append(f"{path.name}: {expansion.group(1)}/{suite} does not exist")

# 3. Feature workflow covers every playlist-migration suite.
feature_suites = array_suites.get("playlist-migration.yml", set())
feature = (ROOT / ".github/workflows/playlist-migration.yml").read_text(encoding="utf-8")
feature += "\n" + "\n".join(f"{bundle}/{suite}" for bundle, suite in feature_suites)
migration_dir = ROOT / "Tests/Unit/PlaylistMigration"
for path in sorted(migration_dir.glob("*.swift")):
    for suite in re.findall(r"class\s+(\w+)\s*:\s*XCTestCase", path.read_text(encoding="utf-8")):
        if f"OFFLINETests/{suite}" not in feature:
            problems.append(f"playlist-migration.yml does not run OFFLINETests/{suite} ({path.name})")
for suite in ("PlaylistMigrationUITests", "ReviewQueueUITests", "PlaylistFileImportUITests"):
    if f"OFFLINEUITests/{suite}" not in feature:
        problems.append(f"playlist-migration.yml does not run OFFLINEUITests/{suite}")

# 4. Each ci.yml shard's result-check requirements match what that shard selects:
#    every required suite is selected (no unrelated suite is demanded), and a shard that
#    selects whole bundles requires every selected suite (nothing silently unchecked).
import importlib.util
import shlex
spec = importlib.util.spec_from_file_location("check_results", ROOT / "Scripts/check-test-results.py")
check_results = importlib.util.module_from_spec(spec); spec.loader.exec_module(check_results)
suites_with_tests = {f"{b}/{s}" for (b, s), methods in classes.items() if methods}

def selected_suites(selectors):
    chosen, whole_bundle = set(), False
    for token in selectors:
        if token.startswith("-only-testing:"):
            parts = token.split(":", 1)[1].split("/")
            if len(parts) == 1:
                whole_bundle = True
                chosen |= {name for name in suites_with_tests if name.startswith(parts[0] + "/")}
            else:
                chosen.add(f"{parts[0]}/{parts[1]}")
    for token in selectors:
        if token.startswith("-skip-testing:"):
            parts = token.split(":", 1)[1].split("/")
            chosen = {name for name in chosen if not (name == "/".join(parts[:2]) or (len(parts) == 1 and name.startswith(parts[0] + "/")))}
    return chosen, whole_bundle

ci_text = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8").replace("\\\n", " ")
shards = re.findall(r"^\s*run_suite\s+(.+)$", ci_text, re.M)
shards = [line for line in shards if not line.startswith("()")]
if not shards:
    problems.append("ci.yml: no run_suite invocations found")
for line in shards:
    label, _allowance, checks, *selectors = shlex.split(line)
    tokens = shlex.split(checks)
    required, exclusions, expect = set(), [], []
    for flag, value in zip(tokens, tokens[1:] + [""]):
        if flag == "--require": required.add(value)
        elif flag == "--except": exclusions.append(value)
        elif flag == "--expect-suites-in": expect.append(value)
    previous = os.getcwd(); os.chdir(ROOT)
    for spec_dir in expect:
        required |= check_results.suites_in_sources(spec_dir, exclusions)
    os.chdir(previous)
    chosen, whole_bundle = selected_suites(selectors)
    if not required:
        problems.append(f"ci.yml {label}: no suite requirements")
    for name in sorted(required - chosen):
        problems.append(f"ci.yml {label}: requires {name}, which this shard does not select")
    if whole_bundle:
        for name in sorted(chosen - required):
            problems.append(f"ci.yml {label}: selects {name} but does not require it to execute")
    print(f"{label}: {len(chosen)} selected, {len(required)} required{' (whole bundle)' if whole_bundle else ''}")

for problem in problems:
    print(f"::error::{problem}")
print(f"{len(classes)} test classes, {len(workflows)} workflows checked; {len(problems)} problem(s)")
sys.exit(1 if problems else 0)
