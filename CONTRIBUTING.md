# Contributing

## Start with an issue

Open an issue before writing code, unless the fix is small and obvious.

- **Bug report:** something is broken.
- **Feature request:** new behavior. Describe the problem before the solution.
- **Plan:** a larger goal, split into build tasks linked as sub-issues.
- **Build task:** one atomic step that fits in a single pull request.

New bugs and feature requests get the `needs-triage` label. Wait for a maintainer to
remove it before starting work, so effort isn't spent on changes that won't be accepted.

## Pull requests

1. Branch from `main`.
2. Make one focused change. Split independent fixes into separate pull requests.
3. Run `make check` locally.
4. Open the pull request with a conventional-commit title, such as
   `fix(api): retries no longer duplicate orders`, and fill in every template section.

CI must pass before merging. Pull requests are squash-merged, so the title becomes the
commit message on `main`.

## Automation

- **AI review:** a pull request is reviewed automatically when it is opened ready for
  review, or when a draft is marked ready.
- **`/oc` comments:** maintainers can comment `/oc <request>` on an issue or pull request
  to ask the agent a question or have it make a change.
- **`agent-ready` label:** on a build task, this has the agent implement it and open a
  draft pull request.
