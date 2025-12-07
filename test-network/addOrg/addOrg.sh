#!/bin/bash
#
# Copyright IBM Corp All Rights Reserved
#
# SPDX-License-Identifier: Apache-2.0
#

ROOTDIR=$(cd "$(dirname "$0")" && pwd)
cd "${ROOTDIR}"

export PATH=${ROOTDIR}/../../bin:${ROOTDIR}:$PATH
export FABRIC_CFG_PATH=${ROOTDIR}/../../config
export VERBOSE=false


. ../scripts/utils.sh

: ${CONTAINER_CLI:="docker"}
if command -v ${CONTAINER_CLI} compose > /dev/null 2>&1; then
    : ${CONTAINER_CLI_COMPOSE:="${CONTAINER_CLI} compose"}
else
    : ${CONTAINER_CLI_COMPOSE:="${CONTAINER_CLI} compose"}
fi
infoln "Using ${CONTAINER_CLI} and ${CONTAINER_CLI_COMPOSE}"

TEST_NETWORK_HOME=$(realpath "${ROOTDIR}/..")
export TEST_NETWORK_HOME

CCP_TEMPLATE_JSON=${ROOTDIR}/ccp-template.json
CCP_TEMPLATE_YAML=${ROOTDIR}/ccp-template.yaml

SOCK="${DOCKER_HOST:-/var/run/docker.sock}"
DOCKER_SOCK="${SOCK##unix://}"

CRYPTO="cryptogen"
CLI_TIMEOUT=10
CLI_DELAY=3
CHANNEL_NAME="mychannel"
DATABASE="leveldb"
MAX_RETRY=5

printHelp() {
  cat <<EOF
Usage:
  addOrg.sh up|generate [-c <channel name>] [-t <timeout>] [-d <delay>] [-s <dbtype>] [-ca] [-verbose]
  addOrg.sh down
  addOrg.sh -h|--help

Modes:
  up        Generate crypto & config for the next organization, start its nodes, join the channel, and set the anchor peer.
  generate  Generate crypto & config artifacts for the next organization without starting nodes or updating the channel.
  down      Delegate to ../network.sh down.

Flags:
  -c <channel name>  Channel to join (default: mychannel)
  -t <timeout>       CLI timeout in seconds (default: 10)
  -d <delay>         Delay between retries in seconds (default: 3)
  -s <dbtype>        Peer state database: leveldb (default) or couchdb
  -n <count>         Number of organizations to add (default: 1)
  -ca                Use Fabric CAs to generate crypto material instead of cryptogen
  -verbose           Enable verbose output
EOF
}

orgDomain() {
  echo "org$1.example.com"
}

orgMSP() {
  echo "Org$1MSP"
}

peerName() {
  echo "peer0.$(orgDomain "$1")"
}

channelPeerOrgNumbers() {
  local config_json="$1"
  jq -r '.channel_group.groups.Application.groups
         | keys[]
         | select(endswith("MSP"))' "${config_json}" \
  | sed -E 's/^Org([0-9]+)MSP$/\1/' \
  | sort -n
}
signWithMajority() {
  local envelope="$1"
  shift
  local signers=("$@")
  local n="${#signers[@]}"
  local need=$(( n/2 + 1 ))
  local count=0
  for org in "${signers[@]}"; do
    infoln "Firmando update como Admin de Org${org} (${count}/${need})"
    signConfigtxAsPeerOrg "${org}" "${envelope}"
    count=$((count+1))
    if [ "${count}" -ge "${need}" ]; then
      break
    fi
  done
  if [ "${count}" -lt "${need}" ]; then
    fatalln "No se alcanzó la mayoría: ${count}/${need}"
  fi
  echo "${signers[0]}"
}


orgWorkdir() {
  echo "${ROOTDIR}/generated/org$1"
}

peerOrgDir() {
  echo "${TEST_NETWORK_HOME}/organizations/peerOrganizations/$(orgDomain "$1")"
}

couchContainerName() {
  local org=$1
  echo "couchdb$((org + 1))"
}

PORT_STRIDE=5

_basePeerPort() {
  local org=$1
  case "$org" in
    1) echo 7051 ;;                     # fijo (test-network)
    2) echo 9051 ;;                     # fijo (test-network)
    *) echo $((11051 + (org-3)*PORT_STRIDE)) ;;  # compacto desde 11051
  esac
}

peerListenPort() {
  _basePeerPort "$1"
}

peerChaincodePort() {
  local base; base=$(_basePeerPort "$1")
  echo $((base + 1))
}

caPort() {
  local org=$1
  case "$org" in
    1) echo 7054 ;;
    2) echo 9054 ;;
    *) local base; base=$(_basePeerPort "$org")
       echo $((base + 3)) ;;
  esac
}

# Solo si usas CouchDB: mantenemos Org1/Org2 como en samples,
# y para Org>=3 usamos otra base compacta con stride=5 que no colisiona.
couchExternalPort() {
  local org=$1
  case "$org" in
    1) echo 5984 ;;
    2) echo 7984 ;;
    *) echo $((11584 + (org-3)*PORT_STRIDE)) ;;  # 11584, 11589, 11594, ...
  esac
}

