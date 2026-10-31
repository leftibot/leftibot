#!/usr/bin/env python3
"""Generate timeline.json from GitHub API data for all leftibot interactions."""

import json
import re
import subprocess
import sys
from datetime import datetime, timezone

BOT_USER = "leftibot"
OUTPUT = "docs/timeline.json"


def gh_api(endpoint, paginate=False):
    """Call GitHub API via gh CLI."""
    cmd = ["gh", "api", endpoint]
    if paginate:
        cmd.append("--paginate")
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  warning: gh api {endpoint} failed: {result.stderr.strip()}", file=sys.stderr)
        return []
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        # --paginate can produce concatenated JSON arrays
        try:
            return json.loads("[" + result.stdout.replace("][", ",") + "]")
        except json.JSONDecodeError:
            return []


def gh_search(kind, query):
    """Search GitHub via gh CLI."""
    cmd = ["gh", "search", kind, query, "--json",
           "number,title,repository,state,url", "--limit", "200"]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  warning: gh search {kind} failed: {result.stderr.strip()}", file=sys.stderr)
        return []
    return json.loads(result.stdout)


def parse_issue_number(pr_title, pr_body):
    """Extract linked issue number from PR title or body."""
    # Title patterns: "Fix #123:", "[WIP] Issue #123 —"
    m = re.search(r'(?:Fix|Fixes|Close|Closes|Issue)\s+#(\d+)', pr_title, re.I)
    if m:
        return int(m.group(1))
    if pr_body:
        m = re.search(r'(?:Fix|Fixes|Close|Closes)\s+#(\d+)', pr_body, re.I)
        if m:
            return int(m.group(1))
    return None


def fetch_conversation(owner, repo, number, is_pr):
    """Fetch all comments on an issue or PR, merged and sorted."""
    messages = []

    # Issue comments (works for both issues and PRs)
    for c in gh_api(f"repos/{owner}/{repo}/issues/{number}/comments", paginate=True):
        messages.append({
            "timestamp": c.get("created_at", ""),
            "author": c.get("user", {}).get("login", ""),
            "author_avatar": c.get("user", {}).get("avatar_url", ""),
            "type": "issue_comment",
            "body": c.get("body", ""),
            "url": c.get("html_url", ""),
            "path": None,
        })

    if is_pr:
        # Inline review comments
        for c in gh_api(f"repos/{owner}/{repo}/pulls/{number}/comments", paginate=True):
            messages.append({
                "timestamp": c.get("created_at", ""),
                "author": c.get("user", {}).get("login", ""),
                "author_avatar": c.get("user", {}).get("avatar_url", ""),
                "type": "review_comment",
                "body": c.get("body", ""),
                "url": c.get("html_url", ""),
                "path": c.get("path"),
            })

        # Top-level reviews with body text
        for r in gh_api(f"repos/{owner}/{repo}/pulls/{number}/reviews", paginate=True):
            body = r.get("body", "")
            if body and body.strip():
                messages.append({
                    "timestamp": r.get("submitted_at", ""),
                    "author": r.get("user", {}).get("login", ""),
                    "author_avatar": r.get("user", {}).get("avatar_url", ""),
                    "type": "review",
                    "body": body,
                    "url": r.get("html_url", ""),
                    "path": None,
                })

    messages.sort(key=lambda m: m["timestamp"])
    return messages


