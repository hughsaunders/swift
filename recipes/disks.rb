#
# Copyright 2011, Dell
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author: andi abes
# Supporting butchery by: ron pedde <ron.pedde@rackspace.com>

include_recipe "osops-utils"

%q(xfsprogs parted util-linux).each do |pkg|
  package pkg do
    action :upgrade
  end
end

all_disks = eval(node[:swift][:disk_enum_expr])

Chef::Log.info("All disks: #{all_disks.keys.join(',')}")

filters = node[:swift][:disk_test_filter]

to_use_disks={}

candidates_expression="all_disks.select{|candidate,info| (" +
  filters.map{|x| "(#{x})"}.join(" and ") + ")}"
to_use_disks=Hash[eval(candidates_expression)]

Chef::Log.info("will use these disks: #{to_use_disks.keys.join(', ')} based on filter #{candidates_expression}")

if node[:swift].has_key?(:expected_disks)
  expected_disks = eval(node[:swift][:expected_disks])
  if expected_disks != to_use_disks.keys
    Chef::Log.info("Unexpected disks")
    raise "Unexpected Disks: not #{expected_disks.join(',')}"
  end
end

node[:swift][:state] ||= {}
node[:swift][:state][:devs] = {}

to_use_disks.each { |k,v|
  next if !File.exists?("/dev/#{k}")

  target_suffix= "#{k}1"
  target_dev = "/dev/#{target_suffix}"

  Chef::Log.info("target dev: #{target_dev}")

  swift_disk "/dev/#{k}" do
    Chef::Log.info "processing device #{target_dev}"
    part [{ :type => "xfs", :size => :remaining} ]
    action :ensure_exists
  end

  # should make a unique label on this and mount by label
  execute "make xfs filesystem on #{k}" do
    # jmaltin added "-f" to force creation.  Probably a bad idea."
    command "mkfs.xfs -f -i size=512 #{target_dev}"
    ## test if the FS is already an XFS file system.
    not_if "xfs_admin -l #{target_dev}"
  end

  target_uuid = `blkid #{target_dev} -s UUID -o value`.strip

  directory "/srv/node/#{target_uuid}" do
    group "swift"
    owner "swift"
    recursive true
    action :create
  end

  execute "mount-#{target_uuid}" do
    command "sudo mount /srv/node/#{target_uuid}"
    action :nothing
  end

  mount "/srv/node/#{target_uuid}" do
    device target_uuid
    device_type :uuid
    options "noatime,nodiratime,nobarrier,logbufs=8"
    dump 0
    fstype "xfs"
    action :enable
    notifies :run, resources(:execute => "mount-#{target_uuid}"), :immediately
  end

  target_size = `sfdisk -s #{target_dev}`.to_i / 1024 # in Mb
  target_mounted = system("mount | grep #{target_uuid}")
  target_ip = IPManagement.get_ip_for_net("swift", node)

  ####
  # publish the disks
  node[:swift][:state][:devs][target_uuid] = {
    :device => target_suffix,
    :size => target_size,
    :uuid => target_uuid,
    :mounted => target_mounted,
    :ip => target_ip }
}
