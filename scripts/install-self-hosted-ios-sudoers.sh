#!/bin/bash
# One-time, explicitly approved admin setup for an isolated development Mac.
# This is ROOT-CAPABLE access, not a security sandbox. See self-hosted-ios-ci.md.
set -euo pipefail
print_only=0
if [[ "${1:-}" == --print ]]; then print_only=1; shift; fi
user="${1:-}"
if [[ $# != 1 || ! "$user" =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ || "$user" == root ]]; then
    echo "Usage: $0 [--print] <runner-user>" >&2
    exit 2
fi
id "$user" >/dev/null
policy() {
    cat <<EOF
# Heeler iOS CI on an isolated development Mac. Root-capable fixture operations.
# Deliberately no general shell / NOPASSWD: ALL grant. These commands can still
# confer root: never approve untrusted jobs onto this persistent machine.
Cmnd_Alias HEELER_IOS_FIXTURES = /usr/bin/true "", /usr/sbin/sysadminctl, /usr/bin/dscl, /usr/sbin/dseditgroup, /usr/sbin/chown, /bin/kill, /usr/sbin/sshd
$user ALL=(root) NOPASSWD: HEELER_IOS_FIXTURES
EOF
}
if [[ "$print_only" == 1 ]]; then policy; exit 0; fi
if [[ "$EUID" != 0 ]]; then
    echo "Run once with sudo after reviewing --print and the CI security guide." >&2
    exit 1
fi
directory=/private/etc/sudoers.d
[[ -d "$directory" && ! -L "$directory" ]] || { echo "Unsafe/missing sudoers.d" >&2; exit 1; }
path="$directory/heeler-ios-$user"
[[ ! -L "$path" ]] || { echo "Refusing a symlink at $path" >&2; exit 1; }
umask 077
temporary="$(mktemp "$directory/.heeler-ios.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
policy > "$temporary"
/usr/sbin/visudo -cf "$temporary"
if [[ -e "$path" ]] && ! cmp -s "$path" "$temporary"; then
    echo "Existing $path differs; review it manually rather than overwriting it." >&2
    exit 1
fi
/usr/bin/install -o root -g wheel -m 0440 "$temporary" "$path"
echo "Installed $path. CI fixture commands are now root-capable for $user."
