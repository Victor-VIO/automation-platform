#!/usr/bin/env bash
export PATH="$HOME/.local/bin:$PATH"
cd /home/victor/automation-platform || exit 1

echo "############ ACCEPTANCE 1: pull from Cloud ############"
./scripts/pull.sh --instance cloud || exit 1

echo
echo "############ files written ############"
ls -1 workflows/
echo "--- index ---"
jq . workflows/.index.json

echo
echo "############ ACCEPTANCE 2: validate ############"
./scripts/validate.sh || exit 1

echo
echo "############ credential leak check (must be empty) ############"
grep -l '"credentials"' workflows/*.json 2>/dev/null && echo "LEAK FOUND" || echo "clean: no credentials object in any file"
echo "--- the OpenAI credential that exists live: ---"
grep -o 'r9SSBBE1q0nl0d0m' workflows/*.json 2>/dev/null && echo "LEAKED" || echo "not present in repo (correctly stripped)"

echo
echo "############ ACCEPTANCE 3: pull twice = zero diff ############"
git add -A >/dev/null 2>&1
git stash list >/dev/null 2>&1
before=$(git status --porcelain workflows/ | wc -l)
echo "staged changes from first pull: $before file(s)"
git -c user.name=Victor-VIO -c user.email=v.idowu@alustudent.com commit -q -m "pull: initial workflow export from Cloud" 2>/dev/null
echo "--- second pull ---"
./scripts/pull.sh --instance cloud >/dev/null 2>&1
echo "--- git status after second pull (MUST be empty) ---"
git status --porcelain
if [ -z "$(git status --porcelain)" ]; then
  echo "PASS: second pull produced ZERO diff"
else
  echo "FAIL: second pull changed files"
  git --no-pager diff --stat
fi
