# Source from other zsh test scripts. TEST_ARCH is the executable architecture,
# independent from the machine that launches it (x86_64 runs through Rosetta on ARM).
if [[ -n "${TARGET_TRIPLE:-}" ]]; then
    _requested_arch="${TARGET_TRIPLE%%-*}"
else
    _requested_arch="${TEST_ARCH:-$(/usr/bin/uname -m)}"
fi
case "$_requested_arch" in
    arm64|x86_64) ;;
    *) print -u2 "Unsupported test architecture: $_requested_arch"; return 2 ;;
esac
if [[ -n "${TEST_ARCH:-}" && "$TEST_ARCH" != "$_requested_arch" ]]; then
    print -u2 "TEST_ARCH and TARGET_TRIPLE disagree"; return 2
fi
TEST_ARCH="$_requested_arch"
TARGET_TRIPLE="${TARGET_TRIPLE:-$TEST_ARCH-apple-macosx13.0}"
[[ "$TARGET_TRIPLE" == "$TEST_ARCH-apple-macosx13.0" ]] || { print -u2 "Unsupported TARGET_TRIPLE: $TARGET_TRIPLE"; return 2; }
TEST_PRODUCTS="${TASK_BUILD_DIR:?set TASK_BUILD_DIR before sourcing test-architecture.zsh}/$TEST_ARCH-apple-macosx/debug"
export TEST_ARCH TARGET_TRIPLE TEST_PRODUCTS
unset _requested_arch
