#!/usr/bin/env python3
"""Installer fixtures only. Never invokes real root installation or SMC writes.

Runs shell syntax and extracted guard/lock functions against a private temporary
fixture. The copied guard functions use the current test UID instead of root,
which permits testing ACL/hardlink behavior without administrative changes.
An optional --app /absolute/GoodTouchBar.app invokes only --preflight.
"""
from pathlib import Path
import argparse
import os
import pwd
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "Resources/FanControl"
count = 0

def check(condition, message):
    global count
    if not condition:
        raise AssertionError(message)
    count += 1
    print("PASS:", message)

def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, timeout=8, **kwargs)

def functions(source):
    return source[source.index("# Refuse path tricks"):source.index("stop_service() {")]

def harness(path, definitions, command):
    return "\n".join([
        "#!/bin/sh", "set -eu", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "umask 077",
        f"ROOT_UID={os.getuid()}", f"LOCK='{path}'", "LOCK_HELD=0", "LOCK_ID=''",
        "fail() { printf '%s\\n' \"ERROR: $*\" >&2; exit 1; }", definitions,
        "cleanup_fixture() { code=$?; set +e; trap - EXIT HUP INT TERM; release_lock; exit \"$code\"; }",
        "trap cleanup_fixture EXIT", "trap 'exit 129' HUP", "trap 'exit 130' INT", "trap 'exit 143' TERM", command,
    ])

parser = argparse.ArgumentParser()
parser.add_argument("--app", type=Path)
args = parser.parse_args()
install = (SCRIPTS / "install-helper.sh").read_text()
uninstall = (SCRIPTS / "uninstall-helper.sh").read_text()
for name in ["install-helper.sh", "uninstall-helper.sh"]:
    check(run(["/bin/sh", "-n", str(SCRIPTS / name)]).returncode == 0, name + " shell syntax")
check(functions(install) == functions(uninstall), "installation and removal share identical security and locking functions")
check("LOCK=/Library/PrivilegedHelperTools/.goodtouchbar-fan-install.lock" in install and "LOCK=/Library/PrivilegedHelperTools/.goodtouchbar-fan-install.lock" in uninstall, "both operations use the same fixed lock path")
for source in [install, uninstall]:
    check(source.index("acquire_lock\n", source.index("trap cleanup")) < source.rindex("\nstop_service\n"), "lock is held before service stop and recovery")
    check("release_lock\n    exit \"$code\"" in source, "EXIT and handled signals release only the owned lock")
    check("[ \"$(/usr/bin/stat -f %l \"$p\")\" = 1 ]" in source, "pre-existing managed files require exactly one hardlink")
check("/bin/chmod -N \"$STATE\"" not in install, "existing state ACL is rejected instead of silently removed")
check(install.index("--preflight") < install.index('secure_dir /Library\n'), "preflight returns before root filesystem setup")
check(install.index('"$SNAPSHOT" || fail "复制后签名不一致"') < install.rindex("\nstop_service\n"), "private copied bundle is reverified before stopping installed service")
check('and cdhash H' in install and 'clientUID' in install, "policy binds exact client code hash and desktop UID")
check('codesign --verify --strict "$SOURCE_HELPER"' in install and 'lipo -archs "$SOURCE_HELPER"' in install, "preflight validates the isolated helper signature and Intel architecture")
check(uninstall.rindex('if [ -e "$PENDING" ]') < uninstall.index('/bin/rm -f "$HELPER"'), "uninstall preserves recovery executable while marker remains")

