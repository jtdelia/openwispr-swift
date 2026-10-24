Review this pull request. You are read-only: do not edit files.

Get the diff with `git diff origin/<base branch>...HEAD`. Read surrounding code when a change
depends on it. Read AGENTS.md for this repository's conventions.

Check, in this order:

1. Correctness: bugs, unhandled errors, edge cases, race conditions, and security problems
   such as injection, leaked secrets, or missing authorization.
2. Scope: the pull request solves one problem. Flag unrelated changes that belong in their
   own pull request. If it links an issue, check the change meets that issue's acceptance
   criteria and respects its "Out of scope" section.
3. Description: the body follows the template. Problem, Change, Scope, and Verification
   are filled in. Verification must describe what was run and what was observed. "Tests
   pass" alone is not enough.
4. Tests: behavior changes come with tests, or Verification explains why not.

Reply in this format:

## Summary
One or two sentences: what the change does and whether it is ready to merge.

## Issues
A numbered list of problems, most serious first. For each, give `path:line`, what is wrong,
and a concrete fix. Write "None found." if there are none.

## Suggestions
Optional, non-blocking improvements. Omit this section if there are none.

Be direct and specific. Do not praise the code or restate the diff. Do not invent problems.
