#!/usr/bin/env ruby

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

# NB! the hook is runnig on the KVM hosts so rubygem nokogiri must be installed
# on CentOS7: yum -y --enablerepo=epel install rubygem-nokogiri
#
# hook definition
#
#NAME = "vnfilter"
#TYPE = "state"
#ON = "CUSTOM"
#ARGUMENTS = "$TEMPLATE"
#ARGUMENTS_STDIN="YES"
#COMMAND="alias_ip/vnfilter.rb"
#REMOTE="YES"
#RESOURCE="VM"
#STATE="ACTIVE"
#LCM_STATE="HOTPLUG_NIC"
#

ONE_LOCATION = ENV['ONE_LOCATION']

if !ONE_LOCATION
    RUBY_LIB_LOCATION = '/usr/lib/one/ruby'
    GEMS_LOCATION     = '/usr/share/one/gems'
    PACKET_LOCATION   = '/usr/lib/one/ruby/vendors/packethost/lib'
    LOG_FILE          = '/var/log/one/hook-alias_ip.log'
else
    RUBY_LIB_LOCATION = ONE_LOCATION + '/lib/ruby'
    GEMS_LOCATION     = ONE_LOCATION + '/share/gems'
    PACKET_LOCATION   = ONE_LOCATION + '/ruby/vendors/packethost/lib'
    LOG_FILE          = ONE_LOCATION + '/var/net_fw_hook.log'
end

if File.directory?(GEMS_LOCATION)
    Gem.use_paths(GEMS_LOCATION)
end

$LOAD_PATH << RUBY_LIB_LOCATION
$LOAD_PATH << PACKET_LOCATION

require 'base64'
require 'nokogiri'
require 'open3'
require 'shellwords'
require 'syslog/logger'

###############################################################################
# Helpers

@slog = Syslog::Logger.new 'vnfilter_hook'

def log(msg, level = 'I')
    msg.lines do |line|
        puts(line)
        @slog.info "[#{level}] #{line}"
    end
end

def log_error(msg)
    log(msg, 'E')
end

def get_data(xpath, entries)
    data = Hash.new
    xentry = VM_XML.xpath(xpath)
    entries.each do |e|
        val = xentry.xpath(e)
        if !val.nil?
            key = e.downcase.to_sym
            if e.end_with?("_ID")
                data[key] = val.text.to_i
            else
                data[key] = val.text
            end
        end
    end
    data
end

def alias_nic_data()
    xpath = '//TEMPLATE/NIC_ALIAS[ATTACH="YES"]'
    entries = %w[ALIAS_ID PARENT_ID NAME IP IP6 IP6_GLOBAL IP6_LINK]
    get_data(xpath, entries)
end

def nic_data(nic_id)
    xpath = "//TEMPLATE/NIC[NIC_ID=#{nic_id}]"
    entries = %w[IP IP6 IP6_GLOBAL IP6_LINK VN_MAD ALIAS_IDS 
                 FILTER FILTER_IP_SPOOFING FILTER_MAC_SPOOFING]
    get_data(xpath, entries)
end

def vm_data()
    vm = Hash.new
    data = get_data("//VM", %w[ID])
    vm[:id] = VM_XML.xpath('//VM/ID').text.to_i
    vm[:domain] = "one-#{vm[:id]}"
    vm[:a] = alias_nic_data()
    nic_id = vm[:a][:parent_id]
    vm[:n] = nic_data(nic_id)

    vm[:nicdev] = "#{vm[:domain]}-#{nic_id}"
    vm[:a][:idx] = vm[:a][:name].split('_ALIAS')[1].to_i

    vm[:action] = 'del'
    if !vm[:n][:alias_ids].nil? and !vm[:n][:alias_ids].empty?
        vm[:n][:alias_ids].split(',').each do |idx|
            if vm[:a][:idx] == idx.to_i
                vm[:action] = 'add'
            end
        end
    end
    #log("#{vm}")
    vm
end

def run(cmds)
    cmd = String.new
    cmds.each do |c|
        cmd.concat(" #{Shellwords.escape(c)}")
    end
    stdout, stderr, status = Open3.capture3(cmd)
    log("(#{status.exitstatus}) #{cmd}")
    if !status.success?
        log_error("PID[#{status.pid}] #{stderr}")
    end
end

def toggle_ebtables_filter(vm)
    if !vm[:a][:ip].nil? and !vm[:a][:ip].empty?
        action = vm[:action]=='add'? '-A' : '-D'
        ['i', 'o'].each do |d|
            rule = d=='o'? '--arp-ip-dst' : '--arp-ip-src'
            chain = "#{vm[:nicdev]}-#{d}-arp4"
            run(['sudo', 'ebtables', '--concurrent', '-t', 'nat', action,
                 chain, '-p', 'ARP', rule, vm[:a][:ip], '-j', 'RETURN'])
        end
    end
end

def toggle_ipset_filter(vm)
    ['IP', 'IP6', 'IP6_GLOBAL'].each do |e|
        key = e.downcase.to_sym
        if !vm[:a][key].nil? and !vm[:a][key].empty?
            chain = "#{vm[:nicdev]}-#{e.split('_')[0].downcase}-spoofing"
            run(['sudo', 'ipset', '-exist', vm[:action], chain, vm[:a][key]])
            if e == 'IP6_GLOBAL' and !vm[:a][:ip6_link].nil?
                link = vm[:a][:ip6_link]
                run(['sudo', 'ipset', '-exist', vm[:action], chain, link])
            end
        end
    end
end


###############################################################################
# Main
#

log("vnfilter hook BEGIN")

vm_xml_raw = Base64.decode64(STDIN.read)
vm_xml = Nokogiri::XML(vm_xml_raw)
VM_XML = vm_xml

vm = vm_data()

filters = Hash.new
filters[:filter_ip_spoofing] = method(:toggle_ipset_filter)
filters[:filter_mac_spoofing] = method(:toggle_ebtables_filter)

filters.each do |key, method|
    if !vm[:n][key].nil?
        if vm[:n][key] == 'YES'
            method.(vm)
        end
    end
end

log('vnfilter hook END')

exit 0
