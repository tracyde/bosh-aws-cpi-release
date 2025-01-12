require 'spec_helper'
require 'bosh/cpi/compatibility_helpers/delete_vm'
require 'tempfile'
require 'logger'
require 'cloud'

describe Bosh::AwsCloud::Cloud do
  before(:all) do
    @access_key_id     = ENV['BOSH_AWS_ACCESS_KEY_ID']       || raise("Missing BOSH_AWS_ACCESS_KEY_ID")
    @secret_access_key = ENV['BOSH_AWS_SECRET_ACCESS_KEY']   || raise("Missing BOSH_AWS_SECRET_ACCESS_KEY")
    @subnet_id         = ENV['BOSH_AWS_SUBNET_ID']           || raise("Missing BOSH_AWS_SUBNET_ID")
    @subnet_zone       = ENV['BOSH_AWS_SUBNET_ZONE']         || raise("Missing BOSH_AWS_SUBNET_ZONE")
    @manual_ip         = ENV['BOSH_AWS_LIFECYCLE_MANUAL_IP'] || raise("Missing BOSH_AWS_LIFECYCLE_MANUAL_IP")
    @elb_id            = ENV['BOSH_AWS_ELB_ID']              || raise("Missing BOSH_AWS_ELB_ID")
  end

  let(:instance_type_with_ephemeral)    { ENV.fetch('BOSH_AWS_INSTANCE_TYPE', 'm3.medium') }
  let(:instance_type_without_ephemeral) { ENV.fetch('BOSH_AWS_INSTANCE_TYPE_WITHOUT_EPHEMERAL', 't2.small') }
  let(:default_key_name)                { ENV.fetch('BOSH_AWS_DEFAULT_KEY_NAME', 'bosh')}
  let(:ami)                             { ENV.fetch('BOSH_AWS_IMAGE_ID', 'ami-b66ed3de') }
  let(:instance_type) { instance_type_with_ephemeral }
  let(:vm_metadata) { { deployment: 'deployment', job: 'cpi_spec', index: '0', delete_me: 'please' } }
  let(:disks) { [] }
  let(:network_spec) { {} }
  let(:resource_pool) { { 'instance_type' => instance_type } }
  let(:registry) { instance_double(Bosh::Registry::Client).as_null_object }

  before {
    allow(Bosh::Registry::Client).to receive(:new).and_return(registry)
    allow(registry).to receive(:read_settings).and_return({})
  }

  # Use subject-bang because AWS SDK needs to be reconfigured
  # with a current test's logger before new AWS::EC2 object is created.
  # Reconfiguration happens via `AWS.config`.
  subject!(:cpi) do
    described_class.new(
      'aws' => {
        'region' => 'us-east-1',
        'default_key_name' => default_key_name,
        'fast_path_delete' => 'yes',
        'access_key_id' => @access_key_id,
        'secret_access_key' => @secret_access_key,
        'default_availability_zone' => @subnet_zone,
      },
      'registry' => {
        'endpoint' => 'fake',
        'user' => 'fake',
        'password' => 'fake'
      }
    )
  end

  before do
    AWS::EC2.new(
      access_key_id:     @access_key_id,
      secret_access_key: @secret_access_key,
    ).instances.tagged('delete_me').each(&:terminate)
  end

  before { allow(Bosh::Clouds::Config).to receive_messages(logger: logger) }
  let(:logger) { Logger.new(STDERR) }

  before { @instance_id = nil }
  after  { cpi.delete_vm(@instance_id) if @instance_id }

  before { @volume_id = nil }
  after  { cpi.delete_disk(@volume_id) if @volume_id }

  extend Bosh::Cpi::CompatibilityHelpers

  describe 'deleting things that no longer exist' do
    it 'raises the appropriate Clouds::Error' do
      # pass in *real* previously deleted ids instead of made up ones
      # because AWS returns Malformed/Invalid errors for fake ids
      expect {
        cpi.delete_vm('i-49f9f169')
      }.to raise_error Bosh::Clouds::VMNotFound

      expect {
        cpi.delete_disk('vol-4c68780b')
      }.to raise_error Bosh::Clouds::DiskNotFound
    end
  end

  context 'manual networking' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'manual',
          'ip' => @manual_ip, # use different IP to avoid race condition
          'cloud_properties' => { 'subnet' => @subnet_id }
        }

      }
    end

    context 'resource_pool specifies elb for instance' do
      let(:resource_pool) { { 'instance_type' => instance_type, 'elbs' => [@elb_id] } }

      it 'registers new instance with elb' do
        begin
          stemcell_id = cpi.create_stemcell('/not/a/real/path', {'ami' => {'us-east-1' => ami}})
          vm_id = cpi.create_vm(
            nil,
            stemcell_id,
            resource_pool,
            network_spec,
            nil,
          )
          aws_params = {
            'access_key_id' => @access_key_id,
            'secret_access_key' => @secret_access_key
          }
            elb_client = AWS::ELB::Client.new(aws_params)
          instances = elb_client.describe_load_balancers({:load_balancer_names => [@elb_id]})[:load_balancer_descriptions]
                        .first[:instances].first[:instance_id]
          expect(instances).to include(vm_id)


          cpi.delete_vm(vm_id)
          vm_id=nil
          instances = elb_client.describe_load_balancers({:load_balancer_names => [@elb_id]})[:load_balancer_descriptions]
                        .first[:instances]
          expect(instances).to be_empty
        ensure
          cpi.delete_stemcell(stemcell_id) if stemcell_id
          cpi.delete_vm(vm_id) if vm_id
        end
      end
    end

    context 'without existing disks' do
      it 'should exercise the vm lifecycle' do
        vm_lifecycle do |instance_id|
          volume_id = cpi.create_disk(2048, {}, instance_id)
          expect(volume_id).not_to be_nil
          expect(cpi.has_disk?(volume_id)).to be(true)

          cpi.attach_disk(instance_id, volume_id)

          snapshot_metadata = vm_metadata.merge(
            bosh_data: 'bosh data',
            instance_id: 'instance',
            agent_id: 'agent',
            director_name: 'Director',
            director_uuid: '6d06b0cc-2c08-43c5-95be-f1b2dd247e18',
          )

          snapshot_id = cpi.snapshot_disk(volume_id, snapshot_metadata)
          expect(snapshot_id).not_to be_nil

          snapshot = cpi.ec2.snapshots[snapshot_id]
          expect(snapshot.tags.device).to eq '/dev/sdf'
          expect(snapshot.tags.agent_id).to eq 'agent'
          expect(snapshot.tags.instance_id).to eq 'instance'
          expect(snapshot.tags.director_name).to eq 'Director'
          expect(snapshot.tags.director_uuid).to eq '6d06b0cc-2c08-43c5-95be-f1b2dd247e18'

          expect(snapshot.tags[:Name]).to eq 'deployment/cpi_spec/0/sdf'

          cpi.delete_snapshot(snapshot_id)

          Bosh::Common.retryable(tries: 20, on: Bosh::Clouds::DiskNotAttached, sleep: lambda { |n, _| [2**(n-1), 30].min }) do
            cpi.detach_disk(instance_id, volume_id)
            true
          end
        end
      end
    end

    context 'with existing disks' do
      let!(:existing_volume_id) { cpi.create_disk(2048, {}) }
      let(:disks) { [existing_volume_id] }
      after  { cpi.delete_disk(existing_volume_id) if existing_volume_id }

      it 'can excercise the vm lifecycle and list the disks' do
        vm_lifecycle do |instance_id|
          volume_id = cpi.create_disk(2048, {}, instance_id)
          expect(volume_id).not_to be_nil
          expect(cpi.has_disk?(volume_id)).to be(true)

          cpi.attach_disk(instance_id, volume_id)
          expect(cpi.get_disks(instance_id)).to include(volume_id)

          Bosh::Common.retryable(tries: 20, on: Bosh::Clouds::DiskNotAttached, sleep: lambda { |n, _| [2**(n-1), 30].min }) do
            cpi.detach_disk(instance_id, volume_id)
            true
          end
        end
      end
    end

    it 'can create encrypted disks' do
      vm_lifecycle do |instance_id|
        volume_id = cpi.create_disk(2048, {'encrypted' => true}, instance_id)
        expect(volume_id).not_to be_nil
        expect(cpi.has_disk?(volume_id)).to be(true)

        encrypted_volume = cpi.ec2.volumes[volume_id]
        expect(encrypted_volume.encrypted?).to be(true)
      end
    end

    context 'when ephemeral_disk properties are specified' do
      let(:resource_pool) do
        {
          'instance_type' => instance_type,
          'ephemeral_disk' => {
            'size' => 4 * 1024,
            'type' => 'gp2'
          }
        }
      end
      let(:instance_type) { instance_type_without_ephemeral }

      it 'requests ephemeral disk with the specified size' do
        vm_lifecycle do |instance_id|
          disks = cpi.get_disks(instance_id)
          expect(disks.size).to eq(2)

          ephemeral_volume = cpi.ec2.volumes[disks[1]]
          expect(ephemeral_volume.size).to eq(4)
        end
      end
    end

    context 'when raw_instance_storage is true' do
      let(:resource_pool) do
        {
            'instance_type' => instance_type,
            'raw_instance_storage' => true,
            'ephemeral_disk' => {
                'size' => 4 * 1024,
                'type' => 'gp2'
            }
        }
      end
      let(:instance_type) { instance_type_with_ephemeral }

      it 'requests all available instance disks and puts the mappings in the registry' do
        vm_lifecycle do |instance_id|
          expect(registry).to have_received(:update_settings).with(instance_id, hash_including({
                "disks" => {
                    "system" => "/dev/xvda",
                    "persistent" => {},
                    "ephemeral" => "/dev/sdb",
                    "raw_ephemeral" => [{"path" => "/dev/xvdba"}]
                }
            }))
        end
      end
    end

    context 'when vm with attached disk is removed' do
      it 'should wait for 10 mins to attach disk/delete disk ignoring VolumeInUse error' do
        begin
          disk_id = cpi.create_disk(2048, {})
          expect(cpi.has_disk?(disk_id)).to be(true)

          stemcell_id = cpi.create_stemcell('/not/a/real/path', {'ami' => {'us-east-1' => ami}})
          vm_id = cpi.create_vm(
            nil,
            stemcell_id,
            resource_pool,
            network_spec,
            [disk_id],
            nil,
          )

          cpi.attach_disk(vm_id, disk_id)
          expect(cpi.get_disks(vm_id)).to include(disk_id)

          cpi.delete_vm(vm_id)
          vm_id = nil

          new_vm_id = cpi.create_vm(
            nil,
            stemcell_id,
            resource_pool,
            network_spec,
            [disk_id],
            nil,
          )

          expect {
            cpi.attach_disk(new_vm_id, disk_id)
          }.to_not raise_error

          expect(cpi.get_disks(new_vm_id)).to include(disk_id)
        ensure
          cpi.delete_vm(new_vm_id) if new_vm_id
          cpi.delete_disk(disk_id) if disk_id
          cpi.delete_stemcell(stemcell_id) if stemcell_id
          cpi.delete_vm(vm_id) if vm_id
        end
      end
    end

    it 'will not raise error when detaching a non-existing disk' do
      # Detaching a non-existing disk from vm should NOT raise error
      vm_lifecycle do |instance_id|
        expect {
          cpi.detach_disk(instance_id, 'non-existing-volume-uuid')
        }.to_not raise_error
      end
    end
  end

  context 'dynamic networking' do
    let(:network_spec) do
      {
        'default' => {
          'type' => 'dynamic',
          'cloud_properties' => { 'subnet' => @subnet_id }
        }
      }
    end

    it 'can exercise the vm lifecycle' do
      vm_lifecycle
    end
  end

  def vm_lifecycle
    stemcell_id = cpi.create_stemcell('/not/a/real/path', { 'ami' => { 'us-east-1' => ami } })
    instance_id = cpi.create_vm(
      nil,
      stemcell_id,
      resource_pool,
      network_spec,
      disks,
      nil,
    )
    expect(instance_id).not_to be_nil

    expect(cpi.has_vm?(instance_id)).to be(true)

    cpi.set_vm_metadata(instance_id, vm_metadata)

    yield(instance_id) if block_given?
  ensure
    cpi.delete_vm(instance_id) if instance_id
    cpi.delete_stemcell(stemcell_id) if stemcell_id
  end
end
