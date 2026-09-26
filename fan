#!/bin/sh
# fan: show actual fan speed and likely sources of sustained CPU heat.

set -eu

version=0.3.0
samples=5
interval=1
count=5
watch=0
deep=0

# ANSI styling is deliberately confined to labels, never copyable commands.
bold=
italic=
cyan=
green=
yellow=
dim=
reset=
if [ -t 1 ] && [ -z "${NO_COLOR+x}" ] && [ "${TERM:-dumb}" != dumb ]; then
  esc=$(printf '\033')
  bold="${esc}[1m"
  italic="${esc}[3m"
  cyan="${esc}[36m"
  green="${esc}[32m"
  yellow="${esc}[33m"
  dim="${esc}[2m"
  reset="${esc}[0m"
fi

heading() {
  printf '%s%s%s\n' "$bold$cyan" "$1" "$reset"
}

label() {
  printf '%s%s%s\n' "$bold" "$1" "$reset"
}

usage() {
  cat <<'EOF'
Usage: fan [-w] [-d] [-s samples] [-i seconds] [-n results]

Read fan RPM, then sample CPU use and group helper processes by app.

  -s samples   number of samples (default: 5)
  -i seconds   pause between samples (default: 1)
  -n results   number of suspects to show (default: 5)
  -w           watch until the fans stop (Ctrl-C to stop)
  -d           show deeper thermal and GPU diagnostic commands
  -v           show version
  -h           show this help

Colors appear on terminals only; set NO_COLOR=1 to disable them.

Examples:
  fan
  fan -s 10 -i 0.5
  fan -w
  fan -d
EOF
}

die() {
  printf 'fan: %s\n' "$*" >&2
  exit 2
}

while getopts 's:i:n:wdhv' option; do
  case "$option" in
    s) samples=$OPTARG ;;
    i) interval=$OPTARG ;;
    n) count=$OPTARG ;;
    w) watch=1 ;;
    d) deep=1 ;;
    h) usage; exit 0 ;;
    v) printf 'fan %s\n' "$version"; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
[ "$#" -eq 0 ] || die "unexpected argument: $1"

case "$samples" in *[!0-9]*|'') die "samples must be a positive integer" ;; esac
case "$count" in *[!0-9]*|'') die "results must be a positive integer" ;; esac
[ "$samples" -gt 0 ] || die "samples must be greater than zero"
[ "$count" -gt 0 ] || die "results must be greater than zero"
awk -v n="$interval" 'BEGIN {
  valid = (n ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/)
  exit !(valid && n > 0)
}' || die "seconds must be a positive number"

[ "$(uname -s)" = Darwin ] || die "this version supports macOS only"
for command_name in ps awk sort mktemp sleep id head dirname; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
sensor_bin=$script_dir/fan-rpm
fan_status=unavailable
fan_data=

