#!/bin/bash

LPMU_INTERNAL_CIDR="10.10.99.99/24"
# Route protocol number used for the preferred default installed by this script.
LPMU_ROUTE_PROTOCOL=99

lpmu_internal_interface() {
    local addresses
    addresses=$(ip -o -4 addr show) || return
    awk -v cidr="$LPMU_INTERNAL_CIDR" '
        $3 == "inet" && $4 == cidr {
            split($2, name, "@")
            if (!seen[name[1]]++) {
                iface = name[1]
                count++
            }
        }
        END {
            if (count != 1) {
                printf "需要唯一一个持有 %s 的接口，找到 %d 个\n", cidr, count > "/dev/stderr"
                exit 1
            }
            print iface
        }
    ' <<< "$addresses"
}

lpmu_select_default_route() {
    local iface="$1" gateway="$2" current
    current=$(ip -4 route show default) || return
    current=${current%%$'\n'*}
    if [[ " $current " == *" via $gateway dev $iface "* ]]; then
        return 0
    fi

    # Clear only the previous preference. Existing defaults keep their gateways
    # and metrics, so a later run can still discover every available uplink.
    sudo ip -4 route flush default proto "$LPMU_ROUTE_PROTOCOL" || return
    sudo ip -4 route prepend default via "$gateway" dev "$iface" metric 0 proto "$LPMU_ROUTE_PROTOCOL"
}
