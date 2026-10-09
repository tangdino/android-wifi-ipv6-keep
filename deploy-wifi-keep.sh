#!/system/bin/sh
# wifi-keep v5 one-click deploy (self-contained)
# Usage: copy this file to the target phone, then:
#   su -c 'sh /sdcard/Download/deploy-wifi-keep.sh'
PATH=/system/bin:/system/xbin:/vendor/bin
export PATH
[ "$(id -u)" = 0 ] || { echo 'ERROR: need root'; exit 1; }
SRC=/data/adb/service.d/wifi-keep.sh
DIR=/data/adb/wifi-keep
mkdir -p "$DIR"
chmod 700 "$DIR"
[ -f "$SRC" ] && cp -p "$SRC" "$DIR/wifi-keep.sh.bak.$(date +%Y%m%d-%H%M%S)"

cat > "$SRC" <<'WIFIKEEP_SCRIPT'
#!/system/bin/sh
case "$(/system/bin/readlink /proc/$$/exe)" in
    *busybox*) exec /system/bin/sh "$0" "$@" ;;
esac
ip() { /system/bin/ip "$@"; }
# Adaptive IPv6 default-route fallback. Does not reconnect Wi-Fi.
PATH=/system/bin:/system/xbin:/vendor/bin
export PATH
IFACE=wlan0
DIR=/data/adb/wifi-keep
LOG=$DIR/wifi-keep.log
LOCK=$DIR/lock
CACHE=$DIR/current-network
METRIC=4096
PROTO=99
INTERVAL=30
IDLE_INTERVAL=300
STABLE_INTERVAL=300
READY=0
EVENT_FIFO=$DIR/link-events.fifo
MON_PID=''
KEEP_POWER_SAVE_OFF=1
[ "$(id -u)" = 0 ] || exit 1
mkdir -p "$DIR"
chmod 700 "$DIR"
log() {
    [ ! -f "$LOG" ] || [ "$(wc -c < "$LOG")" -le 131072 ] || mv -f "$LOG" "$LOG.1"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}
