#!/usr/bin/env bash
# Opens the pull request that promotes to production the image staging got: the same tag and the same digest.
# Merging the pull request is the approval and the deploy; reverting it is the rollback.
set -euo pipefail

cd "$(dirname "$0")/.."

for tool in git gh; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
[ -z "$(git status --porcelain)" ] || { echo "commit or stash your changes first" >&2; exit 1; }

image_field() {
  sed -n "s/^  $1: \"\(.*\)\"$/\1/p"
}

git fetch --quiet origin dev
staging=$(git show origin/dev:environments/staging/api.yaml)
tag=$(image_field tag <<< "$staging")
digest=$(image_field digest <<< "$staging")
if [ -z "$tag" ] || [ -z "$digest" ]; then
  echo "the staging values pin no tag and digest" >&2
  exit 1
fi

production=environments/production/api.yaml
if [ "$(git show "origin/dev:$production" | image_field digest)" = "$digest" ]; then
  echo "production already runs ${tag:0:7}"
  exit 0
fi

branch="promote/${tag:0:7}"
git switch --quiet --create "$branch" origin/dev
sed -i -e "s/^  tag: \".*\"$/  tag: \"$tag\"/" -e "s/^  digest: \".*\"$/  digest: \"$digest\"/" "$production"
git --no-pager diff -- "$production"
git commit --quiet -m "chore: promote ${tag:0:7} to production" -- "$production"
git push --quiet --set-upstream origin "$branch"
gh pr create --base dev --head "$branch" --title "chore: promote ${tag:0:7} to production" --body "$(cat <<EOF
Promotes the image staging runs to production.

- image: \`segp-api:$tag@$digest\`
- the promotion check in CI confirms staging got this tag and digest first
- at admission, Kyverno checks the signature, the SBOM and the provenance again in production
- rollout: Argo CD replaces the pods one at a time
- rollback: revert this pull request
EOF
)"
git switch --quiet dev
