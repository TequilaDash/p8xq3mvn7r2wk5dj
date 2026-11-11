#!/usr/bin/env python3
"""CI 终态轮询器 —— R-CI-1 的执行工具.

规则（04_规则与雷区.md R-CI-1）:
    dispatch 之后必须轮询到终态（success / failure / cancelled）才能收尾。
    禁止在 CI 未终态时输出「已完成 / 绿了打 tag / 请你验证」。

用法:
    # 轮询最近一次 dispatch 的 run（自动取 head_sha 匹配）
    python Resources/Scripts/ci_wait.py --repo 1336329101 --branch migrate-xcode

    # 轮询指定 run
    python Resources/Scripts/ci_wait.py --repo 1336329101 --run 42966013181

    # 只查一次状态，不轮询
    python Resources/Scripts/ci_wait.py --repo 1336329101 --run <id> --once

退出码:
    0 = 全部 job success
    1 = 有 job failure/cancelled
    2 = 参数或环境问题
    3 = 超时仍未终态（此时**不许**收尾）
"""

import argparse
import json
import os
import subprocess
import sys
import time

TOKEN_FILE_CANDIDATES = [
    "C:/Users/xcrad/WorkBuddy/tequiladash/Github Token.txt",
]


def token():
    env = os.environ.get("GITHUB_TOKEN")
    if env:
        return env.strip()
    import re
    for path in TOKEN_FILE_CANDIDATES:
        if not os.path.exists(path):
            continue
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            m = re.search(r"gh[pousr]_[A-Za-z0-9]{20,}", fh.read())
            if m:
                return m.group(0)
    return None


def api(path):
    tok = token()
    if not tok:
        print("[ci-wait] 找不到 GitHub token", file=sys.stderr)
        sys.exit(2)
    out = subprocess.run(
        ["curl", "-s", "--ssl-no-revoke",
         "-H", "Accept: application/vnd.github+json",
         "-H", "Authorization: Bearer %s" % tok,
         "https://api.github.com%s" % path],
        capture_output=True, text=True, encoding="utf-8", errors="replace")
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        print("[ci-wait] API 返回非 JSON: %s" % out.stdout[:200], file=sys.stderr)
        sys.exit(2)


def latest_run(repo, branch):
    data = api("/repositories/%s/actions/runs?per_page=5" % repo)
    for run in data.get("workflow_runs", []):
        if branch and run.get("head_branch") != branch:
            continue
        return run
    return None


def job_states(repo, run_id):
    data = api("/repositories/%s/actions/runs/%s/jobs" % (repo, run_id))
    return [(j["name"], j["status"], j["conclusion"]) for j in data.get("jobs", [])]


def print_states(states):
    for name, status, conclusion in states:
        mark = {"success": "OK", "failure": "FAIL", "cancelled": "CANCEL",
                None: status}.get(conclusion, conclusion)
        print("  %-16s %-12s %s" % (name, status, mark))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="repository id（数字，不是 owner/name）")
    ap.add_argument("--run", type=int, help="run id；不给则取 branch 最新一次")
    ap.add_argument("--branch", default="migrate-xcode")
    ap.add_argument("--interval", type=int, default=45, help="轮询间隔秒")
    ap.add_argument("--timeout", type=int, default=1800, help="最长等待秒")
    ap.add_argument("--once", action="store_true", help="只查一次")
    args = ap.parse_args()

    run_id = args.run
    if not run_id:
        run = latest_run(args.repo, args.branch)
        if not run:
            print("[ci-wait] 找不到 %s 的 run" % args.branch, file=sys.stderr)
            return 2
        run_id = run["id"]
        print("[ci-wait] 使用最新 run %s (%s)" % (run_id, run["head_sha"][:7]))

    deadline = time.time() + args.timeout
    while True:
        states = job_states(args.repo, run_id)
        print_states(states)
        if not states:
            print("[ci-wait] 还没有 job（排队中）")
        else:
            running = [s for s in states if s[1] != "completed"]
            if not running:
                bad = [s for s in states if s[2] not in ("success", "skipped")]
                if bad:
                    print("[ci-wait] 终态: FAILURE（%d 个 job 失败）" % len(bad))
                    return 1
                print("[ci-wait] 终态: SUCCESS")
                return 0
        if args.once:
            print("[ci-wait] --once: 未到终态就返回（退出码 3，不许收尾）")
            return 3
        if time.time() > deadline:
            print("[ci-wait] 超时 %ds 仍未终态（退出码 3，不许收尾）" % args.timeout)
            return 3
        time.sleep(args.interval)


if __name__ == "__main__":
    sys.exit(main())
