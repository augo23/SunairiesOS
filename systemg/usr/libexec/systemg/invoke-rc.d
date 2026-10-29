#!/bin/sh
# SystemG wrapper for invoke-rc.d and service (installed with dpkg-divert;
# the originals are kept as *.distrib).
#
# Package scripts and admins call `invoke-rc.d cups restart` or
# `service ssh reload`. Without systemd as PID 1 these would run the old
# /etc/init.d script and start a second copy of a daemon dinit already
# supervises. If SystemG manages the service, use systemctl instead; otherwise
# fall through to the original tool.
self=$(basename "$0")
real="/usr/sbin/$self.distrib"

# Skip invoke-rc.d's options (--quiet, --force, --skip-systemd-native, ...).
args=""
for a; do case "$a" in --*) ;; *) args="$args $a" ;; esac; done
# shellcheck disable=SC2086
set -- $args
svc=${1:-}; action=${2:-}

if [ -n "$svc" ] && [ -e "/etc/dinit.d/$svc" ] && [ -S /run/dinitctl ]; then
  # Respect policy-rc.d (e.g. inside an installer chroot) like invoke-rc.d does.
  if [ "$self" = invoke-rc.d ] && [ -x /usr/sbin/policy-rc.d ]; then
    /usr/sbin/policy-rc.d "$svc" "$action" >/dev/null 2>&1
    [ $? -eq 101 ] && exit 0
  fi
  case "$action" in
    start|stop|restart|reload|status) exec /usr/bin/systemctl "$action" "$svc" ;;
    force-reload|try-restart) exec /usr/bin/systemctl try-restart "$svc" ;;
  esac
fi
exec "$real" "$@"
