#!/usr/bin/env bash
# Make POP Flow's cosmic-settings survive system/package updates.
#
# A package update overwrites /usr/bin/cosmic-settings with the stock binary.
# This installs an APT/dpkg post-invoke hook that runs (as root, no password)
# after every package operation and reinstalls our build whenever the on-disk
# binary no longer matches our "golden" copy.
#
# One-time setup; needs sudo. Undo with ./remove-auto-reapply.sh
set -euo pipefail
cd "$(dirname "$0")"

# --- component-specific settings ------------------------------------------
COMP=cosmic-settings                      # name under /usr/bin
PKG=cosmic-settings                       # package that owns /usr/bin/$COMP
BUILT="target/release/cosmic-settings"    # our build
# Settings is an ordinary app, not a session daemon: nothing to restart. An
# open window keeps the old binary until it is closed.
RELOAD=":"
# The upstream release our build is from. Unlike the other components, the
# reapplier only puts our build back over the *same* release: Settings writes
# the configs the rest of COSMIC reads, so after an upgrade to a newer release
# the stock Settings of that release stays, and the journal says why
# (`journalctl -t pop-flow`). Rebase the fork and run ./install.sh to bring the
# feature back.
BUILT_VER="$(awk -F'"' '/^version = /{print $2; exit}' cosmic-settings/Cargo.toml)"
# --------------------------------------------------------------------------

LIBDIR=/usr/local/lib/pop-flow
GOLDEN="$LIBDIR/$COMP"
REAPPLY="$LIBDIR/reapply-$COMP"
HOOK="/etc/apt/apt.conf.d/99-pop-flow-$COMP"

[ -f "$BUILT" ] || { echo "Build first: ./install.sh (or cargo build --release)"; exit 1; }
[ -n "$BUILT_VER" ] || { echo "Could not read the version from cosmic-settings/Cargo.toml"; exit 1; }

echo "==> Installing golden copy + reapply hook for $COMP (needs sudo)..."
sudo install -d -m 0755 "$LIBDIR"
sudo install -m 0755 "$BUILT" "$GOLDEN"

# The reapplier: reinstall our binary if the system one drifted (or vanished).
# `cmp` follows symlinks, so a package that restores the target as a symlink to
# a stock binary also counts as drift. `install` unlinks the destination first,
# so replacing a symlink leaves whatever it pointed at untouched.
sudo tee "$REAPPLY" >/dev/null <<EOS
#!/usr/bin/env bash
set -e
GOLDEN=$GOLDEN
TARGET=/usr/bin/$COMP
PKG=$PKG
BUILT_VER=$BUILT_VER
[ -f "\$GOLDEN" ] || exit 0
# Survive an update, not a removal. With the package gone the user asked
# for this program to be gone, and putting the binary back would leave a
# file no package owns.
dpkg-query -W -f='\${Status}' "\$PKG" 2>/dev/null | grep -q '^install ok installed$' || exit 0
if [ ! -f "\$TARGET" ] || [ -L "\$TARGET" ] || ! cmp -s "\$GOLDEN" "\$TARGET"; then
    # Same release only: never put an older Settings over a newer COSMIC.
    PKG_VER="\$(dpkg-query -W -f='\${Version}' "\$PKG" 2>/dev/null | cut -d'~' -f1)"
    if [ "\$PKG_VER" != "\$BUILT_VER" ]; then
        command -v logger >/dev/null 2>&1 && logger -t pop-flow "not reapplying $COMP: package is \$PKG_VER, our build is \$BUILT_VER; rebase the fork and run its install.sh"
        exit 0
    fi
    install -m 0755 -o root -g root "\$GOLDEN" "\$TARGET"
    command -v logger >/dev/null 2>&1 && logger -t pop-flow "reapplied $COMP after change"
    $RELOAD
fi
EOS
sudo chmod 0755 "$REAPPLY"

# The hook. `|| true` guarantees a failing reapplier can never break apt.
sudo tee "$HOOK" >/dev/null <<EOS
// POP Flow: reapply our $COMP after any package operation that overwrites
// /usr/bin/$COMP. Remove with ./remove-auto-reapply.sh
DPkg::Post-Invoke { "$REAPPLY || true"; };
EOS

echo "==> Done. POP Flow's $COMP will be reapplied automatically after updates"
echo "    of the same release ($BUILT_VER); a newer release keeps its stock Settings"
echo "    until the fork is rebased (see: journalctl -t pop-flow)."
echo "    golden: $GOLDEN"
echo "    hook:   $HOOK"
