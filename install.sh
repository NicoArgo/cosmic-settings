#!/usr/bin/env bash
# Build and install POP Flow's cosmic-settings (Displays -> "Show desktop":
# only the screen where it was triggered, or all of them) over the system
# cosmic-settings. Reversible with ./uninstall.sh
set -euo pipefail
cd "$(dirname "$0")"

COMP=cosmic-settings
PKG=cosmic-settings
TARGET=/usr/bin/$COMP

# What the package itself shipped as $TARGET, per dpkg's own checksums. Empty if
# the package isn't installed or dpkg has no record.
pkg_md5() {
    local sums
    sums="$(dpkg-query --control-path "$PKG" md5sums 2>/dev/null)" || return 0
    [ -n "$sums" ] && [ -f "$sums" ] || return 0
    awk -v f="${TARGET#/}" '$2 == f { print $1 }' "$sums"
}

# This fork is branched from the exact upstream commit the installed package was
# built from (the hash after the last '~' in its version), not from upstream
# master: Settings writes the configs every other COSMIC component reads, so it
# should match their release. `--version` can't be trusted for this, so ask dpkg,
# whose version starts with upstream's.
PKG_VER="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null | cut -d'~' -f1)"
OURS_VER="$(awk -F'"' '/^version = /{print $2; exit}' cosmic-settings/Cargo.toml)"
if [ -n "$PKG_VER" ] && [ -n "$OURS_VER" ] && [ "$PKG_VER" != "$OURS_VER" ]; then
    echo
    echo "!! The installed $PKG package is $PKG_VER, but this fork is based"
    echo "   on upstream $OURS_VER."
    echo
    echo "   Installing would swap the Settings app of one COSMIC release into"
    echo "   another. Rebase the fork's 'pop-flow' branch onto the upstream commit"
    echo "   of the installed package (the hash at the end of"
    echo "   'dpkg-query -W $PKG'), then run this again."
    echo
    echo "   To install anyway, knowing the above:"
    echo "       POP_FLOW_ALLOW_VERSION_MISMATCH=1 ./install.sh"
    # Refuses before the build, not after: a warning at the end of a
    # many-minute build scrolls past unread.
    [ "${POP_FLOW_ALLOW_VERSION_MISMATCH:-0}" = "1" ] || exit 1
fi

# Build dependencies the other POP Flow components don't need: the Sound page
# links PipeWire, and its bindings are generated with libclang. Checked up
# front because the build otherwise dies minutes in, deep inside libspa-sys.
missing=()
pkg-config --exists libpipewire-0.3 2>/dev/null || missing+=(libpipewire-0.3-dev)
if [ -z "${LIBCLANG_PATH:-}" ] && ! ls /usr/lib/llvm-*/lib/libclang.so* /usr/lib/x86_64-linux-gnu/libclang-*.so* >/dev/null 2>&1; then
    missing+=(libclang-dev)
fi
if [ ${#missing[@]} -gt 0 ]; then
    echo "!! Missing build dependencies: ${missing[*]}"
    echo "       sudo apt install ${missing[*]}"
    exit 1
fi

echo "==> Building (cargo build --release)..."
cargo build --release

BIN="target/release/$COMP"
[ -f "$BIN" ] || { echo "Build failed: $BIN not found"; exit 1; }

# The backup taken here is what ./uninstall.sh restores. It must be the
# package's own binary, or "uninstall" would restore something else instead of
# stock (an earlier hand-installed build, say).
if [ ! -f "$COMP.orig" ] && [ -f "$TARGET" ]; then
    WANT_MD5="$(pkg_md5)"
    if [ -n "$WANT_MD5" ] && [ "$(md5sum < "$TARGET" | cut -d' ' -f1)" != "$WANT_MD5" ]; then
        echo
        echo "!! $TARGET is not the binary the $PKG package installed"
        echo "   (its checksum differs from dpkg's record), so it is no original"
        echo "   to back up. Put the package's own binary back first:"
        echo "       sudo apt install --reinstall $PKG"
        echo
        echo "   To back it up anyway, knowing the above:"
        echo "       POP_FLOW_ALLOW_STALE_BACKUP=1 ./install.sh"
        [ "${POP_FLOW_ALLOW_STALE_BACKUP:-0}" = "1" ] || exit 1
    fi
fi

if [ ! -f "$COMP.orig" ] && [ -f "$TARGET" ]; then
    echo "==> Backing up current $TARGET -> ./$COMP.orig"
    cp "$TARGET" "$COMP.orig"
fi

echo "==> Installing to $TARGET (needs sudo)..."
sudo install -m 0755 "$BIN" "$TARGET"

# Keep the auto-reapply golden copy in sync, or say out loud that this install
# is temporary — silence here used to hide the fact that a package update wipes
# the feature.
GOLDEN=/usr/local/lib/pop-flow/$COMP
if [ -f "$GOLDEN" ]; then
    echo "==> Refreshing auto-reapply golden copy"
    sudo install -m 0755 "$BIN" "$GOLDEN"
    # The reapplier records the version it was set up for; re-run the setup so
    # it follows this build (cheap, and idempotent).
    ./setup-auto-reapply.sh
else
    echo "!! No auto-reapply hook installed: the next package update of"
    echo "   $PKG will silently restore the stock binary."
    echo "   Run ./setup-auto-reapply.sh to make this install stick."
fi

# Settings is an ordinary app, not a session daemon: nothing to restart. A
# window already open keeps running the old binary until it is closed.
echo "==> Done. If COSMIC Settings is open, close it and open it again."
echo "    Then: Settings -> Displays -> \"Show desktop\" ->"
echo "    \"Only the screen where it was triggered\"."
