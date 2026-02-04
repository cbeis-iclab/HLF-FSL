package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strconv" // ADDED: needed for counter conversion

	"github.com/hyperledger/fabric-chaincode-go/pkg/cid"
	"github.com/hyperledger/fabric-chaincode-go/shim"
	"github.com/hyperledger/fabric-contract-api-go/contractapi"
)

type SplitLearningContract struct {
	contractapi.Contract
}

type Data struct {
	IntermediateData string `json:"intermediateData,omitempty"`
	GradientData     string `json:"gradientData,omitempty"`
}

type ClientModelUpdate struct {
	RoundID        string `json:"roundID"`
	ModelParamHash string `json:"modelParamHash"`
	ClientID       string `json:"clientID"`
	DatasetSize    string `json:"datasetSize"`
}

type GlobalModelCommit struct {
	RoundID                   string `json:"roundID"`
	AggregatedGlobalModelHash string `json:"aggregatedGlobalModelHash"`
	IPFSCid                   string `json:"ipfsCid"`
	ClientID                  string `json:"clientID"`
}

const RegisteredMSPsKey = "ALL_REGISTERED_MSPS"
const TotalClientsKey = "TOTAL_REGISTERED_CLIENTS"

// -------------------------------------------------------------
// HELPER: Auto-Discovery de MSPs
// -------------------------------------------------------------

func (s *SplitLearningContract) ensureMSPRegistered(stub shim.ChaincodeStubInterface, mspID string) error {
	bytes, err := stub.GetState(RegisteredMSPsKey)
	if err != nil {
		return fmt.Errorf("failed to read registered MSPs: %v", err)
	}

	var msps []string
	if bytes != nil {
		if err := json.Unmarshal(bytes, &msps); err != nil {
			return fmt.Errorf("failed to unmarshal MSP list: %v", err)
		}
	}

	for _, m := range msps {
		if m == mspID {
			return nil
		}
	}

	msps = append(msps, mspID)
	newBytes, err := json.Marshal(msps)
	if err != nil {
		return fmt.Errorf("failed to marshal MSP list: %v", err)
	}

	if err := stub.PutState(RegisteredMSPsKey, newBytes); err != nil {
		return fmt.Errorf("failed to update registered MSPs: %v", err)
	}

	return nil
}

// -------------------------------------------------------------
// FUNCIONES DEL CONTRATO
// -------------------------------------------------------------

func (s *SplitLearningContract) RegisterServer(ctx contractapi.TransactionContextInterface, topic string) (string, error) {
	creator, err := ctx.GetStub().GetCreator()
	if err != nil {
		return "", fmt.Errorf("failed to get creator: %v", err)
	}

	creatorBase64 := base64.StdEncoding.EncodeToString(creator)
	serverKey := fmt.Sprintf("server:%s", creatorBase64)

	existingTopic, err := ctx.GetStub().GetState(serverKey)
	if err != nil {
		return "", fmt.Errorf("failed to get state: %v", err)
	}
	if existingTopic != nil {
		return "", fmt.Errorf("server is already registered")
	}

	err = ctx.GetStub().PutState(serverKey, []byte(topic))
	if err != nil {
		return "", fmt.Errorf("failed to put state: %v", err)
	}
	return creatorBase64, nil
}

func (s *SplitLearningContract) GetServerAddress(ctx contractapi.TransactionContextInterface) ([]string, error) {
	prefix := "server:A"
	sufix := "server:Z"

	resultsIterator, err := ctx.GetStub().GetStateByRange(prefix, sufix)
	if err != nil {
		return nil, fmt.Errorf("failed to get state: %v", err)
	}
	defer resultsIterator.Close()

	var serverAddresses []string
	for resultsIterator.HasNext() {
		queryResponse, err := resultsIterator.Next()
		if err != nil {
			return nil, fmt.Errorf("failed to iterate results: %v", err)
		}
		serverAddresses = append(serverAddresses, queryResponse.Key)
	}

	if len(serverAddresses) == 0 {
		return nil, fmt.Errorf("no server addresses found")
	}

	return serverAddresses, nil
}

