#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
cd /home/victor/automation-platform || exit 1
echo "--- index file ---"
cat workflows/.index.json
echo "--- jq version ---"
jq --version
echo "--- trace (last 45 lines) ---"
bash -x scripts/pull.sh --instance cloud 2>&1 | tail -45
