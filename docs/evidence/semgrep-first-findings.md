# Semgrep's first run found two real issues

Short version: the first time Semgrep ran in GitHub Actions it failed the pipeline on two findings in code I had carried over from Project 1, code that had already passed SonarQube. Neither was planted for a demo.

I added a `sast` job that runs Semgrep with the curated `p/default` rules plus `p/github-actions`, and `--error`, so any finding fails the job. The image build waits for it (`needs: [test, secrets, sast]`), so a red Semgrep means no image gets built.

What it found:

- `app/Dockerfile` had no `USER` line. The image already ran as UID 65532 because the distroless `:nonroot` base sets it, but Semgrep only reads the Dockerfile and cannot know that. Making it explicit is the better fix than silencing the rule: anyone reading the file sees it, and it no longer depends on the base image.
- `app/.npmrc` did not set `min-release-age`. That npm option refuses package versions published less than N days ago, which protects against the pattern where a maintainer account gets hijacked, a malicious version goes out, and it is pulled again within hours.

The run (GitHub Actions, run 37669776460, commit `e3c2b70`):

```text
X dev ci · 37669776460
JOBS
X sast in 27s
  X semgrep
✓ test in 59s
✓ secrets in 7s
- image in 0s
```

Semgrep's output from the failed step:

```text
  Scanning 34 files tracked by git with 1075 Code rules:
┌─────────────────┐
│ 2 Code Findings │
└─────────────────┘
    app/.npmrc
    ❯❱ package_managers.npm.npm-missing-minimum-release-age.npm-missing-minimum-release-age
          ❰❰ Blocking ❱❱
          This .npmrc does not set a minimum release age or sets it too low. Newly published packages can be
          malicious or unstable. Add `min-release-age = 7` to wait 7 days before resolving newly published
          package versions.
            1┆ engine-strict=true
    app/Dockerfile
   ❯❯❱ dockerfile.security.missing-user.missing-user
          ❰❰ Blocking ❱❱
          By not specifying a USER, a program in the container may run as 'root'. This is a security hazard.
           24┆ CMD ["dist/main.js"]
 • Findings: 2 (2 blocking)
 • Rules run: 255
 • Targets scanned: 34
Ran 255 rules on 34 files: 2 findings.
##[error]Process completed with exit code 1.
```

## The fix

Two small commits, one per finding: `fa10b7d fix: declare nonroot user in dockerfile` adds `USER 65532:65532` before `CMD` (numeric on purpose, so Kubernetes can check `runAsNonRoot` before starting the container), and `7f1865d build: set npm minimum release age` adds `min-release-age=7` to `app/.npmrc`. `npm ci` installs exactly what the lockfile says, so the setting only matters when someone picks a new version. Tests, the image build and `/health` were unchanged.

The next run (run 37670484019, commit `7f1865d`) was green, and the image job ran again:

```text
✓ dev ci · 37670484019
JOBS
✓ sast in 27s
✓ test in 56s
✓ secrets in 7s
✓ image in 34s

  Scanning 34 files tracked by git with 1075 Code rules:
 • Findings: 0 (0 blocking)
Ran 255 rules on 34 files: 0 findings.
```
