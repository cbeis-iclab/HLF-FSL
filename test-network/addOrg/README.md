# Adding Organizations Dynamically

Use the `addOrg.sh` script to extend the Fabric test network with additional peer organizations. Each execution discovers the next available organization number (Org3, Org4, …), generates the required crypto material, updates the channel configuration, starts the new peer, and joins it to the specified channel.

Typical workflow:

```bash
./network.sh up createChannel
cd addOrg
./addOrg.sh up
```

Running `./addOrg.sh up` repeatedly continues adding Org4, Org5, and so on. Pass `-c <channel>` to target a different channel, `-s couchdb` to deploy CouchDB, or `-ca` to use Fabric CAs instead of cryptogen. The `generate` mode prepares artifacts without starting containers, while `down` delegates to `../network.sh down`.

Each additional organization reuses the same Compose project as the core test network, so `network.sh down` cleans everything automatically. Ports for new peers, chaincode listeners, CAs, and CouchDB instances increment in steps of 10 beyond Org3 (for example, Org4 uses 11061/11062/11064/9994).
