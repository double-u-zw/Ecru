"""Fail closed if shipping code acquires system input or test event capabilities.

Reads sources/binary only. Does not run Ecru or interact with the keyboard.
"""
from pathlib import Path
import re
import subprocess
import os

root = Path(__file__).resolve().parents[1]
prohibited = re.compile(
    r"\b(?:CGEventPost\w*|CGEventTap\w*|CGEventCreateKeyboardEvent|IOHIDPostEvent)\b"
    r"|\.post\s*\(\s*tap\s*:|\.postToPid\s*\("
    r"|NSEvent\.(?:keyEvent|addGlobalMonitorForEvents)\b|\.sendEvent\s*\("
    r"|\b(?:Process|NSTask)\s*\("
)
for path in (root / "Sources").glob("*.swift"):
    assert not prohibited.search(path.read_text()), f"Shipping input capability: {path}"
print("PASS: shipping sources cannot fabricate/post keyboard input, install global taps or spawn input helpers")
app = (root / "Sources/App.swift").read_text()
assert re.search(r"#if ECRU_UI_TESTS\s+if let flagIndex.*?UITestDriver.*?#endif", app, re.S)
assert re.search(r"func applicationWillTerminate.*?disconnectInputAndViews", app, re.S)
assert not list((root / "Sources").glob("*UITest*.swift"))
assert not list((root / "Sources").glob("*Checks.swift"))
build = (root / "Scripts/build.sh").read_text()
assert "Tests/UI" not in build and "ECRU_UI_TESTS" not in build
print("PASS: UI event simulation is compiled only in the separate opt-in development runner")
probe = (root / "Scripts/inspect-space.swift").read_text()
assert "options:.listenOnly" in probe and "CGPreflightListenEventAccess()" in probe
assert "CFMachPortInvalidate(tap)" in probe and "IOHIDManagerClose(manager" in probe
assert not re.search(r"CGEventPost|\.post\s*\(|keyboardEventSource|CGRequestListenEventAccess|kIOHIDOptionsTypeSeizeDevice", probe)
assert '? 30 : 5' in probe
print("PASS: optional diagnostic is read-only, bounded and releases its tap/device resources")
variant=os.environ.get('ECRU_VARIANT','development')
name='Ecru Dev' if variant=='development' else 'Ecru'
binary=Path(os.environ.get('ECRU_TEST_APP_PATH',root/'output'/f'{name}.app'))/'Contents/MacOS/Ecru'
if binary.exists():
    symbols = subprocess.check_output(["nm", "-u", str(binary)], text=True)
    assert not re.search(r"CGEvent(?:Post|Tap|CreateKeyboard)|IOHIDPostEvent|_(?:posix_spawn|execve)", symbols)
    print("PASS: installed bundle has no system keyboard-post/tap or input helper spawn imports")
else:
    raise AssertionError("Build the selected App variant before checking its capability boundary")