func (s *SplitLearningContract) RegisterClient(ctx contractapi.TransactionContextInterface, serverAddress string) (string, error) {
	stub := ctx.GetStub()
	creator, err := stub.GetCreator()
	if err != nil {
		return "", fmt.Errorf("failed to get creator: %v", err)
	}

	creatorBase64 := base64.StdEncoding.EncodeToString(creator)
	clientKey := fmt.Sprintf("clientToServer:%s", creatorBase64)

	existingServer, err := stub.GetState(clientKey)
	if err != nil {
		return "", fmt.Errorf("failed to get state: %v", err)
	}

	if existingServer != nil {
		return creatorBase64, nil
	}

	serverKey := fmt.Sprintf("server:%s", serverAddress)
	registeredServer, err := stub.GetState(serverKey)
	if err != nil {
		return "", fmt.Errorf("failed to get state: %v", err)
	}
	if registeredServer == nil {
		return "", fmt.Errorf("server is not registered")
	}

	err = stub.PutState(clientKey, []byte(serverAddress))
	if err != nil {
		return "", fmt.Errorf("failed to put state: %v", err)
	}

	// AUTO-DISCOVERY: Register MSP
	mspID, err := cid.GetMSPID(stub)
	if err == nil {
		s.ensureMSPRegistered(stub, mspID)
	}

	totalClientsBytes, _ := stub.GetState(TotalClientsKey)
	var currentTotal int = 0
	if totalClientsBytes != nil {
		currentTotal, _ = strconv.Atoi(string(totalClientsBytes))
	}
	currentTotal++
	stub.PutState(TotalClientsKey, []byte(strconv.Itoa(currentTotal)))
	// -----------------------------------------------

	return creatorBase64, nil
}

func (s *SplitLearningContract) AddIntermediateData(ctx contractapi.TransactionContextInterface) error {
	stub := ctx.GetStub()

	// 1. Identity & MSP
	creatorBytes, err := stub.GetCreator()
	if err != nil {
		return fmt.Errorf("GetCreator failed: %v", err)
	}
	clientID := base64.StdEncoding.EncodeToString(creatorBytes)

	mspID, err := cid.GetMSPID(stub)
	if err != nil {
		return fmt.Errorf("GetMSPID failed: %v", err)
	}

	if err := s.ensureMSPRegistered(stub, mspID); err != nil {
		fmt.Printf("Warning: failed to register MSP dynamically: %v\n", err)
	}

	// 2. Verify client→server binding
	assocKey := fmt.Sprintf("clientToServer:%s", clientID)
	serverAddr, err := stub.GetState(assocKey)
	if err != nil {
		return fmt.Errorf("get binding failed: %v", err)
	}
	if serverAddr == nil {
		return fmt.Errorf("client %s not bound to any server", clientID)
	}

	// 3. Pull the IPFS CID
	transientMap, err := stub.GetTransient()
	if err != nil {
		return fmt.Errorf("GetTransient failed: %v", err)
	}
	cidBytes, ok := transientMap["cid"]
	if !ok {
		return fmt.Errorf("transient 'cid' not found")
	}
	ipfsCID := string(cidBytes)

	// 4. Write into the per-MSP PDC
	mspMapKey := fmt.Sprintf("clientToMSP-%s", clientID)
	if err := stub.PutState(mspMapKey, []byte(mspID)); err != nil {
		return fmt.Errorf("failed to record client MSP: %v", err)
	}
	collName := fmt.Sprintf("intermediateDataHashCollection%s", mspID)
	pdcKey := fmt.Sprintf("intermediateData-%s", clientID)
	dataStruct := Data{IntermediateData: string(cidBytes)}
	dataBytes, err := json.Marshal(dataStruct)
	if err != nil {
		return fmt.Errorf("marshal failed: %v", err)
	}
	if err := stub.PutPrivateData(collName, pdcKey, dataBytes); err != nil {
		return fmt.Errorf("PutPrivateData failed on %s: %v", collName, err)
	}

	// 5. Grab hash
	hashBytes, err := stub.GetPrivateDataHash(collName, pdcKey)
	if err != nil {
		return fmt.Errorf("GetPrivateDataHash failed: %v", err)
	}
	ledgerKey := fmt.Sprintf("intermediateHash-%s", clientID)
	if err := stub.PutState(ledgerKey, hashBytes); err != nil {
		return fmt.Errorf("PutState failed: %v", err)
	}

	// 6. Emit event
	eventName := fmt.Sprintf("IntermediateDataAdded:%s", clientID)
	eventPayload, _ := json.Marshal(map[string]string{
		"dataHash": ipfsCID,
		"txID":     stub.GetTxID(),
		"mspID":    mspID,
	})
	if err := stub.SetEvent(eventName, eventPayload); err != nil {
		return fmt.Errorf("SetEvent failed: %v", err)
	}

	return nil
}

