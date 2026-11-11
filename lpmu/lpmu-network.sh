#!/bin/bash

LPMU_INTERNAL_CIDR="10.10.99.99/24"

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
