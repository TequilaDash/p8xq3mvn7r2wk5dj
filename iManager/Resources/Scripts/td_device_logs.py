#!/usr/bin/env python3
"""通过设备内置 SSH 服务读取诊断日志（免去手动抓日志）.

用法:
    python Resources/Scripts/td_device_logs.py td-console 2000
    python Resources/Scripts/td_device_logs.py exploit 300
    python Resources/Scripts/td_device_logs.py login 300
    python Resources/Scripts/td_device_logs.py raw "status"

环境变量（都可覆盖默认值）:
    TD_SSH_HOST=192.168.0.4  TD_SSH_PORT=2222  TD_SSH_USER=...  TD_SSH_PASSWORD=...

依赖: paramiko（pip install paramiko）.
"""

import os
import sys

import paramiko


def main() -> int:
    what = sys.argv[1] if len(sys.argv) > 1 else "td-console"
    count = sys.argv[2] if len(sys.argv) > 2 else ""
    if what == "raw":
        cmd = count or "status"
    elif what == "td-console":
        cmd = "cat td-console.log"
    elif what == "exploit":
        cmd = "cat exploit.log"
    elif what == "login":
        cmd = "logs %s" % (count or "300")
    else:
        cmd = "%s %s" % (what, count)
        cmd = cmd.strip()

    host = os.environ.get("TD_SSH_HOST", "192.168.0.4")
    port = int(os.environ.get("TD_SSH_PORT", "2222"))
    user = os.environ.get("TD_SSH_USER", "")
    password = os.environ.get("TD_SSH_PASSWORD", "")
    if not user or not password:
        print("缺少 TD_SSH_USER / TD_SSH_PASSWORD", file=sys.stderr)
        return 2

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(host, port=port, username=user, password=password,
                   timeout=15, allow_agent=False, look_for_keys=False)
    try:
        stdin, stdout, stderr = client.exec_command(cmd, timeout=60)
        sys.stdout.write(stdout.read().decode("utf-8", "replace"))
        err = stderr.read().decode("utf-8", "replace")
        if err:
            sys.stderr.write(err)
        return 0
    finally:
        client.close()


if __name__ == "__main__":
    sys.exit(main())