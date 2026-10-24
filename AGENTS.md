# Agent instructions

Read this before changing anything in this repository.

## Project

<!-- One paragraph: what this project is, its main language and framework, and where the
     important code lives. Update this when you create a repository from the template. -->

## Commands

- `make lint`: lint and format checks
- `make test`: the test suite
- `make build`: build the project
- `make check`: all three

Run `make lint` and `make test` before you say a change works.

## How to work

- **One task, one pull request.** Implement only what the issue asks. Leave anything listed
  under "Out of scope" alone, and do not refactor or reformat unrelated code.
- **Follow existing patterns.** Match the naming, structure, and style of nearby code
  before introducing anything new.
- **Test behavior changes.** Add or update tests for what you change.
- **Ask instead of guessing.** If a task is ambiguous, stop and explain what is missing
  rather than inventing requirements.
- **Never commit secrets,** credentials, or `.env` files.

## Pull requests

- The title is a conventional commit: `type(scope): summary`, where type is one of
  `feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`, or `revert`.
- Fill in every section of `.github/pull_request_template.md`. Under Verification, list
  the commands you ran and what they showed. "Tests pass" alone is not enough.
- Link the issue with `Closes #<number>`.