with tempfile.TemporaryDirectory(prefix="goodtouchbar-installer-check-") as temporary:
    temp = Path(temporary)
    defs = functions(install)
    lock = temp / "install.lock"
    def probe(command):
        return run(["/bin/sh"], input=harness(lock, defs, command))
    check(probe("acquire_lock\n:").returncode == 0 and not lock.exists(), "normal exit removes the test-owned lock")
    check(probe("acquire_lock\nexit 7").returncode == 7 and not lock.exists(), "error exit releases the test-owned lock")
    locked = subprocess.Popen(["/bin/sh"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert locked.stdin is not None and locked.stdout is not None
    locked.stdin.write(harness(lock, defs, "acquire_lock\nprintf 'LOCK_READY\\n'\nwhile :; do /bin/sleep 0.1; done"))
    locked.stdin.close()
    try:
        check(locked.stdout.readline().strip() == "LOCK_READY", "first operation acquires atomic lock")
        contender = probe("acquire_lock\n:")
        check(contender.returncode != 0 and lock.exists(), "concurrent operation is refused without removing another operation's lock")
        locked.terminate(); locked.wait(timeout=5)
        check(locked.returncode == 143 and not lock.exists(), "SIGTERM handler releases the test-owned lock")
    finally:
        if locked.poll() is None:
            locked.kill(); locked.wait()
    lock.mkdir(mode=0o700)
    check(probe("acquire_lock\n:").returncode != 0 and lock.exists(), "stale lock is not automatically reclaimed")
    lock.rmdir()
    target = temp / "real-directory"; target.mkdir()
    lock.symlink_to(target, target_is_directory=True)
    check(probe("acquire_lock\n:").returncode != 0 and lock.is_symlink() and target.is_dir(), "symlink lock path is rejected and preserved")
    lock.unlink()
    file = temp / "plain-file"; file.write_text("fixture"); file.chmod(0o600)
    check(probe(f"secure_file_if_present '{file}'").returncode == 0, "ordinary fixture file passes guards using the fixture UID")
    hardlink = temp / "second-link"; os.link(file, hardlink)
    rejected = probe(f"secure_file_if_present '{file}'")
    check(rejected.returncode != 0 and "硬链接" in rejected.stderr, "hardlinked managed file is refused")
    hardlink.unlink()
    user = pwd.getpwuid(os.getuid()).pw_name
    acl = run(["/bin/chmod", "+a", f"user:{user} allow write", str(file)])
    check(acl.returncode == 0, "temporary fixture extended ACL can be created")
    rejected = probe(f"reject_acl '{file}'")
    check(rejected.returncode != 0 and "扩展 ACL" in rejected.stderr, "BSD ls ACL entry output is recognized and refused")

    run(["/bin/chmod", "-N", str(file)])
    check(probe(f"reject_acl '{file}'").returncode == 0, "ACL-free fixture is accepted")
    bad_app = temp / "Missing.app"
    invalid = run(["/bin/sh", str(SCRIPTS / "install-helper.sh"), "--preflight", str(bad_app), str(os.getuid())])
    check(invalid.returncode != 0, "preflight rejects a missing App without system writes")

install_agent = (ROOT / "scripts/install-autostart.sh").read_text()
uninstall_agent = (ROOT / "scripts/uninstall-autostart.sh").read_text()
check('LABEL="io.github.yihuirui.goodtouchbar"' in install_agent and 'APP_BUNDLE="/Applications/goodtouchbar.app"' in install_agent, "LaunchAgent install uses the new bundle and label")
check('"$PROGRAM" == "/Applications/goodtouchbar.app/Contents/MacOS/GoodTouchBar"' in uninstall_agent, "LaunchAgent uninstall verifies the exact app path")
check("com.learning.touchbarlearning" not in install_agent + uninstall_agent and "bootout.*OLD" not in install_agent + uninstall_agent, "autostart scripts do not take over the previous service")

if args.app:
    check(args.app.is_absolute() and args.app.is_dir(), "preflight App path exists and is absolute")
    result = run(["/bin/sh", str(SCRIPTS / "install-helper.sh"), "--preflight", str(args.app), str(os.getuid())])
    check(result.returncode == 0 and "未安装系统文件" in result.stdout, "final App signature, helper and exact-code client policy preflight")
    print(result.stdout.strip())
print(f"{count} installer fixture checks passed; no root installation or hardware writes")
