# mozark-run

Run a Mozark App Studio test suite on real devices from CI. It uploads your build, starts the suite, waits for the result, writes `junit.xml`, and fails the job when tests fail.

## Setup

1. In App Studio, open the suite › **Run from CI** › **Generate CI key**. Copy the key; it is shown once.
2. Save it in your CI as a secret named `MOZARK_TOKEN`.
3. Copy the ids shown in the same dialog into your pipeline, then add the step for your CI below.

## GitHub Actions

```yaml
- uses: ARYANK-08/mozark-run@v1
  with:
    mozark-token: ${{ secrets.MOZARK_TOKEN }}
    api-url: https://<app-studio-api>
    org-id: <org-id>
    app-id: <app-id>
    project-id: <project-id>
    suite-id: <suite-id>
    build-path: app/build/outputs/apk/release/app-release.apk   # optional
```

Runs on Linux and macOS runners. Full workflow: [examples/github-actions.yml](examples/github-actions.yml).

## Any other CI: the Docker image

`ghcr.io/aryank-08/mozark-run:1` — set the `MOZARK_*` variables and run `mozark-run`.

| CI | Example |
|---|---|
| Jenkins | [examples/Jenkinsfile](examples/Jenkinsfile) |
| Bitbucket Pipelines | [examples/bitbucket-pipelines.yml](examples/bitbucket-pipelines.yml) |
| GitLab CI | [examples/gitlab-ci.yml](examples/gitlab-ci.yml) |

```bash
docker run --rm -v "$PWD:/work" -w /work \
  -e MOZARK_TOKEN -e MOZARK_API_URL -e MOZARK_ORG_ID -e MOZARK_APP_ID \
  -e MOZARK_PROJECT_ID -e MOZARK_SUITE_ID \
  ghcr.io/aryank-08/mozark-run:1
```

## Settings

| Action input | Variable | Required | |
|---|---|---|---|
| `mozark-token` | `MOZARK_TOKEN` | ✅ | CI key |
| `api-url` | `MOZARK_API_URL` | ✅ | App Studio API |
| `org-id` | `MOZARK_ORG_ID` | ✅ | |
| `app-id` | `MOZARK_APP_ID` | ✅ | |
| `project-id` | `MOZARK_PROJECT_ID` | ✅ | |
| `suite-id` | `MOZARK_SUITE_ID` | ✅ | Suite to run |
| `app-url` | `MOZARK_APP_URL` | | App Studio UI, for full report links |
| `build-path` | `MOZARK_BUILD_PATH` | | `.apk`/`.ipa` to upload and test |
| `build-id` | `MOZARK_BUILD_ID` | | A build already in App Studio |
| `app-version` | `MOZARK_APP_VERSION` | | Label shown on the run |
| `timeout-minutes` | `MOZARK_TIMEOUT_MINUTES` | | Default 45 |
| `results-dir` | `MOZARK_RESULTS_DIR` | | Default `results` |

With neither `build-path` nor `build-id`, the suite runs its own build.

## Results

- **Exit code:** `0` passed · `1` tests failed · `2` errored (key, config, devices) · `3` timed out
- **Files:** `results/junit.xml` and `results/run.json`
- Commit and branch are read from GitHub Actions, Bitbucket, Jenkins and GitLab automatically.

## API

To call App Studio directly, see [docs/API.md](docs/API.md).
