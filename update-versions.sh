#!/bin/bash
# Fetches all open PRs from upstream obzorarr repo (excluding dependabot/renovate)
# For each PR: updates VERSION.json with the PR's commit SHA, commits, and pushes
# Each push triggers the call-build.yml workflow
# After processing, cleans up stale PR entries from tags.json on master

set -e

#######################################
# Clean up stale PR entries from tags.json on master branch
# Arguments:
#   $1 - Space-separated list of open PR numbers
#######################################
cleanup_tags_json() {
    local open_prs="$1"

    echo ""
    echo "=== Starting tags.json cleanup ==="

    # Fetch latest master
    git fetch origin master:refs/remotes/origin/master 2>/dev/null || {
        echo "Warning: Failed to fetch master branch, skipping cleanup"
        return 1
    }

    # Get current tags.json from master
    local tags_json
    tags_json=$(git show origin/master:tags.json 2>/dev/null) || {
        echo "Warning: tags.json not found on master, skipping cleanup"
        return 1
    }

    # Build array of open PR keys
    local pr_keys=""
    for pr_num in $open_prs; do
        [[ -n "$pr_keys" ]] && pr_keys="${pr_keys}, "
        pr_keys="${pr_keys}\"pr-pr-${pr_num}\""
    done

    # Filter: keep non-PR entries + open PR entries only
    local cleaned_json
    cleaned_json=$(echo "$tags_json" | jq --argjson open_prs "[$pr_keys]" '
        to_entries |
        map(select(
            (.key | startswith("pr-pr-") | not) or
            (.key as $k | $open_prs | any(. == $k))
        )) |
        from_entries
    ') || {
        echo "Error: jq processing failed"
        return 1
    }

    # Check if anything changed
    local orig_keys new_keys
    orig_keys=$(echo "$tags_json" | jq -r 'keys | map(select(startswith("pr-pr-"))) | sort | join(",")')
    new_keys=$(echo "$cleaned_json" | jq -r 'keys | map(select(startswith("pr-pr-"))) | sort | join(",")')

    if [[ "$orig_keys" == "$new_keys" ]]; then
        echo "No stale PR entries found"
        return 0
    fi

    # Calculate removed count
    local orig_count new_count removed_count
    orig_count=$(echo "$tags_json" | jq 'keys | map(select(startswith("pr-pr-"))) | length')
    new_count=$(echo "$cleaned_json" | jq 'keys | map(select(startswith("pr-pr-"))) | length')
    removed_count=$((orig_count - new_count))
    echo "Removing ${removed_count} stale PR entries"

    # Use worktree to modify master without switching branches
    local worktree_dir
    worktree_dir=$(mktemp -d)

    git worktree add --quiet --detach "$worktree_dir" origin/master || {
        echo "Error: Failed to create worktree"
        rm -rf "$worktree_dir"
        return 1
    }

    # Write cleaned JSON and commit
    echo "$cleaned_json" > "${worktree_dir}/tags.json"

    (
        cd "$worktree_dir" || exit 1
        git checkout -b temp-cleanup-branch origin/master 2>/dev/null
        git add tags.json
        git commit -m "chore: remove ${removed_count} stale PR tag entries [skip ci]"

        # Push with retry for race conditions
        for attempt in 1 2 3; do
            if git push origin HEAD:master 2>/dev/null; then
                echo "Cleanup pushed successfully"
                exit 0
            fi
            echo "Push attempt ${attempt} failed, retrying..."
            git fetch origin master 2>/dev/null
            git rebase origin/master 2>/dev/null || { git rebase --abort 2>/dev/null; exit 1; }
        done
        echo "Failed to push after 3 attempts"
        exit 1
    )
    local result=$?

    # Cleanup worktree
    git worktree remove --force "$worktree_dir" 2>/dev/null || true
    rm -rf "$worktree_dir" 2>/dev/null || true

    [[ $result -eq 0 ]] && echo "=== Cleanup completed ===" || echo "=== Cleanup failed ==="
    return $result
}

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

# Extract PR numbers for cleanup function
open_pr_numbers=$(echo "$prs" | jq -r '.[].number' | tr '\n' ' ' | xargs)

if [[ "$count" -eq 0 ]]; then
    echo "No open PRs found (excluding dependabot/renovate)"
    # Still run cleanup to remove all stale entries
    cleanup_tags_json ""
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

    short_sha="${pr_sha:0:7}"
    echo "=== Processing PR #${pr_number} (${pr_branch}): ${pr_sha} ==="

    # Check git log to see if we already have a commit for this PR+SHA
    # This prevents duplicate builds when multiple PRs are processed in sequence
    if git log --oneline -100 | grep -q "PR update: #${pr_number} => ${short_sha}"; then
        echo "PR #${pr_number} already built at ${short_sha}, skipping"
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
    git commit -m "PR update: #${pr_number} => ${short_sha}"
    git push

    echo "Committed and pushed update for PR #${pr_number}"

    # Small delay between PRs to avoid overwhelming CI
    sleep 5
done

# Clean up stale PR entries from tags.json on master
cleanup_tags_json "$open_pr_numbers"
