#!/usr/bin/env bash
# Restore the original system cosmic-settings (undo install.sh).
set -euo pipefail
cd "$(dirname "$0")"

COMP=cosmic-settings
PKG=cosmic-settings
TARGET=/usr/bin/$COMP

[ -f "$COMP.orig" ] || { echo "No backup ($COMP.orig) found."; exit 1; }

# The backup was taken whenever this fork was first installed, and apt may have
# moved since (a newer cosmic-settings is already waiting in the archive on the
# machine this fork was made on). Restoring a backup older than the package
# would be a silent downgrade — undoing more than this script promises to undo.
# dpkg keeps the checksum of the binary the *installed* package shipped, so the
# backup must match it exactly to count as "the original".
SUMS="$(dpkg-query --control-path "$PKG" md5sums 2>/dev/null || true)"
WANT_MD5=""
if [ -n "$SUMS" ] && [ -f "$SUMS" ]; then
    WANT_MD5="$(awk -v f="${TARGET#/}" '$2 == f { print $1 }' "$SUMS")"
fi
PKG_VER="$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null || true)"
if [ -n "$WANT_MD5" ] && [ "$(md5sum < "$COMP.orig" | cut -d' ' -f1)" != "$WANT_MD5" ]; then
    echo
    echo "!! The backup ($COMP.orig) is not the binary of the $PKG package"
    echo "   installed on this system (${PKG_VER:-unknown version})."
    echo
    echo "   Restoring it would put an older build back — a downgrade, and not"
    echo "   what 'undo the fork' should mean."
    echo
    echo "   Let apt restore its own binary instead, which is the real original:"
    echo "       ./remove-auto-reapply.sh"
    echo "       sudo apt install --reinstall $PKG"
    echo "       rm $(pwd)/$COMP.orig"
    echo
    echo "   To restore the backup anyway, knowing the above:"
    echo "       POP_FLOW_ALLOW_STALE_BACKUP=1 ./uninstall.sh"
    echo
    [ "${POP_FLOW_ALLOW_STALE_BACKUP:-0}" = "1" ] || exit 1
fi

# Turn off auto-reapply first, or the next package operation would re-patch the
# binary right after we restore the original. Delegating to the script that owns
# those paths rather than repeating them: this used to remove only the golden
# copy, leaving a root-owned APT hook behind for good.
if [ -x ./remove-auto-reapply.sh ]; then
    ./remove-auto-reapply.sh
fi

echo "==> Restoring original $TARGET (needs sudo)..."
sudo install -m 0755 "$COMP.orig" "$TARGET"

echo "==> Restored. If COSMIC Settings is open, close it and open it again."
echo "    The setting itself (~/.config/cosmic/com.popflow.ShowDesktop) is left"
echo "    in place: it belongs to the show-desktop toggle, which still reads it."