ensureComposeProject() {
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-fabric}"
}

ensureNetworkPrereqs() {
  if [ ! -d "${TEST_NETWORK_HOME}/organizations/ordererOrganizations" ]; then
    fatalln "Orderer organizations not found. Run ../network.sh up createChannel first."
  fi
}

existingOrgNumbers() {
  local dir="${TEST_NETWORK_HOME}/organizations/peerOrganizations"
  if [ ! -d "$dir" ]; then
    return
  fi
  shopt -s nullglob
  local entries=("$dir"/org*.example.com)
  shopt -u nullglob
  local entry name
  for entry in "${entries[@]}"; do
    [ -d "$entry" ] || continue
    name=$(basename "$entry")
    if [[ $name =~ ^org([0-9]+)\.example\.com$ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done
}

nextOrgNumber() {
  local max=0
  local found=false
  local number
  while IFS= read -r number; do
    found=true
    if (( number > max )); then
      max=$number
    fi
  done < <(existingOrgNumbers)

  if ! $found; then
    fatalln "No existing peer organizations detected. Run ../network.sh up createChannel first."
  fi

  if (( max < 2 )); then
    max=2
  fi
  echo $((max + 1))
}

prepareWorkdir() {
  local org=$1
  local workdir
  workdir=$(orgWorkdir "$org")
  mkdir -p "${workdir}"
  echo "${workdir}"
}

writeCryptoConfig() {
  local org=$1
  local workdir=$2
  cat > "${workdir}/org${org}-crypto.yaml" <<EOF
PeerOrgs:
  - Name: Org${org}
    Domain: $(orgDomain "${org}")
    EnableNodeOUs: true
    Template:
      Count: 1
      SANS:
        - localhost
    Users:
      Count: 1
EOF
}

runCryptogen() {
  local org=$1
  local workdir=$2
  which cryptogen >/dev/null 2>&1 || fatalln "cryptogen tool not found."
  writeCryptoConfig "$org" "$workdir"
  infoln "Generating certificates for Org${org} using cryptogen"
  set -x
  cryptogen generate --config="${workdir}/org${org}-crypto.yaml" --output="${TEST_NETWORK_HOME}/organizations"
  local res=$?
  { set +x; } 2>/dev/null
  if [ $res -ne 0 ]; then
    fatalln "Failed to generate certificates for Org${org}."
  fi
}

writeConfigTx() {
  local org=$1
  local workdir=$2
  local msp_dir
  msp_dir="$(peerOrgDir "${org}")/msp"
  cat > "${workdir}/configtx.yaml" <<EOF
---
Organizations:
    - &Org${org}
        Name: $(orgMSP "${org}")
        ID: $(orgMSP "${org}")
        MSPDir: ${msp_dir}
        Policies:
            Readers:
                Type: Signature
                Rule: "OR('$(orgMSP "${org}").admin', '$(orgMSP "${org}").peer', '$(orgMSP "${org}").client')"
            Writers:
                Type: Signature
                Rule: "OR('$(orgMSP "${org}").admin', '$(orgMSP "${org}").client')"
            Admins:
                Type: Signature
                Rule: "OR('$(orgMSP "${org}").admin')"
            Endorsement:
                Type: Signature
                Rule: "OR('$(orgMSP "${org}").peer')"
EOF
}

generateOrgDefinition() {
  local org=$1
  local workdir=$2
  writeConfigTx "$org" "$workdir"
  which configtxgen >/dev/null 2>&1 || fatalln "configtxgen tool not found."
  local original_cfg=${FABRIC_CFG_PATH}
  export FABRIC_CFG_PATH="${workdir}"
  infoln "Generating organization definition for Org${org}"
  set -x
  configtxgen -printOrg "$(orgMSP "${org}")" > "${TEST_NETWORK_HOME}/organizations/peerOrganizations/$(orgDomain "${org}")/org${org}.json"
  local res=$?
  { set +x; } 2>/dev/null
  export FABRIC_CFG_PATH="${original_cfg}"
  if [ $res -ne 0 ]; then
    fatalln "Failed to generate organization definition for Org${org}."
  fi
}

waitForFile() {
  local file=$1
  local timeout=$2
  local waited=0
  while [ ! -f "$file" ]; do
    sleep 1
    waited=$((waited + 1))
    if [ $waited -ge $timeout ]; then
      return 1
    fi
  done
  return 0
}

writeFabricCAServerConfig() {
  local org=$1
  local workdir=$2
  local ca_dir="${workdir}/fabric-ca/org${org}"
  mkdir -p "${ca_dir}"
  cat > "${ca_dir}/fabric-ca-server-config.yaml" <<EOF
version: 1.2.0
port: $(caPort "${org}")
debug: false
crlsizelimit: 512000
tls:
  enabled: true
  certfile:
  keyfile:
  clientauth:
    type: noclientcert
    certfiles:
ca:
  name: Org${org}CA
  keyfile:
  certfile:
  chainfile:
crl:
  expiry: 24h
registry:
  maxenrollments: -1
  identities:
     - name: admin
       pass: adminpw
       type: client
       affiliation: ""
       attrs:
          hf.Registrar.Roles: "*"
          hf.Registrar.DelegateRoles: "*"
          hf.Revoker: true
          hf.IntermediateCA: true
          hf.GenCRL: true
          hf.Registrar.Attributes: "*"
          hf.AffiliationMgr: true
db:
  type: sqlite3
  datasource: fabric-ca-server.db
  tls:
      enabled: false
      certfiles:
      client:
        certfile:
        keyfile:
ldap:
   enabled: false
   url: ldap://<adminDN>:<adminPassword>@<host>:<port>/<base>
   tls:
      certfiles:
      client:
         certfile:
         keyfile:
   attribute:
      names: ['uid','member']
      converters:
         - name:
           value:
      maps:
         - name:
           value:
signing:
    default:
      usage:
        - digital signature
        - key encipherment
        - authentication
      expiry: 8760h
    profiles:
      ca:
        usage:
          - cert sign
          - crl sign
        expiry: 43800h
      tls:
        usage:
          - digital signature
          - key encipherment
          - server auth
          - client auth
        expiry: 8760h
csr:
  cn: fabric-ca-server
  keyrequest:
    algo: ecdsa
    size: 256
  names:
    - C: US
      ST: "North Carolina"
      L:
      O: Hyperledger
      OU: Fabric
  hosts:
    - localhost
  ca:
    expiry: 131400h
    pathlength: 2
idemix:
  rhpoolsize: 1000
  nonceexpiration: 15s
  noncecachelimit: 1000
affiliations:
    org1:
       - department1
       - department2
       - department3
    org2:
       - department1
       - department2
       - department3
    org3:
       - department1
       - department2
       - department3
    org4:
       - department1
       - department2
       - department3
    org5:
       - department1
       - department2
       - department3
credential:
  hosts:
    - localhost
  profiles:
    default:
      usage:
        - client auth
        - server auth
      expiry: 8760h
      caconstraint:
        isca: false
        maxpathlen: 0
      ocsp:
        expiration: 24h
      crl:
        expiration: 24h
intermediate:
  parentserver:
    url:
    caname:
  enrollment:
    hosts:
      - localhost
    profile:
    label:
  tls:
    certfiles:
    client:
      certfile:
      keyfile:
caConfig:
  registry:
    maxenrollments: -1
    identities: []
  affiliationMgr:
    affiliations: []
EOF
}

generateCACompose() {
  local org=$1
  local workdir=$2
  local compose_file="${workdir}/${CONTAINER_CLI} compose-ca-org${org}.yaml"
  local ca_dir="${workdir}/fabric-ca/org${org}"
  cat > "${compose_file}" <<EOF
version: '3.7'

networks:
  test:

services:
  ca_org${org}:
    image: hyperledger/fabric-ca:latest
    labels:
      service: hyperledger-fabric
    environment:
      - FABRIC_CA_HOME=/etc/hyperledger/fabric-ca-server
      - FABRIC_CA_SERVER_CA_NAME=ca-org${org}
      - FABRIC_CA_SERVER_TLS_ENABLED=true
      - FABRIC_CA_SERVER_PORT=$(caPort "${org}")
    ports:
      - "$(caPort "${org}"):$(caPort "${org}")"
    command: sh -c 'fabric-ca-server start -b admin:adminpw -d'
    volumes:
      - ${ca_dir}:/etc/hyperledger/fabric-ca-server
    container_name: ca_org${org}
    networks:
      - test
EOF
  echo "${compose_file}"
}

startCAContainer() {
  local org=$1
  local workdir=$2
  local compose_file=$3
  local ca_project="fabric_ca_org${org}"     # <- proyecto aislado

  infoln "Starting CA container for Org${org} (project ${ca_project})"
  set -x
  ${CONTAINER_CLI_COMPOSE} -p "${ca_project}" -f "${compose_file}" up -d
  local res=$?
  { set +x; } 2>/dev/null
  verifyResult $res "Unable to start CA container for Org${org}"

  local tls_cert="${workdir}/fabric-ca/org${org}/tls-cert.pem"
  if ! waitForFile "${tls_cert}" 30; then
    fatalln "Timed out waiting for CA TLS cert for Org${org}"
  fi
}

stopCAContainer() {
  local org=$1
  if [ -z "${CA_COMPOSE_FILE:-}" ]; then
    warnln "CA compose file unknown for Org${org}; skipping CA shutdown"
    return
  fi
  local ca_project="fabric_ca_org${org}"     # <- mismo nombre que en up
  infoln "Stopping CA stack for Org${org} (project ${ca_project})"
  set -x
  # Nada de --remove-orphans aquí para no tocar otros stacks
  ${CONTAINER_CLI_COMPOSE} -p "${ca_project}" -f "${CA_COMPOSE_FILE}" down --volumes >/dev/null 2>&1 || true
  { set +x; } 2>/dev/null
}

register_if_needed() {
  local caname="$1"; shift
  local idname="$1"; shift
  local idtype="$1"; shift
  local idsecret="$1"; shift
  local tlscert="$1"; shift
  if fabric-ca-client identity list --caname "${caname}" --id "${idname}" --tls.certfiles "${tlscert}" >/dev/null 2>&1; then
    infoln "Identity '${idname}' ya existe en ${caname}, omito registro"
    return 0
  fi
  set -x
  fabric-ca-client register --caname "${caname}" \
    --id.name "${idname}" --id.secret "${idsecret}" --id.type "${idtype}" \
    --tls.certfiles "${tlscert}" || true
  local res=$?
  { set +x; } 2>/dev/null
  verifyResult $res "Fallo registrando identidad '${idname}' en ${caname}"
}


enrollUsingCA() {
  local org=$1
  local workdir=$2
  which fabric-ca-client >/dev/null 2>&1 || fatalln "fabric-ca-client tool not found."

  local org_dir
  org_dir=$(peerOrgDir "$org")
  local domain
  domain=$(orgDomain "$org")
  local peer
  peer=$(peerName "$org")
  local caport
  caport=$(caPort "$org")
  local caname="ca-org${org}"
  local ca_tls_cert="${workdir}/fabric-ca/org${org}/tls-cert.pem"

  mkdir -p "${org_dir}"
  export FABRIC_CA_CLIENT_HOME="${org_dir}"

  infoln "Enrolling CA admin for Org${org}"
  set -x
  fabric-ca-client enroll -u https://admin:adminpw@localhost:${caport} --caname "${caname}" --tls.certfiles "${ca_tls_cert}"
  local res=$?
  { set +x; } 2>/dev/null
  if [ $res -ne 0 ]; then
    fatalln "Failed to enroll CA admin for Org${org}"
  fi

  cat > "${org_dir}/msp/config.yaml" <<EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:
    Certificate: cacerts/localhost-${caport}-${caname}.pem
    OrganizationalUnitIdentifier: client
  PeerOUIdentifier:
    Certificate: cacerts/localhost-${caport}-${caname}.pem
    OrganizationalUnitIdentifier: peer
  AdminOUIdentifier:
    Certificate: cacerts/localhost-${caport}-${caname}.pem
    OrganizationalUnitIdentifier: admin
  OrdererOUIdentifier:
    Certificate: cacerts/localhost-${caport}-${caname}.pem
    OrganizationalUnitIdentifier: orderer
EOF

  infoln "Registering identities for Org${org}"
  set -x
  register_if_needed "${caname}" "peer0" "peer" "peer0pw" "${ca_tls_cert}"
  register_if_needed "${caname}" "user1" "client" "user1pw" "${ca_tls_cert}"
  register_if_needed "${caname}" "org${org}admin" "admin" "org${org}adminpw" "${ca_tls_cert}"
  { set +x; } 2>/dev/null

  local peer_msp_dir="${org_dir}/peers/${peer}/msp"
  local peer_tls_dir="${org_dir}/peers/${peer}/tls"
  mkdir -p "${peer_msp_dir}"
  mkdir -p "${peer_tls_dir}"

  infoln "Generating MSP for ${peer}"
  set -x
  fabric-ca-client enroll -u https://peer0:peer0pw@localhost:${caport} --caname "${caname}" -M "${peer_msp_dir}" --tls.certfiles "${ca_tls_cert}"
  { set +x; } 2>/dev/null
  cp "${org_dir}/msp/config.yaml" "${peer_msp_dir}/config.yaml"

  infoln "Generating TLS certs for ${peer}"
  set -x
  fabric-ca-client enroll -u https://peer0:peer0pw@localhost:${caport} --caname "${caname}" -M "${peer_tls_dir}" --enrollment.profile tls --csr.hosts "${peer}" --csr.hosts localhost --tls.certfiles "${ca_tls_cert}"
  { set +x; } 2>/dev/null

  cp "${peer_tls_dir}/tlscacerts/"* "${peer_tls_dir}/ca.crt"
  cp "${peer_tls_dir}/signcerts/"* "${peer_tls_dir}/server.crt"
  cp "${peer_tls_dir}/keystore/"* "${peer_tls_dir}/server.key"

  mkdir -p "${org_dir}/msp/tlscacerts"
  cp "${peer_tls_dir}/tlscacerts/"* "${org_dir}/msp/tlscacerts/ca.crt"

  mkdir -p "${org_dir}/tlsca"
  cp "${peer_tls_dir}/tlscacerts/"* "${org_dir}/tlsca/tlsca.${domain}-cert.pem"

  mkdir -p "${org_dir}/ca"
  cp "${peer_msp_dir}/cacerts/"* "${org_dir}/ca/ca.${domain}-cert.pem"

  local user_msp_dir="${org_dir}/users/User1@${domain}/msp"
  mkdir -p "${user_msp_dir}"
  infoln "Generating user MSP for Org${org}"
  set -x
  fabric-ca-client enroll -u https://user1:user1pw@localhost:${caport} --caname "${caname}" -M "${user_msp_dir}" --tls.certfiles "${ca_tls_cert}"
  { set +x; } 2>/dev/null
  cp "${org_dir}/msp/config.yaml" "${user_msp_dir}/config.yaml"

  local admin_msp_dir="${org_dir}/users/Admin@${domain}/msp"
  mkdir -p "${admin_msp_dir}"
  infoln "Generating admin MSP for Org${org}"
  set -x
  fabric-ca-client enroll -u https://org${org}admin:org${org}adminpw@localhost:${caport} --caname "${caname}" -M "${admin_msp_dir}" --tls.certfiles "${ca_tls_cert}"
  { set +x; } 2>/dev/null
  cp "${org_dir}/msp/config.yaml" "${admin_msp_dir}/config.yaml"

  unset FABRIC_CA_CLIENT_HOME
}

generateCryptoMaterial() {
  local org=$1
  local workdir=$2
  local org_dir
  org_dir=$(peerOrgDir "$org")
  if [ -d "${org_dir}" ]; then
    warnln "Organization $(orgDomain "${org}") already exists. Skipping crypto generation for this org."
    return 2   # código no-catastrófico
  fi
  if [ "$CRYPTO" == "cryptogen" ]; then
    runCryptogen "$org" "$workdir"
  elif [ "$CRYPTO" == "Certificate Authorities" ]; then
    writeFabricCAServerConfig "$org" "$workdir"
    local compose_file
    compose_file=$(generateCACompose "$org" "$workdir")
    ensureComposeProject
    CA_COMPOSE_FILE="${compose_file}"
    startCAContainer "$org" "$workdir" "${compose_file}"
    enrollUsingCA "$org" "$workdir"
    stopCAContainer "$org"
    unset CA_COMPOSE_FILE
  else
    fatalln "Unsupported crypto provider: $CRYPTO"
  fi
}

one_line_pem() {
  awk 'NF {gsub(/\r/, ""); printf "%s\\\\n",$0;}' "$1"
}

json_ccp() {
  local org=$1
  local peer_port=$2
  local ca_port=$3
  local peer_pem=$4
  local ca_pem=$5
  local pp cp
  pp=$(one_line_pem "${peer_pem}")
  cp=$(one_line_pem "${ca_pem}")
  sed -e "s/\${ORG}/${org}/" \
      -e "s/\${P0PORT}/${peer_port}/" \
      -e "s/\${CAPORT}/${ca_port}/" \
      -e "s#\${PEERPEM}#${pp}#" \
      -e "s#\${CAPEM}#${cp}#" \
      "${CCP_TEMPLATE_JSON}"
}

yaml_ccp() {
  local org=$1
  local peer_port=$2
  local ca_port=$3
  local peer_pem=$4
  local ca_pem=$5
  local pp cp
  pp=$(one_line_pem "${peer_pem}")
  cp=$(one_line_pem "${ca_pem}")
  sed -e "s/\${ORG}/${org}/" \
      -e "s/\${P0PORT}/${peer_port}/" \
      -e "s/\${CAPORT}/${ca_port}/" \
      -e "s#\${PEERPEM}#${pp}#" \
      -e "s#\${CAPEM}#${cp}#" \
      "${CCP_TEMPLATE_YAML}" | sed -e $'s/\\\\n/\\\n          /g'
}

generateConnectionProfiles() {
  local org=$1
  local org_dir
  org_dir=$(peerOrgDir "$org")
  local peer_port
  peer_port=$(peerListenPort "$org")
  local caport
  caport=$(caPort "$org")
  local peer_pem="${org_dir}/tlsca/tlsca.$(orgDomain "${org}")-cert.pem"
  local ca_pem="${org_dir}/ca/ca.$(orgDomain "${org}")-cert.pem"

  if [ ! -f "${peer_pem}" ] || [ ! -f "${ca_pem}" ]; then
    warnln "Skipping CCP generation for Org${org}; TLS certificates not found."
    return
  fi

  infoln "Generating CCP files for Org${org}"
  echo "$(json_ccp "${org}" "${peer_port}" "${caport}" "${peer_pem}" "${ca_pem}")" > "${org_dir}/connection-org${org}.json"
  echo "$(yaml_ccp "${org}" "${peer_port}" "${caport}" "${peer_pem}" "${ca_pem}")" > "${org_dir}/connection-org${org}.yaml"
}

generatePeerCompose() {
  local org=$1
  local workdir=$2
  local compose_file="${workdir}/${CONTAINER_CLI} compose-org${org}.yaml"
  local peer
  peer=$(peerName "$org")
  local peer_port
  peer_port=$(peerListenPort "$org")
  local chaincode_port
  chaincode_port=$(peerChaincodePort "$org")
  local peer_dir
  peer_dir=$(peerOrgDir "$org")
  local peer_cfg_dir
  if [ "${CONTAINER_CLI}" == "docker" ]; then
    peer_cfg_dir="${TEST_NETWORK_HOME}/compose/docker/peercfg"
  else
    peer_cfg_dir="${TEST_NETWORK_HOME}/compose/podman/peercfg"
  fi
  ensureComposeProject
  local project_network="${COMPOSE_PROJECT_NAME}_test"

  cat > "${compose_file}" <<EOF
version: '3.7'

volumes:
  ${peer}:

networks:
  test:
    external: true
    name: ${project_network}

services:
EOF

  if [ "${DATABASE}" == "couchdb" ]; then
    cat >> "${compose_file}" <<EOF
  $(couchContainerName "${org}"):
    container_name: $(couchContainerName "${org}")
    image: couchdb:3.3.3
    labels:
      service: hyperledger-fabric
    environment:
      - COUCHDB_USER=admin
      - COUCHDB_PASSWORD=adminpw
    ports:
      - "$(couchExternalPort "${org}"):5984"
    networks:
      - test

EOF
  fi

  cat >> "${compose_file}" <<EOF
  ${peer}:
    container_name: ${peer}
    image: hyperledger/fabric-peer:latest
    labels:
      service: hyperledger-fabric
    environment:
      - FABRIC_CFG_PATH=/etc/hyperledger/peercfg
      - FABRIC_LOGGING_SPEC=INFO
      - CORE_PEER_TLS_ENABLED=true
      - CORE_PEER_PROFILE_ENABLED=true
      - CORE_PEER_TLS_CERT_FILE=/etc/hyperledger/fabric/tls/server.crt
      - CORE_PEER_TLS_KEY_FILE=/etc/hyperledger/fabric/tls/server.key
      - CORE_PEER_TLS_ROOTCERT_FILE=/etc/hyperledger/fabric/tls/ca.crt
      - CORE_PEER_ID=${peer}
      - CORE_PEER_ADDRESS=${peer}:${peer_port}
      - CORE_PEER_MSPCONFIGPATH=/etc/hyperledger/fabric/msp
      - CORE_PEER_LISTENADDRESS=0.0.0.0:${peer_port}
      - CORE_PEER_CHAINCODEADDRESS=${peer}:${chaincode_port}
      - CORE_PEER_CHAINCODELISTENADDRESS=0.0.0.0:${chaincode_port}
      - CORE_PEER_GOSSIP_BOOTSTRAP=${peer}:${peer_port}
      - CORE_PEER_GOSSIP_EXTERNALENDPOINT=${peer}:${peer_port}
      - CORE_PEER_LOCALMSPID=$(orgMSP "${org}")
      - CORE_METRICS_PROVIDER=prometheus
      - CHAINCODE_AS_A_SERVICE_BUILDER_CONFIG={"peername":"peer0org${org}"}
      - CORE_CHAINCODE_EXECUTETIMEOUT=300s
EOF

  if [ "${CONTAINER_CLI}" == "docker" ]; then
    cat >> "${compose_file}" <<EOF
      - CORE_VM_ENDPOINT=unix:///host/var/run/docker.sock
      - CORE_VM_DOCKER_HOSTCONFIG_NETWORKMODE=${project_network}
EOF
  fi

  if [ "${DATABASE}" == "couchdb" ]; then
    cat >> "${compose_file}" <<EOF
      - CORE_LEDGER_STATE_STATEDATABASE=CouchDB
      - CORE_LEDGER_STATE_COUCHDBCONFIG_COUCHDBADDRESS=$(couchContainerName "${org}"):5984
      - CORE_LEDGER_STATE_COUCHDBCONFIG_USERNAME=admin
      - CORE_LEDGER_STATE_COUCHDBCONFIG_PASSWORD=adminpw
EOF
  fi

  cat >> "${compose_file}" <<EOF
    volumes:
      - ${peer_cfg_dir}:/etc/hyperledger/peercfg
      - ${peer_dir}/peers/${peer}:/etc/hyperledger/fabric
      - ${peer}:/var/hyperledger/production
EOF

  if [ "${CONTAINER_CLI}" == "docker" ]; then
    cat >> "${compose_file}" <<EOF
      - ${DOCKER_SOCK}:/host/var/run/docker.sock
EOF
  fi

  if [ "${DATABASE}" == "couchdb" ]; then
    cat >> "${compose_file}" <<EOF
    depends_on:
      - $(couchContainerName "${org}")
EOF
  fi

  cat >> "${compose_file}" <<EOF
    working_dir: /opt/gopath/src/github.com/hyperledger/fabric/peer
    command: peer node start
    ports:
      - "${peer_port}:${peer_port}"
    networks:
      - test
EOF

  echo "${compose_file}"
}

startPeer() {
  local org=$1
  local workdir=$2
  local compose_file
  ensureComposeProject
  compose_file=$(generatePeerCompose "$org" "$workdir")
  infoln "Starting peer for Org${org}"
  if [ "${CONTAINER_CLI}" == "docker" ]; then
    set -x
    DOCKER_SOCK="${DOCKER_SOCK}" ${CONTAINER_CLI_COMPOSE} -f "${compose_file}" up -d
    local res=$?
    { set +x; } 2>/dev/null
    if [ $res -ne 0 ]; then
      fatalln "Unable to start Org${org} peer"
    fi
  else
    set -x
    ${CONTAINER_CLI_COMPOSE} -f "${compose_file}" up -d
    local res=$?
    { set +x; } 2>/dev/null
    if [ $res -ne 0 ]; then
      fatalln "Unable to start Org${org} peer"
    fi
  fi
}

waitForPeer() {
  local org=$1
  local port=$(peerListenPort "${org}")
  infoln "Waiting for peer0.org${org} on localhost:${port}"
  for i in {1..30}; do
    (echo > /dev/tcp/127.0.0.1/${port}) >/dev/null 2>&1 && { successln "peer0.org${org} is up"; return 0; }
    sleep 1
  done
  fatalln "peer0.org${org} did not open port ${port} in time"
}

updateChannelConfig() {
  local org=$1
  local org_json="${TEST_NETWORK_HOME}/organizations/peerOrganizations/$(orgDomain "${org}")/org${org}.json"
  if [ ! -f "${org_json}" ]; then
    fatalln "Organization definition ${org_json} not found"
  fi
  export FABRIC_CFG_PATH=${TEST_NETWORK_HOME}/../config
  export TEST_NETWORK_HOME
  . ${TEST_NETWORK_HOME}/scripts/configUpdate.sh

  infoln "Creating channel update to add Org${org}"
  local config_json=${TEST_NETWORK_HOME}/channel-artifacts/config.json
  local modified_json=${TEST_NETWORK_HOME}/channel-artifacts/modified_config.json
  local envelope=${TEST_NETWORK_HOME}/channel-artifacts/org${org}_update_in_envelope.pb

  fetchChannelConfig 1 "${CHANNEL_NAME}" "${config_json}"

  set -x
  jq -s --arg msp "$(orgMSP "${org}")" '.[0] * {"channel_group":{"groups":{"Application":{"groups": {($msp):.[1]}}}}}' \
    "${config_json}" "${org_json}" > "${modified_json}"
  local res=$?
  { set +x; } 2>/dev/null
  if [ $res -ne 0 ]; then
    fatalln "Failed to append Org${org} definition to channel config. Ensure jq is installed."
  fi

  createConfigUpdate "${CHANNEL_NAME}" "${config_json}" "${modified_json}" "${envelope}"

  # --- Mayoría de firmas dinámicas ---
  # msps[] = Org1MSP, Org2MSP, ...
  mapfile -t msps < <(jq -r '.channel_group.groups.Application.groups | keys[]' "${config_json}")
  total=${#msps[@]}
  req=$(( total/2 + 1 ))

  infoln "Se requieren ${req}/${total} firmas de Admins (MAJORITY)"

  signed=0
  submitter_org_num=""

  for msp in "${msps[@]}"; do
    # extrae el número de org a partir de Org<N>MSP
    org_num="${msp#Org}"
    org_num="${org_num%MSP}"

    # firma como esa org
    infoln "Firmando como Org${org_num} (${msp})"
    signConfigtxAsPeerOrg "${org_num}" "${envelope}"
    signed=$((signed+1))

    # recuerda la primera firmante para hacer el update
    if [ -z "${submitter_org_num}" ]; then
      submitter_org_num="${org_num}"
    fi

    # ya tenemos suficientes firmas
    [ "${signed}" -ge "${req}" ] && break
  done

  # envía la actualización como la primera firmante
  infoln "Enviando update firmado (submitter Org${submitter_org_num})"
  setGlobals "${submitter_org_num}"
  set -x
  peer channel update -f "${envelope}" -c "${CHANNEL_NAME}" -o localhost:7050 \
    --ordererTLSHostnameOverride orderer.example.com --tls --cafile "$ORDERER_CA"
  res=$?
  { set +x; } 2>/dev/null
  verifyResult $res "Failed to update channel with Org${org}"

  successln "Config update for Org${org} submitted"
}

joinOrgToChannel() {
  local org=$1
  export FABRIC_CFG_PATH=${TEST_NETWORK_HOME}/../config
  export TEST_NETWORK_HOME
  . ${TEST_NETWORK_HOME}/scripts/envVar.sh

  local peer
  peer=$(peerName "$org")
  local block_file=${TEST_NETWORK_HOME}/channel-artifacts/${CHANNEL_NAME}.block

  infoln "Fetching channel block for Org${org}"
  setGlobals "${org}"
  set -x
  peer channel fetch 0 "${block_file}" -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com -c "${CHANNEL_NAME}" --tls --cafile "$ORDERER_CA" >&log.txt
  local res=$?
  { set +x; } 2>/dev/null
  cat log.txt
  verifyResult $res "Failed to fetch channel block for Org${org}"

  local retry=1
  local joined=false
  while [ $retry -le $MAX_RETRY ]; do
    set -x
    peer channel join -b "${block_file}" >&log.txt
    res=$?
    { set +x; } 2>/dev/null
    cat log.txt
    if [ $res -eq 0 ]; then
      joined=true
      break
    fi
    warnln "peer0.org${org} failed to join channel '${CHANNEL_NAME}', retrying in ${CLI_DELAY}s (attempt ${retry}/${MAX_RETRY})"
    sleep "${CLI_DELAY}"
    retry=$((retry + 1))
  done
  if ! $joined; then
    fatalln "After $MAX_RETRY attempts, peer0.org${org} failed to join channel '${CHANNEL_NAME}'"
  fi

  infoln "Setting anchor peer for Org${org}"
  set -x
  ${TEST_NETWORK_HOME}/scripts/setAnchorPeer.sh "${org}" "${CHANNEL_NAME}"
  res=$?
  { set +x; } 2>/dev/null
  verifyResult $res "Failed to set anchor peer for Org${org}"

  successln "Org${org} joined channel '${CHANNEL_NAME}'"
}

addOrganization() {
  local org=${1:-$(nextOrgNumber)}  # Accept org number as parameter or calculate if not provided
  ensureNetworkPrereqs
  infoln "Preparing to add Org${org} to channel '${CHANNEL_NAME}'"
  local workdir
  workdir=$(prepareWorkdir "${org}")
  mkdir -p "${TEST_NETWORK_HOME}/channel-artifacts"

  generateCryptoMaterial "${org}" "${workdir}"
  rc=$?
  if [ $rc -ne 0 ] && [ $rc -ne 2 ]; then
    return $rc
  fi

  generateOrgDefinition "${org}" "${workdir}" || return $?
  updateChannelConfig "${org}"              || return $?
  startPeer "${org}" "${workdir}"           || return $?
  waitForPeer "${org}"                      || return $?
  joinOrgToChannel "${org}"                 || return $?
  generateConnectionProfiles "${org}"       || return $?
}

generateOnly() {
  local org=${1:-$(nextOrgNumber)}
  ensureNetworkPrereqs
  infoln "Generating artifacts for Org${org}"
  local workdir
  workdir=$(prepareWorkdir "${org}")
  generateCryptoMaterial "${org}" "${workdir}"
  generateOrgDefinition "${org}" "${workdir}"
  generateConnectionProfiles "${org}"
  successln "Artifacts for Org${org} generated"
}

delegateNetworkDown() {
  infoln "Delegating to ../network.sh down"
  ( cd "${TEST_NETWORK_HOME}" && ./network.sh down )
}

MODE=""

if [[ $# -lt 1 ]]; then
  printHelp
  exit 0
else
  MODE=$1
  shift
fi

ORG_COUNT=1

while [[ $# -ge 1 ]]; do
  key="$1"
  case $key in
    -h|--help)
      printHelp
      exit 0
      ;;
    -c)
      CHANNEL_NAME="$2"
      shift
      ;;
    -t)
      CLI_TIMEOUT="$2"
      shift
      ;;
    -d)
      CLI_DELAY="$2"
      shift
      ;;
    -s)
      DATABASE="$2"
      shift
      ;;
    -n)
      ORG_COUNT="$2"
      shift
      ;;
    -ca)
      CRYPTO="Certificate Authorities"
      ;;
    -verbose)
      VERBOSE=true
      ;;
    *)
      errorln "Unknown flag: $key"
      printHelp
      exit 1
      ;;
  esac
  shift
done

case "${MODE}" in
  up)
    infoln "Adding ${ORG_COUNT} organization(s) using database '${DATABASE}' and crypto '${CRYPTO}'"
    added=0
    while (( added < ORG_COUNT )); do
      org=$(nextOrgNumber)              # recálculo dinámico
      infoln "Adding organization ${org} ($((added+1))/${ORG_COUNT})"
      if addOrganization "${org}"; then
        added=$((added+1))
      else
        warnln "addOrganization ${org} failed; retrying with next available org"
        # no incrementes 'added' para reintentar con el siguiente libre
      fi
    done
    ;;
  generate)
    infoln "Generating artifacts for ${ORG_COUNT} organization(s)"
    generated=0
    while (( generated < ORG_COUNT )); do
      org=$(nextOrgNumber)
      infoln "Generating organization ${org} ($((generated+1))/${ORG_COUNT})"
      if generateOnly "${org}"; then
        generated=$((generated+1))
      else
        warnln "generateOnly ${org} failed; retrying with next available org"
      fi
    done
    ;;
  down)
    delegateNetworkDown
    ;;
  *)
    errorln "Unknown mode: ${MODE}"
    printHelp
    exit 1
    ;;
esac
