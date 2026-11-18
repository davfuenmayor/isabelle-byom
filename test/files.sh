#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
isabelle=${ISABELLE_TOOL:-isabelle}
export USER_HOME
USER_HOME=$(mktemp -d)
trap 'rm -rf "$USER_HOME"' EXIT
mkdir -p "$USER_HOME/component/lib"
cp -R "$root/server/component/etc" "$root/server/component/src" "$USER_HOME/component/"
user_dir=$("$isabelle" getenv -b ISABELLE_HOME_USER)
mkdir -p "$user_dir/etc"
printf 'init_component "%s/component"\n' "$USER_HOME" > "$user_dir/etc/settings"
"$isabelle" scala "$root/test/files.scala"
