# Operations Guide

Monitoring, alerts, runbooks, cost control and troubleshooting.

## 1. Monitoring

`terraform output dashboard_url` opens the dashboard: a guide panel and twelve charts.

| Chart | Healthy | Tells you |
|---|---|---|
| API requests per minute | Follows real traffic | Demand |
| API server errors (5xx) | Flat at zero | Failures |
| API latency p50 / p95 | p95 under the alert threshold (1500 ms) | Speed, including cold starts |
| Active instances | **Returns to 0 when idle** | Scale-to-zero works; scale-out under load |
| Billable instance time | Small, tracks traffic | The cost driver |
| Memory / CPU utilization p95 | Well below 1.0 | Under-sizing (near 1.0) or over-sizing (near 0) |
| Orders received / processed | Track each other | Pipeline health |
| Orders dead-lettered | Zero | Failed orders |
| Messages waiting | Near zero | Backlog |

Logs: Logging > Logs Explorer.

```text
resource.type="cloud_run_revision" severity>=ERROR                 # all errors
jsonPayload.event="order_processed"                                # successful orders
jsonPayload.event="dead_lettered"                                  # failed orders
jsonPayload.event="request" jsonPayload.latency_ms>1000            # slow requests
```

## 2. Alerts

| Tier | Alert | Fires when | Defaults |
|---|---|---|---|
| ERROR | API returning server errors | More than N HTTP 5xx in 5 minutes | N = 5 |
| WARNING | API p95 latency | p95 above the threshold for 5 minutes | 1500 ms |
| ERROR | Orders waiting unprocessed | Oldest unprocessed message older than the threshold for 5 minutes | 600 s |
| WARNING | Function memory above 85% | p99 memory utilization high for 10 minutes | 85% |
| CRITICAL | Order dead-lettered | An order failed every attempt | any |
| ERROR | Order stored but not queued | Pub/Sub refused a message | any |
| WARNING | Unexpected error in a function | An error log that is not a known failure | any |

Each alert contains its own runbook in the notification. Recipients come from `alert_emails`.

## 3. Runbooks

### An order was dead-lettered (CRITICAL)

1. Open the alert's log entry: `order_id` and `reason`.
2. Read the parked message:
   ```bash
   gcloud pubsub subscriptions pull DEAD_LETTER_SUBSCRIPTION --limit=5
   ```
   (Add `--auto-ack` to remove it afterwards.)
3. Fix the cause (bad data or a code bug). If it was a bug, deploy the fix first.
4. Re-submit the order through `POST /orders`.

### Orders are piling up (backlog alert)

1. Look at *Messages waiting* and *Active instances*. If instances sit at `max_instances`, raise it.
2. Look for processor errors in the logs.
3. If the processor is failing, fix and redeploy; waiting messages are processed automatically afterwards.

### API errors or slow responses

1. Dashboard: did it start with a deployment? Compare to the revision list; roll back if so ([DEPLOYMENT_WORKFLOW.md](DEPLOYMENT_WORKFLOW.md)).
2. High latency only on the first request after a quiet period is a **cold start**. Accept it, or set `min_instances = 1`.
3. High memory: raise `memory_mb`.

### Publishing failures (503)

The order exists with status `publish_failed`. Check Pub/Sub status and the runtime identity's publisher role, then re-submit.

## 4. Cost

Serverless means you pay **only while code runs**, per request and per second of CPU and memory, plus the managed services. With the defaults (scale to zero, 256 MB, capped at 10 instances) an idle application costs effectively nothing.

| Item | Billing model | Notes |
|---|---|---|
| Cloud Run functions | Requests + vCPU/memory seconds while running | A generous monthly free tier applies; idle = $0 |
| Pub/Sub | Per GB of messages | Tiny messages; a free monthly allowance |
| Firestore | Per document read/write/delete and storage | A daily free quota applies |
| Cloud Scheduler | Per job | A few jobs are free per account |
| Cloud Build | Build minutes per deploy | A daily free allowance |
| Artifact Registry | Storage of built images | Small |
| Cloud Storage | Source zip, deleted after 30 days | Negligible |
| Logging and Monitoring | Ingested log volume | Small at this scale |

> Free-tier amounts change; check the current pricing pages before relying on them.

### Cost levers

| Lever | Effect |
|---|---|
| `min_instances = 0` (default) | No idle cost; accept cold starts |
| `min_instances = 1` | No cold starts, but you pay for one warm instance per function all month |
| `max_instances` | Caps the worst-case bill and protects Firestore from a stampede |
| `memory_mb` | Lower is cheaper; raise only if the memory chart shows pressure |
| Timeouts | Short timeouts stop a stuck request from billing for minutes |
| Log volume | Log events, not payloads |

A short demo costs **cents or nothing**. The one thing that can cost real money is an unprotected, unbounded public endpoint, which is why the API key and `max_instances` exist.

## 5. Performance (efficiency)

- **Warm path:** clients (Firestore, Pub/Sub) are created once per instance and reused, so warm requests do no setup work.
- **Cold path:** cloud libraries are imported lazily; only the function that needs them pays for them.
- **Small footprint:** 256 MB, three dependencies, a single Firestore read or write per request.
- **Measure it:** `python scripts/load_test.py --requests 300 --concurrency 20` prints throughput and p50/p95/p99 latency, and shows the instance count rising during the test and returning to zero afterwards.

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| First request is slow | Cold start (scaled to zero). Normal; see cost levers. |
| 401 from the API | Missing or wrong `X-API-Key`. `terraform output -raw api_key`. |
| 403 from Cloud Run (HTML page) | `allow_unauthenticated = false`, or the invoker binding has not propagated; wait a minute. |
| Orders stay `received` | The processor is not running: check its logs, the Pub/Sub trigger and the invoker binding. |
| Orders loop between `processing` and retries | A business-rule failure: expected for `poison`; otherwise read the `processing_retry` logs. |
| Build fails | Open the build in Cloud Build > History; usually a dependency or permission issue. |
| Scheduler job runs but no report | Check the report function's logs; `GET /report` is 404 until it has run once. |
