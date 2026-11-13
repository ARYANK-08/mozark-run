# App Studio CI API

The API that `mozark-run` calls. Use it directly from any CI tool or script that the action and image don't cover.

## Flow

```
1. POST /app-uploads                 upload the .apk/.ipa          → build id   (optional)
2. GET  /app-uploads/{id}/status     wait until "ready"                          (optional)
3. POST /ci/v1/suites/{suiteId}/runs start the suite                → run id
4. GET  /ci/v1/runs/{runId}          poll until status = FINISHED  → PASSED / FAILED / ERRORED
5. GET  /ci/v1/runs/{runId}/junit    JUnit XML for your CI's test view
```

Skip steps 1–2 to run the suite with the build it already has in App Studio.

## Authentication

Send these headers on every request:

| Header | Value |
|---|---|
| `Authorization` | `Bearer <CI key>`. An org admin creates the key in App Studio › suite › **Run from CI**. Store it as a CI secret. |
| `x-org-id` | Organization id |
| `x-app-id` | App id |
| `x-project-id` | Project id |

All ids are shown next to the key in **Run from CI**. The base URL is the `api-url` shown there.

The key can only reach the org, apps and projects it was created for. A key is valid for one year and can be revoked in the same dialog.

## Endpoints

### Upload a build

`POST /app-uploads` — `multipart/form-data` with one field, `file` (an `.apk` or `.ipa`, at most 500 MB).

```bash
curl -H "Authorization: Bearer $MOZARK_TOKEN" -H "x-org-id: $ORG" -H "x-app-id: $APP" -H "x-project-id: $PROJECT" \
  -F "file=@app-release.apk" "$API/app-uploads"
```

The response is the upload record. You need two fields:

```json
{ "id": "6b1f…", "status": "processing" }
```

`status` is `processing`, `ready` or `failed`. Android builds are usually `ready` at once; iOS builds are processed first.

### Check a build

`GET /app-uploads/{id}/status` → the upload record, with `status` now `ready`, `processing` or `failed`.

Poll every ~10 seconds until it is not `processing`. Only a `ready` build can be run.

### Start a suite

`POST /ci/v1/suites/{suiteId}/runs` → `202 Accepted`

| Body field | Required | Meaning |
|---|---|---|
| `buildId` | no | Upload to test (from step 1). Omitted: the suite's own build. |
| `commitSha` | no | Shown on the run. Max 64 characters. |
| `branch` | no | Shown on the run. Max 255 characters. |
| `appVersion` | no | Shown on the run, e.g. `v2.4.0`. Max 100 characters. |
| `timeZone` | no | IANA zone used in the run's name, e.g. `Asia/Kolkata`. Default UTC. |

| Header | Required | Meaning |
|---|---|---|
| `Idempotency-Key` | recommended | 1–255 characters, unique per pipeline attempt and suite. Sending the same key again returns the first run instead of starting another, so a retried request never books devices twice. Reusing it for a different suite or build is a `409`. |

```bash
curl -X POST -H "Authorization: Bearer $MOZARK_TOKEN" -H "x-org-id: $ORG" -H "x-app-id: $APP" -H "x-project-id: $PROJECT" \
  -H "Content-Type: application/json" -H "Idempotency-Key: build-1234-$SUITE" \
  -d '{"buildId":"6b1f…","commitSha":"a1b2c3d","branch":"main","appVersion":"v2.4.0"}' \
  "$API/ci/v1/suites/$SUITE/runs"
```

The response is a run (see below). A suite that names several platforms or apps books one job for each.

### Poll a run

`GET /ci/v1/runs/{runId}`

```json
{
  "id": "9c4e…",
  "status": "FINISHED",
  "result": "FAILED",
  "suiteId": "…", "buildId": "6b1f…", "commitSha": "a1b2c3d", "branch": "main", "appVersion": "v2.4.0",
  "createdAt": "2026-11-13T10:40:00.000Z",
  "jobs": [
    {
      "jobId": "…",
      "platform": "android",
      "verdict": "FAIL",
      "running": false,
      "summary": { "total": 20, "passed": 18, "failed": 2 },
      "reportPath": "/reports/…"
    }
  ],
  "refused": []
}
```

| Field | Values |
|---|---|
| `status` | `RUNNING` until every job has finished, then `FINISHED` |
| `result` | `null` while running; then `PASSED`, `FAILED` (a test failed) or `ERRORED` (the run never reached a verdict: not run, aborted, or a job could not be booked) |
| `jobs[].verdict` | `SCHEDULED`, `RUNNING`, `PASS`, `FAIL`, `SKIPPED`, `UNKNOWN` |
| `jobs[].summary` | Counts from the job report, e.g. `total`, `passed`, `failed`; `null` until the job has results |
| `jobs[].reportPath` | Append to the App Studio UI URL for the full report |
| `refused[]` | Jobs that could not be booked: `{ suiteName, error, code }`. `code` is `DevicesSkipped`, `TestCasesSkipped`, `AppSkipped` or `null`. Any refusal makes the run `ERRORED`: a pass must cover the whole suite. |

Poll every 15–30 seconds. `PASSED` needs every test on every device to have run and passed.

### Get JUnit results

`GET /ci/v1/runs/{runId}/junit` → `application/xml`. One `<testsuite>` per job, one `<testcase>` per test × device.

## Errors

| Status | Meaning | What to do |
|---|---|---|
| `400` | Bad id or body | Fix the request; the body's `message` says what is wrong |
| `401` | Missing, expired or revoked key | Create a new key |
| `403` | The key cannot reach this org, app or project, or lacks the permission | Check the ids, or ask an admin |
| `404` | Suite, build or run not found in this project | Check the ids |
| `409` | `Idempotency-Key` reused for a different suite or build | Use a new key |
| `5xx`, network error | Temporary | Retry with backoff |

## Minimal script

```bash
H=(-H "Authorization: Bearer $MOZARK_TOKEN" -H "x-org-id: $ORG" -H "x-app-id: $APP" -H "x-project-id: $PROJECT")
RUN=$(curl -sf "${H[@]}" -X POST -H "Content-Type: application/json" -d '{}' "$API/ci/v1/suites/$SUITE/runs" | jq -r .id)
until [ "$(curl -sf "${H[@]}" "$API/ci/v1/runs/$RUN" | jq -r .status)" = FINISHED ]; do sleep 20; done
curl -sf "${H[@]}" "$API/ci/v1/runs/$RUN/junit" > junit.xml
[ "$(curl -sf "${H[@]}" "$API/ci/v1/runs/$RUN" | jq -r .result)" = PASSED ]
```

`mozark-run` does the same with retries, a timeout and build upload.