func (s *SplitLearningContract) AddGradients(ctx contractapi.TransactionContextInterface, clientBase64 string) error {
	stub := ctx.GetStub()

	// 1. Verify this server is indeed bound to that client
	creatorBytes, err := stub.GetCreator()
	if err != nil {
		return fmt.Errorf("GetCreator failed: %v", err)
	}
	serverID := base64.StdEncoding.EncodeToString(creatorBytes)

	bindKey := fmt.Sprintf("clientToServer:%s", clientBase64)
	binding, err := stub.GetState(bindKey)
	if err != nil {
		return fmt.Errorf("get binding failed: %v", err)
	}
	if binding == nil || string(binding) != serverID {
		return fmt.Errorf("client %s not bound to server %s", clientBase64, serverID)
	}

	// 2. Pull the CID from transient
	mspMapKey := fmt.Sprintf("clientToMSP-%s", clientBase64)
	mspBytes, err := stub.GetState(mspMapKey)
	if err != nil {
		return fmt.Errorf("failed to lookup client MSP: %v", err)
	}
	if len(mspBytes) == 0 {
		return fmt.Errorf("no MSP recorded for client %s", clientBase64)
	}
	clientMSP := string(mspBytes)

	transientMap, err := stub.GetTransient()
	if err != nil {
		return fmt.Errorf("GetTransient failed: %v", err)
	}
	gradCID, ok := transientMap["cid"]
	if !ok {
		return fmt.Errorf("transient 'cid' not found")
	}
	ipfsCID := string(gradCID)

	// 3. Write to PDC
	collName := fmt.Sprintf("intermediateDataHashCollection%s", clientMSP)
	pdcKey := fmt.Sprintf("gradients-%s", clientBase64)
	dataStruct := Data{GradientData: string(gradCID)}
	dataBytes, _ := json.Marshal(dataStruct)
	if err := stub.PutPrivateData(collName, pdcKey, dataBytes); err != nil {
		return fmt.Errorf("PutPrivateData failed on %s: %v", collName, err)
	}

	// 4. Record hash on-ledger
	hashBytes, err := stub.GetPrivateDataHash(collName, pdcKey)
	if err != nil {
		return fmt.Errorf("GetPrivateDataHash failed: %v", err)
	}
	ledgerKey := fmt.Sprintf("gradientsHash-%s", clientBase64)
	if err := stub.PutState(ledgerKey, hashBytes); err != nil {
		return fmt.Errorf("PutState failed: %v", err)
	}

	// 6. Emit event
	eventName := fmt.Sprintf("GradientsAdded:%s", clientBase64)
	eventPayload, _ := json.Marshal(map[string]string{
		"dataHash": ipfsCID,
		"txID":     stub.GetTxID(),
		"mspID":    clientMSP,
	})
	if err := stub.SetEvent(eventName, eventPayload); err != nil {
		return fmt.Errorf("SetEvent failed: %v", err)
	}

	return nil
}

