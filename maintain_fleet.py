#!/usr/bin/env python3
"""Run maintenance scripts across the self-hosted fleet."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import os
import re
import shlex
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

LOG_ROOT = Path(os.environ.get("MAINTAIN_LOG_ROOT", "/home/dunx/.openclaw/workspace/tmp/maintain-runs"))
LOCK_FILE = Path(os.environ.get("MAINTAIN_LOCK_FILE", "/tmp/maintain-fleet.lock"))
SCRIPT_DIR = "/home/dunx/Desktop/scripts"
APP_SCRIPT = "maintain.sh"
PROXMOX_SCRIPT = "/root/maintain_proxmox.sh"


@dataclass(frozen=True)
class Host:
    name: str
    target: str
    runner: str  # local | ssh | sudo | root | qga
    allowed_modes: set[str]
    script: str = "app"  # app | proxmox
    timeout: int = 900
    known_failed_units: tuple[str, ...] = ()
    note: str = ""


HOSTS: tuple[Host, ...] = (
    Host("s04", "local", "local", {"check", "safe", "docker", "all"}),
    Host("earth", "earth", "sudo", {"check", "safe", "docker", "all"}, timeout=1200, known_failed_units=("cups-browsed.service",), note="Production app host; Docker mode can recreate services."),
    Host("s01", "s01", "sudo", {"check", "safe", "all"}, timeout=900, known_failed_units=("sys-kernel-config.mount",), note="No Docker."),
    Host("desk02", "dunx@desk02", "ssh", {"check", "safe", "docker", "all"}),
    Host("vps01", "vps01", "sudo", {"check", "safe", "docker", "all"}, timeout=900, known_failed_units=("rc-local.service",), note="Public edge/control-plane; fail2ban is intentionally not whitelisted."),
    Host("vps02", "vps02", "sudo", {"check", "safe", "docker", "all"}, timeout=900, note="No active Docker services at last check."),
    Host("vtp-wsl", "vtp-wsl", "sudo", {"check", "safe", "docker", "all"}, timeout=900, known_failed_units=("tpm-udev.path", "tpm-udev.service", "lightdm.service"), note="SSH alias vtp-wsl uses agent for passwordless sudo; script path remains /home/dunx/Desktop/scripts."),
    Host("pm", "pm", "root", {"check", "safe", "all"}, script="proxmox", timeout=1200, note="Proxmox VE root-managed host; script is /root/maintain_proxmox.sh."),
    Host("pm02", "pm02", "root", {"check", "safe", "all"}, script="proxmox", timeout=1200, note="Proxmox VE root-managed host; script is /root/maintain_proxmox.sh."),
    Host("pbs01", "pm02:135", "qga", {"check", "safe", "all"}, script="proxmox", timeout=1200, note="PBS VM; SSH port 22 is unavailable, run through pm02 QEMU Guest Agent VMID 135."),
)

APP_MODE_COMMANDS = {
    "check": ["check"],
    "safe": ["system", "clean", "check"],
    "docker": ["docker", "check"],
    "all": ["all"],
}

PROXMOX_MODE_COMMANDS = {
    "check": ["check"],
    "safe": ["safe"],
    "all": ["all"],
}

MODE_COMMANDS = {mode: None for mode in sorted(set(APP_MODE_COMMANDS) | set(PROXMOX_MODE_COMMANDS))}


@dataclass
class HostResult:
    host: Host
    status: str
    commands: list[str]
    log_path: Path
    duration_s: float
    returncodes: list[int] = field(default_factory=list)
    skipped: bool = False
    reason: str = ""
    disk_root_pct: int | None = None
    upgradable: int | None = None
    failed_units: list[str] = field(default_factory=list)
    new_failed_units: list[str] = field(default_factory=list)
    docker_issues: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)


def commands_for(host: Host, mode: str) -> list[str]:
    if host.script == "app":
        return APP_MODE_COMMANDS[mode]
    if host.script == "proxmox":
        return PROXMOX_MODE_COMMANDS[mode]
    raise ValueError(f"Unknown script type: {host.script}")


def command_for(host: Host, maintain_cmd: str) -> list[str]:
    if host.script == "app":
        inner = f"cd {shlex.quote(SCRIPT_DIR)} && bash ./{APP_SCRIPT} {shlex.quote(maintain_cmd)}"
    elif host.script == "proxmox":
        inner = f"{shlex.quote(PROXMOX_SCRIPT)} {shlex.quote(maintain_cmd)}"
    else:
        raise ValueError(f"Unknown script type: {host.script}")

    if host.runner == "local":
        return ["bash", "-lc", inner]
    if host.runner == "ssh":
        remote = f"bash -lc {shlex.quote(inner)}"
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host.target, remote]
    if host.runner == "sudo":
        remote = f"sudo -n bash -lc {shlex.quote(inner)}"
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host.target, remote]
    if host.runner == "root":
        remote = f"bash -lc {shlex.quote(inner)}"
        return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host.target, remote]
    if host.runner == "qga":
        bridge, vmid = host.target.split(":", 1)
        guest_cmd = f"{inner} 2>&1"
        remote = "qm guest exec " + shlex.quote(vmid) + " --timeout " + shlex.quote(str(host.timeout)) + " -- /bin/sh -lc " + shlex.quote(guest_cmd)
        decoder = (
            "import json,sys; "
            "d=json.load(sys.stdin); "
            "sys.stdout.write(d.get('out-data','')); "
            "sys.stderr.write(d.get('err-data','')); "
            "sys.exit(int(d.get('exitcode',0)))"
        )
        wrapped = f"ssh -o BatchMode=yes -o ConnectTimeout=10 {shlex.quote(bridge)} {shlex.quote(remote)} | python3 -c {shlex.quote(decoder)}"
        return ["bash", "-lc", wrapped]
    raise ValueError(f"Unknown runner: {host.runner}")


def parse_status(text: str, host: Host, result: HostResult) -> None:
    disk_matches = re.findall(r"^\S+\s+\S+\s+\S+\s+\S+\s+(\d+)%\s+/$", text, flags=re.MULTILINE)
    if disk_matches:
        result.disk_root_pct = int(disk_matches[-1])
        if result.disk_root_pct >= 90:
            result.warnings.append(f"root disk đỏ: {result.disk_root_pct}%")
        elif result.disk_root_pct >= 80:
            result.warnings.append(f"root disk cao: {result.disk_root_pct}%")

    upgradable_matches = re.findall(r"Upgradable packages:\s*(\d+)", text)
    if upgradable_matches:
        result.upgradable = int(upgradable_matches[-1])
        if result.upgradable > 0:
            result.warnings.append(f"apt còn {result.upgradable} gói upgradable")

    failed_units = set(re.findall(r"(?:^|[●*]\s+)([A-Za-z0-9_.@:-]+\.(?:service|mount|path|timer|socket))\s+loaded\s+failed\s+failed", text, flags=re.MULTILINE))
    result.failed_units = sorted(failed_units)
    known = set(host.known_failed_units)
    result.new_failed_units = sorted(failed_units - known)
    if result.new_failed_units:
        result.warnings.append("failed unit mới/cần xử lý: " + ", ".join(result.new_failed_units))

    if "Reboot required: yes" in text:
        result.warnings.append("host cần reboot sau update")

    if host.script == "app":
        docker_lines = []
        for line in text.splitlines():
            lower = line.lower()
            if any(token in lower for token in ("unhealthy", "restarting", "exited", "dead")):
                if not line.startswith("==") and "failed systemd" not in lower:
                    docker_lines.append(line.strip())
        result.docker_issues = docker_lines[-10:]
        if result.docker_issues:
            result.warnings.append("Docker có dòng trạng thái bất thường")


def run_host(host: Host, mode: str, run_dir: Path, dry_run: bool = False) -> HostResult:
    start = dt.datetime.now()
    log_path = run_dir / f"{host.name}.log"
    result = HostResult(host=host, status="ok", commands=[], log_path=log_path, duration_s=0)

    if mode not in host.allowed_modes:
        result.status = "skipped"
        result.skipped = True
        result.reason = f"mode {mode} chưa được phép trên host này"
        log_path.write_text(result.reason + "\n", encoding="utf-8")
        result.duration_s = (dt.datetime.now() - start).total_seconds()
        return result

    commands = commands_for(host, mode)
    result.commands = commands

    with log_path.open("w", encoding="utf-8", errors="replace") as log:
        log.write(f"# host={host.name} mode={mode} started={start.isoformat()} runner={host.runner} target={host.target} script={host.script}\n")
        if host.note:
            log.write(f"# note={host.note}\n")
        for maintain_cmd in commands:
            cmd = command_for(host, maintain_cmd)
            log.write("\n$ " + " ".join(shlex.quote(part) for part in cmd) + "\n")
            log.flush()
            if dry_run:
                result.returncodes.append(0)
                continue
            try:
                proc = subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=host.timeout)
                log.write(proc.stdout)
                result.returncodes.append(proc.returncode)
                if proc.returncode != 0:
                    result.status = "failed"
                    result.reason = f"command {maintain_cmd} exited {proc.returncode}"
                    break
            except subprocess.TimeoutExpired as exc:
                if exc.stdout:
                    out = exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode(errors="replace")
                    log.write(out)
                result.returncodes.append(124)
                result.status = "failed"
                result.reason = f"command {maintain_cmd} timeout sau {host.timeout}s"
                break
        log.write(f"\n# finished={dt.datetime.now().isoformat()} status={result.status}\n")

    result.duration_s = (dt.datetime.now() - start).total_seconds()
    text = log_path.read_text(encoding="utf-8", errors="replace")
    parse_status(text, host, result)
    if result.status == "ok" and result.warnings:
        result.status = "warning"
    return result


def render_report(mode: str, run_dir: Path, results: Iterable[HostResult]) -> str:
    rows = list(results)
    now = dt.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    lines = [
        "# Báo cáo bảo trì hệ thống self-hosted",
        "",
        f"- Thời gian: {now}",
        f"- Mode: `{mode}`",
        f"- Log: `{run_dir}`",
        "",
        "## Tóm tắt",
    ]
    for r in rows:
        disk = f"{r.disk_root_pct}%" if r.disk_root_pct is not None else "n/a"
        apt = str(r.upgradable) if r.upgradable is not None else "n/a"
        suffix = ""
        if r.reason:
            suffix = f" - {r.reason}"
        elif r.warnings:
            suffix = " - " + "; ".join(r.warnings[:3])
        lines.append(f"- `{r.host.name}`: {r.status.upper()} | root `{disk}` | apt `{apt}` | log `{r.log_path.name}`{suffix}")

    problem_rows = [r for r in rows if r.status in {"failed", "warning"} or r.skipped]
    lines += ["", "## Cần chú ý"]
    if problem_rows:
        for r in problem_rows:
            details = []
            if r.reason:
                details.append(r.reason)
            if r.warnings:
                details.extend(r.warnings)
            known = [u for u in r.failed_units if u in set(r.host.known_failed_units)]
            if known:
                details.append("known failed units: " + ", ".join(known))
            lines.append(f"- `{r.host.name}`: " + ("; ".join(details) if details else r.status))
    else:
        lines.append("- Không có lỗi hoặc cảnh báo mới.")

    lines += [
        "",
        "## Ghi chú vận hành",
        "- `check`: chỉ kiểm tra và báo cáo.",
        "- `safe`: cập nhật apt/snap nếu có, dọn rác an toàn; Proxmox/PBS dùng `/root/maintain_proxmox.sh` và không đụng Docker/VM state.",
        "- `docker`: chỉ áp dụng cho app/dev host có Docker Compose, có thể recreate container; không áp dụng cho Proxmox/PBS.",
    ]
    return "\n".join(lines) + "\n"


def acquire_lock():
    LOCK_FILE.parent.mkdir(parents=True, exist_ok=True)
    fh = LOCK_FILE.open("w")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        raise SystemExit(f"Another maintain_fleet run is active: {LOCK_FILE}") from exc
    fh.write(str(os.getpid()))
    fh.flush()
    return fh


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Run maintenance scripts across self-hosted hosts.")
    parser.add_argument("--mode", choices=sorted(MODE_COMMANDS), default="check")
    parser.add_argument("--hosts", default="all", help="Comma-separated host names, or all")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--log-root", default=str(LOG_ROOT))
    args = parser.parse_args(argv)

    selected = list(HOSTS)
    if args.hosts != "all":
        wanted = {h.strip() for h in args.hosts.split(",") if h.strip()}
        selected = [h for h in HOSTS if h.name in wanted]
        missing = wanted - {h.name for h in selected}
        if missing:
            raise SystemExit(f"Unknown hosts: {', '.join(sorted(missing))}")

    lock_fh = acquire_lock()
    stamp = dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
    run_dir = Path(args.log_root) / f"{stamp}-{args.mode}"
    run_dir.mkdir(parents=True, exist_ok=True)

    results = [run_host(host, args.mode, run_dir, args.dry_run) for host in selected]
    report = render_report(args.mode, run_dir, results)
    report_path = run_dir / "report.md"
    report_path.write_text(report, encoding="utf-8")
    latest = Path(args.log_root) / "latest-report.md"
    latest.write_text(report, encoding="utf-8")
    print(report, end="")
    lock_fh.close()
    return 1 if any(r.status == "failed" for r in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
