#!/bin/sh
# Install the plugin by symlinking this repository as open-with.yazi.
# It never edits keymap.toml or any other yazi configuration.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_DIR=${YAZI_CONFIG_HOME:-${XDG_CONFIG_HOME:-"$HOME/.config"}/yazi}
DEST="$CONFIG_DIR/plugins/open-with.yazi"

if [ -e "$DEST" ] || [ -L "$DEST" ]; then
	printf 'Refusing to overwrite existing %s\n' "$DEST" >&2
	printf 'Move it away first, then re-run this script.\n' >&2
	exit 1
fi

mkdir -p "$CONFIG_DIR/plugins"
ln -s "$ROOT" "$DEST"

printf 'Installed: %s -> %s\n\n' "$DEST" "$ROOT"
printf 'Now add this to %s/keymap.toml:\n\n' "$CONFIG_DIR"
cat <<'EOF'
[[mgr.prepend_keymap]]
on   = "O"
run  = "plugin open-with"
desc = "Open with (native picker + system apps)"
EOF
