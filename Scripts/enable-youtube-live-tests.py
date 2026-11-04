"""Create a separate xctestrun with explicit opt-in; preserve TESTROOT paths."""
import pathlib
import plistlib
import sys

source, destination = map(pathlib.Path, sys.argv[1:3])
data = plistlib.loads(source.read_bytes())
updated = 0


def visit(value):
    global updated
    if isinstance(value, dict):
        if str(value.get("TestBundlePath", "")).endswith("OFFLINETests.xctest"):
            value.setdefault("EnvironmentVariables", {})["MB_YOUTUBE_LIVE"] = "1"
            value.setdefault("TestHostEnvironmentVariables", {})["MB_YOUTUBE_LIVE"] = "1"
            updated += 1
        for key, item in list(value.items()):
            if isinstance(item, str):
                value[key] = item.replace("__TESTROOT__", str(source.parent.resolve()))
            else:
                visit(item)
    elif isinstance(value, list):
        for item in value:
            visit(item)


visit(data)
assert updated == 1, f"Expected one unit-test bundle, found {updated}"
destination.write_bytes(plistlib.dumps(data))
