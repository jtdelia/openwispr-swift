# After creating a repository from this template

GitHub copies the files from a template, but not its labels, branch rules, secrets, or
settings. Do these steps once per new repository.

## 1. Run the setup script

```sh
scripts/setup-repo.sh
```

It creates the labels, sets squash-only merging, makes the Actions token read-only by
default, and protects `main` so that pull requests and the `ci-success` check are required.
It also offers to store a Kiro API key (see step 3).

Branch protection on private repositories needs GitHub Pro, Team, or Enterprise. On the
Free plan the script warns and skips that step. Everything else still works.

## 2. Install the OpenCode GitHub app

Install [opencode-agent](https://github.com/apps/opencode-agent) on the repository. `/oc`
comments and `agent-ready` tasks push code as this app, which lets CI run on their pull
requests. The AI review works without it.

No AI model key is needed. The workflows choose a free OpenCode model on every run.

## 3. Optional: Kiro CLI fallback

If no free OpenCode model works, the AI review falls back to Kiro CLI using GPT 5.6 Luna.
That needs a `KIRO_API_KEY` repository secret, which requires a paid Kiro plan (Pro or
higher). Without the secret, the review is skipped with a warning when no free model is
available. To use a different model, change `KIRO_MODEL` in `opencode-review.yml`; run
`kiro-cli chat --list-models` to see the options.

```sh
gh secret set KIRO_API_KEY
```

## 4. Fill in the project specifics

- `Makefile`: replace the `lint`, `test`, and `build` placeholders with real commands.
  CI runs these targets, so no workflow changes are needed.
- `README.md`: replace the placeholders and remove the template note.
- `AGENTS.md`: describe the project in the Project section.
- `LICENSE`: change it if this project needs something other than MIT.
- `.github/CODEOWNERS`: add other reviewers if needed.
- `.gitignore`: add entries for the project's language.

## How the automation works

| Workflow | Runs when | What it does |
| --- | --- | --- |
| `ci.yml` | Every pull request, and pushes to `main` | `make lint`, `make test`, `make build`, plus workflow linting, secret scanning, spelling, and EditorConfig checks. `make ui-test` runs only on manual dispatch. `ci-success` passes only if none of them fail. |
| `pr-title.yml` | A pull request opens or its title changes | Checks the title is a conventional commit. |
| `opencode-review.yml` | A pull request opens ready for review, or a draft is marked ready | Reviews the change with a free OpenCode model, falling back to Kiro CLI. |
| `opencode.yml` | A maintainer comments `/oc <request>` | Answers the question or makes the change. |
| `agent-task.yml` | A build task gets the `agent-ready` label | Implements the task and opens a draft pull request. Skips the task if any issue under "Blocked by" is still open. |

### Free model selection

Before each run, `.github/actions/pick-free-model` lists the models OpenCode offers for
free right now and picks the best one. If that model fails, the workflow retries once with
the next one. Edit `.github/opencode/models.json` to change the preferred order or exclude
models.

In private repositories, only models whose provider says it does not train on your data
qualify. The picker reads this from the OpenCode docs on every run, so if the docs change
or a model is undocumented, that model is skipped rather than risked.

### Agent workflow for build tasks

1. Write a **Plan** issue, then one **Build task** issue per step. Add each task as a
   sub-issue of the plan.
2. Add `agent-ready` to a task whose blockers are closed.
3. The agent opens a draft pull request titled from the task, with `Closes #<task>`.
4. Check CI and the diff, then mark it **Ready for review**. That starts the AI review.
5. Ask for changes with `/oc <request>` comments, or edit the branch yourself.
