#!/bin/bash

# -------------------------------------------------------------------------- #
# Copyright 2002-2021, StorPool                                              #
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

if [ -z "$HOST_INSTALL" ]; then
    echo "*** copy files ..."
    for f in $(find remotes/ -type f -o -type l); do
        p="/var/lib/one/${f%/*}"
        [ -d "$p" ] || mkdir -vp "$p"
        cp -vf "$f" "$p"/
    done

    echo "*** set file ownership ..."
    chown -R oneadmin.oneadmin /var/lib/one/remotes/

    if [ -z "$SKIP_HOSTS_SYNC" ]; then
        echo "*** sync hosts ..."
        su - oneadmin -c 'onehost sync --force'
    fi
    if [ -z "$SKIP_ONEHOOK_REGISTRATION" ]; then
        if [ -f vnfilter.hooktemplate ]; then
            echo "*** register the vnfilter hook ..."
            onehook show "vnfilter" || onehook create vnfilter.hooktemplate
        else
            echo "*** Error: vnfilter.hooktemplate not found!"
            echo "*** Please define the vnfilter hook manually"
        fi
    fi
else
    sudo dnf -y install opennebula-rubygems || \
    sudo apt -y install opennebula-rubygems || \
    sudo yum -y install rubygem-nokogiri || \
    echo -u "\n*** Please install rubygem nokogiri.\n"
    echo "oneadmin ALL=(ALL) NOPASSWD: /usr/sbin/ebtables-save" | sudo tee /etc/sudoers.d/vnfilter
    sudo chmod 0440 /etc/sudoers.d/vnfilter
fi

