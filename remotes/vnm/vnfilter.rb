# rubocop:disable Naming/FileName
# vim: ts=4 sw=4 et
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

require 'vnmmad'
require 'syslog/logger'

# IP filter for aliases
class VnFilter < VNMMAD::VNMDriver

    DRIVER = 'vnfilter'
    XPATH_FILTER = 'TEMPLATE/NIC|TEMPLATE/NIC_ALIAS'

    def initialize(vm_template, xpath_filter = nil, deploy_id = nil)
        @locking = true
        @slog = Syslog::Logger.new 'vnfilter'
        xpath_filter ||= XPATH_FILTER
        @slog.info "initialize #{xpath_filter} //#{caller[-1]}"
        super(vm_template, xpath_filter, deploy_id)
    end

    def append_ebtables(chain, ipv4)
        @slog.info "activate_ebtables(#{chain},#{ipv4})"
        dirs = { "i" => "src", "o" => "dst" }
        ret = false
        commands =  VNMMAD::VNMNetwork::Commands.new
        commands.add "sudo -n", "ebtables-save"
        ebtables_nat = commands.run!
        if !ebtables_nat.nil?
            ebtables_nat.split("\n").each do |rule|
                if rule.match(/-A #{chain}-([io]{1})-arp4/)
                    dir = $+
                    rule_e = rule.split
                    ip = rule_e[5]
                    if ipv4 == rule_e[5]
                        @slog.info "[match] #{rule} // #{ip} #{dir}"
                        dirs.delete(dir)
                        ret = true
                    end
                end
            end
        end
        if dirs.any?
            dirs.each do |k,v|
                @slog.info "whitelist arp-ip-#{v} #{ipv4} (#{k})"
                commands.add :ebtables, "-t nat -A #{chain}-#{k}-arp4 -p ARP "\
                                            "--arp-ip-#{v} #{ipv4} -j RETURN"
                ret = true
            end
            commands.run!
        end
        return ret
    end

    def activate
        ipv4_offset = 2
        ipv6_offset = 5
        lock
        vm_id = vm['ID']
        attach_nic_id = vm['TEMPLATE/NIC[ATTACH="YES"]/NIC_ID']
        parent_id = vm['TEMPLATE/NIC_ALIAS[ATTACH="YES"]/PARENT_ID']
        if parent_id
            ipv4 = vm['TEMPLATE/NIC_ALIAS[ATTACH="YES"]/IP']
            if ipv4
                @slog.info "activate() VM #{vm_id} parent_id:#{parent_id} BEGIN"
                chain = "one-#{vm_id}-#{parent_id}"
                if append_ebtables(chain, ipv4)
                    @slog.info "activate() VM #{vm_id} parent_id:#{parent_id} END"
                    return
                end
            end
        end
        @slog.info "activate() VM #{vm_id} (#{attach_nic_id}) parent_id:#{parent_id} BEGIN"
        # pre-process
        nics = Hash.new
        process do |nic|
            nic_id = nic[:nic_id]
            ip4 = Array.new
            ip6 = Array.new
            [:ip, :vrouter_ip].each do |key|
                if !nic[key].nil? && !nic[key].empty?
                    ip4 << nic[key]
                end
            end
            [:ip6, :ip6_global, :ip6_link].each do |key|
                if !nic[:alias_id].nil? && "#{key}" == "ip6_link"
                    @slog.info "activate() Skip IPv6 link local address for alias interfaces"
                    next
                end
                if !nic[key].nil? && !nic[key].empty?
                    ip6 << nic[key]
                end
            end
            if !nic[:alias_id].nil?
                parent_id = nic[:parent_id]
                if nics[parent_id].nil?
                    nics[parent_id] = Hash.new
                    nics[parent_id][:ip4] = Array.new
                    nics[parent_id][:ip6] = Array.new
                end
                nics[parent_id][:ip4].push(*ip4)
                nics[parent_id][:ip6].push(*ip6)
                next
            end
            if nics[nic_id].nil?
                nics[nic_id] = Hash.new
                nics[nic_id][:ip4] = ip4
                nics[nic_id][:ip6] = ip6
            else
                nics[nic_id][:ip4].push(*ip4)
                nics[nic_id][:ip6].push(*ip6)
            end
            nics[nic_id][:nic] = nic
        end

        nics.each do |nic_id, nicdata|
            nic = nicdata[:nic]
            @slog.info "VM #{vm_id} nic_id #{nic_id} attach_nic_id:#{attach_nic_id}"
            OpenNebula.log_info "activate #{vm_id} nic_id #{nic_id} attach_nic_id #{attach_nic_id}"
            next if attach_nic_id and attach_nic_id != nic_id
            chain = "one-#{vm_id}-#{nic_id}"
            chain_i = "#{chain}-i"
            chain_o = "#{chain}-o"

            commands =  VNMMAD::VNMNetwork::Commands.new

            if nic[:filter_ip_spoofing] == "YES"
                @slog.info "VM #{vm_id} NIC #{nic_id} FILTER_IP_SPOOFING"
                commands.add :iptables, "-S #{chain_o}"
                begin
                    iptables_s = commands.run!
                rescue
                    @slog.warn "Can't process chain #{chain_o}"
                    next
                end
                iptables_s.each_line { |c| @slog.info "[iptables -S] #{c}" }
                if iptables_s !~ /#{chain}-ip-spoofing/
                    @slog.info "patching #{chain_o} to add #{chain}-ip-spoofing"
                    commands.add :ipset, "create -exist #{chain}-ip-spoofing hash:ip family inet"
                    commands.add :iptables, "-R #{chain_o} #{ipv4_offset} -m set ! --match-set #{chain}-ip-spoofing src -j DROP"
                    commands.add :iptables, "-I #{chain_o} #{ipv4_offset} -s 0.0.0.0/32 -d 255.255.255.255/32 -p udp -m udp --sport 68 --dport 67 -j RETURN"
                end
                if !nicdata[:ip4].nil? and !nicdata[:ip4].empty?
                    nicdata[:ip4].each do |ip|
                        @slog.info "ipset add #{chain}-ip-spoofing #{ip}"
                        commands.add :ipset, "add -exist #{chain}-ip-spoofing #{ip}"
                    end
                    commands.run!
                end
                commands.add :ip6tables, "-S #{chain_o}"
                ip6tables_s = commands.run!
                ip6tables_s.each_line { |c| @slog.info "[ip6tables -S] #{c}" }
                if ip6tables_s !~ /#{chain}-ip6-spoofing/
                    @slog.debug "altering #{chain_o} to add #{chain}-ip6-spoofing"
                    commands.add :ipset, "create -exist #{chain}-ip6-spoofing hash:ip family inet6"
                    commands.add :ip6tables, "-R #{chain_o} #{ipv6_offset} -m set ! --match-set #{chain}-ip6-spoofing src -j DROP"
                end
                if !nicdata[:ip6].nil? and !nicdata[:ip6].empty?
                    nicdata[:ip6].each do |ip|
                        @slog.info "ipset add #{chain}-ip6-spoofing #{ip}"
                        commands.add :ipset, "add -exist #{chain}-ip6-spoofing #{ip}"
                    end
                    commands.run!
                end
            end

            if nic[:filter_mac_spoofing] == "YES"
                @slog.info "VM #{vm_id} NIC #{nic_id} FILTER_MAC_SPOOFING"
                deactivate_ebtables(chain)
                commands.add :ebtables, "-t nat -N #{chain_i}-arp4 -P DROP"
                commands.add :ebtables, "-t nat -N #{chain_o}-arp4 -P DROP"
                if !nicdata[:ip4].nil? and !nicdata[:ip4].empty?
                    nicdata[:ip4].each do |ip|
                        @slog.info "ARP whitelist #{ip} (#{chain})"
                        commands.add :ebtables, "-t nat -A #{chain_i}-arp4 -p ARP "\
                            "--arp-ip-src #{ip} -j RETURN"
                        commands.add :ebtables, "-t nat -A #{chain_o}-arp4 -p ARP "\
                            "--arp-ip-dst #{ip} -j RETURN"
                    end
                end
                # Input
                commands.add :ebtables, "-t nat -N #{chain_i}-arp -P DROP"
                commands.add :ebtables, "-t nat -A #{chain_i}-arp -p ARP "\
                    "-s ! #{nic[:mac]} -j DROP"
                commands.add :ebtables, "-t nat -A #{chain_i}-arp -p ARP "\
                        "--arp-mac-src ! #{nic[:mac]} -j DROP"
                commands.add :ebtables, "-t nat -A #{chain_i}-arp -p ARP "\
                    "-j #{chain_i}-arp4"
                commands.add :ebtables, "-t nat -A #{chain_i}-arp -p ARP "\
                    "--arp-op Request -j ACCEPT"
                commands.add :ebtables, "-t nat -A #{chain_i}-arp -p ARP "\
                    "--arp-op Reply -j ACCEPT"
                commands.add :ebtables, "-t nat -N #{chain_i}-rarp -P DROP"
                commands.add :ebtables, "-t nat -A #{chain_i}-rarp -p 0x8035 "\
                    "-s #{nic[:mac]} -d Broadcast --arp-op Request_Reverse "\
                    "--arp-ip-src 0.0.0.0 --arp-ip-dst 0.0.0.0 "\
                    "--arp-mac-src #{nic[:mac]} --arp-mac-dst #{nic[:mac]} "\
                    "-j ACCEPT"
                commands.add :ebtables, "-t nat -N #{chain_i} -P ACCEPT"
#            commands.add :ebtables, "-t nat -N #{chain_i}-ip4 -P ACCEPT"
#            commands.add :ebtables, "-t nat -A #{chain_i}-ip4 "\
#                "-s ! #{nic[:mac]} -j DROP"
#            commands.add :ebtables, "-t nat -A #{chain_i} -p IPv4 "\
#                "-j #{chain_i}-ip4"
                commands.add :ebtables, "-t nat -A #{chain_i} -p IPv4 "\
                    "-j ACCEPT"
                commands.add :ebtables, "-t nat -A #{chain_i} -p IPv6 "\
                    "-j ACCEPT"
                commands.add :ebtables, "-t nat -A #{chain_i} -p ARP "\
                    "-j #{chain_i}-arp"
                commands.add :ebtables, "-t nat -A #{chain_i} -p 0x8035 "\
                    "-j #{chain_i}-rarp"
                commands.add :ebtables, "-t nat -A PREROUTING -i #{chain} "\
                    "-j #{chain_i}"
                # Output
                commands.add :ebtables, "-t nat -N #{chain_o}-arp -P DROP"
                commands.add :ebtables, "-t nat -A #{chain_o}-arp -p ARP "\
                    "--arp-op Reply --arp-mac-dst ! #{nic[:mac]} -j DROP"
                commands.add :ebtables, "-t nat -A #{chain_o}-arp -p ARP "\
                    "-j #{chain_o}-arp4"
                commands.add :ebtables, "-t nat -A #{chain_o}-arp -p ARP "\
                    "--arp-op Request -j ACCEPT"
                commands.add :ebtables, "-t nat -A #{chain_o}-arp -p ARP "\
                    "--arp-op Reply -j ACCEPT"
                commands.add :ebtables, "-t nat -N #{chain_o}-rarp -P DROP"
                commands.add :ebtables, "-t nat -A #{chain_o}-rarp -p 0x8035 "\
                    "-d Broadcast --arp-op Request_Reverse "\
                    "--arp-ip-src 0.0.0.0 --arp-ip-dst 0.0.0.0 "\
                    "--arp-mac-src #{nic[:mac]} --arp-mac-dst #{nic[:mac]} "\
                    "-j ACCEPT"
                commands.add :ebtables, "-t nat -N #{chain_o} -P ACCEPT"
#            commands.add :ebtables, "-t nat -N #{chain_o}-ip4 -P ACCEPT"
#            commands.add :ebtables, "-t nat -A #{chain_o} -p IPv4 "\
#                "-j #{chain_o}-ip4"
                commands.add :ebtables, "-t nat -A #{chain_o} -p IPv4 "\
                    "-j ACCEPT"
                commands.add :ebtables, "-t nat -A #{chain_o} -p IPv6 "\
                    "-j ACCEPT"
                commands.add :ebtables, "-t nat -A #{chain_o} -p ARP "\
                    "-j #{chain_o}-arp"
                commands.add :ebtables, "-t nat -A #{chain_o} -p 0x8035 "\
                    "-j #{chain_o}-rarp"
                commands.add :ebtables, "-t nat -A POSTROUTING -o #{chain} "\
                    "-j #{chain_o}"

                commands.run!
            end
        end
        @slog.info "activate() VM #{vm_id} END"
        unlock
    end

    def deactivate
        lock
        vm_id = vm['ID']
        parent_id = vm['TEMPLATE/NIC_ALIAS[ATTACH="YES"]/PARENT_ID']
        if parent_id
            ipv4 = vm['TEMPLATE/NIC_ALIAS[ATTACH="YES"]/IP']
            @slog.info "deactivate() VM #{vm_id} parent_id:#{parent_id} #{ipv4} BEGIN"
            chain = "one-#{vm_id}-#{parent_id}"
            deactivate_ebtables(chain, ipv4) if ipv4
        else
            attach_nic_id = vm['TEMPLATE/NIC[ATTACH="YES"]/NIC_ID']
            @slog.info "deactivate() VM #{vm_id} attach_nic_id:#{attach_nic_id} BEGIN"
            process do |nic|
                nic_id = nic[:nic_id]
                next if attach_nic_id and attach_nic_id != nic_id
                chain = "one-#{vm_id}-#{nic_id}"
                deactivate_ebtables(chain)
            end
        end
        @slog.info "deactivate() VM #{vm_id} END"
        unlock
    end

    def deactivate_ebtables(chain, ipv4 = nil)
        commands =  VNMMAD::VNMNetwork::Commands.new
        @slog.info "deactivate_ebtables(#{chain}, #{ipv4})"
        commands.add "sudo -n", "ebtables-save"
        ebtables_nat = commands.run!
        if !ebtables_nat.nil?
            ebtables = Array.new
            ebtables_nat.split("\n").each do |rule|
                if ipv4
                    if rule.match(/-A #{chain}/)
                        rule_e = rule.split
                        @slog.info "[rule] #{rule}"
                        if rule_e[5] == ipv4
                            @slog.info "Delete #{rule}"
                            ebtables.push("-t nat -D #{rule_e[1..-1].join(" ")}")
                        end
                    end
                    next
                end

                # flush chains only if not ipv4 defined (no alias nic)
                if rule.match(/-j #{chain}/)
                    rule_e = rule.split
                    @slog.info "[rule] #{rule}"
                    if rule_e[2] == "-p"
                        ebtables.push("-t nat -F #{rule_e[-1]}")
                        ebtables.push("-t nat -X #{rule_e[-1]}")
                        ebtables.unshift("-t nat -D #{rule_e[1..-1].join(" ")}")
                    else
                        ebtables.push("-t nat -D #{rule_e[1..-1].join(" ")}")
                        ebtables.push("-t nat -F #{rule_e[-1]}")
                        ebtables.push("-t nat -X #{rule_e[-1]}")
                    end
                end
            end
            if ebtables.any?
                ebtables.each { |c| @slog.info "[run] ebtables #{c}" }
                ebtables.each { |c| commands.add :ebtables, c }
                commands.run!
            end
        end
    end

end
