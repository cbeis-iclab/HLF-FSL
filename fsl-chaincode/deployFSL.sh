#!/bin/bash

export ORDERER_CA=${PWD}/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
export PEER0_ORG1_CA=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export PEER0_ORG2_CA=${PWD}/organizations/peerOrganizations/org2.example.com/peers/peer0.org2.example.com/tls/ca.crt
export CHANNEL_NAME=mychannel
export CC_NAME=fsl
export PATH=${PWD}/../bin:$PATH
export FABRIC_CFG_PATH=$PWD/../config/

# Environment variables for Org1
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID=Org1MSP
export CORE_PEER_TLS_ROOTCERT_FILE=${PWD}/organizations/peerOrganizations/org1.example.com/peers/peer0.org1.example.com/tls/ca.crt
export CORE_PEER_MSPCONFIGPATH=${PWD}/organizations/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp
export CORE_PEER_ADDRESS=localhost:7051
export PATH=${PWD}/../bin:$PATH
export FABRIC_CFG_PATH=$PWD/../config/

peer lifecycle chaincode package fsl.tar.gz --path fsl --lang golang --label fsl_1
./network.sh deployCC -ccn fsl -ccp ./fsl/ -ccl go -ccv 1.0 -ccs 1 -cccg ./fsl/collections_config.json -ccep "OR('Org1MSP.peer','Org2MSP.peer','Org3MSP.peer')"

# "OutOf(2,'Org1MSP.peer','Org2MSP.peer','Org3MSP.peer','Org4MSP.peer','Org5MSP.peer','Org6MSP.peer','Org7MSP.peer','Org8MSP.peer','Org9MSP.peer','Org10MSP.peer','Org11MSP.peer','Org12MSP.peer','Org13MSP.peer','Org14MSP.peer','Org15MSP.peer','Org16MSP.peer','Org17MSP.peer','Org18MSP.peer','Org19MSP.peer','Org20MSP.peer','Org21MSP.peer','Org22MSP.peer','Org23MSP.peer','Org24MSP.peer','Org25MSP.peer')"
