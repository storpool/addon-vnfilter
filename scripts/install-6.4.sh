#!/bin/bash

# -------------------------------------------------------------------------- #
# Copyright 2015-2024, Storpool (storpool.com)                               #
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

for mad in im vnm; do
    [[ -d "patches/${mad}" ]] || continue
    for ver in "${ONE_VER:-0.0}" "${ONE_MAJOR:-0}.${ONE_MINOR:-0}"; do
        patchdir="${PWD}/patches/${mad}/${ver}"
        [[ -d "${patchdir}" ]] || continue
        echo "*** Applying patches found in ${patchdir} ..."
        if pushd "${ONE_VAR:-/var/lib/one}"; then
            while read -ru "${fdh}" patchfile; do
                do_patch "${patchfile}" "backup"
            done {fdh}< <(ls -1 "${patchdir}"/*.patch || true)
            popd || exit $?
        fi
        break 1
    done
done

echo "*** chown -R ${ONE_USER:-oneadmin}":"${ONE_GROUP:-oneadmin}" "${ONE_VAR:-/var/lib/one}/remotes ..."
chown -R "${ONE_USER:-oneadmin}":"${ONE_GROUP:-oneadmin}" "${ONE_VAR:-/var/lib/one}/remotes"