# Identity includes association, interface generation, IPv6 prefixes and Android network rules.
network_key() {
    status=$(timeout 8 cmd wifi status 2>/dev/null)
    connected=$(printf '%s\n' "$status" | grep '^Wifi is connected to ')
    bssid=$(printf '%s\n' "$status" | sed -n 's/^WifiInfo:.* BSSID: \([^,]*\),.*/\1/p' | head -n 1)
    [ -n "$connected" ] && [ -n "$bssid" ] || return 1
    [ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" = 1 ] || return 1
    ip -6 addr show dev "$IFACE" 2>/dev/null | grep 'scope global' | grep -Ev 'deprecated|tentative|dadfailed' >/dev/null || return 1
    prefixes=$(ip -6 route show table "$IFACE" 2>/dev/null | awk '$1 != "default" && /proto kernel/ && $1 !~ /^fe80:/ {print $1}' | sort)
    [ -n "$prefixes" ] || return 1
    { printf '%s\n' "$connected" "$bssid" "$prefixes"; cat /sys/class/net/$IFACE/ifindex /sys/class/net/$IFACE/address; ip -6 rule show | grep "lookup $IFACE "; } | sha256sum | awk '{print $1}'
}
# Helper used during installation to preserve the already verified current network.
if [ "$1" = --network-key ]; then network_key; exit $?; fi
# Parse only the active NetworkAgentInfo, never network requests/offers.
parse_default_network() {
    awk '
    /^Active default network:/ {id=$4; seen=1}
    /NetworkAgentInfo\{network\{/ {
        n=$0; sub(/^.*NetworkAgentInfo\{network\{/, "", n); sub(/\}.*/, "", n)
        agents[n]=$0
    }
    END {
        if(!seen) {print "unknown"; exit}
        if(id=="none" || id=="null" || id=="-1") {print "none"; exit}
        line=agents[id]
        if(line=="") {print "unknown"; exit}
        transport=line
        sub(/^.*Transports: /, "", transport); sub(/ Capabilities:.*/, "", transport)
        if(transport ~ /VPN/) {print "other"; exit}
        if(transport ~ /CELLULAR/) {print "cellular"; exit}
        if(transport ~ /WIFI/ && line ~ /InterfaceName: wlan0[ ]/) {print "wifi"; exit}
        print "other"
    }'
}
default_transport() {
    timeout 8 dumpsys connectivity 2>/dev/null | parse_default_network
}
if [ "$1" = --default-transport ]; then default_transport; exit; fi
if [ "$1" = --parse-default-network ]; then parse_default_network; exit; fi
DEFAULT_POLL_INTERVAL=60
NO_V6_FAST_SECONDS=120
NO_V6_IDLE_INTERVAL=300
PAUSED=0
pause_reason=''
no_v6=0
no_v6_since=0
pause_guard() {
    no_v6=0; no_v6_since=0
    if [ "$PAUSED" != 1 ]; then
        remove_owned
        key=''; gw=''; mac=''; mtu=''; last=''; READY=0
        reset_health
    fi
    PAUSED=1
    if [ "$pause_reason" != "$1" ]; then
        log "guard=paused default_network=$1 fallback=cleared gateway_health=unknown; no gateway probes or parameter changes"
        pause_reason=$1
    fi
}
if ! mkdir "$LOCK" 2>/dev/null; then
    old=$(cat "$LOCK/pid" 2>/dev/null)
    case "$old" in ''|*[!0-9]*) sleep 2; old=$(cat "$LOCK/pid" 2>/dev/null);; esac
    case "$old" in ''|*[!0-9]*) exit 1;; *) kill -0 "$old" 2>/dev/null && exit 0;; esac
    rm -f "$LOCK/pid"
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || exit 1
fi
printf '%s\n' "$$" > "$LOCK/pid"
remove_owned() {
    ip -6 route show table "$IFACE" 2>/dev/null | awk '/^default / && /proto (99|0x63) / && /metric 4096 / {print $3}' |
    while read -r g; do
        ip -6 route del default via "$g" dev "$IFACE" table "$IFACE" proto "$PROTO" metric "$METRIC" >> "$LOG" 2>&1
    done
}
cleanup() {
    [ -z "$MON_PID" ] || { kill "$MON_PID" 2>/dev/null; wait "$MON_PID" 2>/dev/null; }
    exec 7>&-
    rm -f "$EVENT_FIFO"
    remove_owned; log stopped; rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null
}
trap 'exit 0' TERM INT HUP
trap cleanup EXIT
until [ "$(getprop sys.boot_completed)" = 1 ]; do sleep 5; done
sleep 5
rm -f "$EVENT_FIFO"
mkfifo "$EVENT_FIFO" || exit 1
chmod 600 "$EVENT_FIFO"
exec 7<>"$EVENT_FIFO" || exit 1
start_monitor() {
    [ -z "$MON_PID" ] || wait "$MON_PID" 2>/dev/null
    /system/bin/ip -o monitor link address route dev "$IFACE" >"$EVENT_FIFO" 2>>"$DIR/monitor-errors.log" 7>&- &
    MON_PID=$!
    log "link monitor started pid=$MON_PID"
}
start_monitor
# Start listening before the initial state check. No wakelock.
# Health deadlines use monotonic uptime, not wall-clock time.
HEALTH_INTERVAL=300
RETRY_INTERVAL=60
FAIL_THRESHOLD=3
next_check=0
failures=0
health=unknown
probe_target=''
state_last=''
clock_now() { awk '{split($1,a,"."); print a[1]}' /proc/uptime; }
route_present() {
    ip -6 route show table "$IFACE" 2>/dev/null |
        awk -v g="$1" -v m="$METRIC" '
        $1=="default" && $2=="via" && $3==g {
            p=0; q=0
            for(i=4;i<NF;i++) {
                if($i=="proto" && ($(i+1)=="99" || $(i+1)=="0x63")) p=1
                if($i=="metric" && $(i+1)==m) q=1
            }
            if(p && q) found=1
        }
        END {exit !found}'
}
report_state() {
    if [ "$READY" = 1 ]; then fallback=installed; else fallback=missing; fi
    state="fallback=$fallback gateway_health=$health gateway=${gw:-none} probe_target=${probe_target:-none}"
    if [ "$state" != "$state_last" ]; then log "$state"; state_last=$state; fi
}
reset_health() {
    next_check=0; failures=0; health=unknown; probe_target=''; state_last=''
}
wait_next() {
    if ! kill -0 "$MON_PID" 2>/dev/null; then
        log 'link monitor exited; restarting'
        sleep 30
        start_monitor
        return
    fi
    delay=$INTERVAL
    mode=preparing
    if [ "$(cat /sys/class/net/$IFACE/carrier 2>/dev/null)" != 1 ]; then
        delay=$IDLE_INTERVAL; mode=idle
    elif [ "$no_v6" = 1 ]; then
        now=$(clock_now)
        if [ "$no_v6_since" -gt 0 ] && [ $((now-no_v6_since)) -ge "$NO_V6_FAST_SECONDS" ]; then
            delay=$NO_V6_IDLE_INTERVAL; mode=no-ipv6-idle
        else
            delay=$INTERVAL; mode=no-ipv6
        fi
    elif [ "$next_check" -gt 0 ]; then
        now=$(clock_now)
        delay=$((next_check-now))
        [ "$delay" -gt 0 ] || delay=1
        if [ "$health" = suspect ]; then mode=health-retry
        elif [ "$READY" = 1 ]; then mode=stable
        else mode=preparing; fi
    elif [ "$READY" = 1 ]; then
        delay=$STABLE_INTERVAL; mode=stable
    fi
    # Keep default-network detection fast while a fallback route may still be
    # installed and must be removed on a switch to cellular. The no-IPv6 idle
    # state has no fallback route to remove, so it keeps its longer interval.
    if [ "$no_v6" != 1 ]; then
        [ "$delay" -le "$DEFAULT_POLL_INTERVAL" ] || delay=$DEFAULT_POLL_INTERVAL
    fi
    if [ "$PAUSED" = 1 ]; then delay=$DEFAULT_POLL_INTERVAL; mode=paused; fi
    if [ "$mode" != "$wait_mode" ]; then
        log "scheduler=$mode timeout=${delay}s"
        wait_mode=$mode
    fi
    if IFS= read -r -t "$delay" event <&7; then
        log 'network event received; checking state (probe deadline unchanged)'
        count=0
        while [ "$count" -lt 20 ] && IFS= read -r -t 0.1 event <&7; do count=$((count+1)); done
        sleep 1
    fi
    if ! kill -0 "$MON_PID" 2>/dev/null; then
        log 'link monitor exited; restarting'
        sleep 30
        start_monitor
    fi
}
wait_mode=''
log "adaptive health guard v5 started pid=$$ health=${HEALTH_INTERVAL}s retry=${RETRY_INTERVAL}s threshold=$FAIL_THRESHOLD no_v6_fast=${NO_V6_FAST_SECONDS}s no_v6_idle=${NO_V6_IDLE_INTERVAL}s mtu=inherit"
key=''
gw=''
mac=''
mtu=''
last=''
set_value() {
    f=/proc/sys/net/ipv6/conf/$IFACE/$1
    [ -f "$f" ] || return
    v=$(cat "$f" 2>/dev/null) || return
    [ "$v" = "$2" ] || { printf '%s\n' "$2" > "$f" 2>> "$LOG" && log "$1 changed to $2"; }
}
while :; do
    READY=0
    transport=$(default_transport)
    if [ "$transport" != wifi ]; then
        pause_guard "$transport"
        wait_next; continue
    fi
    if [ "$PAUSED" = 1 ]; then
        PAUSED=0; pause_reason=''
        no_v6=0; no_v6_since=0
        log 'guard=active default_network=wifi; revalidating Wi-Fi session'
    fi
    new=$(network_key)
    if [ -z "$new" ]; then
        remove_owned
        if [ "$no_v6" != 1 ]; then
            no_v6=1
            no_v6_since=$(clock_now)
            log 'no usable IPv6 on Wi-Fi; fast checks then slower'
        fi
        [ -z "$key" ] || log 'disconnected/no usable IPv6; cleared session'
        key=''; gw=''; mac=''; mtu=''
        reset_health
        rm -f "$CACHE"
        wait_next; continue
    fi
    no_v6=0; no_v6_since=0
    if [ "$new" != "$key" ]; then
        remove_owned
        key=$new; gw=''; mac=''; mtu=''; last=''
        reset_health
        if [ "$(sed -n '1p' "$CACHE" 2>/dev/null)" = "$key" ]; then
            gw=$(sed -n '2p' "$CACHE"); mac=$(sed -n '3p' "$CACHE"); mtu=$(sed -n '4p' "$CACHE")
        else
            rm -f "$CACHE"
        fi
        log 'new network/session; old fallback cleared'
    fi
    set_value accept_ra_min_lft 1
    set_value accept_ra 2
    if [ "$KEEP_POWER_SAVE_OFF" = 1 ] && [ -x /system/bin/iw ] && /system/bin/iw dev "$IFACE" get power_save 2>/dev/null | grep -q 'Power save: on'; then
        /system/bin/iw dev "$IFACE" set power_save off >> "$LOG" 2>&1
    fi
    routes=$(ip -6 route show table "$IFACE" 2>/dev/null)
    learned=$(printf '%s\n' "$routes" | awk '/^default via / && /proto ra / {print $3; exit}')
    ra_mtu=$(printf '%s\n' "$routes" | awk '/^default via / && /proto ra / {for(i=1;i<=NF;i++) if($i=="mtu") {v=$(i+1); if(v ~ /^[0-9]+$/) print v; exit}}')
    [ -n "$ra_mtu" ] && mtu=$ra_mtu
    target=${learned:-$gw}
    [ -z "$gw" ] || { route_present "$gw" && READY=1; }
    if [ -z "$target" ]; then
        reason='waiting for normal RA default route'
        [ "$reason" = "$last" ] || { log "$reason"; last=$reason; }
        report_state
        wait_next; continue
    fi
    now=$(clock_now)
    # Events check identity/routes, but never advance the probe deadline.
    if [ "$now" -lt "$next_check" ]; then
        report_state
        wait_next; continue
    fi
    if [ "$target" != "$probe_target" ]; then
        probe_target=$target; failures=0; health=unknown
        log "verifying gateway $target; existing fallback retained until replacement succeeds"
    fi
    expected=''
    [ "$target" != "$gw" ] || expected=$mac
    verified=0
    reason='gateway did not reply'
    if timeout 8 ping6 -c 2 -W 2 "$target%$IFACE" >/dev/null 2>&1; then
        observed=$(ip -6 neigh show dev "$IFACE" | awk -v g="$target" '$1==g {for(i=1;i<NF;i++) if($i=="lladdr") print $(i+1)}' | head -n 1)
        if [ -n "$observed" ] && { [ -z "$expected" ] || [ "$observed" = "$expected" ]; }; then
            verified=1
        else
            reason='gateway MAC mismatch/unresolved'
        fi
    fi
    # Recheck default transport after blocking probe commands.
    transport=$(default_transport)
    if [ "$transport" != wifi ]; then
        pause_guard "$transport"
        wait_next; continue
    fi
    # Never act on a stale probe after switching networks.
    if [ "$(network_key)" != "$key" ]; then
        remove_owned
        log 'network changed during verification; old fallback cleared'
        key=''; gw=''; mac=''; mtu=''; READY=0
        reset_health
        rm -f "$CACHE"
        continue
    fi
    now=$(clock_now)
    if [ "$verified" = 1 ]; then
        health=verified; failures=0
        next_check=$((now+HEALTH_INTERVAL))
        mtu_arg=''
        [ -z "$mtu" ] || mtu_arg=" mtu $mtu"
        # replace is atomic: adds the fallback, carries the RA MTU, and
        # switches the gateway in place without an add/delete gap.
        if ip -6 route replace default via "$target" dev "$IFACE" table "$IFACE" proto "$PROTO" metric "$METRIC"$mtu_arg >> "$LOG" 2>&1; then
            if [ "$gw" != "$target" ]; then
                log "verified gateway selected $target (previous=${gw:-none})"
            fi
            gw=$target
            mac=$observed
            printf '%s\n' "$key" "$gw" "$mac" "$mtu" > "$CACHE.tmp"
            chmod 600 "$CACHE.tmp"; mv -f "$CACHE.tmp" "$CACHE"
            READY=1; last=''
        else
            next_check=$((now+RETRY_INTERVAL))
            reason='fallback replace failed; previous fallback retained'
            [ "$reason" = "$last" ] || { log "$reason"; last=$reason; }
        fi
    else
        failures=$((failures+1)); health=suspect
        next_check=$((now+RETRY_INTERVAL))
        [ "$reason" = "$last" ] || { log "health check failed target=$target: $reason; no fallback deleted"; last=$reason; }
        if [ "$failures" -eq "$FAIL_THRESHOLD" ]; then
            log "WARNING: gateway health suspect target=$target consecutive_failures=$failures; fallback retained; retry=${RETRY_INTERVAL}s"
        fi
    fi
    report_state
    wait_next
done
WIFIKEEP_SCRIPT

chmod 755 "$SRC"
chown 0:0 "$SRC"

if ! /system/bin/sh -n "$SRC"; then
    echo 'SYNTAX_FAILED - rolling back'
    latest=$(ls -t "$DIR"/wifi-keep.sh.bak.* 2>/dev/null | head -n 1)
    [ -n "$latest" ] && cp -p "$latest" "$SRC"
    exit 1
fi
echo 'SYNTAX_OK'

old=$(cat "$DIR/lock/pid" 2>/dev/null)
if [ -n "$old" ]; then
    if [ -r "/proc/$old/cmdline" ] && tr '\0' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q 'wifi-keep.sh'; then
        kill -TERM "$old" 2>/dev/null
        n=0
        while kill -0 "$old" 2>/dev/null && [ "$n" -lt 20 ]; do sleep 1; n=$((n+1)); done
        echo "old_stopped pid=$old"
    else
        echo "old_pid_ignored=$old"
    fi
fi

nohup /system/bin/sh "$SRC" >> "$DIR/launcher.log" 2>&1 </dev/null &
echo "started_pid=$!"
sleep 10
echo '--- processes ---'
ps -A -o PID,PPID,ARGS | grep -E 'service\.d/wifi-keep\.sh|ip -o monitor' | grep -v grep
echo '--- routes ---'
ip -6 route show table wlan0 2>/dev/null | grep -E 'proto ra|proto 99' || echo '(wlan0 table not ready yet)'
echo 'DONE'
