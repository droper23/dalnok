#!/usr/bin/env bash
# Publishes site/ (feature-parity page) to the public status repo's GitHub Pages.
# Only site/ is published; the code repo stays private.
# Usage: scripts/publish-site.sh ["commit message"]
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="${DALNOK_STATUS_REPO:-droper23/dalnok-status}"
MSG="${1:-Update parity page ($(date +%Y-%m-%d))}"
WORK=".build/site-publish"

python3 -c "import json; json.load(open('site/parity.json'))" # refuse to publish invalid data

if ! gh repo view "$REPO" >/dev/null 2>&1; then
  gh repo create "$REPO" --public --description "Dalnok DAW: public feature-parity tracker" >/dev/null
  echo "created $REPO"
fi
if [[ ! -d "$WORK/.git" ]]; then
  rm -rf "$WORK"
  gh repo clone "$REPO" "$WORK" -- -q 2>/dev/null || { mkdir -p "$WORK" && git -C "$WORK" init -q -b main && git -C "$WORK" remote add origin "https://github.com/$REPO.git"; }
fi
git -C "$WORK" pull -q --rebase origin main 2>/dev/null || true
rsync -a --delete --exclude .git site/ "$WORK"/
touch "$WORK/.nojekyll"
cat > "$WORK/README.md" <<MD
# Dalnok: feature parity

Public progress tracker for Dalnok, an open-source DAW in development.
Live page: https://${REPO%%/*}.github.io/${REPO#*/}/

Generated from the main project. Percentages count only verified steps (tests, self-tests, benchmarks).
MD
git -C "$WORK" add -A
if git -C "$WORK" diff --cached --quiet; then
  echo "no changes to publish"
else
  git -C "$WORK" commit -q -m "$MSG"
  git -C "$WORK" push -q -u origin main
  echo "pushed to $REPO"
fi
# Enable Pages (main branch, root) if not yet enabled.
if ! gh api "repos/$REPO/pages" >/dev/null 2>&1; then
  gh api -X POST "repos/$REPO/pages" -f "source[branch]=main" -f "source[path]=/" >/dev/null && echo "enabled GitHub Pages"
fi
echo "https://${REPO%%/*}.github.io/${REPO#*/}/"
