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

set -e

echo "*** copy files ..."
for f in $(find remotes/ -type f -o -type l); do
    p="/var/lib/one/${f%/*}"
    [ -d "$p" ] || mkdir -vp "$p"
    cp -vf "$f" "$p"/
done

echo "*** set ownership ..."
chown -R oneadmin.oneadmin /var/lib/one/remotes/

echo "*** sync hosts ..."
su - oneadmin -c 'onehost sync --force'

echo "*** register the vnfilter hook ..."
onehook show "vnfilter" || onehook create vnfilter.hooktemplate

cat <<EOF
*** Please install rubygem nokogiri on the hosts:"

yum -y --enablerepo=epel install opennebula-rubygems || \
yum -y --enablerepo=epel install rubygem-nokogiri || \
echo "ERROR: Can't install rubygem nokogiri."
EOF
