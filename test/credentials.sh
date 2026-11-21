#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
cat > "$tmp/bin/websocat" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ ${!#} == wss://example.org/isabelle ]]
read -r password
[[ "$password" == native-secret ]]
read -r command
[[ "$command" == 'echo "byom-ready"' ]]
if [[ ${MOCK_REJECT:-0} == 1 ]]; then
  echo 'ERROR'
else
  printf 'OK {"isabelle_name":"Isabelle2026"}\nOK "byom-ready"\n'
fi
MOCK
chmod +x "$tmp/bin/websocat"
export PATH="$tmp/bin:$PATH" BYOM_INFO="$tmp/custom.info"
printf 'server "test" = 127.0.0.1:8081 (password "native-secret")\n' > "$BYOM_INFO"
"$root/server/credentials.sh" wss://example.org/isabelle > "$tmp/result"
[[ $(cat "$tmp/result") == $'URL=wss://example.org/isabelle\nPASSWORD=native-secret' ]]
if MOCK_REJECT=1 "$root/server/credentials.sh" wss://example.org/isabelle > "$tmp/result" 2>/dev/null; then
  echo 'Unverified credentials were accepted' >&2; exit 1
fi
[[ ! -s "$tmp/result" ]]
echo 'Custom metadata, authenticated verification and failure stdout checks passed.'