read_fans() {
  fan_status=unavailable
  fan_data=
  [ -x "$sensor_bin" ] || return
  if fan_data=$("$sensor_bin" 2>/dev/null) && [ -n "$fan_data" ]; then
    fan_status=$(printf '%s\n' "$fan_data" | awk -F '\t' '
      NF != 2 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { bad = 1 }
      $2 + 0 > 0 { running = 1 }
      END { if (bad) print "unavailable"; else if (running) print "running"; else print "stopped" }
    ')
  fi
}

snapshot=$(mktemp "${TMPDIR:-/tmp}/fan.XXXXXX") || die "could not create a temporary file"
ranked=$(mktemp "${TMPDIR:-/tmp}/fan.XXXXXX") || {
  rm -f "$snapshot"
  die "could not create a temporary file"
}
trap 'rm -f "$snapshot" "$ranked"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

sample() {
  : >"$snapshot"
  printf 'Sampling CPU (%s check' "$samples"
  [ "$samples" -eq 1 ] || printf 's'
  printf '): '
  remaining=$samples
  while [ "$remaining" -gt 0 ]; do
    ps -axo pid=,ppid=,pcpu=,comm= >>"$snapshot" || die "could not read the process list"
    printf '\n' >>"$snapshot"
    remaining=$((remaining - 1))
    if [ "$remaining" -gt 0 ]; then
      printf '%s ' "$remaining"
      sleep "$interval"
    fi
  done
  printf '%sdone%s\n\n' "$dim" "$reset"
}

rank() {
awk -v samples="$samples" '
  NF >= 4 {
    pid = $1
    parents[pid] = $2
    cpu[pid] += $3
    $1 = $2 = $3 = ""
    sub(/^[[:space:]]+/, "")
    commands[pid] = $0
  }

  function base(path, parts, n) {
    n = split(path, parts, "/")
    return parts[n]
  }

  function app_in_path(path, parts, n, j, candidate) {
    n = split(path, parts, "/")
    for (j = 1; j <= n; j++) {
      if (parts[j] ~ /\.app$/) {
        candidate = parts[j]
        sub(/\.app$/, "", candidate)
        return candidate
      }
    }
    return ""
  }

  function known_app(executable) {
    if (executable ~ /^Google Chrome Helper/) return "Google Chrome"
    if (executable ~ /^Code Helper/) return "Visual Studio Code"
    if (executable ~ /^com\.apple\.WebKit/) return "Safari / WebKit"
    if (executable ~ /^(mds|mds_stores|mdworker|mdworker_shared|spotlightknowledged\.updater)$/) return "Spotlight"
    if (executable ~ /^(photoanalysisd|photolibraryd)$/) return "Photos analysis"
    if (executable == "mediaanalysisd") return "Media analysis"
    if (executable ~ /^com\.opalcamera\./) return "Opal"
    if (executable ~ /^(bird|cloudd)$/) return "iCloud"
    if (executable ~ /^(backupd|backupd-helper)$/) return "Time Machine"
    if (executable ~ /^(com\.docker\.backend|vpnkit)$/) return "Docker"
    if (executable == "WindowServer") return "WindowServer"
    if (executable == "kernel_task") return "macOS kernel"
    return ""
  }

  function app_for(pid, depth, path_app, executable, known, parent_app) {
    if (depth > 8 || !(pid in commands)) return ""
    path_app = app_in_path(commands[pid])
    if (path_app != "") return path_app
    executable = base(commands[pid])
    known = known_app(executable)
    if (known != "") return known
    if (executable ~ /(Helper|helper|Renderer|GPU|Utility|Web Content|Plugin)/) {
      parent_app = app_for(parents[pid], depth + 1)
      if (parent_app != "") return parent_app
    }
    return executable
  }

  END {
    for (pid in cpu) {
      app = app_for(pid, 0)
      if (app == "" || app == "ps" || app == "fan" || app == "fan-rpm") continue
      average = cpu[pid] / samples
      totals[app] += average
      executable = base(commands[pid])
      if (average > hottest_cpu[app]) {
        hottest_cpu[app] = average
        hottest_name[app] = executable
        hottest_pid[app] = pid
        hottest_path[app] = commands[pid]
      }
      if (commands[pid] ~ /^\/Applications\// || commands[pid] ~ /^\/Users\/.*\/Applications\// || commands[pid] ~ /^\/System\/Applications\//)
        if (app_in_path(commands[pid]) != "") quit_app[app] = 1
    }
    for (app in totals) {
      killable = (hottest_path[app] ~ /^\/Users\// || hottest_path[app] ~ /^\/opt\/homebrew\// || hottest_path[app] ~ /^\/usr\/local\/bin\//)
      if (totals[app] >= 0.1)
        printf "%.1f\t%s\t%.1f\t%s\t%s\t%d\t%d\n", totals[app], app, hottest_cpu[app], hottest_name[app], hottest_pid[app], quit_app[app], killable
    }
  }
' "$snapshot" | LC_ALL=C sort -k1,1nr >"$ranked"
}

report() {

if [ "$fan_status" = unavailable ]; then
  printf '%sFan RPM: unavailable.%s Keep fan-rpm beside this script to enable the sensor.\n\n' "$yellow" "$reset"
else
  printf '%s\n' "$fan_data" | awk -F '\t' -v color="$bold$cyan" -v reset="$reset" '{ printf "%sFan %d: %d RPM%s\n", color, $1 + 1, $2, reset }'
  if [ "$fan_status" = stopped ]; then
    printf '%sFans are stopped.%s\n\n' "$green" "$reset"
  else
    printf '%sFans are spinning.%s\n\n' "$yellow" "$reset"
  fi
fi

if [ ! -s "$ranked" ]; then
  printf 'No measurable CPU activity found.\n'
  if [ "$fan_status" = running ]; then
    printf 'Check airflow: move the Mac off blankets or bedding onto a hard, flat surface; keep vents clear.\n'
    printf 'Wait a few minutes and run fan -w. This tool cannot detect a blocked vent directly.\n'
  fi
  top_cpu=0
  return
fi

heading 'Recent CPU activity'
printf '%s(100%% = one fully used core)%s\n' "$dim" "$reset"
head -n "$count" "$ranked" | awk -F '\t' '{
  printf "%d. %-27s %7.1f%%\n", NR, $2, $1
  if ($4 != "" && $4 != $2) printf "   hottest process: %s (%.1f%%)\n", $4, $3
}'

top_cpu=$(awk -F '\t' 'NR == 1 { print int($1 + 0.5) }' "$ranked")
top_app=$(awk -F '\t' 'NR == 1 { print $2 }' "$ranked")

printf '\n'
if [ "$fan_status" = stopped ]; then
  printf '%sThe fans are off.%s These CPU readings are not evidence of a fan culprit.\n' "$green" "$reset"
  return
elif [ "$top_cpu" -ge 25 ]; then
  printf '%sTop recent CPU activity:%s %s (%s%%). %sThis is a clue, not proof of the fan cause.%s\n' "$bold" "$reset" "$top_app" "$top_cpu" "$italic" "$reset"
else
  printf 'No clear CPU culprit right now; the top app is %s at %s%%.\n' "$top_app" "$top_cpu"
  printf 'The fan may be reacting to earlier load, GPU work, charging, or blocked airflow.\n'
fi

printf '\n%sFirst check airflow:%s move the Mac off blankets or bedding onto a hard, flat surface; keep vents clear.\n' "$bold$yellow" "$reset"
printf 'Wait a few minutes and run fan -w. This tool cannot detect a blocked vent directly.\n'

system_notes=0
shown=0
while IFS="$(printf '\t')" read -r row_cpu row_app row_hottest row_process row_pid row_quit row_kill; do
  shown=$((shown + 1))
  [ "$shown" -le "$count" ] || break
  case "$row_app" in
    WindowServer)
      note='WindowServer draws windows. Close busy tabs/windows, stop screen sharing, or test without an external display; do not kill it.' ;;
    com.crowdstrike.falcon.Agent|Falcon|FalconSensor)
      note='CrowdStrike Falcon is managed security software. Do not kill it; if CPU stays high, ask your IT team to investigate.' ;;
    coreaudiod)
      note='coreaudiod handles audio. Close calls, recording, or playback apps and check virtual audio devices; do not kill it.' ;;
    ControlCenter)
      note='ControlCenter is macOS UI. Dismiss open controls and check screen sharing or media apps; do not kill it.' ;;
    Spotlight)
      note='Spotlight may be indexing. Let it finish and watch whether CPU and RPM settle; do not kill its workers.' ;;
    syspolicyd)
      note='syspolicyd performs macOS security checks. A brief spike can follow app launches or updates; do not kill it.' ;;
    'Media analysis'|'Photos analysis')
      note='macOS is analyzing photos or media in the background. Wait and recheck; do not kill its workers.' ;;
    fileproviderd)
      note='fileproviderd handles cloud files. Check OneDrive or another sync app for active transfers; do not kill it.' ;;
    com.apple.Virtualization.VirtualMachine)
      note='A virtual machine is running. Check Docker or another VM app and stop the VM there; do not kill this service.' ;;
    corespeechd)
      note='corespeechd is a macOS speech service. Check voice or dictation activity; do not kill it.' ;;
    com.cisco.anyconnect.macos.acsockext|acumbrellaagent|vpnagentd)
      note='This is managed Cisco VPN/security software. Do not kill it; ask IT if sustained usage is high.' ;;
    'macOS kernel')
      note='kernel_task is macOS. High usage can accompany thermal management; check airflow and charging before blaming an app.' ;;
    *) continue ;;
  esac
  if [ "$system_notes" -eq 0 ]; then
    printf '\n'
    heading 'About the system processes'
    system_notes=1
  fi
  printf '%s\n' "$note"