func (s *SplitLearningContract) SubmitClientModelHash(ctx contractapi.TransactionContextInterface, roundID string, datasetSizeStr string) error {
	stub := ctx.GetStub()

	creator, err := stub.GetCreator()
	if err != nil {
		return fmt.Errorf("GetCreator failed: %v", err)
	}
	clientID := base64.StdEncoding.EncodeToString(creator)

	mspID, err := cid.GetMSPID(stub)
	if err != nil {
		return fmt.Errorf("GetMSPID failed: %v", err)
	}

	s.ensureMSPRegistered(stub, mspID)

	tm, err := stub.GetTransient()
	if err != nil {
		return fmt.Errorf("GetTransient failed: %v", err)
	}
	hashBytes, ok := tm["modelHash"]
	if !ok {
		return fmt.Errorf("transient field 'modelHash' not found")
	}
	modelHash := string(hashBytes)

	collName := fmt.Sprintf("clientModelHashCollection%s", mspID)
	update := ClientModelUpdate{
		RoundID:        roundID,
		ModelParamHash: modelHash,
		ClientID:       clientID,
		DatasetSize:    datasetSizeStr,
	}
	updBytes, err := json.Marshal(update)
	if err != nil {
		return fmt.Errorf("marshal update failed: %v", err)
	}
	pdcKey := fmt.Sprintf("clientUpdate-%s-%s", roundID, clientID)
	if err := stub.PutPrivateData(collName, pdcKey, updBytes); err != nil {
		return fmt.Errorf("PutPrivateData failed on %s: %v", collName, err)
	}

	hashOnLedger, err := stub.GetPrivateDataHash(collName, pdcKey)
	if err != nil {
		return fmt.Errorf("GetPrivateDataHash failed: %v", err)
	}
	refKey := fmt.Sprintf("clientModelHashRef-%s-%s", roundID, clientID)
	if err := stub.PutState(refKey, hashOnLedger); err != nil {
		return fmt.Errorf("PutState failed: %v", err)
	}

	roundCounterKey := fmt.Sprintf("RoundSubmissionCount_%s", roundID)
	roundCountBytes, _ := stub.GetState(roundCounterKey)
	currentRoundCount := 0
	if roundCountBytes != nil {
		currentRoundCount, _ = strconv.Atoi(string(roundCountBytes))
	}
	currentRoundCount++
	stub.PutState(roundCounterKey, []byte(strconv.Itoa(currentRoundCount)))

	totalClientsBytes, _ := stub.GetState(TotalClientsKey)
	totalClients := 0
	if totalClientsBytes != nil {
		totalClients, _ = strconv.Atoi(string(totalClientsBytes))
	}

	if totalClients > 0 && currentRoundCount >= totalClients {
		eventName := fmt.Sprintf("RoundThresholdReached:%s", roundID)
		stub.SetEvent(eventName, []byte(roundID))
	}
	// ---------------------------------------------------

	return nil
}

func (s *SplitLearningContract) TriggerClientAggregation(ctx contractapi.TransactionContextInterface, roundID string) error {
	stub := ctx.GetStub()

	bytes, err := stub.GetState(RegisteredMSPsKey)
	if err != nil {
		return fmt.Errorf("failed to get registered MSPs: %v", err)
	}
	var msps []string
	if bytes != nil {
		json.Unmarshal(bytes, &msps)
	}

	prefix := fmt.Sprintf("clientUpdate-%s-", roundID)
	var allUpdates []ClientModelUpdate
	endKey := prefix + "\u00FF"

	// 2) Iterar sobre los MSPs descubiertos dinámicamente
	for _, mspID := range msps {
		collName := fmt.Sprintf("clientModelHashCollection%s", mspID)

		iter, err := stub.GetPrivateDataByRange(collName, prefix, endKey)
		if err != nil {
			fmt.Printf("Warning: Skipping collection %s: %v\n", collName, err)
			continue
		}

		func() {
			defer iter.Close()
			for iter.HasNext() {
				qr, err := iter.Next()
				if err != nil {
					return
				}

				dataBytes, err := stub.GetPrivateData(collName, qr.Key)
				if err != nil || len(dataBytes) == 0 {
					continue
				}

				var upd ClientModelUpdate
				if err := json.Unmarshal(dataBytes, &upd); err == nil {
					allUpdates = append(allUpdates, upd)
				}
			}
		}()
	}

	if len(allUpdates) == 0 {
		return fmt.Errorf("no client updates found for round %s", roundID)
	}

	eventName := fmt.Sprintf("AggregationTaskStart:%s", roundID)
	payload := struct {
		RoundID string              `json:"roundID"`
		Updates []ClientModelUpdate `json:"updates"`
	}{
		RoundID: roundID,
		Updates: allUpdates,
	}

	payloadBytes, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("failed to marshal event payload: %v", err)
	}
	if err := stub.SetEvent(eventName, payloadBytes); err != nil {
		return fmt.Errorf("failed to emit %s: %v", eventName, err)
	}

	return nil
}

