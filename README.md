# HLF-FSL: Hyperledger Fabric Federated Split Learning

Decentralized Federated Split Learning (FSL) on Hyperledger Fabric using transient fields, Private Data Collections, and off-chain storage for large parameters.

This repository implements the framework described in the paper: *“HLF-FSL: A Decentralized Federated Split Learning Solution for IoT on Hyperledger Fabric”* (Beis-Penedo et al.) DOI: [10.1016/j.array.2026.100685](https://doi.org/10.1016/j.array.2026.100685). It addresses the challenge of training Split Learning models in a decentralized, trustless environment by leveraging Blockchain for coordination and IPFS for off-chain storage of large model parameters.

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Python](https://img.shields.io/badge/Python-3.8%2B-blue)](https://www.python.org/)
[![Node](https://img.shields.io/badge/Node-16%2B-green)](https://nodejs.org/)
[![Hyperledger Fabric](https://img.shields.io/badge/Hyperledger%20Fabric-2.x-black)](https://www.hyperledger.org/use/fabric)

---

## 📖 Table of Contents

- [Architecture Overview](#-architecture-overview)
- [Project Structure](#-project-structure)
- [Prerequisites](#-prerequisites)
- [Installation & Setup](#-installation--setup)
- [Usage Guide](#-usage-guide)
  - [1. Launch Fabric Network](#1-launch-fabric-network)
  - [2. Deploy Chaincode](#2-deploy-chaincode)
  - [3. Start Services (IPFS & API)](#3-start-services-ipfs--api)
  - [4. Run Experiment](#4-run-experiment)
- [Scaling to More Organizations](#-scaling-to-more-organizations)
- [Citation](#-citation)
- [License](#-license)

---

## 🏗 Architecture Overview

The system bridges high-performance Machine Learning with Blockchain trust through four main components:

1.  **Hyperledger Fabric Network**: The trust layer. Manages identities (MSPs), records model update hashes, and enforces access control via Private Data Collections (PDC).
2.  **IPFS (InterPlanetary File System)**: Off-chain storage. Stores bulky ML data (activations, gradients, weights) to avoid blockchain bloat, returning only immutable Content Identifiers (CIDs) to the ledger.
3.  **TypeScript API Servers**: The bridge. Acts as a secure proxy between the ML application and the Fabric SDK, handling cryptographic signing and transaction submission.
4.  **Python ML Application**: The core logic. Uses `PyTorch` for training split models, communicating with the API servers for coordination and IPFS for data exchange.

### Interaction Flow

```mermaid
graph TD
    subgraph "Python Layer"
        ML[Python ML App<br>(Client/Server Threads)]
    end
    
    subgraph "Middleware Layer"
        API[TypeScript API Server]
        IPFS_Node[Local IPFS Node]
    end
    
    subgraph "Infrastructure Layer"
        Fabric[Hyperledger Fabric<br>(Peers/Orderers)]
        IPFS_Net[IPFS Network]
    end

    ML -->|REST/WS| API
    ML -->|Store/Retrieve Data| IPFS_Node
    API -->|Submit Trans/Query| Fabric
    IPFS_Node <--> IPFS_Net
    Fabric -.->|Store CIDs| Fabric

```

---

## 📂 Project Structure

```text
cbeis-iclab/HLF-FSL
├── api-ts/                       # TypeScript Middleware (Fabric SDK Bridge)
│   ├── src/                      # Source code (Gateway, Server, Client)
│   ├── startserver.sh            # Script to build & launch the API
│   └── package.json              # Node dependencies
├── fsl-chaincode/                # Smart Contracts & Deployment
│   ├── chaincode/                # Go Chaincode & PDC configs
│   ├── deployFSL.sh              # Installation script
│   └── generate_collections.py   # Helper to generate PDC policies
├── src/fabric_project/           # Python ML Orchestrator
│   ├── client.py                 # Client-side SL logic
│   ├── server.py                 # Server-side SL logic
│   ├── models.py                 # PyTorch model definitions
│   ├── ipfs_interface.py         # IPFS interaction handler
│   ├── config.py                 # Experiment configuration (epochs, clients)
│   └── startIpfs.sh              # IPFS daemon launcher
├── requirements.txt              # Python dependencies
└── README.md                     # Documentation

```

---

## ✅ Prerequisites

Ensure the following are installed and configured in your environment:

* **Docker & Docker Compose** (for running Fabric containers)
* **Hyperledger Fabric Binaries**: `peer`, `orderer`, `configtxgen`, `cryptogen` must be in your `$PATH`.
* **Go** (v1.18+)
* **Node.js** (v16+) & **npm**
* **Python** (3.8+) & **pip**
* **IPFS CLI**: Installed and initialized (`ipfs init`).

---

## 🛠 Installation & Setup

1. **Clone the repository**
```bash
git clone [https://github.com/cbeis-iclab/HLF-FSL.git](https://github.com/cbeis-iclab/HLF-FSL.git)
cd HLF-FSL

```


2. **Install Python Dependencies**
```bash
pip install -r requirements.txt

```


3. **Install Node.js Dependencies**
```bash
cd api-ts
npm install
cd ..

```



---

## 🚀 Usage Guide

### 1. Launch Fabric Network

*Note: This project assumes you have access to `fabric-samples/test-network`.*

Navigate to your Fabric test network directory, tear down any existing network, and bring up a fresh one with a Certificate Authority (CA).

```bash
# Example path - adjust to your local installation
cd ~/fabric-samples/test-network

./network.sh down
./network.sh up createChannel -ca

```

*Return to the project root once the channel is created.*

### 2. Deploy Chaincode

First, generate the Private Data Collection (PDC) configuration for your organizations (Default: 3 Orgs).

```bash
# Generate PDC config
python fsl-chaincode/generate_collections_config.py

```

Then, deploy the chaincode to the active channel.

```bash
cd fsl-chaincode
./deployFSL.sh
cd ..

```

### 3. Start Services (IPFS & API)

**Terminal A: Start IPFS**
Launch the local IPFS daemon to handle off-chain storage.

```bash
cd src/fabric_project
./startIpfs.sh

```

**Terminal B: Start API Servers**
*Edit `api-ts/startserver.sh` first to ensure the `CLIENTS` array matches your Fabric network organizations.*

```bash
cd api-ts
./startserver.sh

```

### 4. Run Experiment

**Terminal C: Run ML Application**
Start the federated split learning process. This will initialize the server and client threads based on `src/fabric_project/config.py`.

```bash
cd src/fabric_project
python main.py

```

Results will be saved to the `results_fabric/` directory.

---

## 📈 Scaling to More Organizations

To extend the experiment beyond the default setup (Org1, Org2, Org3):

1. **Crypto Material**: Generate MSPs for `OrgN` using `cryptogen` or Fabric CA.
2. **Channel Config**: Update `configtx.yaml` to include `OrgNMSP` in the application channel.
3. **Infrastructure**: Add `peer0.orgN.example.com` to your Docker Compose files (ensure unique ports).
4. **Scripts**: Update `createChannel.sh` to join the new peer to the channel.
5. **Project Config**:
* Re-run `generate_collections_config.py` with the new MSP list.
* Update `CLIENTS` in `api-ts/startserver.sh`.
* Update `NUM_CLIENTS` in `src/fabric_project/config.py`.
* Re-deploy chaincode.



---

## 📄 Citation

If you use this code in your research, please cite the original paper:

```bibtex
@article{BEISPENEDO2026100685,
title = {HLF-FSL: A decentralized federated split learning solution for IoT on hyperledger fabric},
journal = {Array},
volume = {29},
pages = {100685},
year = {2026},
issn = {2590-0056},
doi = {https://doi.org/10.1016/j.array.2026.100685},
url = {https://www.sciencedirect.com/science/article/pii/S2590005626000081},
author = {Carlos Beis-Penedo and Rebeca P. Díaz-Redondo and Ana Fernández-Vilas and Manuel Fernández-Veiga and Francisco Troncoso-Pastoriza},
keywords = {Federated learning, Split learning, Federated split learning, Blockchain, Decentralized systems, Hyperledger fabric},
abstract = {Collaborative machine learning in sensitive domains demands scalable, privacy-aware and access-controlled solutions for enterprise-grade deployment. Conventional federated learning (FL) relies on a central server, introducing single points of failure and privacy risks, while split learning (SL) partitions models for privacy but scales poorly because of sequential training. We present HLF-FSL, a decentralized architecture that combines federated split learning (FSL) with the permissioned blockchain Hyperledger Fabric (HLF). Chaincode orchestrates split-model execution and peer-to-peer aggregation without a central coordinator, leveraging HLF’s transient fields and Private Data Collections (PDCs) to keep raw data and model activations off-chain and access-controlled. On CIFAR-10, MNIST and ImageNet-Mini, HLF-FSL matches the accuracy of a standard server-coordinated FSL baseline while reducing per-epoch training time versus Ethereum-based baselines. Performance and scalability tests quantify the Fabric coordination overhead via a component-level breakdown of SDK-facing latencies and communication volumes; empirically, this overhead increases wall-clock epoch time while preserving the same accuracy-vs-epoch behavior as a FedSplit Learning baseline.}
}

```

---

## ⚖️ License

This project is licensed under the Apache 2.0 License - see the [LICENSE](https://www.google.com/search?q=LICENSE) file for details.

```

```