done <"$ranked"

printf '\nTo test a cause, save your work and close one busy app at a time.\n'
printf 'Watch whether fan RPM falls afterward; cooling can take a few minutes.\n'
heading 'Possible actions'
shown=0
action_count=0
while IFS="$(printf '\t')" read -r row_cpu row_app row_hottest row_process row_pid row_quit row_kill; do
  shown=$((shown + 1))
  [ "$shown" -le "$count" ] || break
  case "$row_app" in
    WindowServer|com.crowdstrike.falcon.Agent|Falcon|FalconSensor|coreaudiod|ControlCenter|Spotlight|'macOS kernel'|syspolicyd|'Media analysis'|'Photos analysis'|fileproviderd|com.apple.Virtualization.VirtualMachine|corespeechd|com.cisco.anyconnect.macos.acsockext|acumbrellaagent|vpnagentd) continue ;;
  esac
  awk -v n="$row_cpu" 'BEGIN { exit !(n >= 10) }' || continue
  if [ "$row_quit" = 1 ]; then
    case "$row_app" in
      'Google Chrome'|'Google Chrome Canary')
        printf 'Try closing a busy tab in %s before quitting the whole browser.\n' "$row_app" ;;
    esac
    if [ "$row_app" = ChatGPT ]; then
      printf 'Closing ChatGPT will interrupt any active Codex/ChatGPT session.\n'
    fi
    case "$row_app" in
      *[!A-Za-z0-9._\ -]*) ;;
      *)
        printf '%sClose %s:%s\n' "$bold" "$row_app" "$reset"
        printf 'osascript -e '\''tell application "%s" to quit'\''\n' "$row_app"
        action_count=$((action_count + 1))
        ;;
    esac
  elif [ "$row_kill" = 1 ] && [ -n "$row_pid" ] && [ "$(ps -p "$row_pid" -o uid= 2>/dev/null | awk '{print $1}')" = "$(id -u)" ]; then
    printf '%sInspect %s:%s\n' "$bold" "$row_app" "$reset"
    printf 'ps -p %s -o pid=,user=,comm=\n' "$row_pid"
    printf '%sStop %s:%s\n' "$bold" "$row_app" "$reset"
    printf 'kill -TERM %s\n' "$row_pid"
    action_count=$((action_count + 1))
  fi
