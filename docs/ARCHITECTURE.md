# Architecture

An event-driven order-processing application built only from managed, serverless services. There are no servers, no operating systems and no capacity planning.

## 1. Components

| Component | Service | Role |
|---|---|---|
| **api** | Cloud Run function (HTTP) | Public REST API: validates and stores orders, publishes an event, serves reads |
| **processor** | Cloud Run function (Pub/Sub trigger) | One invocation per order message: applies business rules, updates the order |
| **report** | Cloud Run function (Pub/Sub trigger) | Scheduled: counts orders by status and stores a report |
| **orders topic** | Pub/Sub | Decouples the API from the worker; absorbs bursts |
| **dead-letter topic + subscription** | Pub/Sub | Parks orders that failed every attempt, for 7 days |
| **report-trigger topic + job** | Pub/Sub + Cloud Scheduler | Cron trigger for the report |
| **database** | Firestore (native mode) | Orders and the latest report |
| **source bucket** | Cloud Storage | Private bucket holding the function source zip |
| **monitoring** | Cloud Monitoring and Logging | Dashboard, 7 alert policies, 3 business metrics |

## 2. Event flow

```
                         HTTPS                    1. store order (status=received)
 client  ───────────────────────►  api  ─────────────────────────────────────────►  Firestore
                                    │
                                    │ 2. publish {order_id}
                                    ▼
                               orders topic
                                    │  3. event: one message = one invocation (retried on failure)
                                    ▼
                               processor ──── 4. claim (transaction), rules, total ──►  Firestore (processed)
                                    │
                                    │ 5. after max attempts: mark failed + publish
                                    ▼
                          dead-letter topic ──► pull subscription (kept 7 days)

 Cloud Scheduler ──► report-trigger topic ──► report ──► Firestore (reports/latest)
```

1. The API validates the request, writes the order (`received`) and publishes `{order_id}`. If publishing fails the caller gets HTTP 503 with `Retry-After`, and the order is marked `publish_failed` so nothing is silently lost.
2. Pub/Sub triggers the **processor** once per message.
3. The processor **claims** the order in a Firestore transaction (increments `attempts`, sets `processing`). If it is already `processed` or `failed` the message is a duplicate and is ignored.
4. On success the order becomes `processed` with its total.
5. On a business failure the function raises, so the platform **redelivers** the message. After `max_delivery_attempts` the order is marked `failed`, a copy goes to the **dead-letter topic**, and the message is acknowledged so it can never block the queue.

## 3. Design decisions

| Decision | Why |
|---|---|
| **One source folder, three entry points** | One codebase and one build artifact; each function still scales, fails and is monitored independently. |
| **Queue between API and worker** | A traffic spike fills a queue instead of overloading the worker; the API answers in milliseconds regardless of processing time. |
| **Idempotent worker** | Pub/Sub guarantees *at least once* delivery, so duplicates will happen. The transactional claim makes them harmless. |
| **Application-level dead-lettering** | The platform-managed subscription of an event-driven function cannot carry a dead-letter policy, so the code counts attempts itself. The result is the same, and it is unit-tested. |
| **Business logic separate from cloud SDKs** | Routing, validation and processing are plain Python and are unit-tested without any cloud account (43 tests). Cloud clients are thin adapters imported lazily. |
| **Firestore** | Serverless, scales to zero cost, no capacity to size, free tier included. |
| **Structured JSON logs** | Every line is a JSON object; Cloud Logging turns the `event` field into searchable fields, log-based metrics and alerts. |
| **Two service accounts** | One identity *runs* the code (Firestore, events, logs, publish to two topics) and one *builds* it. Neither has a primitive role. |
| **Named Firestore database with random suffix** | Firestore database IDs cannot be reused right after deletion, so a quick destroy-and-redeploy would otherwise fail. |

## 4. Serverless configuration

| Setting | Default | Meaning |
|---|---|---|
| Runtime | Python 3.12 | Generation 2 Cloud Run functions |
| `min_instances` | **0** | Scale to zero: no idle cost. Trade-off: a cold start (typically one to a few seconds) after a quiet period. |
| `max_instances` | **10** | Hard cap per function: protects against a runaway bill and limits load on Firestore |
| `memory_mb` | **256** | Small and cheap; raise only if the memory chart shows pressure |
| `api_timeout_seconds` | 30 | A single API request must finish in 30 s |
| `worker_timeout_seconds` | 120 | A single order or report run |
| Retry policy | Retry | Failed event invocations are redelivered |
| `max_delivery_attempts` | 5 | Attempts before an order is dead-lettered |
| Ingress | All | API is internet-facing; `/health` is public, the data routes need `X-API-Key` |

## 5. Scaling behaviour

- **Automatic:** Cloud Run adds instances as requests or messages arrive and removes them when idle. Nobody configures a load balancer, auto-scaler or capacity.
- **From zero to `max_instances`:** each function scales independently up to the cap.
- **Back to zero:** after a short idle period all instances are gone and billing stops.
- **Backpressure:** if the worker is slower than arrivals, messages wait in Pub/Sub (visible as *Messages waiting*); the *oldest message age* alert fires if they wait too long.

## 6. Security model

| Control | Implementation |
|---|---|
| Authentication on data routes | `X-API-Key` header (random 32 characters, generated by Terraform, compared in constant time) |
| Optional Google identity | `allow_unauthenticated = false` makes Cloud Run require an identity token on every request |
| Least privilege | Runtime identity: Firestore user, event receiver, log and metric writer, publisher on two topics. Build identity: build, artifact write, log write. |
| Input validation | Type, range and size checks on every field; 64 KB body limit; strict ID format |
| No stack traces to clients | Unhandled errors return a generic 500; details go to the log |
| Private source bucket | Public access prevention enforced; builds read it with a dedicated identity |

For production prefer **Secret Manager** for the API key and **API Gateway / Cloud Endpoints or IAP** in front of the API; the demo keeps the key in an environment variable to stay simple.
