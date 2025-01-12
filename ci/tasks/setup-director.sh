#!/usr/bin/env bash

set -e

source bosh-cpi-release/ci/tasks/utils.sh

check_param base_os
check_param aws_access_key_id
check_param aws_secret_access_key
check_param region_name
check_param private_key_data
check_param AWS_NETWORK_CIDR
check_param AWS_NETWORK_GATEWAY
check_param PRIVATE_DIRECTOR_STATIC_IP

source /etc/profile.d/chruby.sh
chruby 2.1.2

export AWS_ACCESS_KEY_ID=${aws_access_key_id}
export AWS_SECRET_ACCESS_KEY=${aws_secret_access_key}
export AWS_DEFAULT_REGION=${region_name}

stack_name="aws-cpi-stack"
stack_info=$(get_stack_info $stack_name)

sg_id=$(get_stack_info_of "${stack_info}" "securitygroupid")
SECURITY_GROUP_NAME=$(aws ec2 describe-security-groups --group-ids ${sg_id} | jq -r '.SecurityGroups[] .GroupName')

DIRECTOR=$(get_stack_info_of "${stack_info}" "${base_os}directorvip")
SUBNET_ID=$(get_stack_info_of "${stack_info}" "${base_os}subnetid")
AVAILABILITY_ZONE=$(get_stack_info_of "${stack_info}" "${base_os}availabilityzone")

semver=`cat version-semver/number`
cpi_release_name=bosh-aws-cpi
deployment_dir="${PWD}/deployment"
manifest_filename="director-manifest.yml"
private_key=${deployment_dir}/bats.pem

echo "setting up artifacts used in $manifest_filename"
mkdir -p ${deployment_dir}
cp ./bosh-cpi-dev-artifacts/${cpi_release_name}-${semver}.tgz ${deployment_dir}/${cpi_release_name}.tgz
cp ./bosh-release/release.tgz ${deployment_dir}/bosh-release.tgz
cp ./stemcell/stemcell.tgz ${deployment_dir}/stemcell.tgz
echo "${private_key_data}" > ${private_key}
chmod go-r ${private_key}
eval $(ssh-agent)
ssh-add ${private_key}

#create director manifest as heredoc
cat > "${deployment_dir}/${manifest_filename}"<<EOF
---
name: bosh

releases:
- name: bosh
  url: file://bosh-release.tgz
- name: bosh-aws-cpi
  url: file://bosh-aws-cpi.tgz

networks:
- name: private
  type: manual
  subnets:
  - range:    ${AWS_NETWORK_CIDR}
    gateway:  ${AWS_NETWORK_GATEWAY}
    dns:      [8.8.8.8]
    cloud_properties: {subnet: ${SUBNET_ID}}
- name: public
  type: vip

resource_pools:
- name: default
  network: private
  stemcell:
    url: file://stemcell.tgz
  cloud_properties:
    instance_type: m3.xlarge
    availability_zone: ${AVAILABILITY_ZONE}
    ephemeral_disk:
      size: 25000
      type: gp2

disk_pools:
- name: default
  disk_size: 25_000
  cloud_properties: {type: gp2}

jobs:
- name: bosh
  templates:
  - {name: nats, release: bosh}
  - {name: redis, release: bosh}
  - {name: postgres, release: bosh}
  - {name: blobstore, release: bosh}
  - {name: director, release: bosh}
  - {name: health_monitor, release: bosh}
  - {name: registry, release: bosh}
  - {name: cpi, release: bosh-aws-cpi}

  instances: 1
  resource_pool: default
  persistent_disk_pool: default

  networks:
  - name: private
    static_ips: [${PRIVATE_DIRECTOR_STATIC_IP}]
    default: [dns, gateway]
  - name: public
    static_ips: [${DIRECTOR}]

  properties:
    nats:
      address: 127.0.0.1
      user: nats
      password: nats-password

    redis:
      listen_addresss: 127.0.0.1
      address: 127.0.0.1
      password: redis-password

    postgres: &db
      host: 127.0.0.1
      user: postgres
      password: postgres-password
      database: bosh
      adapter: postgres

    # Tells the Director/agents how to contact registry
    registry:
      address: ${PRIVATE_DIRECTOR_STATIC_IP}
      host: ${PRIVATE_DIRECTOR_STATIC_IP}
      db: *db
      http: {user: admin, password: admin, port: 25777}
      username: admin
      password: admin
      port: 25777

    # Tells the Director/agents how to contact blobstore
    blobstore:
      address: ${PRIVATE_DIRECTOR_STATIC_IP}
      port: 25250
      provider: dav
      director: {user: director, password: director-password}
      agent: {user: agent, password: agent-password}

    director:
      address: 127.0.0.1
      name: micro
      db: *db
      cpi_job: cpi

    hm:
      http: {user: hm, password: hm-password}
      director_account: {user: admin, password: admin}

    aws: &aws
      access_key_id: ${aws_access_key_id}
      secret_access_key: ${aws_secret_access_key}
      default_key_name: "bats"
      default_security_groups: ["${SECURITY_GROUP_NAME}"]
      region: "${region_name}"

    # Tells agents how to contact nats
    agent: {mbus: "nats://nats:nats-password@${PRIVATE_DIRECTOR_STATIC_IP}:4222"}

    ntp: &ntp
    - 0.north-america.pool.ntp.org
    - 1.north-america.pool.ntp.org

cloud_provider:
  template: {name: cpi, release: bosh-aws-cpi}

  # Tells bosh-micro how to SSH into deployed VM
  ssh_tunnel:
    host: ${DIRECTOR}
    port: 22
    user: vcap
    private_key: ${private_key}

  # Tells bosh-micro how to contact remote agent
  mbus: https://mbus-user:mbus-password@${DIRECTOR}:6868

  properties:
    aws: *aws

    # Tells CPI how agent should listen for requests
    agent: {mbus: "https://mbus-user:mbus-password@0.0.0.0:6868"}

    blobstore:
      provider: local
      path: /var/vcap/micro_bosh/data/cache

    ntp: *ntp
EOF

initver=$(cat bosh-init/version)
initexe="$PWD/bosh-init/bosh-init-${initver}-linux-amd64"
chmod +x ${initexe}

echo "using bosh-init CLI version..."
$initexe version

pushd ${deployment_dir}
  echo "deploying BOSH..."
  $initexe deploy ${manifest_filename}
popd
