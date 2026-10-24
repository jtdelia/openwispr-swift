#!/usr/bin/env bash
# One-time setup for a repository created from this template. GitHub copies files
# from a template but not labels, branch rules, or settings, so this applies them.
#
# Usage: scripts/setup-repo.sh [owner/repo]   (defaults to the current directory's repo)
# Requires the GitHub CLI (gh), logged in with admin access to the repository.
# Safe to run more than once.

set -euo pipefail

repo="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
echo "Setting up $repo"

step() { printf '\n==> %s\n' "$1"; }
warn() { printf 'warning: %s\n' "$1" >&2; }

step "Labels"
while IFS='|' read -r name color description; do
  gh label create "$name" --repo "$repo" --color "$color" --description "$description" --force
done <<'EOF'
type:bug|d73a4a|Something is broken
type:feature|a2eeef|New behavior
type:plan|5319e7|A larger goal split into build tasks
type:task|0e8a16|An atomic build task
needs-triage|fbca04|Waiting for a maintainer to accept it
agent-ready|1d76db|Ready for the agent to implement
blocked|b60205|Waiting on other work
EOF

step "Merge settings: squash only, pull request title as the commit message"
gh api --silent -X PATCH "repos/$repo" \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -F allow_auto_merge=true \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY

step "Actions: read-only token by default"
gh api --silent -X PUT "repos/$repo/actions/permissions/workflow" \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false

step "Private vulnerability reporting"
gh api --silent -X PUT "repos/$repo/private-vulnerability-reporting" 2>/dev/null \
  || warn "could not enable it (GitHub only offers this on public repositories)"

step "Protect the default branch"
branch=$(gh api "repos/$repo" --jq .default_branch)
ruleset=$(cat <<EOF
{
  "name": "protect-$branch",
  "target": "branch",
  "enforcement": "active",
  "conditions": {"ref_name": {"include": ["~DEFAULT_BRANCH"], "exclude": []}},
  "bypass_actors": [{"actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always"}],
  "rules": [
    {"type": "deletion"},
    {"type": "non_fast_forward"},
    {"type": "pull_request", "parameters": {
      "required_approving_review_count": 0,
      "dismiss_stale_reviews_on_push": false,
      "require_code_owner_review": false,
      "require_last_push_approval": false,
      "required_review_thread_resolution": false
    }},
    {"type": "required_status_checks", "parameters": {
      "strict_required_status_checks_policy": false,
      "required_status_checks": [{"context": "ci-success"}]
    }}
  ]
}
EOF
)
existing=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"protect-$branch\") | .id" 2>/dev/null || true)
if [ -n "$existing" ]; then
  method=PUT path="repos/$repo/rulesets/$existing"
else
  method=POST path="repos/$repo/rulesets"
fi
if printf '%s' "$ruleset" | gh api --silent -X "$method" "$path" --input - 2>/dev/null; then
  echo "Pull requests and the ci-success check are now required on $branch. Admins can bypass."
else
  warn "could not create the branch ruleset. Private repositories need GitHub Pro, Team, or Enterprise for this."
fi

step "Kiro CLI fallback reviewer (optional)"
echo "When no free OpenCode model works, the AI review falls back to Kiro CLI."
echo "That needs a KIRO_API_KEY from a paid Kiro plan (Pro or higher)."
read -r -p "Set the KIRO_API_KEY secret now? [y/N] " answer
if [[ "$answer" =~ ^[Yy] ]]; then
  gh secret set KIRO_API_KEY --repo "$repo"
fi

step "Remaining manual step"
cat <<EOF
Install the OpenCode GitHub app on $repo:

  https://github.com/apps/opencode-agent

The /oc comments and agent-ready tasks push branches and open pull requests as that app,
so CI runs on them. The AI review works without it.
EOF
