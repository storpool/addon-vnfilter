#!/bin/bash
#

# A tool to check and propose a fix for the case
# when a SG are defined but important rules not
# applied due to missing interface. Usually it is 
# happening after VM migration
#
# Usage:
#  - to check for inconsistency,
#    the exit status will be 1 if there is an omission
#
#  ./vncheck.sh
#
#  - to check and fix
#  ./vncheck.sh | bash
#
#  Optionally use SUDO

TMPDIR=$(mktemp -d)
trap 'rm -rf "${TMPDIR}"' EXIT QUIT ERR

IPTABLES_SAVE="${TMPDIR}/iptables-save.list"
${SUDO:+sudo }iptables-save >"${IPTABLES_SAVE}"

RET=0

function process_domain()
{
    local domain="$1"
    while read -r -u ${domfd} iface mac; do
        #echo "${iface} ${mac}"
        if grep -- "${iface}-o" "${IPTABLES_SAVE}" &>"${TMPDIR}/${iface}-o" ; then
            if grep -q -e "match-set" -e "m mac" -e "p udp" -e "p tcp" "${TMPDIR}/${iface}-o"; then
                if ! grep -q -- "physdev-in ${iface}" "${IPTABLES_SAVE}"; then
                    echo "# missing in $iface $mac" >&2
                    echo "${SUDO:+sudo }iptables -I opennebula -m physdev --physdev-in ${iface} --physdev-is-bridged -j ${iface}-o"
                    RET=1
                fi
            fi
        fi
        if grep -- "${iface}-i" "${IPTABLES_SAVE}" &>"${TMPDIR}/${iface}-i" ; then
            if grep -q -e "match-set" -e "m mac" -e "p udp" -e "p tcp" "${TMPDIR}/${iface}-i"; then
                if ! grep -q -- "physdev-out ${iface}" "${IPTABLES_SAVE}"; then
                    echo "# missing out $iface $mac" >&2
                    echo "${SUDO:+sudo }iptables -I opennebula -m physdev --physdev-out ${iface} --physdev-is-bridged -j ${iface}-i"
                    RET=1
                fi
            fi
        fi
    done {domfd}< <(${SUDO:+sudo }virsh --readonly dumpxml "${domain}" |\
      xmlstarlet sel -t -m '//interface[@type="bridge"]' -v target/@dev -o ' ' -v mac/@address -n - )
    exec {domfd}<&-
}

while read -r -u ${virsh_list} i domain state; do
    [[ -n "${domain}" ]] || continue
    [[ ${domain} =~ "one-" ]] || continue
    process_domain "${domain}"
done {virsh_list}< <(${SUDO:+sudo }virsh list)

exit "${RET}"