func (s *SplitLearningContract) CommitGlobalModelHash(ctx contractapi.TransactionContextInterface, roundID string, aggregatedGlobalModelHash string, ipfsCid string) error {
	creator, err := ctx.GetStub().GetCreator()
	if err != nil {
		return fmt.Errorf("failed to get creator: %v", err)
	}
	clientID := base64.StdEncoding.EncodeToString(creator)

	commit := GlobalModelCommit{
		RoundID:                   roundID,
		AggregatedGlobalModelHash: aggregatedGlobalModelHash,
		IPFSCid:                   ipfsCid,
		ClientID:                  clientID,
	}
	commitBytes, err := json.Marshal(commit)
	if err != nil {
		return fmt.Errorf("failed to marshal global model commit: %v", err)
	}

	pdcKey := fmt.Sprintf("globalCommit-%s-%s", roundID, clientID)
	err = ctx.GetStub().PutPrivateData("globalModelHashCollection", pdcKey, commitBytes)
	if err != nil {
		return fmt.Errorf("failed to put global model commit in PDC: %v", err)
	}

	eventPayload := map[string]string{
		"roundID":  roundID,
		"clientID": clientID,
	}
	payloadBytes, _ := json.Marshal(eventPayload)

	if err := ctx.GetStub().SetEvent("GlobalModelHashCommitted", payloadBytes); err != nil {
		return fmt.Errorf("failed to set event: %v", err)
	}
	// --------------------------------------------------

	return nil
}

func (s *SplitLearningContract) EndGlobalModel(ctx contractapi.TransactionContextInterface, roundID string) error {
	iter, err := ctx.GetStub().GetPrivateDataByRange(
		"globalModelHashCollection",
		"globalCommit-"+roundID+"-",
		"globalCommit-"+roundID+"-\u00FF",
	)
	if err != nil {
		return err
	}
	defer iter.Close()

	voteCounts := map[string]int{}
	cidForHash := map[string]string{}
	total := 0

	for iter.HasNext() {
		qr, _ := iter.Next()
		var c GlobalModelCommit
		json.Unmarshal(qr.Value, &c)
		voteCounts[c.AggregatedGlobalModelHash]++
		total++
		if _, seen := cidForHash[c.AggregatedGlobalModelHash]; !seen {
			cidForHash[c.AggregatedGlobalModelHash] = c.IPFSCid
		}
	}

	var winnerHash string
	maxVotes := 0
	for h, cnt := range voteCounts {
		if cnt > maxVotes {
			maxVotes, winnerHash = cnt, h
		}
	}
	if maxVotes == 0 {
		return fmt.Errorf("no commits for round %s", roundID)
	}

	const quorumRatio = 0.66
	if float64(maxVotes)/float64(total) < quorumRatio {
		return fmt.Errorf(
			"consensus not met for round %s: %d/%d votes (need ≥ %.0f%%)",
			roundID,
			maxVotes,
			total,
			quorumRatio*100,
		)
	}

	finalCid := cidForHash[winnerHash]
	eventName := fmt.Sprintf("GlobalModelUpdated:%s", roundID)
	return ctx.GetStub().SetEvent(eventName, []byte(finalCid))
}

func main() {
	chaincode, err := contractapi.NewChaincode(&SplitLearningContract{})
	if err != nil {
		return
	}

	if err := chaincode.Start(); err != nil {
	}
}
