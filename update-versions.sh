#!/bin/bash
# Fetches all open PRs from upstream obzorarr repo (excluding dependabot/renovate)
# For each PR: updates VERSION.json with the PR's commit SHA, commits, and pushes
# Each push triggers the call-build.yml workflow

set -e

# Fetch all open PRs targeting main, excluding bot PRs
prs=$(curl -u "${GITHUB_ACTOR}:${GITHUB_TOKEN}" -fsSL \
  "https://api.github.com/repos/engels74/obzorarr/pulls?state=open&sort=updated&direction=desc" | \
  jq -c '[.[] | select(
    (.base.ref == "main") and
    (.head.ref | test("dependabot|renovate"; "i") | not)
  ) | {
    number: .number,
    branch: .head.ref,
    sha: .head.sha
  }]') || exit 1

count=$(echo "$prs" | jq 'length')
echo "Found ${count} open PR(s)"

if [[ "$count" -eq 0 ]]; then
    echo "No open PRs found (excluding dependabot/renovate)"
    exit 0
fi

# Configure git for commits
git config user.name "github-actions[bot]"
git config user.email "github-actions[bot]@users.noreply.github.com"

# Process each PR
echo "$prs" | jq -c '.[]' | while read -r pr; do
    pr_number=$(echo "$pr" | jq -r '.number')
    pr_sha=$(echo "$pr" | jq -r '.sha')
    pr_branch=$(echo "$pr" | jq -r '.branch')

    echo "=== Processing PR #${pr_number} (${pr_branch}): ${pr_sha} ==="

    # Check if we need to update (compare with current VERSION.json)
    current_version=$(jq -r '.version' VERSION.json 2>/dev/null || echo "")
    current_branch=$(jq -r '.branch' VERSION.json 2>/dev/null || echo "")

    if [[ "$current_version" == "$pr_sha" && "$current_branch" == "pr-${pr_number}" ]]; then
        echo "PR #${pr_number} already at ${pr_sha}, skipping"
        continue
    fi

    # Update VERSION.json with this PR's info
    json=$(cat VERSION.json)
    jq --sort-keys \
        --arg version "${pr_sha}" \
        --arg branch "pr-${pr_number}" \
        '.version = $version | .branch = $branch' <<< "${json}" > VERSION.json

    # Commit and push to trigger build
    git add VERSION.json
    git commit -m "PR update: #${pr_number} => ${pr_sha:0:7}"
    git push

    echo "Committed and pushed update for PR #${pr_number}"

    # Small delay between PRs to avoid overwhelming CI
    sleep 5
done
