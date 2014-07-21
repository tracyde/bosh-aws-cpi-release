require "common/common"
require "time"

module Bosh::AwsCloud
  class InstanceManager
    include Helpers

    def initialize(region, registry, elb, az_selector, logger)
      @region = region
      @registry = registry
      @elb = elb
      @az_selector = az_selector
      @logger = logger
    end

    def create(agent_id, stemcell_id, resource_pool, networks_spec, disk_locality, environment, options)
      instance_params = {count: 1}
      instance_params[:image_id] = stemcell_id
      instance_params[:instance_type] = resource_pool["instance_type"]

      set_user_data_parameter(instance_params, networks_spec)

      set_key_name_parameter(instance_params, resource_pool["key_name"], options["aws"]["default_key_name"])

      set_security_groups_parameter(instance_params, networks_spec, options["aws"]["default_security_groups"])

      set_vpc_parameters(instance_params, networks_spec)

      set_availability_zone_parameter(
        instance_params,
        (disk_locality || []).map { |volume_id| @region.volumes[volume_id].availability_zone.to_s },
        resource_pool["availability_zone"],
        (instance_params[:subnet].availability_zone_name if instance_params[:subnet])
      )

      @logger.info("Creating new instance with: #{instance_params.inspect}")

      aws_instance = nil
      if resource_pool["spot_bid_price"]
        @logger.info("Launching spot instance...")
        spot_manager = Bosh::AwsCloud::SpotManager.new(@region)
        aws_instance = spot_manager.create(instance_params, resource_pool["spot_bid_price"])
      else
        # Retry the create instance operation a couple of times if we are told that the IP
        # address is in use - it can happen when the director recreates a VM and AWS
        # is too slow to update its state when we have released the IP address and want to
        # realocate it again.
        errors = [AWS::EC2::Errors::InvalidIPAddress::InUse]
        Bosh::Common.retryable(sleep: instance_create_wait_time, tries: 10, on: errors) do |tries, error|
          @logger.info("Launching on demand instance...")
          @logger.warn("IP address was in use: #{error}") if tries > 0
          aws_instance = @region.instances.create(instance_params)
        end
      end

      instance = Instance.new(aws_instance, @registry, @elb, @logger)

      # We need to wait here for the instance to be running, as if we are going to
      # attach to a load balancer, the instance must be running.
      instance.wait_for_running
      instance.attach_to_load_balancers(resource_pool['elbs'] || [])

      instance
    end

    # @param [String] instance_id EC2 instance id
    def find(instance_id)
      Instance.new(@region.instances[instance_id], @registry, @elb, @logger)
    end

    def set_key_name_parameter(instance_params, resource_pool_key_name, default_aws_key_name)
      key_name = resource_pool_key_name || default_aws_key_name
      instance_params[:key_name] = key_name unless key_name.nil?
    end

    def set_security_groups_parameter(instance_params, networks_spec, default_security_groups)
      security_group_names = extract_security_group_names(networks_spec)
      if security_group_names.empty?
        instance_params[:security_groups] = default_security_groups
      else
        instance_params[:security_groups] = security_group_names
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

    private

    def instance_create_wait_time; 30; end
  end
end
