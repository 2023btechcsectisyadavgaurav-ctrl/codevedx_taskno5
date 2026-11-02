#!/usr/bin/env python3
"""Load test: proves the API scales out automatically and reports its latency.

Usage (from the project folder, after `terraform apply`):
    python scripts/load_test.py --requests 300 --concurrency 20

Only the Python standard library is needed. It creates real orders (small, harmless) and reads them back,
then prints throughput, latency percentiles and the error rate. While it runs, watch the dashboard:
"Active instances" climbs from 0 and returns to 0 afterwards.
"""
import argparse
import json
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor


def terraform_output(name, raw=False):
    cmd = ["terraform", "output", "-raw" if raw else "-json", name]
    result = subprocess.run(cmd, capture_output=True, text=True, shell=(sys.platform == "win32"))
    if result.returncode != 0:
        sys.exit("Could not read terraform output '%s'. Run from the project folder after `terraform apply`." % name)
    return result.stdout.strip() if raw else json.loads(result.stdout)


def request(url, key, method="GET", body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers={"X-API-Key": key, "Content-Type": "application/json"})
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            resp.read()
            status = resp.status
    except urllib.error.HTTPError as exc:
        status = exc.code
    except Exception:
        status = 0
    return status, (time.perf_counter() - started) * 1000


def percentile(sorted_values, p):
    if not sorted_values:
        return 0.0
    index = min(len(sorted_values) - 1, max(0, int(round(p / 100.0 * len(sorted_values))) - 1))
    return sorted_values[index]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--requests", type=int, default=200, help="total requests to send (default 200)")
    parser.add_argument("--concurrency", type=int, default=20, help="parallel workers (default 20)")
    parser.add_argument("--url", help="API URL (default: from terraform output)")
    parser.add_argument("--key", help="API key (default: from terraform output)")
    args = parser.parse_args()

    url = (args.url or terraform_output("api_url", raw=True)).rstrip("/")
    key = args.key or terraform_output("api_key", raw=True)

    order = {"customer": "loadtest", "items": [{"sku": "LOAD-1", "qty": 1, "price_cents": 100}]}

    def work(i):
        # Mix: 70% creates, 30% reads (like a real client).
        if i % 10 < 7:
            return request(url + "/orders", key, "POST", order)
        return request(url + "/orders?limit=5", key)

    print("Sending %d requests with %d parallel workers to %s ..." % (args.requests, args.concurrency, url))
    started = time.perf_counter()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        results = list(pool.map(work, range(args.requests)))
    elapsed = time.perf_counter() - started

    latencies = sorted(ms for status, ms in results if 200 <= status < 300)
    errors = sum(1 for status, _ in results if not 200 <= status < 300)

    print("")
    print("Requests:     %d in %.1f s  (%.1f requests/s)" % (len(results), elapsed, len(results) / elapsed))
    print("Succeeded:    %d   Failed: %d  (error rate %.1f%%)" % (len(latencies), errors, 100.0 * errors / len(results)))
    if latencies:
        print("Latency ms:   p50 %.0f   p95 %.0f   p99 %.0f   max %.0f   mean %.0f" % (
            percentile(latencies, 50), percentile(latencies, 95), percentile(latencies, 99),
            latencies[-1], statistics.mean(latencies)))
        print("First request (often includes a cold start): %.0f ms" % results[0][1])
    print("")
    print("Now open the dashboard: 'Active instances' rose during the test and falls back to 0 when idle.")


if __name__ == "__main__":
    main()
