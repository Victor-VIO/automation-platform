#!/usr/bin/env bash
# Offline acceptance tests for Build 0a. No API key, no network.
export PATH="$HOME/.local/bin:$PATH"
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

pass=0; fail=0
ok()   { echo "PASS  $*"; pass=$((pass+1)); }
bad()  { echo "FAIL  $*"; fail=$((fail+1)); }

echo "############ TEST 1: validate.sh on empty repo ############"
if ./scripts/validate.sh; then ok "empty repo validates"; else bad "empty repo should validate"; fi

echo
echo "############ TEST 2: a clean workflow passes ############"
cat > workflows/sample-clean.json <<'EOF'
{"name":"Sample Clean","nodes":[{"id":"a1","name":"Webhook","type":"n8n-nodes-base.webhook","typeVersion":2,"position":[0,0],"parameters":{"path":"hook"}}],"connections":{},"settings":{}}
EOF
# normalise it the way pull.sh would
jq -S '{name,nodes:[(.nodes//[])[]|del(.credentials)],connections:(.connections//{}),settings:(.settings//{})}' \
  workflows/sample-clean.json > /tmp/n.json && mv /tmp/n.json workflows/sample-clean.json
if ./scripts/validate.sh >/dev/null 2>&1; then ok "clean normalised workflow passes"; else bad "clean workflow rejected"; ./scripts/validate.sh; fi

echo
echo "############ TEST 3: THE GATE - committed credential must FAIL ############"
jq '.nodes[0].credentials={"httpBasicAuth":{"id":"99","name":"my-secret-cred"}}' \
  workflows/sample-clean.json > /tmp/c.json && mv /tmp/c.json workflows/sample-clean.json
if ./scripts/validate.sh >/dev/null 2>&1; then
  bad "GATE IS BROKEN - credential was accepted"
else
  ok "credential object rejected"
  ./scripts/validate.sh 2>&1 | grep FAIL | head -2
fi

echo
echo "############ TEST 4: secret-shaped string must FAIL ############"
cat > workflows/sample-clean.json <<'EOF'
{"connections":{},"name":"Sample Clean","nodes":[{"id":"a1","name":"HTTP","parameters":{"token":"sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"},"position":[0,0],"type":"n8n-nodes-base.httpRequest","typeVersion":4}],"settings":{}}
EOF
if ./scripts/validate.sh >/dev/null 2>&1; then
  bad "GATE IS BROKEN - secret string accepted"
else
  ok "secret-shaped string rejected"
fi

echo
echo "############ TEST 5: non-normalised file must FAIL ############"
printf '{"name":"Messy","nodes":[],"connections":{},"settings":{},"extra":"field"}' > workflows/sample-clean.json
if ./scripts/validate.sh >/dev/null 2>&1; then
  bad "GATE IS BROKEN - unnormalised file accepted"
else
  ok "unnormalised file rejected"
fi

echo
echo "############ TEST 6: normalisation is idempotent ############"
cat > /tmp/raw.json <<'EOF'
{"id":"XYZ","name":"Idem","active":true,"updatedAt":"2026-01-01","pinData":{"x":1},"settings":{"b":2,"a":1},"connections":{"Webhook":{"main":[[]]}},"nodes":[{"name":"Webhook","credentials":{"k":{"id":"1"}},"id":"n1","type":"t","typeVersion":1,"position":[0,0],"parameters":{}}]}
EOF
N='{name:.name,nodes:[(.nodes//[])[]|del(.credentials)],connections:(.connections//{}),settings:(.settings//{})}'
jq -S "$N" /tmp/raw.json > /tmp/p1.json
jq -S "$N" /tmp/p1.json > /tmp/p2.json
if diff -q /tmp/p1.json /tmp/p2.json >/dev/null; then ok "normalise twice = identical (zero-diff pull)"; else bad "normalisation not idempotent"; diff /tmp/p1.json /tmp/p2.json; fi

