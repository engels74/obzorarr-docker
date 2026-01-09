#!/bin/bash
# Fetches all open PRs from upstream obzorarr repo (excluding dependabot/renovate)
# For each PR: updates VERSION.json with the PR's commit SHA, commits, and pushes
# Each push triggers the call-build.yml workflow
# After processing, cleans up stale PR entries from obzorarr-tags.json on website

set -exuo pipefail

#######################################
# Clean up stale PR entries from obzorarr-tags.json on website repo
# Arguments:
#   $1 - Space-separated list of open PR numbers
#######################################
cleanup_tags_json() {
    local open_prs="$1"

    echo ""
    echo "=== Starting website tags.json cleanup ==="

    # Clone website repo to temporary directory
    local website_dir
    website_dir=$(mktemp -d)

    git clone --depth 1 -b master "https://${PERSONAL_TOKEN}@github.com/engels74/website.git" "$website_dir" 2>/dev/null || {
        echo "Warning: Failed to clone website repo, skipping cleanup"
        rm -rf "$website_dir"
        return 1
    }

    local tags_file="${website_dir}/docs/containers/obzorarr-tags.json"

    # Get current tags.json from website
    local tags_json
    if [[ -f "$tags_file" ]]; then
        tags_json=$(cat "$tags_file")
    else
        echo "Warning: obzorarr-tags.json not found on website, skipping cleanup"
        rm -rf "$website_dir"
        return 1
    fi

    # Build array of open PR keys (format: pr-{number})
    local pr_keys=""
    for pr_num in $open_prs; do
        [[ -n "$pr_keys" ]] && pr_keys="${pr_keys}, "
        pr_keys="${pr_keys}\"pr-${pr_num}\""
    done

    # Filter: keep non-PR entries + open PR entries only
    local cleaned_json
    cleaned_json=$(echo "$tags_json" | jq --argjson open_prs "[$pr_keys]" '
        to_entries |
        map(select(
            (.key | startswith("pr-") | not) or
            (.key as $k | $open_prs | any(. == $k))
        )) |
        from_entries
    ') || {
        echo "Error: jq processing failed"
        rm -rf "$website_dir"
        return 1
    }

    # Check if anything changed
    local orig_keys new_keys
    orig_keys=$(echo "$tags_json" | jq -r 'keys | map(select(startswith("pr-"))) | sort | join(",")')
    new_keys=$(echo "$cleaned_json" | jq -r 'keys | map(select(startswith("pr-"))) | sort | join(",")')

    if [[ "$orig_keys" == "$new_keys" ]]; then
        echo "No stale PR entries found"
        rm -rf "$website_dir"
        return 0
    fi

    # Calculate removed count
    local orig_count new_count removed_count
    orig_count=$(echo "$tags_json" | jq 'keys | map(select(startswith("pr-"))) | length')
    new_count=$(echo "$cleaned_json" | jq 'keys | map(select(startswith("pr-"))) | length')
    removed_count=$((orig_count - new_count))
    echo "Removing ${removed_count} stale PR entries"

    # Write cleaned JSON
    echo "$cleaned_json" > "$tags_file"

    # Commit and push
    (
        cd "$website_dir" || exit 1
        git config user.name "github-actions[bot]"
        git config user.email "github-actions[bot]@users.noreply.github.com"
        git add docs/containers/obzorarr-tags.json
        git commit -m "chore: remove ${removed_count} stale PR tag entries from obzorarr [skip ci]"

        # Push with retry for race conditions
        for attempt in 1 2 3; do
            if git push origin master 2>/dev/null; then
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

    # Cleanup
    rm -rf "$website_dir"

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
  }]')

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
