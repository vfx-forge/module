#!/usr/bin/env python3
"""Run the engine test lane on real Roblox servers via Open Cloud.

Every spec under tests/roblox is a shard of its own. For each one this writes
an entry that hands the spec to scripts/cloud_entry.luau, bundles that entry
and everything it requires into one minified file with darklua, and runs the
bundle as a Luau execution session task against the test place. It prints each
task's logs, then one summary over every shard, and exits non-zero unless every
shard completed with no failed case.

Bundling is what keeps this to a single API and a single scope. The create-task
body carries one `script` string with no field for extra modules, so the only
alternatives are a self-contained script or uploading a place for the task to
require out of, and the latter needs place-write on the key as well.

A task per spec is what keeps every script under the api's size limit as specs
are added, since each bundle holds one spec's require graph and never the sum
of them. It also gives every spec a runtime of its own (a spec that leaves the
pool running cannot fail the next), its own time limit and its own logs.

Usage:
  python3 scripts/roblox_cloud_test.py              run every shard
  python3 scripts/roblox_cloud_test.py pool         run the named shards only
  python3 scripts/roblox_cloud_test.py --dry-run    bundle and size, no api

A shard's name is its spec's file name without `.spec.luau`. Every bundle is
kept at .build/cloud/<name>.luau, so a line number in a failure can be looked
up there after a dry run builds the same commit.

Credentials come from ROBLOX_API_KEY, ROBLOX_UNIVERSE_ID and ROBLOX_PLACE_ID,
read from the environment or from a local .env, which is gitignored. A dry run
needs none of them.
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SPECS = ROOT / "tests" / "roblox"
ENTRY = ROOT / "scripts" / "cloud_entry.luau"
CONFIG = ROOT / "scripts" / "bundle.darklua.json"
BUILD = ROOT / ".build" / "cloud"

API = "https://apis.roblox.com/cloud/v2"

# what the create-task api enforces: it answers INVALID_ARGUMENT "Script too
# large: was N bytes, limit is 1048576 bytes". Its reference still says 4 MB,
# which is what this guard said until a bundle passed the real limit.
MAX_SCRIPT_BYTES = 1024 * 1024

# a shard past this share of the limit is reported on every run, so growth is
# seen before a push breaks on it
WARN_SHARE = 0.8

# the api allows ten incomplete tasks per place and answers 429 past that.
# three leaves room for a second run against the same place (a push and its
# pull request), and a 429 still only waits and retries.
MAX_IN_FLIGHT = 3

POLL_SECONDS = 3

# per task, from its creation: the api stops a script at its own five minute
# default, so this only catches a task the api never finishes
POLL_TIMEOUT_SECONDS = 600

# QUEUED and PROCESSING are the two states that mean "keep waiting"; everything
# else is terminal. Treating only PROCESSING as pending would report a freshly
# queued task as a failure.
PENDING_STATES = {"STATE_UNSPECIFIED", "QUEUED", "PROCESSING"}

# seconds to wait before each retry of a 429 or a 5xx
RETRY_WAITS = [2, 4, 8, 16, 32, 60]


class CloudError(Exception):
    pass


def load_dotenv(path):
    if not path.exists():
        return

    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue

        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip())


def require_env(name):
    value = os.environ.get(name)
    if not value:
        sys.exit(f"{name} is not set; see .env.template")
    return value


def discover(names):
    shards = sorted(path.name[: -len(".spec.luau")] for path in SPECS.glob("*.spec.luau"))

    if not names:
        return shards

    unknown = [name for name in names if name not in shards]
    if unknown:
        sys.exit(f"no engine spec named {', '.join(unknown)}; there are {', '.join(shards)}")

    return [name for name in shards if name in names]


def bundle(name):
    BUILD.mkdir(parents=True, exist_ok=True)

    # under the repo, so darklua resolves the aliases from its .luaurc
    entry = BUILD / f"{name}.entry.luau"
    out = BUILD / f"{name}.luau"

    cloud_entry = os.path.relpath(ENTRY.with_suffix(""), entry.parent)
    entry.write_text(
        "-- written by scripts/roblox_cloud_test.py: the engine shard for "
        f"tests/roblox/{name}.spec.luau\n"
        f'return require("{cloud_entry}")(require("@tests/roblox/{name}.spec"))\n',
        encoding="utf8",
    )

    # the config minifies: comments, spaces and type annotations go, and
    # locals get short names. The runtime alone is most of a bundle, and only
    # minified does it stay well under the limit
    result = subprocess.run(
        ["darklua", "process", "--config", str(CONFIG), str(entry), str(out)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        sys.exit(f"darklua failed on {name}:\n{result.stdout}{result.stderr}")

    return out.read_text(encoding="utf8")


def bundle_all(names):
    sources = {}
    over = []

    print(f"{len(names)} engine shards, limit {MAX_SCRIPT_BYTES} bytes")

    for name in names:
        source = bundle(name)
        size = len(source.encode("utf8"))
        share = size / MAX_SCRIPT_BYTES

        if size > MAX_SCRIPT_BYTES:
            note = "  OVER THE LIMIT"
            over.append(name)
        elif share > WARN_SHARE:
            note = f"  past {WARN_SHARE:.0%} of the limit"
        else:
            note = ""

        print(f"  {name:<24} {size:>9} bytes  {share:>4.0%}{note}")
        if note and os.environ.get("GITHUB_ACTIONS"):
            print(f"::warning::engine shard {name} is {size} bytes, {share:.0%} of the script limit")

        sources[name] = source

    if over:
        sys.exit(
            f"{', '.join(over)} over the {MAX_SCRIPT_BYTES} byte script limit; "
            "split the spec or trim what it requires"
        )

    return sources


def request(url, headers, body=None):
    method = "GET" if body is None else "POST"

    for attempt in range(len(RETRY_WAITS) + 1):
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=60) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf8", "replace")
            # 429 is too many incomplete tasks or a rate limit, and 5xx is the
            # service; any other 4xx is a bad request or a bad key, which no
            # retry changes
            retry = error.code == 429 or error.code >= 500
            if not retry or attempt == len(RETRY_WAITS):
                raise CloudError(f"{method} {url} failed with {error.code}:\n{detail}")
            reason = error.code
        except (urllib.error.URLError, TimeoutError) as error:
            if attempt == len(RETRY_WAITS):
                raise CloudError(f"{method} {url} failed: {error}")
            reason = getattr(error, "reason", error)

        print(f"retrying {method} after {reason}", file=sys.stderr)
        time.sleep(RETRY_WAITS[attempt])


def create_task(api_key, universe, place, source):
    url = f"{API}/universes/{universe}/places/{place}/luau-execution-session-tasks"
    headers = {"x-api-key": api_key, "Content-Type": "application/json"}

    return request(url, headers, body=json.dumps({"script": source}).encode("utf8"))


def get_task(api_key, path):
    return request(f"{API}/{path}", {"x-api-key": api_key})


def task_logs(api_key, path):
    messages = []
    token = None

    while True:
        url = f"{API}/{path}/logs"
        if token:
            url += "?" + urllib.parse.urlencode({"pageToken": token})

        logs = request(url, {"x-api-key": api_key})
        for page in logs.get("luauExecutionSessionTaskLogs", []):
            messages.extend(page.get("messages", []))

        token = logs.get("nextPageToken")
        if not token:
            return messages


def outcome(task):
    """passed, failed, failures and an error for a finished task"""

    if task["state"] != "COMPLETE":
        error = task.get("error", {})
        text = f"{task['state']} {error.get('code', '')} {error.get('message', '')}"
        return 0, 0, [], " ".join(text.split())

    results = (task.get("output") or {}).get("results") or []
    summary = results[0] if results and isinstance(results[0], dict) else None
    if summary is None:
        return 0, 0, [], f"completed without a result: {json.dumps(task.get('output'))}"

    # an empty Luau table comes back as either [] or {}
    failures = summary.get("failures")
    failures = failures if isinstance(failures, list) else []

    return int(summary.get("passed", 0)), int(summary.get("failed", 0)), failures, None


def run_all(api_key, universe, place, sources):
    waiting = list(sources)
    running = {}
    results = {}

    def finish(name, passed, failed, failures, error, logs):
        results[name] = (passed, failed, failures, error)

        print(f"\n== {name}")
        for message in logs:
            print(message)
        if error:
            print(f"shard error: {error}")

    while waiting or running:
        while waiting and len(running) < MAX_IN_FLIGHT:
            name = waiting.pop(0)
            try:
                task = create_task(api_key, universe, place, sources[name])
            except CloudError as error:
                finish(name, 0, 0, [], str(error), [])
                continue

            if not task.get("path"):
                finish(name, 0, 0, [], f"the api answered no task: {json.dumps(task)}", [])
                continue

            running[name] = (task["path"], time.monotonic())

        if not running:
            continue

        time.sleep(POLL_SECONDS)

        for name, (path, started) in list(running.items()):
            try:
                task = get_task(api_key, path)
            except CloudError as error:
                del running[name]
                finish(name, 0, 0, [], str(error), [])
                continue

            if task["state"] in PENDING_STATES:
                if time.monotonic() - started > POLL_TIMEOUT_SECONDS:
                    del running[name]
                    finish(name, 0, 0, [], f"still {task['state']} after {POLL_TIMEOUT_SECONDS}s", [])
                continue

            del running[name]

            # the outcome stands without the logs; they only show it
            try:
                logs = task_logs(api_key, path)
            except CloudError as error:
                logs = [f"(no logs: {error})"]

            finish(name, *outcome(task), logs)

    return results


def report(results):
    passed = sum(result[0] for result in results.values())
    failed = sum(result[1] for result in results.values())
    errored = [name for name, result in results.items() if result[3]]

    print("\nengine lane")
    for name in sorted(results):
        shard_passed, shard_failed, _, error = results[name]
        status = f"error: {' '.join(error.split())[:300]}" if error else f"{shard_passed} passed, {shard_failed} failed"
        print(f"  {name:<24} {status}")

    for name in sorted(results):
        for failure in results[name][2]:
            print(f"\n[FAIL] {name} > {failure.get('name')}\n       {failure.get('message')}")

    summary = f"{passed} passed, {failed} failed"
    if errored:
        summary += f", {len(errored)} of {len(results)} shards errored ({', '.join(errored)})"
    print(f"\n{summary}")

    if failed or errored:
        print("engine lane failed")
        return 1

    print("engine lane passed")
    return 0


def main():
    parser = argparse.ArgumentParser(description="Run the engine test lane on Open Cloud.")
    parser.add_argument("shards", nargs="*", help="shard names to run (default: all)")
    parser.add_argument("--dry-run", action="store_true", help="bundle and print sizes without calling the api")
    args = parser.parse_args()

    # a pipe in CI buffers stdout, which would print a retry on stderr out of
    # order with the shard it belongs to
    sys.stdout.reconfigure(line_buffering=True)

    names = discover(args.shards)
    sources = bundle_all(names)

    if args.dry_run:
        return 0

    load_dotenv(ROOT / ".env")

    api_key = require_env("ROBLOX_API_KEY")
    universe = require_env("ROBLOX_UNIVERSE_ID")
    place = require_env("ROBLOX_PLACE_ID")

    print(f"running {len(sources)} shards, {MAX_IN_FLIGHT} at a time")
    return report(run_all(api_key, universe, place, sources))


if __name__ == "__main__":
    sys.exit(main())
