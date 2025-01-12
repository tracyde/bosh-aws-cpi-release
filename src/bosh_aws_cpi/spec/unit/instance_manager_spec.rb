require 'spec_helper'
require 'bosh/registry/client'

describe Bosh::AwsCloud::InstanceManager do
  subject(:instance_manager) { described_class.new(region, registry, elb, az_selector, logger) }
  let(:region) do
    _, region = mock_ec2
    region
  end
  let(:registry) { double('Bosh::Registry::Client', :endpoint => 'http://...', :update_settings => nil) }
  let(:elb) { double('AWS::ELB', load_balancers: nil) }
  let(:az_selector) { instance_double('Bosh::AwsCloud::AvailabilityZoneSelector', common_availability_zone: 'us-east-1a') }
  let(:logger) { Logger.new('/dev/null') }

  describe '#create' do
    subject(:create_instance) do
      instance_manager.create(
        agent_id,
        stemcell_id,
        resource_pool,
        networks_spec,
        disk_locality,
        environment,
        instance_options
      )
    end

    before { allow(region).to receive(:subnets).and_return('sub-123456' => fake_aws_subnet) }
    let(:fake_aws_subnet) { instance_double('AWS::EC2::Subnet').as_null_object }

    let(:aws_instance_params) do
      {
        count: 1,
        image_id: 'stemcell-id',
        instance_type: 'm1.small',
        user_data: '{"registry":{"endpoint":"http://..."},"dns":{"nameserver":"foo"}}',
        subnet: fake_aws_subnet,
        security_groups: ['baz'],
        private_ip_address: '1.2.3.4',
        availability_zone: 'us-east-1a',
        block_device_mappings: [{
                                    device_name: '/dev/sdb',
                                    virtual_name: 'ephemeral0',
                                }]
      }
    end

    before { allow(region).to receive(:instances).and_return(aws_instances) }
    let(:aws_instances) { instance_double('AWS::EC2::InstanceCollection') }

    let(:aws_instance) { instance_double('AWS::EC2::Instance', id: 'i-12345678') }
    let(:aws_client) { double(AWS::EC2::Client) }

    let(:agent_id) { 'agent-id' }
    let(:stemcell_id) { 'stemcell-id' }
    let(:resource_pool) { {'instance_type' => 'm1.small'} }
    let(:networks_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'dns' => 'foo',
          'cloud_properties' => {'security_groups' => 'baz'}
        },
        'other' => {
          'type' => 'manual',
          'cloud_properties' => {'subnet' => 'sub-123456'},
          'ip' => '1.2.3.4'
        }
      }
    end
    let(:disk_locality) { nil }
    let(:environment) { nil }
    let(:instance_options) { {'aws' => {'region' => 'us-east-1'}} }
    let(:block_devices) {[
        {
            device_name: 'fake-image-root-device',
            ebs: {
                volume_size: 17
            }
        }
    ]}

    before do
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: :running)
      allow(region).to receive(:images).and_return(
        {
          stemcell_id => instance_double('AWS::EC2::Image',
            block_devices: block_devices,
            root_device_name: 'fake-image-root-device',
            virtualization_type: :hvm
          )
        }
      )
    end

    it 'should ask AWS to create an instance in the given region, with parameters built up from the given arguments' do
      expect(aws_instances).to receive(:create).with(aws_instance_params).and_return(aws_instance)

      create_instance
    end

    context 'when iam instance options are passed in' do
      context 'via the resource pool' do
        let(:resource_pool) { {'instance_type' => 'm1.small', 'iam_instance_profile' => 'some_iam_profile'} }

        it 'sends creates the instance with the passed in profile' do
          augmented_aws_instance_params = aws_instance_params.merge(iam_instance_profile: 'some_iam_profile')
          expect(aws_instances).to receive(:create).with(augmented_aws_instance_params).and_return(aws_instance)

          create_instance
        end
      end

      context 'via the instance options' do
        let(:instance_options) { {'aws' => {'region' => 'us-east-1', 'default_iam_instance_profile' => 'some_default_iam_profile'} } }

        it 'sends creates the instance with the passed in profile' do
          augmented_aws_instance_params = aws_instance_params.merge(iam_instance_profile: 'some_default_iam_profile')
          expect(aws_instances).to receive(:create).with(augmented_aws_instance_params).and_return(aws_instance)

          create_instance
        end
      end

      context 'via the resource pool and instance options' do
        let(:instance_options) { {'aws' => {'region' => 'us-east-1', 'default_iam_instance_profile' => 'some_default_iam_profile'} } }
        let(:resource_pool) { {'instance_type' => 'm1.small', 'iam_instance_profile' => 'some_iam_profile'} }

        it 'sends creates the instance with the passed in profile' do
          augmented_aws_instance_params = aws_instance_params.merge(iam_instance_profile: 'some_iam_profile')
          expect(aws_instances).to receive(:create).with(augmented_aws_instance_params).and_return(aws_instance)

          create_instance
        end
      end
    end

    context 'when spot_bid_price is specified' do
      let(:resource_pool) do
        # NB: The spot_bid_price param should trigger spot instance creation
        {'spot_bid_price'=>0.15, 'instance_type' => 'm1.small', 'key_name' => 'bar'}
      end

      it 'should ask AWS to create a SPOT instance in the given region, when resource_pool includes spot_bid_price' do
        allow(region).to receive(:client).and_return(aws_client)
        allow(region).to receive(:subnets).and_return('sub-123456' => fake_aws_subnet)
        allow(region).to receive(:instances).and_return('i-12345678' => aws_instance)

        # need to translate security group names to security group ids
        sg1 = instance_double('AWS::EC2::SecurityGroup', security_group_id:'sg-baz-1234')
        allow(sg1).to receive(:name).and_return('baz')
        allow(region).to receive(:security_groups).and_return([sg1])


        # Should not recieve an ondemand instance create call
        expect(aws_instances).to_not receive(:create).with(aws_instance_params)

        #Should rather recieve a spot instance request
        expect(aws_client).to receive(:request_spot_instances) do |spot_request|
          expect(spot_request[:spot_price]).to eq('0.15')
          expect(spot_request[:instance_count]).to eq(1)
          expect(spot_request[:launch_specification]).to eq({
            :image_id=>'stemcell-id',
            :key_name=>'bar',
            :instance_type=>'m1.small',
            :user_data=>Base64.encode64('{"registry":{"endpoint":"http://..."},"dns":{"nameserver":"foo"}}'),
            :placement=> { :availability_zone=>'us-east-1a' },
            :network_interfaces=>[ {
              :subnet_id=>fake_aws_subnet,
              :groups=>['sg-baz-1234'],
              :device_index=>0,
              :private_ip_address=>'1.2.3.4'
            }]
          })

          # return
          {
            :spot_instance_request_set => [ { :spot_instance_request_id=>'sir-12345c', :other_params_here => 'which are not used' }],
            :request_id => 'request-id-12345'
          }
        end

        # Should poll the spot instance request until state is active
        expect(aws_client).to receive(:describe_spot_instance_requests).
          with(:spot_instance_request_ids=>['sir-12345c']).
          and_return(:spot_instance_request_set => [{:state => 'active', :instance_id=>'i-12345678'}])

        # Should then wait for instance to be running, just like in the case of on deman
        expect(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: :running)

        # Trigger spot instance request
        create_instance
      end
    end

    it 'should retry creating the VM when AWS::EC2::Errors::InvalidIPAddress::InUse raised' do
      allow(region).to receive(:subnets).and_return('sub-123456' => fake_aws_subnet)

      expect(aws_instances).to receive(:create).with(aws_instance_params).and_raise(AWS::EC2::Errors::InvalidIPAddress::InUse)
      expect(aws_instances).to receive(:create).with(aws_instance_params).and_return(aws_instance)
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: :running)

      allow(instance_manager).to receive(:instance_create_wait_time).and_return(0)

      create_instance
    end

    it 'retries creating the VM when the request limit is exceeded' do
      allow(region).to receive(:subnets).and_return('sub-123456' => fake_aws_subnet)

      expect(aws_instances).to receive(:create).with(aws_instance_params).and_raise(AWS::EC2::Errors::RequestLimitExceeded)
      expect(aws_instances).to receive(:create).with(aws_instance_params).and_return(aws_instance)
      allow(Bosh::AwsCloud::ResourceWait).to receive(:for_instance).with(instance: aws_instance, state: :running)

      allow(instance_manager).to receive(:instance_create_wait_time).and_return(0)

      create_instance
    end

    context 'when waiting it to become running fails' do
      before { expect(instance).to receive(:wait_for_running).and_raise(create_err) }
      let(:create_err) { StandardError.new('fake-err') }

      before { allow(Bosh::AwsCloud::Instance).to receive(:new).and_return(instance) }
      let(:instance) { instance_double('Bosh::AwsCloud::Instance', id: 'fake-instance-id') }

      before { expect(aws_instances).to receive(:create).and_return(aws_instance) }

      it 'terminates created instance and re-raises the error if ' do
        expect(instance).to receive(:terminate).with(no_args)

        expect {
          create_instance
        }.to raise_error(create_err)
      end

      context 'when termination of created instance fails' do
        before { allow(instance).to receive(:terminate).and_raise(StandardError.new('fake-terminate-err')) }

        it 're-raises creation error' do
          expect {
            create_instance
          }.to raise_error(create_err)
        end
      end
    end

    context 'when attaching instance to load balancers fails' do
      before { expect(instance).to receive(:attach_to_load_balancers).and_raise(lb_err) }
      let(:lb_err) { StandardError.new('fake-err') }

      before { allow(Bosh::AwsCloud::Instance).to receive(:new).and_return(instance) }
      let(:instance) { instance_double('Bosh::AwsCloud::Instance', id: 'fake-instance-id', wait_for_running: nil) }

      before { expect(aws_instances).to receive(:create).and_return(aws_instance) }

      it 'terminates created instance and re-raises the error' do
        expect(instance).to receive(:terminate).with(no_args)

        expect {
          create_instance
        }.to raise_error(lb_err)
      end

      context 'when termination of created instance fails' do
        before { allow(instance).to receive(:terminate).and_raise(StandardError.new('fake-terminate-err')) }

        it 're-raises creation error' do
          expect {
            create_instance
          }.to raise_error(lb_err)
        end
      end
    end

    describe 'instance parameters' do
      describe 'block_device_mappings' do
        let(:resource_pool) do
          {
            'instance_type' => '',
            'key_name' => 'bar'
          }
        end

        def set_instance_type(type)
          resource_pool['instance_type'] = type
        end

        def set_raw_instance_storage
          resource_pool['raw_instance_storage'] = true
        end

        context 'when ephemeral disk size is specified' do
          before do
            resource_pool['ephemeral_disk'] = { 'size' => 0, 'type' => 'gp2' }
          end

          def set_ephemeral_disk_size(size)
            resource_pool['ephemeral_disk']['size'] = size
          end

          context 'when instance type has instance storage' do
            before { set_instance_type 'm3.xlarge' }

            context 'when raw_instance_storage is false' do
              it 'uses ebs storage when specified ephemeral disk size is bigger than instance storage' do
                set_ephemeral_disk_size 51200

                allow(aws_instances).to receive(:create) { aws_instance }

                expect(logger).to receive(:debug).with('Use EBS storage to create the virtual machine')

                create_instance

                expect(aws_instances).to have_received(:create) do |instance_params|
                  expect(instance_params[:block_device_mappings]).to eq([
                    {
                      device_name: '/dev/sdb',
                      ebs: {
                        volume_size: 50,
                        volume_type: 'gp2',
                        delete_on_termination: true,
                      }
                    }])
                end
              end

              it 'uses instance storage when specified ephemeral disk size is not bigger than instance storage' do
                set_ephemeral_disk_size 4000

                allow(aws_instances).to receive(:create) { aws_instance }

                expect(logger).to receive(:debug).with('Use instance storage to create the virtual machine')

                create_instance

                expect(aws_instances).to have_received(:create) do |instance_params|
                  expect(instance_params[:block_device_mappings]).to eq([{
                                                                            device_name: '/dev/sdb',
                                                                            virtual_name: 'ephemeral0',
                                                                        }])
                end
              end
            end

            context 'when raw_instance_storage is true' do
              before do
                set_raw_instance_storage
                set_ephemeral_disk_size 4000
                allow(aws_instances).to receive(:create) { aws_instance }
              end

              it 'creates an ebs volume for the ephemeral disk' do
                expect(logger).to receive(:debug).with('Use EBS storage to create the virtual machine')

                create_instance

                expect(aws_instances).to have_received(:create) do |instance_params|
                  expect(instance_params[:block_device_mappings]).to include(
                    {
                      device_name: '/dev/sdb',
                      ebs: {
                        volume_size: 4,
                        volume_type: 'gp2',
                        delete_on_termination: true,
                      }
                    })
                end
              end

              it 'requests all available instance storage disks to be attached to the instance' do
                create_instance

                expect(aws_instances).to have_received(:create) do |instance_params|
                  expect(instance_params[:block_device_mappings]).to include(
                     {
                       virtual_name: 'ephemeral0',
                       device_name: '/dev/xvdba',
                     })
                  expect(instance_params[:block_device_mappings]).to include(
                     {
                       virtual_name: 'ephemeral1',
                       device_name: '/dev/xvdbb',
                     })
                end
              end

              it 'returns information about the raw ephemeral disks for agent settings' do
                _, disk_info = create_instance
                expect(disk_info).to eq({
                                            "ephemeral" => [{"path" => "/dev/sdb"}],
                                            "raw_ephemeral" => [{"path" => "/dev/xvdba"}, {"path" => "/dev/xvdbb"}],
                                        })
              end

              context 'when the instance is paravirtual' do

                before do
                  allow(region).to receive(:images).and_return(
                     {
                         stemcell_id => instance_double('AWS::EC2::Image',
                                                        block_devices: block_devices,
                                                        root_device_name: 'fake-image-root-device',
                                                        virtualization_type: :paravirtual
                         )
                     }
                 )
                end
                it 'attaches instance disks under /dev/sd[c-z]' do
                  create_instance

                  expect(aws_instances).to have_received(:create) do |instance_params|
                    expect(instance_params[:block_device_mappings]).to include(
                      {
                        virtual_name: 'ephemeral0',
                        device_name: '/dev/sdc',
                      })
                    expect(instance_params[:block_device_mappings]).to include(
                      {
                        virtual_name: 'ephemeral1',
                        device_name: '/dev/sdd',
                      })
                  end
                end
              end
            end
          end

          context 'when instance type does not have instance storage' do
            before do
              set_instance_type 't2.small'
              set_ephemeral_disk_size 6000
            end

            it 'uses ebs storage for ephemeral disk' do
              allow(aws_instances).to receive(:create) { aws_instance }

              create_instance

              expect(aws_instances).to have_received(:create) do |instance_params|
                expect(instance_params[:block_device_mappings]).to eq([
                  {
                    device_name: '/dev/sdb',
                    ebs: {
                      volume_size: 6,
                      volume_type: 'gp2',
                      delete_on_termination: true,
                    }
                  }])
              end
            end

            it 'raises an error when asked for raw instance storage' do
              set_raw_instance_storage
              allow(aws_instances).to receive(:create) { aws_instance }

              expect { create_instance }.to raise_error(
                               Bosh::Clouds::CloudError,
                               "raw_instance_storage requested for instance type t2.small that does not have instance storage")
            end
          end
        end

        context 'when ephemeral disk size is not specified' do
          context 'when instance type has instance storage' do
            before { set_instance_type 'm3.medium' }

            context 'when raw_instance_storage is false' do

              it 'uses the instance storage for ephemeral disk' do
                allow(aws_instances).to receive(:create) { aws_instance }

                create_instance

                expect(aws_instances).to have_received(:create) do |instance_params|
                  expect(instance_params[:block_device_mappings]).to eq([{
                                                                             device_name: '/dev/sdb',
                                                                             virtual_name: 'ephemeral0',
                                                                         }])
                end
              end
            end

            context 'when raw_instance_storage is true' do
              before do
                set_raw_instance_storage
                allow(aws_instances).to receive(:create) { aws_instance }
              end

              it 'creates a 10GB ebs disk for ephemeral storage' do
                create_instance

                expect(aws_instances).to have_received(:create) do |instance_params|
                  expect(instance_params[:block_device_mappings]).to include(
                    {
                      device_name: '/dev/sdb',
                      ebs: {
                        volume_size: 10,
                        volume_type: 'standard',
                        delete_on_termination: true,
                      }
                    })
                end
              end

              it 'requests all available instance storage disks to be attached to the instance' do
                create_instance

                expect(aws_instances).to have_received(:create) do |instance_params|
                  expect(instance_params[:block_device_mappings]).to include(
                    {
                      virtual_name: 'ephemeral0',
                      device_name: '/dev/xvdba',
                    })
                end
              end
            end
          end

          context 'when instance type does not have instance storage' do
            before { set_instance_type 't2.small' }

            it 'uses a default 10GB ebs storage for ephemeral disk' do
              allow(aws_instances).to receive(:create) { aws_instance }

              create_instance

              expect(aws_instances).to have_received(:create) do |instance_params|
                expect(instance_params[:block_device_mappings]).to eq([
                  {
                    device_name: '/dev/sdb',
                    ebs: {
                      volume_size: 10,
                      volume_type: 'standard',
                      delete_on_termination: true,
                    }
                  }])
              end
            end
          end
        end
      end

      describe 'key_name' do
        context 'when resource pool has key name' do
          let(:resource_pool) do
            {
              'key_name' => 'foo',
            }
          end

          let(:instance_options) do
            {
              'aws' => {
                'default_key_name' => 'bar',
              }
            }
          end

          it 'should set the key name' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:key_name]).to eq('foo')
            end
          end
        end

        context 'when aws options have default key name' do
          let(:instance_options) do
            {
              'aws' => {
                'default_key_name' => 'bar',
              }
            }
          end

          it 'should set the key name' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:key_name]).to eq('bar')
            end
          end
        end

        it 'should not have a key name instance parameter by default' do
          allow(aws_instances).to receive(:create) { aws_instance }

          create_instance

          expect(aws_instances).to have_received(:create) do |instance_params|
            expect(instance_params[:key_name]).to be_nil
          end
        end
      end

      describe 'security_groups_parameter' do
        let(:sg_name_1) { 'yay' }
        let(:sg_name_2) { 'aya' }
        let(:sg_name_3) { 'default' }
        let(:sg_id_1) { 'sg-12345678' }
        let(:sg_id_2) { 'sg-23456789' }
        let(:sg_id_3) { 'sg-01234567' }

        let(:networks_spec) do
          {
              'network' => {'cloud_properties' => {}},
              'artwork' => {'cloud_properties' => {}}
          }
        end

        let(:instance_options) do
          {
              'aws' => {}
          }
        end

        before do
          allow(aws_instances).to receive(:create) { aws_instance }
        end

        def verify_security_group_parameter(parameter_name, parameter_value)
          create_instance

          expect(aws_instances).to have_received(:create) do |instance_params|
            expect(instance_params[parameter_name]).to match_array(parameter_value)
          end
        end

        def verify_error
          expect{
            create_instance
          }.to raise_error Bosh::Clouds::CloudError, /security group names and ids can not be used together in security groups/
        end

        context 'when the networks specs have security groups' do
          it 'returns a unique list of the specified group names' do
            networks_spec['network']['cloud_properties']['security_groups'] = sg_name_1
            networks_spec['artwork']['cloud_properties']['security_groups'] = [sg_name_1, sg_name_2]

            verify_security_group_parameter(:security_groups, [sg_name_1, sg_name_2])
          end

          it 'returns a unique list of the specified group ids' do
            networks_spec['network']['cloud_properties']['security_groups'] = sg_id_1
            networks_spec['artwork']['cloud_properties']['security_groups'] = [sg_id_1, sg_id_2]

            verify_security_group_parameter(:security_group_ids, [sg_id_1, sg_id_2])
          end

          it 'raises an error when both ids and names are specified in security_groups' do
            networks_spec['network']['cloud_properties']['security_groups'] = sg_name_1
            networks_spec['artwork']['cloud_properties']['security_groups'] = [sg_id_1, sg_id_2]

            verify_error
          end
        end

        context 'when aws options have default_security_groups' do
          it 'returns the list of default AWS group names' do
            instance_options['aws']['default_security_groups'] = [sg_name_1, sg_name_3]

            verify_security_group_parameter(:security_groups, [sg_name_1, sg_name_3])
          end

          it 'returns the list of default AWS group ids' do
            instance_options['aws']['default_security_groups'] = [sg_id_1, sg_id_3]

            verify_security_group_parameter(:security_group_ids, [sg_id_1, sg_id_3])
          end

          it 'raises an error when default_security_groups contains both ids and names' do
            instance_options['aws']['default_security_groups'] = [sg_name_3, sg_id_3]

            verify_error
          end
        end

        context 'when aws options have both security_groups and default_security_groups configured' do
          it 'returns a unique list of the specified group names' do
            networks_spec['network']['cloud_properties']['security_groups'] = sg_name_1
            networks_spec['artwork']['cloud_properties']['security_groups'] = [sg_name_1, sg_name_2]
            instance_options['aws']['default_security_groups'] = [sg_name_3]

            verify_security_group_parameter(:security_groups, [sg_name_1, sg_name_2])
          end

          it 'returns a unique list of the specified group ids' do
            networks_spec['network']['cloud_properties']['security_groups'] = sg_id_1
            networks_spec['artwork']['cloud_properties']['security_groups'] = [sg_id_1, sg_id_2]
            instance_options['aws']['default_security_groups'] = [sg_id_3]

            verify_security_group_parameter(:security_group_ids, [sg_id_1, sg_id_2])
          end

          it 'raises an error when both ids and names are specified in security_groups' do
            networks_spec['network']['cloud_properties']['security_groups'] = sg_name_1
            networks_spec['artwork']['cloud_properties']['security_groups'] = [sg_id_1, sg_id_2]
            instance_options['aws']['default_security_groups'] = [sg_id_3]

            verify_error
          end
        end
      end

      describe 'vpc_parameters' do
        context 'when there is not a manual network in the specs' do
          let(:networks_spec) do
            {
              'network' => {
                'type' => 'designed by robots',
                'ip' => '1.2.3.4',
              }
            }
          end

          it 'should not set the private IP address parameters' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:private_ip_address]).to be_nil
            end
          end
        end

        context 'when there is a manual network in the specs' do
          let(:networks_spec) do
            {
              'network' => {
                'type' => 'manual',
                'ip' => '1.2.3.4',
              }
            }
          end

          it 'should set the private IP address parameters' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:private_ip_address]).to eq('1.2.3.4')
            end
          end
        end

        context 'when there is a network in the specs with unspecified type' do
          let(:networks_spec) do
            {
              'network' => {
                'ip' => '1.2.3.4',
                'cloud_properties' => {'subnet' => 'sub-123456'},
              }
            }
          end

          it 'should set the private IP address parameters for that network (treat it as manual)' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:private_ip_address]).to eq('1.2.3.4')
            end
          end
        end

        context 'when there is a subnet in the cloud_properties in the specs' do
          let(:networks_spec) do
            {
              'network' => {
                'ip' => '1.2.3.4',
                'cloud_properties' => {'subnet' => 'sub-123456'},
              }
            }
          end

          it 'should set the subnet parameter' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:subnet]).to eq(fake_aws_subnet)
            end
          end

          context 'and network type is dynamic' do
            let(:networks_spec) do
              {
                'network' => {
                  'type' => 'dynamic',
                  'cloud_properties' => {'subnet' => 'sub-123456'},
                }
              }
            end

            it 'should set the subnet parameter' do
              allow(aws_instances).to receive(:create) { aws_instance }

              create_instance

              expect(aws_instances).to have_received(:create) do |instance_params|
                expect(instance_params[:subnet]).to eq(fake_aws_subnet)
              end
            end
          end

          context 'and network type is manual' do
            let(:networks_spec) do
              {
                'network' => {
                  'type' => 'manual',
                  'cloud_properties' => {'subnet' => 'sub-123456'},
                }
              }
            end

            it 'should set the subnet parameter' do
              allow(aws_instances).to receive(:create) { aws_instance }

              create_instance

              expect(aws_instances).to have_received(:create) do |instance_params|
                expect(instance_params[:subnet]).to eq(fake_aws_subnet)
              end
            end
          end

          context 'and network type is not set' do
            let(:networks_spec) do
              {
                'network' => {
                  'cloud_properties' => {'subnet' => 'sub-123456'},
                }
              }
            end

            it 'should set the subnet parameter' do
              allow(aws_instances).to receive(:create) { aws_instance }

              create_instance

              expect(aws_instances).to have_received(:create) do |instance_params|
                expect(instance_params[:subnet]).to eq(fake_aws_subnet)
              end
            end
          end

          context 'and network type is vip' do
            let(:networks_spec) do
              {
                'network' => {
                  'type' => 'vip',
                  'cloud_properties' => {'subnet' => 'sub-123456'},
                }
              }
            end

            it 'should not set the subnet parameter' do
              allow(aws_instances).to receive(:create) { aws_instance }

              create_instance

              expect(aws_instances).to have_received(:create) do |instance_params|
                expect(instance_params[:subnet]).to be_nil
              end
            end
          end
        end

        context 'when there is no subnet in the cloud_properties in the specs' do
          let(:networks_spec) do
            {
              'network' => { 'type' => 'dynamic' }
            }
          end

          it 'should not set the subnet parameter' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:subnet]).to be_nil
            end
          end
        end
      end

      describe 'availability_zone_parameter' do
        let(:az_selector) { instance_double('Bosh::AwsCloud::AvailabilityZoneSelector') }

        context 'if there is a common availability zone specified' do
          before { allow(az_selector).to receive(:common_availability_zone).and_return('fake-zone') }

          it 'sets the availability zone parameter appropriately' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:availability_zone]).to eq('fake-zone')
            end
          end
        end

        context 'if there is no common availability zone' do
          before { allow(az_selector).to receive(:common_availability_zone).and_return(nil) }

          it 'does not set the availability zone parameter' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:availability_zone]).to be_nil
            end
          end
        end
      end

      describe 'user_data_parameter' do
        context 'when a dns configuration is provided' do
          let(:networks_spec) do
            {
              'foo' => {'dns' => 'bar'}
            }
          end

          it 'populates the user data parameter with registry and dns data' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:user_data]).
                to eq('{"registry":{"endpoint":"http://..."},"dns":{"nameserver":"bar"}}')
            end
          end
        end

        context 'when a dns configuration is not provided' do
          let(:networks_spec) do
            {
              'foo' => {'no-dns' => true}
            }
          end

          it 'populates the user data parameter with only the registry data' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:user_data]).
                to eq('{"registry":{"endpoint":"http://..."}}')
            end
          end
        end
      end

      describe 'placement_group' do
        context 'when resource pool has placement group' do
          let(:resource_pool) do
            {
              'placement_group' => 'foo',
            }
          end

          it 'should set the placement group' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:placement_group]).to eq('foo')
            end
          end
        end
      end

      describe 'tenancy_parameter' do
        context 'when resource pool has tenancy parameter' do
          let(:resource_pool) do
            {
              'tenancy' => 'dedicated',
            }
          end

          it 'should set the dedicated_tenancy when tenancy is dedicated' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:dedicated_tenancy]).to be_truthy
            end
          end

          it 'should not set the dedicated_tenancy when tenancy is not dedicated' do
            resource_pool['tenancy'] = 'default'
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:dedicated_tenancy]).to be_nil
            end
          end
        end

        context 'when resource pool does not have tenancy parameter' do
          it 'should not set the dedicated_tenancy' do
            allow(aws_instances).to receive(:create) { aws_instance }

            create_instance

            expect(aws_instances).to have_received(:create) do |instance_params|
              expect(instance_params[:dedicated_tenancy]).to be_nil
            end
          end
        end
      end
    end

  end

  describe '#find' do
    before { allow(region).to receive(:instances).and_return(instance_id => aws_instance) }
    let(:aws_instance) { instance_double('AWS::EC2::Instance', id: instance_id) }
    let(:instance_id) { 'fake-id' }

    it 'returns found instance (even though it might not exist)' do
      instance = instance_double('Bosh::AwsCloud::Instance')

      allow(Bosh::AwsCloud::Instance).to receive(:new).
        with(aws_instance, registry, elb, logger).
        and_return(instance)

      expect(instance_manager.find(instance_id)).to eq(instance)
    end
  end
end
