#!/bin/bash

# -------------------------------------------------------------------------- #
# Copyright 2002-2024, StorPool                                              #
# Portion copyright OpenNebula Project, OpenNebula Systems                   #
#                                                                            #
# Licensed under the Apache License, Version 2.0 (the "License"); you may    #
# not use this file except in compliance with the License. You may obtain    #
# a copy of the License at                                                   #
#                                                                            #
# http://www.apache.org/licenses/LICENSE-2.0                                 #
#                                                                            #
# Unless required by applicable law or agreed to in writing, software        #
# distributed under the License is distributed on an "AS IS" BASIS,          #
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.   #
# See the License for the specific language governing permissions and        #
# limitations under the License.                                             #
#--------------------------------------------------------------------------- #

set -e -o pipefail

PATH="/bin:/usr/bin:/sbin:/usr/sbin:${PATH}"

CP_ARG=${CP_ARG:--vLf}

ONE_USER="${ONE_USER:-oneadmin}"
ONE_GROUP="${ONE_GROUP:-oneadmin}"
ONE_ETC="${ONE_ETC:-/etc/one}"
ONE_VAR="${ONE_VAR:-/var/lib/one}"
ONE_LIB="${ONE_LIB:-/usr/lib/one}"

if [[ -n "${ONE_LOCATION}" ]]; then
    ONE_ETC="${ONE_LOCATION}/etc"
    ONE_VAR="${ONE_LOCATION}/var"
    ONE_LIB="${ONE_LOCATION}/lib"
fi

[[ "${0/\//}" != "$0" ]] && cd "${0%/*}"

CWD=$(pwd)
export CWD

function boolTrue()
{
   case "${!1^^}" in
       1|Y|YES|T|TRUE|ON)
           return 0
           ;;
       *)
           return 1
   esac
}

function do_patch()
{
    local _patch="$1" _backup="$2"
    #check if patch is applied
    echo "*** Testing patch ${_patch##*/}"
    if patch --dry-run --reverse --forward --strip=0 --input="${_patch}" 2>/dev/null >/dev/null; then
        echo "   *** Patch file ${_patch##*/} already applied?"
    else
        if patch --dry-run --forward --strip=0 --input="${_patch}" 2>/dev/null >/dev/null; then
            echo "   *** Apply patch ${_patch##*/}"
            if [[ -n "${_backup}" ]]; then
                read -ra _backup <<<"--backup --version-control=numbered"
            else
                read -ra _backup <<<"--no-backup-if-mismatch"
            fi
            if patch "${_backup[@]}" --strip=0 --forward --input="${_patch}"; then
                DO_PATCH="done"
            else
                DO_PATCH="failed"
            fi
            echo "--- patch ${_patch} ${DO_PATCH}"
        else
            echo "   *** Note! Can't apply patch ${_patch}! Please merge manually."
        fi
    fi
}

oneVersion(){
    read -ra _arr <<<"${1//\./ }"
    export ONE_MAJOR="${_arr[0]}"
    export ONE_MINOR="${_arr[1]}"
    export ONE_VERSION=$((_arr[0]*10000 + _arr[1]*100 + _arr[2]))
    if [[ ${#_arr[*]} -eq 4 ]] || [[ ${ONE_VERSION} -lt 51200 ]]; then
        export ONE_EDITION="CE${_arr[3]}"
    else
        export ONE_EDITION="EE"
    fi
}

if [[ -f "${ONE_VAR}/remotes/VERSION" ]]; then
    [[ -n "${ONE_VER}" ]] || ONE_VER="$(< "${ONE_VAR}/remotes/VERSION")"
fi

oneVersion "${ONE_VER}"

TMPDIR="$(mktemp -d addon-storpool-install-XXXXXXXX)"
export TMPDIR
# shellcheck disable=SC2064
trap "rm -rf \"${TMPDIR}\"" EXIT QUIT TERM

if [[ -f "scripts/install-${ONE_VER}.sh" ]]; then
    # shellcheck source=/dev/null
    source "scripts/install-${ONE_VER}.sh"
elif [[ -f "scripts/install-${ONE_MAJOR}.${ONE_MINOR}.sh" ]]; then
    # shellcheck source=/dev/null
    source "scripts/install-${ONE_MAJOR}.${ONE_MINOR}.sh"
else
    echo "ERROR: Unknown OpenNebula version '${ONE_VER}' detected!"
    echo "Please follow the manual installation procedure described in the README.md file."
    echo "Probably some adjustments will be needed."
    echo
fi

if [[ -z "${HOST_INSTALL}" ]]; then
    echo "*** copy files ..."
    while read -ru "${fds}" fname; do
        dstpath="/var/lib/one/${fname%/*}"
        [[ -d "${dstpath}" ]] || sudo mkdir -v "${dstpath}"
        sudo cp -vLf "${fname}" "${dstpath}"/
    done {fds}< <(find remotes/ -type f -o -type l || true)

    echo "*** set file ownership ..."
    sudo chown -R "${ONE_USER}":"${ONE_GROUP}" /var/lib/one/remotes/

    if [[ -z "${SKIP_HOSTS_SYNC}" ]]; then
        echo "*** sync hosts ..."
        su - oneadmin -c 'onehost sync --force'
    fi
    if [[ -z "${SKIP_ONEHOOK_REGISTRATION}" ]]; then
        if [[ -f vnfilter.hooktemplate ]]; then
            echo "*** register the vnfilter hook ..."
            onehook show "vnfilter" || onehook create vnfilter.hooktemplate
        else
            echo "*** Error: vnfilter.hooktemplate not found!"
            echo "*** Please define the vnfilter hook manually"
        fi
    fi
else
    # on the hosts
    sudo dnf -y install opennebula-rubygems || \
    sudo apt -y install opennebula-rubygems || \
    sudo yum -y install rubygem-nokogiri || \
    echo -e "\n*** Please install rubygem nokogiri.\n"
    echo "oneadmin ALL=(ALL) NOPASSWD: /usr/sbin/ebtables-save" | sudo tee /etc/sudoers.d/vnfilter
    sudo chmod 0440 /etc/sudoers.d/vnfilter
fi

