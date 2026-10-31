#!/usr/bin/env bash
# Fork only (never upstream): rebuilds the integration branch from upstream
# main, every still-open PR branch from the fork, then the "(fork only)"
# commits of the previous build. See FORK-NOTES.md.
#
#   mise exec -- hack/rebuild-integration.sh
#
# The result is left on integration.new. Nothing is pushed: test it, then
#   git branch -f integration integration.new
#   git push --force-with-lease fork integration
set -euo pipefail

# Merge order. #669's branch is stacked on #668, so it brings both.
PRS=(669 671 672 681 682)
UPSTREAM=home-operations/tuppr
BRANCH=integration

git fetch -q origin
git fetch -q fork

prev=$(git rev-parse -q --verify "refs/heads/$BRANCH" || git rev-parse -q --verify "refs/remotes/fork/$BRANCH" || true)
extras=()
if [[ -n $prev ]]; then
	while IFS= read -r c; do extras+=("$c"); done < <(
		git log --reverse --no-merges --format=%H --grep='(fork only)' "origin/main..$prev"
	)
fi

git config rerere.enabled true
git config rerere.autoUpdate true
git checkout -q -B "$BRANCH.new" origin/main

for pr in "${PRS[@]}"; do
	read -r state head < <(gh pr view "$pr" -R "$UPSTREAM" --json state,headRefName --jq '"\(.state) \(.headRefName)"')
	if [[ $state != OPEN ]]; then
		echo "skip #$pr ($head): $state"
		continue
	fi
	echo "merge #$pr ($head)"
	if ! git merge -q --no-ff --no-edit --signoff -m "Merge #$pr ($head) into $BRANCH" "fork/$head"; then
		if [[ -n $(git diff --name-only --diff-filter=U) ]]; then
			echo "unresolved conflicts merging #$pr; resolve them, git commit -s, then re-run" >&2
			exit 1
		fi
		# rerere replayed every resolution.
		git commit -q -s --no-edit
	fi
done

for c in "${extras[@]}"; do
	echo "pick $(git log -1 --format=%s "$c")"
	git cherry-pick --empty=drop "$c"
done

echo
git log --oneline "origin/main..$BRANCH.new"
if [[ -n $prev ]]; then
	echo
	echo "diff against the previous build ($prev):"
	git diff --stat "$prev" "$BRANCH.new"
fi