def main():
    entries = []
    seen_issues = set()  # track issue URLs we've already covered via PRs

    # Step 1: Find all PRs authored by leftibot
    print("Searching for PRs authored by leftibot...", file=sys.stderr)
    prs = gh_search("prs", f"author:{BOT_USER}")
    print(f"  found {len(prs)} PRs", file=sys.stderr)

    for pr_summary in prs:
        repo_full = pr_summary["repository"]["nameWithOwner"]
        owner, repo = repo_full.split("/")
        pr_number = pr_summary["number"]
        pr_url = pr_summary["url"]
        print(f"  processing PR {repo_full}#{pr_number}...", file=sys.stderr)

        # Fetch full PR details
        pr = gh_api(f"repos/{owner}/{repo}/pulls/{pr_number}")
        if not pr:
            continue

        pr_title = pr.get("title", "")
        pr_body = pr.get("body", "") or ""
        pr_merged = pr.get("merged", False)
        pr_draft = pr.get("draft", False)
        pr_state = "merged" if pr_merged else ("draft" if pr_draft else pr.get("state", "open"))

        # Find linked issue
        issue_number = parse_issue_number(pr_title, pr_body)
        issue_data = None
        if issue_number:
            issue = gh_api(f"repos/{owner}/{repo}/issues/{issue_number}")
            if issue and "pull_request" not in issue:
                issue_data = {
                    "number": issue_number,
                    "title": issue.get("title", ""),
                    "url": issue.get("html_url", ""),
                    "state": issue.get("state", ""),
                }
                seen_issues.add(issue.get("html_url", ""))

        # Fetch conversation on the PR
        conversation = fetch_conversation(owner, repo, pr_number, is_pr=True)

        entries.append({
            "id": f"{repo_full}#pr{pr_number}",
            "type": "issue-fix",
            "owner": owner,
            "repo": repo,
            "issue": issue_data,
            "pr": {
                "number": pr_number,
                "title": pr_title,
                "url": pr_url,
                "state": pr_state,
                "merged": pr_merged,
                "draft": pr_draft,
                "created_at": pr.get("created_at", ""),
                "merged_at": pr.get("merged_at") or None,
            },
            "conversation": conversation,
        })

    # Step 2: Find comment-only interactions (issues/PRs where leftibot commented
    # but didn't author a PR)
    print("Searching for issues where leftibot commented...", file=sys.stderr)
    commented = gh_search("issues", f"commenter:{BOT_USER}")
    print(f"  found {len(commented)} issues/PRs with comments", file=sys.stderr)

    # Build set of PR URLs we already have
    pr_urls = {e["pr"]["url"] for e in entries if e["pr"]}

    for item in commented:
        item_url = item["url"]
        repo_full = item["repository"]["nameWithOwner"]
        owner, repo = repo_full.split("/")
        number = item["number"]

        # Skip if we already covered this as a PR or its linked issue
        if item_url in pr_urls or item_url in seen_issues:
            continue

        # Check if this is a PR (search results don't distinguish)
        is_pr = "/pull/" in item_url

        print(f"  processing comment-only {repo_full}#{number}...", file=sys.stderr)

        conversation = fetch_conversation(owner, repo, number, is_pr=is_pr)

        # Only include if leftibot actually has comments here
        if not any(m["author"] == BOT_USER for m in conversation):
            continue

        issue_data = {
            "number": number,
            "title": item.get("title", ""),
            "url": item_url,
            "state": item.get("state", "").lower(),
        }

        entries.append({
            "id": f"{repo_full}#{'pr' if is_pr else ''}{number}",
            "type": "comment-reply",
            "owner": owner,
            "repo": repo,
            "issue": issue_data,
            "pr": None,
            "conversation": conversation,
        })

    # Sort by most recent activity (newest first)
    def sort_key(e):
        if e["pr"] and e["pr"]["created_at"]:
            return e["pr"]["created_at"]
        if e["conversation"]:
            return e["conversation"][-1]["timestamp"]
        return ""

    entries.sort(key=sort_key, reverse=True)

    timeline = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "bot_user": BOT_USER,
        "entries": entries,
    }

    with open(OUTPUT, "w") as f:
        json.dump(timeline, f, indent=2)

    # Summary
    fixes = sum(1 for e in entries if e["type"] == "issue-fix")
    comments = sum(1 for e in entries if e["type"] == "comment-reply")
    merged = sum(1 for e in entries if e.get("pr", {}) and e["pr"] and e["pr"]["merged"])
    print(f"\nWritten {OUTPUT}: {len(entries)} entries ({fixes} fixes, {comments} comment replies, {merged} merged)", file=sys.stderr)


if __name__ == "__main__":
    main()