done <"$ranked"
[ "$action_count" -gt 0 ] || printf '  No ordinary app in the top results has a safe quit command.\n'
if [ "$action_count" -gt 0 ]; then
  label 'Then watch fan RPM:'
  printf 'fan -w\n'
fi
}

watch_report() {
  if [ "$fan_status" = unavailable ]; then
    fan_line='Fan RPM unavailable'
  else
    fan_line=$(printf '%s\n' "$fan_data" | awk -F '\t' '{
      if (NR > 1) printf ", "
      printf "Fan %d %d RPM", $1 + 1, $2
    }')
  fi
  if [ -s "$ranked" ]; then
    top_cpu=$(awk -F '\t' 'NR == 1 { print int($1 + 0.5) }' "$ranked")
    top_app=$(awk -F '\t' 'NR == 1 { print $2 }' "$ranked")
    printf '%s%s%s | top recent CPU: %s %s%%\n' "$cyan" "$fan_line" "$reset" "$top_app" "$top_cpu"
  else
    top_cpu=0
    printf '%s%s%s | no measurable CPU activity\n' "$cyan" "$fan_line" "$reset"
  fi
}

if [ "$deep" -eq 1 ]; then
  heading 'Hardware diagnostics'
  if ! command -v powermetrics >/dev/null 2>&1; then
    printf 'powermetrics is unavailable on this Mac.\n\n'
  else
    printf 'For thermal pressure and per-process GPU activity:\n'
    printf 'sudo powermetrics -n 1 -i 1000 --samplers tasks,thermal,gpu_power --show-process-gpu\n\n'
  fi
fi

calm_rounds=0
watch_round=0
while :; do
  sample
  rank
  read_fans
  if [ "$watch" -eq 1 ] && [ "$watch_round" -gt 0 ]; then
    watch_report
  else
    report
  fi
  [ "$watch" -eq 1 ] || break
  if [ "$fan_status" = stopped ] || { [ "$fan_status" = unavailable ] && [ "$top_cpu" -lt 25 ]; }; then
    calm_rounds=$((calm_rounds + 1))
  else
    calm_rounds=0
  fi
  if [ "$calm_rounds" -ge 2 ]; then
    if [ "$fan_status" = stopped ]; then
      printf '\nFans have been stopped for two rounds.\n'
    else
      printf '\nNo single app has exceeded 25%% CPU for two rounds (fan RPM unavailable).\n'
    fi
    break
  fi
  if [ "$fan_status" = unavailable ]; then
    printf '\nWatching CPU until it settles; fan RPM is unavailable (Ctrl-C to stop)...\n\n'
  else
    printf '\nWatching for fans to stop (Ctrl-C to stop)...\n\n'
  fi
  watch_round=$((watch_round + 1))
done
