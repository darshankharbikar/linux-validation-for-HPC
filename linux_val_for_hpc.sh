#!/usr/bin/env bash

set -Eeuo pipefail

LOG_DIR="/var/log/hpc-validation"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${LOG_DIR}/validation_${TIMESTAMP}.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

mkdir -p "$LOG_DIR"

log() {
  echo -e "$1" | tee -a "$LOG_FILE"
}

section() {
  log ""
  log "${YELLOW}========================================${NC}"
  log "${YELLOW}$1${NC}"
  log "${YELLOW}========================================${NC}"
}

run_cmd() {
  local title="$1"
  shift
  log ""
  log "$title"
  "$@" 2>&1 | tee -a "$LOG_FILE" || true
}

check_root() {
  section "Root Privilege Check"
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    log "${RED}Error: This script must be run as root${NC}"
    exit 1
  fi
  log "${GREEN}Running as root - OK${NC}"
}

validate_os_kernel() {
  section "OS and Kernel Validation"

  log "Operating System:"
  if [ -r /etc/os-release ]; then
    grep -E '^(NAME|VERSION|ID)=' /etc/os-release | tee -a "$LOG_FILE" || true
  else
    log "os-release not available"
  fi

  run_cmd "Kernel Version:" uname -r
  run_cmd "Kernel Parameters (selected):" bash -lc 'sysctl -a 2>/dev/null | grep -E "^(vm|net|kernel)\." | head -20'
  run_cmd "Loaded Kernel Modules:" bash -lc 'lsmod | head -30'
}

validate_hardware() {
  section "Hardware Platform Validation"

  run_cmd "CPU Information:" lscpu
  run_cmd "Memory Information:" free -h
  if command -v numactl >/dev/null 2>&1; then
    run_cmd "NUMA Topology:" numactl --hardware
  else
    log "NUMA not available"
  fi
  run_cmd "PCI Devices:" bash -lc 'lspci | head -30'
  run_cmd "Block Devices:" lsblk
}

validate_network() {
  section "Network Configuration Validation"

  run_cmd "Network Interfaces:" ip addr
  run_cmd "Routing Table:" ip route
  if command -v netstat >/dev/null 2>&1; then
    run_cmd "Network Statistics:" netstat -i
  else
    run_cmd "Network Statistics:" ip -s link
  fi

  if [ -r /etc/resolv.conf ]; then
    run_cmd "DNS Configuration:" cat /etc/resolv.conf
  fi
}

validate_storage() {
  section "Storage Validation"

  run_cmd "Disk Usage:" df -h

  log ""
  log "I/O Scheduler:"
  for dev in /sys/block/*/queue/scheduler; do
    [ -f "$dev" ] || continue
    log "$(basename "$(dirname "$dev")"): $(cat "$dev")"
  done

  run_cmd "Filesystem Check (mounted):" bash -lc 'mount | grep -E "ext4|xfs" || true'
}

validate_security() {
  section "Security Validation"

  if command -v getenforce >/dev/null 2>&1; then
    run_cmd "SELinux Status:" getenforce
  else
    log "SELinux not available"
  fi

  if systemctl is-active --quiet firewalld 2>/dev/null; then
    log "Firewall Status: firewalld active"
  elif systemctl is-active --quiet iptables 2>/dev/null; then
    log "Firewall Status: iptables active"
  else
    log "Firewall Status: No firewall detected"
  fi

  if command -v netstat >/dev/null 2>&1; then
    run_cmd "Open Ports:" netstat -tuln
  else
    run_cmd "Open Ports:" ss -tuln
  fi

  if [ -r /etc/ssh/sshd_config ]; then
    run_cmd "SSH Configuration:" bash -lc 'grep -E "^(PermitRootLogin|PasswordAuthentication)" /etc/ssh/sshd_config || true'
  else
    log "SSH config not accessible"
  fi
}

run_performance_tests() {
  section "Performance Validation"

  if command -v sysbench >/dev/null 2>&1; then
    run_cmd "CPU Performance (sysbench):" sysbench cpu --cpu-max-prime=20000 --events=100000 run
  else
    log "sysbench not installed - skipping"
  fi

  if command -v mbw >/dev/null 2>&1; then
    run_cmd "Memory Bandwidth (mbw):" mbw 100M
  else
    log "mbw not installed - skipping"
  fi

  if command -v fio >/dev/null 2>&1; then
    run_cmd "Disk I/O Performance (fio):" fio --name=seqread --rw=read --bs=1M --size=1G --numjobs=1 --runtime=60 --time_based --group_reporting
  else
    log "fio not installed - skipping"
  fi

  if command -v iperf3 >/dev/null 2>&1; then
    log "Network Performance (iperf3):"
    log "Note: iperf3 requires a server to test against"
    log "Run: iperf3 -c <server_ip> -t 30"
  else
    log "iperf3 not installed - skipping"
  fi
}

validate_hpc_config() {
  section "HPC Configuration Validation"

  if command -v ompi_info >/dev/null 2>&1; then
    run_cmd "OpenMPI Version:" ompi_info --version
  else
    log "OpenMPI not installed"
  fi

  if systemctl is-active --quiet slurmctld 2>/dev/null || systemctl is-active --quiet slurmd 2>/dev/null; then
    log "SLURM Status: active"
  else
    log "SLURM Status: not running"
  fi

  if command -v ibstat >/dev/null 2>&1; then
    run_cmd "InfiniBand/RDMA:" ibstat
  elif command -v ibv_devinfo >/dev/null 2>&1; then
    run_cmd "InfiniBand/RDMA:" ibv_devinfo
  else
    log "InfiniBand not available"
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    run_cmd "GPU Status (NVIDIA):" nvidia-smi
  else
    log "NVIDIA GPU not detected or drivers not installed"
  fi
}

check_system_health() {
  section "System Health Check"

  run_cmd "System Load:" uptime
  run_cmd "Top Processes by CPU:" bash -lc 'ps aux --sort=-%cpu | head -10'
  run_cmd "Top Processes by Memory:" bash -lc 'ps aux --sort=-%mem | head -10'
  run_cmd "Disk Errors (dmesg):" bash -lc 'dmesg | grep -iE "(error|fail|warning)" | tail -20 || true'

  if command -v smartctl >/dev/null 2>&1; then
    log ""
    log "SMART Status (if available):"
    for dev in /dev/sd[a-z]; do
      [ -b "$dev" ] || continue
      smartctl -H "$dev" 2>/dev/null | grep -E "(SMART|PASSED|FAILED)" || true
    done | tee -a "$LOG_FILE"
  else
    log "smartctl not installed - skipping"
  fi
}

finalize() {
  section "Validation Complete"
  log ""
  log "${GREEN}Validation log saved to: $LOG_FILE${NC}"
  log ""
  log "Next Steps:"
  log "1. Review the log file for warnings or errors."
  log "2. Fix any issues found."
  log "3. Re-run validation after fixes."
}

main() {
  log "Linux HPC Validation Script - Started at $(date)"
  check_root
  validate_os_kernel
  validate_hardware
  validate_network
  validate_storage
  validate_security
  run_performance_tests
  validate_hpc_config
  check_system_health
  finalize
  log ""
  log "Linux HPC Validation Script - Completed at $(date)"
}

main "$@"
