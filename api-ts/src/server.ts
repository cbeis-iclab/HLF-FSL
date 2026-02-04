import {Express} from 'express'
import { WebSocketServer } from 'ws';
import bodyParser from 'body-parser';

import { initGateway, getContract, getNetwork } from './gateway';

const express = require('express');
const app: Express = express();
const port = parseInt(process.env.PORT || '3000', 10);

app.use(bodyParser.json({ limit: '300mb' }));
app.use(bodyParser.urlencoded({ limit: '300mb', extended: true }));

const EXPECTED_CLIENTS = parseInt(process.env.NUM_CLIENTS || '2', 10); // Set this in env!
const globalCommitProgress: Record<string, Set<string>> = {};

const wss = new WebSocketServer({ port: 8080, host: '0.0.0.0' });
let wsClient: any = null;
wss.on('connection', ws => {
  wsClient = ws;
  ws.on('close', () => {
    wsClient = null;
  });
});

app.post('/registerServer', async (req, res) => {
    const { topic } = req.body;
    try {
        const contract = await await getContract();
        await contract.submitTransaction('RegisterServer', topic); 
        res.send('Server registered.');
    } catch (error) {
        if (error instanceof Error){
            res.status(500).send(error.message);
        }
    }
});


app.post('/addGradients', async (req, res) => {
  const { clientBase64, data: cid } = req.body;
  try {
    const c = await getContract();
    await c.submit('AddGradients', {
      arguments:    [ clientBase64 ],
      transientData: { cid: Buffer.from(cid) }
    });
    console.log('✅ AddGradients was committed successfully');
    return res.json({ ok: true, cid });
  } catch (err: any) {
    return res.status(500).json({ ok: false, error: err.message });
  }
});

app.post('/triggerClientAggregation', async (req, res) => {
  const { roundID } = req.body;
  const c = getContract();
  try {
    const result = await c.submitTransaction('TriggerClientAggregation', String(roundID));
    res.json({ success: true });
  } catch (e: any) {
    res.status(500).json({ error: e.message });
  }
});

app.post('/endGlobalModel', async (req, res) => {
  const { roundID } = req.body;
  const c = getContract();
  try {
    await c.submitTransaction('EndGlobalModel', String(roundID));
    res.json({ success: true });
  } catch (e: any) {
    res.status(500).json({ error: e.message });
  }
});

async function listenForChaincodeEvents() {
  const network    = getNetwork();
  const ccName     = process.env.CHAINCODE_NAME || 'fsl';
  const events     = await network.getChaincodeEvents(ccName);

  for await (const ev of events) {
    const raw       = Buffer.from(ev.payload).toString('utf8');
    let payload: any = {};
    try { payload = JSON.parse(raw) } catch { /* ignore */ }

    // --- CHANGED: Detect RoundThresholdReached and trigger aggregation ---
    if (ev.eventName.startsWith('RoundThresholdReached:')) {
      const roundID = ev.eventName.split(':')[1];
      console.log(`⚡️ Round threshold reached for round ${roundID}. Triggering aggregation automatically...`);
      
      // The server detects the call and triggers the aggregation in the chaincode
      try {
        const contract = getContract();
        await contract.submitTransaction('TriggerClientAggregation', roundID);
        console.log(`✅ Aggregation triggered for round ${roundID}`);
      } catch (e) {
        console.error(`❌ Failed to auto-trigger aggregation:`, e);
      }
      continue;
    }

    if (ev.eventName === 'GlobalModelHashCommitted') {
          const { roundID, clientID } = payload;
          
          if (!globalCommitProgress[roundID]) {
            globalCommitProgress[roundID] = new Set();
          }

          globalCommitProgress[roundID].add(clientID);
          const currentCount = globalCommitProgress[roundID].size;

          console.log(`🗳️ [Server] Round ${roundID}: Global Commit from ${clientID} (${currentCount}/${EXPECTED_CLIENTS})`);

          if (currentCount >= EXPECTED_CLIENTS) {
            console.log(`🏁 [Server] All clients committed global model for round ${roundID}. Finalizing...`);
            
            // Wait a moment for Private Data to sync via Gossip (Crucial!)
            await new Promise(resolve => setTimeout(resolve, 3000));

            try {
              const contract = getContract();
              await contract.submitTransaction('EndGlobalModel', String(roundID));
              console.log(`✅ [Server] EndGlobalModel successfully triggered for round ${roundID}`);
              
              // Cleanup memory
              delete globalCommitProgress[roundID];
            } catch (e) {
              console.error(`❌ [Server] Failed to finalize global model:`, e);
            }
          }
          continue;
        }
    // -------------------------------------------------------------------

    if (!wsClient || wsClient.readyState !== wsClient.OPEN) {
      continue;
    }

    if (ev.eventName.startsWith('IntermediateDataAdded:')) {
      const clientId = ev.eventName.split(':')[1];
      wsClient.send(JSON.stringify({
        event:     'IntermediateDataAdded',
        payload: {
          clientId,
          dataHash: payload.dataHash,
          txID:     payload.txID,
          mspID:    payload.mspID
        }
      }));
    }
  }

  events.close();
}

async function main() {
  await initGateway();

  app.listen(port, '0.0.0.0', () => {
    console.log(`🚀 Server listening on port ${port}`);
    listenForChaincodeEvents().catch(console.error);
  });
}

main().catch(err => {
  console.error('Failed to start server:', err);
  process.exit(1);
});