require "common/common"
require "time"

module Bosh::AwsCloud
  class InstanceManager
    include Helpers

    class DiskInfo
      attr_reader :size, :count
      def initialize(size, count)
        @size = size
        @count = count
      end
    end

    InstanceStorageMap = {
        # previous generation
        'm1.small' => DiskInfo.new(160, 1),
        'm1.medium' => DiskInfo.new(410, 1),
        'm1.large' => DiskInfo.new(420, 2),
        'm1.xlarge' => DiskInfo.new(420, 4),

        'c1.medium' => DiskInfo.new(350, 1),
        'c1.xlarge' => DiskInfo.new(420, 4),

        'cc2.8xlarge' => DiskInfo.new(840, 4),

        'cg1.4xlarge' => DiskInfo.new(840, 2),

        'm2.xlarge' => DiskInfo.new(420, 1),
        'm2.2xlarge' => DiskInfo.new(850, 1),
        'm2.4xlarge' => DiskInfo.new(840, 2),

        'cr1.8xlarge' => DiskInfo.new(120, 2),

        'hi1.4xlarge' => DiskInfo.new(1024, 2),

        'hs1.8xlarge' => DiskInfo.new(2000, 24),

        # current generation
        'm3.medium' => DiskInfo.new(4, 1),
        'm3.large' => DiskInfo.new(32, 1),
        'm3.xlarge' => DiskInfo.new(40, 2),
        'm3.2xlarge' => DiskInfo.new(80, 2),

        'c3.large' => DiskInfo.new(16, 2),
        'c3.xlarge' => DiskInfo.new(40, 2),
        'c3.2xlarge' => DiskInfo.new(80, 2),
        'c3.4xlarge' => DiskInfo.new(160, 2),
        'c3.8xlarge' => DiskInfo.new(320, 2),

        'r3.large' => DiskInfo.new(32, 1),
        'r3.xlarge' => DiskInfo.new(80, 1),
        'r3.2xlarge' => DiskInfo.new(160, 1),
        'r3.4xlarge' => DiskInfo.new(320, 1),
        'r3.8xlarge' => DiskInfo.new(320, 2),

        'g2.2xlarge' => DiskInfo.new(60, 1),
        'g2.8xlarge' => DiskInfo.new(120, 2),

        'i2.xlarge' => DiskInfo.new(800, 1),
        'i2.2xlarge' => DiskInfo.new(800, 2),
        'i2.4xlarge' => DiskInfo.new(800, 4),
        'i2.8xlarge' => DiskInfo.new(800, 8),

        'd2.xlarge' => DiskInfo.new(2000, 3),
        'd2.2xlarge' => DiskInfo.new(2000, 6),
        'd2.4xlarge' => DiskInfo.new(2000, 12),
        'd2.8xlarge' => DiskInfo.new(2000, 24)
    }

    def initialize(region, registry, elb, az_selector, logger)
      @region = region
      @registry = registry
      @elb = elb
      @az_selector = az_selector
      @logger = logger
    end

    def create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)
      instance_params, block_device_info = build_instance_params(stemcell_id, resource_pool, networks_spec, disk_locality, options)

      @logger.info("Creating new instance with: #{instance_params.inspect}")

      aws_instance = create_aws_instance(instance_params, resource_pool["spot_bid_price"])

      instance = Instance.new(aws_instance, @registry, @elb, @logger)

      begin
        # We need to wait here for the instance to be running, as if we are going to
        # attach to a load balancer, the instance must be running.
        instance.wait_for_running
        instance.attach_to_load_balancers(resource_pool['elbs'] || [])
      rescue => e
        @logger.warn("Failed to configure instance '#{instance.id}': #{e.inspect}")
        begin
          instance.terminate
        rescue => e
          @logger.error("Failed to terminate mis-configured instance '#{instance.id}': #{e.inspect}")
        end
        raise
      end

      block_device_agent_info = block_device_info
                                    .group_by { |v| v[:bosh_type] }
                                    .map { |type, devices| {type => devices.map { |device| {"path" => device[:device_name] }}}}
                                    .inject({}) { |a, b| a.merge(b) }

      return instance, block_device_agent_info
    end

    # @param [String] instance_id EC2 instance id
    def find(instance_id)
      Instance.new(@region.instances[instance_id], @registry, @elb, @logger)
    end

    private

    def build_instance_params(stemcell_id, resource_pool, networks_spec, disk_locality, options)
      virtualization_type = @region.images[stemcell_id].virtualization_type
      block_device_info = block_device_mapping(virtualization_type, resource_pool)

      instance_params = {count: 1}
      instance_params[:image_id] = stemcell_id
      instance_params[:instance_type] = resource_pool["instance_type"]
      instance_params[:block_device_mappings] = block_device_info.map { |entry| entry.reject{ |k| k == :bosh_type } }
      instance_params[:placement_group] = resource_pool["placement_group"] if resource_pool["placement_group"]
      instance_params[:dedicated_tenancy] = true if resource_pool["tenancy"] == "dedicated"

      set_user_data_parameter(instance_params, networks_spec)
      set_key_name_parameter(instance_params, resource_pool["key_name"], options["aws"]["default_key_name"])
      set_security_groups_parameter(instance_params, networks_spec, options["aws"]["default_security_groups"])
      set_vpc_parameters(instance_params, networks_spec)
      set_iam_instance_profile_parameter(instance_params, resource_pool["iam_instance_profile"], options["aws"]["default_iam_instance_profile"])
      set_availability_zone_parameter(
        instance_params,
        (disk_locality || []).map { |volume_id| @region.volumes[volume_id].availability_zone.to_s },
        resource_pool["availability_zone"],
        (instance_params[:subnet].availability_zone_name if instance_params[:subnet])
      )

      return instance_params, block_device_info
    end

    def create_aws_instance(instance_params, spot_bid_price)
      if spot_bid_price
        @logger.info("Launching spot instance...")
        spot_manager = Bosh::AwsCloud::SpotManager.new(@region)
        spot_manager.create(instance_params, spot_bid_price)
      else
        # Retry the create instance operation a couple of times if we are told that the IP
        # address is in use - it can happen when the director recreates a VM and AWS
        # is too slow to update its state when we have released the IP address and want to
        # realocate it again.
        errors = [AWS::EC2::Errors::InvalidIPAddress::InUse, AWS::EC2::Errors::RequestLimitExceeded]
        Bosh::Common.retryable(sleep: instance_create_wait_time, tries: 20, on: errors) do |tries, error|
          @logger.info("Launching on demand instance...")
          @logger.warn("IP address was in use: #{error}") if tries > 0
          @region.instances.create(instance_params)
        end
      end
    end

    def instance_create_wait_time; 30; end

    def block_device_mapping(virtualization_type, resource_pool)
      ephemeral_disk_options = resource_pool.fetch("ephemeral_disk", {})

      ephemeral_volume_size_in_mb = ephemeral_disk_options.fetch('size', 0)
      ephemeral_volume_size_in_gb = (ephemeral_volume_size_in_mb / 1024.0).ceil
      ephemeral_volume_type = ephemeral_disk_options.fetch('type', 'standard')
      instance_type = resource_pool.fetch('instance_type', '')
      raw_instance_storage = resource_pool.fetch('raw_instance_storage', false)

      local_disk_info = InstanceManager::InstanceStorageMap[instance_type]
      if raw_instance_storage && local_disk_info.nil?
        raise Bosh::Clouds::CloudError, "raw_instance_storage requested for instance type #{instance_type} that does not have instance storage"
      end

      if raw_instance_storage || local_disk_info.nil? || local_disk_info.size < ephemeral_volume_size_in_gb
        @logger.debug('Use EBS storage to create the virtual machine')

        ephemeral_volume_size_in_gb = 10 if ephemeral_volume_size_in_gb == 0
        block_device_mapping_param = ebs_ephemeral_disk_mapping ephemeral_volume_size_in_gb, ephemeral_volume_type
      else
        @logger.debug('Use instance storage to create the virtual machine')
        block_device_mapping_param = default_ephemeral_disk_mapping
      end

      block_device_mapping_param[0][:bosh_type] = 'ephemeral'

      if raw_instance_storage
        next_device = first_raw_ephemeral_device(virtualization_type)
        for i in 0..local_disk_info.count - 1 do
          block_device_mapping_param << {
              virtual_name: "ephemeral#{i}",
              device_name: next_device,
              bosh_type: "raw_ephemeral",
          }
          next_device = next_device.next
        end
      end

      block_device_mapping_param
    end

    def first_raw_ephemeral_device(virtualization_type)
      case virtualization_type
        when :hvm
          '/dev/xvdba'
        when :paravirtual
          '/dev/sdc'
        else
          raise Bosh::Clouds::CloudError, "unknown virtualization type #{virtualization_type}"
      end
    end

    def set_key_name_parameter(instance_params, resource_pool_key_name, default_aws_key_name)
      key_name = resource_pool_key_name || default_aws_key_name
      instance_params[:key_name] = key_name unless key_name.nil?
    end

    def set_security_groups_parameter(instance_params, networks_spec, default_security_groups)
      security_groups = extract_security_groups(networks_spec)
      if security_groups.empty?
        validate_and_prepare_security_groups_parameter(instance_params, default_security_groups)
      else
        validate_and_prepare_security_groups_parameter(instance_params, security_groups)
      end
    end

    def set_vpc_parameters(instance_params, network_spec)
      manual_network_spec = network_spec.values.select { |spec| ["manual", nil].include? spec["type"] }.first
      if manual_network_spec
        instance_params[:private_ip_address] = manual_network_spec["ip"]
      end

      subnet_network_spec = network_spec.values.select { |spec|
        ["manual", nil, "dynamic"].include?(spec["type"]) &&
          spec.fetch("cloud_properties", {}).has_key?("subnet")
      }.first
      if subnet_network_spec
        instance_params[:subnet] = @region.subnets[subnet_network_spec["cloud_properties"]["subnet"]]
      end
    end

    def set_availability_zone_parameter(instance_params, volume_zones, resource_pool_zone, subnet_zone)
      availability_zone = @az_selector.common_availability_zone(volume_zones, resource_pool_zone, subnet_zone)
      instance_params[:availability_zone] = availability_zone if availability_zone
    end

    def set_user_data_parameter(instance_params, networks_spec)
      user_data = {registry: {endpoint: @registry.endpoint}}

      spec_with_dns = networks_spec.values.select { |spec| spec.has_key? "dns" }.first
      user_data[:dns] = {nameserver: spec_with_dns["dns"]} if spec_with_dns

      instance_params[:user_data] = Yajl::Encoder.encode(user_data)
    end

    def set_iam_instance_profile_parameter(instance_params, resource_pool_iam_instance_profile, default_aws_iam_instance_profile)
      iam_instance_profile = resource_pool_iam_instance_profile || default_aws_iam_instance_profile
      instance_params[:iam_instance_profile] = iam_instance_profile unless iam_instance_profile.nil?
    end

    def validate_and_prepare_security_groups_parameter(instance_params, security_groups)
      return if security_groups.nil? || security_groups.empty?

      is_id = is_security_group_id?(security_groups.first)

      security_groups.drop(1).each do |security_group|
        unless is_security_group_id?(security_group) == is_id
          raise Bosh::Clouds::CloudError, 'security group names and ids can not be used together in security groups'
        end
      end

      if is_id
        instance_params[:security_group_ids] = security_groups
      else
        instance_params[:security_groups] = security_groups
      end
    end

    def is_security_group_id?(security_group)
      security_group.start_with?('sg-') && security_group.size == 11
    end
  end
end
