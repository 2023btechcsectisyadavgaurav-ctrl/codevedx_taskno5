# Deployment Workflow

How a change gets from your editor to production, and how to undo it.

## 1. The pipeline at a glance

```
edit code ─► unit tests ─► terraform fmt/validate/test ─► terraform plan ─► review ─► terraform apply ─► smoke test ─► monitor
   (app/)     (Python)          (infrastructure)             (preview)                   (build + deploy)   (demo.ps1)    (dashboard)
```

Every step is a command; nothing is clicked in the console. That makes the same workflow usable by a person today and by a CI system later.

## 2. Step by step

| # | Step | Command | What it proves |
|---|---|---|---|
| 1 | Run the application unit tests | `python -I -m unittest discover -s tests/python` | Validation, routing, retries, idempotency and dead-lettering behave (43 tests, no cloud needed) |
| 2 | Check formatting | `terraform fmt -check -recursive` | Consistent code |
| 3 | Validate | `terraform validate` | The configuration is syntactically correct |
| 4 | Run infrastructure tests | `terraform test` | Scaling, cost, security and monitoring settings hold (offline, mocked providers) |
| 5 | Preview | `terraform plan` | Exactly what will change; review it |
| 6 | Deploy | `terraform apply` | Zips `app/`, uploads it, builds each function in Cloud Build, rolls out new revisions |
| 7 | Smoke test | `powershell -ExecutionPolicy Bypass -File scripts\demo.ps1` | Health, auth, validation, processing, retries, dead-letter and report work end to end |
| 8 | Watch | Dashboard | Errors flat, latency normal, instances scale |

## 3. What `terraform apply` does for a code change

1. `app/` is zipped; the object name contains the zip's checksum, so **changed code means a new object**.
2. Each function's build config points at the new object, so Terraform updates the three functions.
3. Cloud Build builds a new container for each function from the source and its `requirements.txt`.
4. Cloud Run creates a **new revision** and moves all traffic to it once it is healthy. The old revision is kept.
5. Unchanged code means no change at all (the plan is empty).

## 4. First deployment

| Order | What happens | Typical time |
|---|---|---|
| 1 | Enable Google APIs, then wait 60 s | 1.5 min |
| 2 | Pub/Sub topics, Firestore database, identities, IAM, wait 45 s | 1.5 min |
| 3 | Upload source, build and deploy three functions (in parallel) | 3-5 min |
| 4 | Scheduler, alerts, dashboard, metrics | 1 min |

Expect about **7-10 minutes** in total.

## 5. Configuration per environment

Use one tfvars file per environment and set `environment` (`dev`, `staging`, `prod`). Names, labels, the Firestore database and the topics all carry the environment, so environments never collide.

```bash
terraform workspace new prod            # separate state per environment
terraform apply -var-file=prod.tfvars
```

Recommended differences: `prod` sets `min_instances = 1` if cold starts matter, a larger `max_instances`, real `alert_emails`, and `allow_unauthenticated = false` behind an API gateway.

## 6. Rollback

| Situation | Action |
|---|---|
| Bad **code** change | Revert the change in git, then `terraform apply`. A new revision with the old code is deployed. |
| Need an **instant** rollback | Route traffic back to the previous revision: `gcloud run services update-traffic SERVICE --to-revisions=REVISION=100 --region REGION`. List revisions with `gcloud run revisions list --service SERVICE --region REGION`. Then fix the code and apply normally (Terraform will take traffic back to the latest revision). |
| Bad **infrastructure** change | Revert the Terraform change and apply. |
| Everything is wrong | `terraform destroy`, then `terraform apply` rebuilds the whole stack from code. |

## 7. Automating it (CI/CD)

The same commands run unchanged in any CI system. A minimal pipeline on every pull request: steps 1-5 (tests and plan); on merge to the main branch: steps 6-7. Authenticate CI with **Workload Identity Federation** instead of storing a service account key. This project deliberately keeps the pipeline as documented commands so it works in GitHub Actions, Cloud Build or GitLab without changes.

## 8. Release checklist

- [ ] Unit tests and `terraform test` pass
- [ ] `terraform plan` reviewed; no unexpected deletions
- [ ] `terraform apply` succeeded
- [ ] `scripts/demo.ps1` shows all checks passing
- [ ] Dashboard: no 5xx, latency normal
- [ ] No new alert incidents after 15 minutes
