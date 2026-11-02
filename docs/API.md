# API Reference

Base URL: `terraform output -raw api_url`
API key: `terraform output -raw api_key`

All bodies and responses are JSON. Data routes need the header `X-API-Key: <key>`; `/` and `/health` are public.

PowerShell setup for the examples:

```powershell
$url = (terraform output -raw api_url)
$key = (terraform output -raw api_key)
$h   = @{ "X-API-Key" = $key }
```

## Endpoints

| Method | Path | Auth | Purpose | Success |
|---|---|---|---|---|
| GET | `/` | no | Service info and endpoint list | 200 |
| GET | `/health` | no | Liveness check | 200 `{"status":"ok"}` |
| POST | `/orders` | key | Create an order | 201 |
| GET | `/orders` | key | List recent orders (newest first) | 200 |
| GET | `/orders/{id}` | key | Get one order | 200 |
| GET | `/stats` | key | Count of orders per status | 200 |
| GET | `/report` | key | Latest scheduled report | 200 (404 until it has run) |

## POST /orders

Request body:

```json
{
  "customer": "Alice",
  "items": [
    { "sku": "BOOK-1", "qty": 2, "price_cents": 1500 },
    { "sku": "PEN_2",  "qty": 5, "price_cents": 120 }
  ]
}
```

| Field | Rule |
|---|---|
| `customer` | string, 1 to 80 characters |
| `items` | list of 1 to 50 objects |
| `items[].sku` | 1 to 40 characters: letters, digits, `-`, `_` |
| `items[].qty` | integer 1 to 100 |
| `items[].price_cents` | integer 0 to 10,000,000 |
| body size | at most 64 KB |

Response `201`:

```json
{ "order_id": "3f2a9c1e5b7d4a8e9c0b1d2e3f4a5b6c", "status": "received" }
```

The order is processed **asynchronously**: poll `GET /orders/{id}` until `status` is `processed` (or `failed`).

PowerShell:

```powershell
$body = @{ customer = "Alice"; items = @(@{ sku = "BOOK-1"; qty = 2; price_cents = 1500 }) } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Post -Uri "$url/orders" -Headers $h -ContentType "application/json" -Body $body
```

curl:

```bash
curl -X POST "$URL/orders" -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"customer":"Alice","items":[{"sku":"BOOK-1","qty":2,"price_cents":1500}]}'
```

## GET /orders/{id}

```powershell
Invoke-RestMethod -Uri "$url/orders/ORDER_ID" -Headers $h
```

```json
{
  "id": "3f2a9c1e5b7d4a8e9c0b1d2e3f4a5b6c",
  "customer": "Alice",
  "items": [ { "sku": "BOOK-1", "qty": 2, "price_cents": 1500 } ],
  "status": "processed",
  "attempts": 1,
  "total_cents": 3000,
  "created_at": "2026-11-01T10:00:00+00:00"
}
```

### Order status

| Status | Meaning |
|---|---|
| `received` | Stored and queued; waiting for the worker |
| `processing` | The worker has claimed it (also shown between retries) |
| `processed` | Done; `total_cents` is set |
| `failed` | Every attempt failed; moved to the dead-letter topic; `failure_reason` is set |
| `publish_failed` | Stored but could not be queued (the caller received 503); re-submit |

## GET /orders?limit=N

Returns `{"orders": [...]}`, newest first. `limit` is 1 to 100 (default 20); invalid values fall back to the default.

## GET /stats

```json
{ "counts": { "received": 0, "processing": 0, "processed": 12, "failed": 1, "publish_failed": 0 } }
```

## GET /report

The report written by the scheduled function:

```json
{ "generated_at": "2026-11-02T06:00:01+00:00", "counts": { "processed": 12, "failed": 1 }, "total": 13 }
```

## Errors

| Status | `error` | When |
|---|---|---|
| 400 | `invalid_json` | The body is not valid JSON |
| 400 | `validation_failed` | A field is wrong; `details` lists each problem |
| 401 | `unauthorized` | Missing or wrong `X-API-Key` |
| 404 | `not_found` | Unknown path, malformed or unknown order ID |
| 404 | `no_report_yet` | `/report` before the first scheduled run |
| 405 | `method_not_allowed` | Wrong HTTP method; the `Allow` header lists the valid ones |
| 413 | `payload_too_large` | Body over 64 KB |
| 500 | `internal_error` | Unexpected failure (details are in the logs, never in the response) |
| 503 | `queue_unavailable` | The order was stored but not queued; retry after `Retry-After` seconds |

Example `400`:

```json
{ "error": "validation_failed", "details": [ "items[0].qty must be an integer from 1 to 100" ] }
```

## Try the failure path

An order for customer `poison` (or containing a SKU starting with `FAIL-`) always fails processing, so it is retried and then dead-lettered:

```powershell
$poison = @{ customer = "poison"; items = @(@{ sku = "BOOK-1"; qty = 1; price_cents = 1000 }) } | ConvertTo-Json -Depth 5
Invoke-RestMethod -Method Post -Uri "$url/orders" -Headers $h -ContentType "application/json" -Body $poison
```