echo
echo "############ TEST 7: credentials stripped by normalisation ############"
if jq -e '[.nodes[]|select(.credentials!=null)]|length==0' /tmp/p1.json >/dev/null; then ok "credentials stripped"; else bad "credentials survived"; fi
if jq -e 'has("pinData")|not' /tmp/p1.json >/dev/null; then ok "pinData dropped"; else bad "pinData survived"; fi
if jq -e 'has("id")|not' /tmp/p1.json >/dev/null; then ok "volatile id dropped"; else bad "id survived"; fi

echo
echo "############ TEST 8: credential merge-back logic ############"
LOCAL='{"name":"W","nodes":[{"name":"Slack","type":"t"},{"name":"Renamed","type":"t"}],"connections":{},"settings":{}}'
LIVE='{"nodes":[{"name":"Slack","credentials":{"slackApi":{"id":"7","name":"prod-slack"}}},{"name":"OldName","credentials":{"httpAuth":{"id":"9"}}}]}'
MERGED=$(jq -n --argjson local "$LOCAL" --argjson live "$LIVE" '
  (($live.nodes//[])|map(select(.credentials!=null)|{key:.name,value:.credentials})|from_entries) as $c
  | $local | .nodes=[.nodes[]|if $c[.name] then .credentials=$c[.name] else . end]')
if jq -e '.nodes[]|select(.name=="Slack")|.credentials.slackApi.id=="7"' <<<"$MERGED" >/dev/null; then
  ok "matching node keeps its live credential"
else bad "credential merge lost a binding"; fi
LOST=$(jq -r -n --argjson live "$LIVE" --argjson merged "$MERGED" '
  (($live.nodes//[])|map(select(.credentials!=null)|.name)) as $had
  | (($merged.nodes//[])|map(select(.credentials!=null)|.name)) as $kept
  | ($had-$kept)|join(",")')
if [ "$LOST" = "OldName" ]; then ok "renamed node reported as unbound: $LOST"; else bad "unbound detection wrong: got '$LOST'"; fi

echo
echo "############ TEST 9: instance guard ############"
# Written as if/then/else rather than `A && B || C`: in that form C also runs
# when A succeeds but B fails, so a broken assertion could report pass AND fail.
OUT=$(./scripts/pull.sh --instance bogus 2>&1)
if echo "$OUT" | grep -q "unknown instance"; then
  ok "rejects unknown instance"
else
  bad "bad instance not caught: $OUT"
fi

OUT=$(env -u N8N_CLOUD_URL ./scripts/pull.sh --instance selfhosted 2>&1)
if echo "$OUT" | grep -q "URL not set"; then
  ok "unset instance fails loudly"
else
  bad "unset instance not caught: $OUT"
fi

echo
echo "############ TEST 10: prefix matching is delimiter-aware ############"
# The audit bug: slugify("ap-") returns "ap" (trailing separators are stripped),
# so the old glob "$slug" == "ap"* also matched api-gateway and apple-sorter.
# shellcheck source=scripts/lib.sh
. ./scripts/lib.sh
# lib.sh sets -e. This harness asserts on commands that fail on purpose, so it
# must not inherit that — test 13 deliberately drives pull.sh to a non-zero exit.
set +e
if prefix_matches "ap-intake" "ap-";   then ok "'ap-' matches ap-intake"; else bad "'ap-' should match ap-intake"; fi
if prefix_matches "api-gateway" "ap-"; then bad "'ap-' must NOT match api-gateway"; else ok "'ap-' rejects api-gateway"; fi
if prefix_matches "apple-sorter" "ap-"; then bad "'ap-' must NOT match apple-sorter"; else ok "'ap-' rejects apple-sorter"; fi
if prefix_matches "ap-intake" "ap";    then ok "bare 'ap' behaves as 'ap-'"; else bad "bare 'ap' should match ap-intake"; fi
if prefix_matches "ap" "ap-";          then ok "prefix matches a slug equal to itself"; else bad "'ap-' should match slug 'ap'"; fi
if prefix_matches "anything" "";       then ok "empty prefix matches everything"; else bad "empty prefix should match everything"; fi

echo
echo "############ TESTS 11-13: pull.sh scoping, against a stubbed API ############"
# pull.sh is driven end-to-end here with curl stubbed on PATH, so these exercise
# the real argument parsing and the real filter rather than a copy of them.
# Still offline: no API key is used and nothing leaves the machine.
STUB="$(mktemp -d)"
mkdir -p "$STUB/bin"
cat > "$STUB/bin/curl" <<'STUBEOF'
#!/usr/bin/env bash
# Test stub for curl. Serves canned n8n API responses from $STUB_DIR.
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  *"/workflows?limit="*) cat "$STUB_DIR/list.json" ;;
  */workflows/*)         cat "$STUB_DIR/wf-${url##*/}.json" ;;
  *)                     printf '{}\n' ;;
esac
STUBEOF
chmod +x "$STUB/bin/curl"

cat > "$STUB/list.json" <<'STUBEOF'
{"data":[
 {"id":"id1","name":"AP — Intake"},
 {"id":"id2","name":"Api Gateway"},
 {"id":"id3","name":"Apple Sorter"}
],"nextCursor":null}
STUBEOF
for i in 1 2 3; do
  printf '{"id":"id%s","name":"N%s","nodes":[],"connections":{},"settings":{}}\n' "$i" "$i" > "$STUB/wf-id$i.json"
done
# The stub needs a URL and a key to get past resolve_instance. A real .env
# overrides these when sourced, which is fine — curl is stubbed either way.
# PULL_PREFIX is exported so the .env-default test is deterministic in CI,
# which has no .env at all.
export STUB_DIR="$STUB" PATH="$STUB/bin:$PATH"
export N8N_CLOUD_URL="https://stub.invalid" N8N_CLOUD_API_KEY="stub-key" PULL_PREFIX="ap-"

cp workflows/.index.json "$STUB/index.bak" 2>/dev/null || true
stub_cleanup() {
  rm -f workflows/ap-intake.json workflows/api-gateway.json workflows/apple-sorter.json
  if [ -f "$STUB/index.bak" ]; then cp "$STUB/index.bak" workflows/.index.json; fi
}

echo "--- 11: an explicit --prefix pulls only whole-segment matches ---"
OUT=$(./scripts/pull.sh --instance cloud --prefix ap- 2>&1); RC=$?
stub_cleanup
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "pulled 1 workflow"; then
  ok "--prefix ap- pulled exactly 1 of 3 (ap-intake)"
else
  bad "--prefix ap- should pull 1, got rc=$RC: $OUT"
fi
if echo "$OUT" | grep -q "skipped 2"; then ok "api-gateway and apple-sorter skipped"; else bad "expected 2 skipped: $OUT"; fi

echo "--- 12: --all beats the PULL_PREFIX default from .env ---"
OUT=$(./scripts/pull.sh --instance cloud --all 2>&1); RC=$?
stub_cleanup
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "pulled 3 workflow"; then
  ok "--all overrode PULL_PREFIX and pulled all 3"
else
  bad "--all should pull 3, got rc=$RC: $OUT"
fi

echo "--- 13: a pull matching zero workflows must NOT exit 0 ---"
OUT=$(./scripts/pull.sh --instance cloud --prefix zz- 2>&1); RC=$?
stub_cleanup
if [ "$RC" -eq 3 ]; then ok "zero-match exits 3, not 0"; else bad "zero-match must exit 3, got rc=$RC"; fi
if echo "$OUT" | grep -q "matched 0 workflows"; then ok "zero-match says so explicitly"; else bad "zero-match message missing: $OUT"; fi
if echo "$OUT" | grep -q "zz-"; then ok "zero-match names the configured prefix"; else bad "zero-match must name the prefix: $OUT"; fi
if echo "$OUT" | grep -q "ap-intake"; then ok "zero-match lists what it skipped"; else bad "zero-match must list skipped slugs: $OUT"; fi

rm -rf "$STUB"

rm -f workflows/sample-clean.json
echo
echo "=================================================="
echo "  PASSED: $pass    FAILED: $fail"
echo "=================================================="
[ "$fail" -eq 0 ]
