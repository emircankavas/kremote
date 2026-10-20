#!/bin/sh
# Emits one `key=value` line per metric so the client never parses prose.
# Two CPU samples are taken 0.35s apart; the *client* computes the delta, which
# keeps the arithmetic testable and off the server.

if [ -r /proc/stat ]; then
  echo "os=linux"
  echo "cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)"
  echo "cpu=$(head -1 /proc/stat)"
  sleep 0.35
  echo "cpu2=$(head -1 /proc/stat)"
  awk -F'[: ]+' '/^MemTotal/{print "mem_total="$2}
    /^MemAvailable/{print "mem_avail="$2}
    /^SwapTotal/{print "swap_total="$2}
    /^SwapFree/{print "swap_free="$2}' /proc/meminfo
  echo "load=$(cut -d' ' -f1-3 /proc/loadavg)"
  echo "uptime=$(cut -d'.' -f1 /proc/uptime)"
else
  echo "os=darwin"
  echo "cores=$(sysctl -n hw.ncpu)"
  echo "mem_total=$(sysctl -n hw.memsize)"
  # One sample of vm_stat; the client turns pages into bytes.
  vm_stat | awk -F: '/page size of/{gsub(/[^0-9]/,"",$2); print "page_size="$2}
    /Pages free/{gsub(/[^0-9]/,"",$2); print "pages_free="$2}
    /Pages active/{gsub(/[^0-9]/,"",$2); print "pages_active="$2}
    /Pages inactive/{gsub(/[^0-9]/,"",$2); print "pages_inactive="$2}
    /Pages wired down/{gsub(/[^0-9]/,"",$2); print "pages_wired="$2}
    /Pages occupied by compressor/{gsub(/[^0-9]/,"",$2); print "pages_compressed="$2}'
  # Two samples: the first is since-boot, the second is the live delta.
  top -l 2 -n 0 -s 1 2>/dev/null | awk '/^CPU usage/{line=$0} END{
    n=split(line,a,","); idle=0;
    for(i=1;i<=n;i++) if (a[i] ~ /idle/) { gsub(/[^0-9.]/,"",a[i]); idle=a[i] }
    printf "cpu_idle=%s\n", idle }'
  echo "load=$(sysctl -n vm.loadavg | tr -d '{}')"
  echo "uptime=$(sysctl -n kern.boottime | sed 's/.*sec = \([0-9]*\).*/\1/')"
fi
