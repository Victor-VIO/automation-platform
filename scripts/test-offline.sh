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
OUT=$(./scripts/pull.sh --instance bogus 2>&1); echo "$OUT" | grep -q "unknown instance" && ok "rejects unknown instance" || bad "bad instance not caught"
OUT=$(env -u N8N_CLOUD_URL ./scripts/pull.sh --instance selfhosted 2>&1); echo "$OUT" | grep -q "URL not set" && ok "unset instance fails loudly" || bad "unset instance not caught: $OUT"

rm -f workflows/sample-clean.json
echo
echo "=================================================="
echo "  PASSED: $pass    FAILED: $fail"
echo "=================================================="
[ "$fail" -eq 0 ]
