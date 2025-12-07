#!/usr/bin/env bash
set -e

# clean up function
cleanup() {
  echo "⏹️  Killing processes…"
  kill "${pids[@]}" 2>/dev/null || true
}
trap cleanup EXIT SIGINT SIGTERM

# Build once
echo "🔨 Building project…"
npm run build

# 1. Arrancar Servidor (Org1)
echo "🚀 Starting Admin server on HTTP=3000 WS=8080"
ORG_NAME=org1 PEER_NAME=peer0 \
MSP_ID=Org1MSP \
PEER_ENDPOINT=localhost:7051 PEER_HOST_ALIAS=peer0.org1.example.com \
CRYPTO_PATH="$PWD/test-network/organizations/peerOrganizations/org1.example.com" \
PORT=3000 WS_PORT=8080 \
node dist/server.js &
pids+=($!)

# 2. Preguntar cantidad de clientes
read -p "👥 ¿Cuántos clientes quieres levantar? (ej. 2): " num_clients

# Base ports para los clientes
http_port=3001
ws_port=8081

# 3. Bucle para generar clientes dinámicamente
# Si num_clients es 2, el bucle corre para i=1 y i=2.
# i=1 -> Org2 (1+1)
# i=2 -> Org3 (2+1)
for (( i=1; i<=num_clients; i++ )); do
  
  # Calculamos la organización destino (Server es org1, así que clientes empiezan en org2)
  org_num=$(( i + 1 ))
  org="org${org_num}"
  user="User1"     # Por defecto User1, como pediste
  peer="peer0"

  # --- Lógica dinámica de puertos ---
  case $org_num in
    2)
      # Puerto estándar Org2
      port=9051
      ;;
    *)
      port=$(( 11051 + (org_num - 3) * 5 ))
      ;;
  esac
  
  endpoint="localhost:${port}"
  # ----------------------------------

  # Derivar resto de variables
  msp="${org^}MSP"  # org2 -> Org2MSP
  alias="${peer}.${org}.example.com"
  crypto="$PWD/test-network/organizations/peerOrganizations/${org}.example.com"

  echo "🤖  Starting client #$i: $user (@${org}) on HTTP=${http_port} WS=${ws_port} -> Peer: $endpoint"

  ORG_NAME=$org PEER_NAME=$peer \
  MSP_ID=$msp \
  PEER_ENDPOINT=$endpoint PEER_HOST_ALIAS=$alias \
  CRYPTO_PATH=$crypto \
  USER_NAME=$user \
  PORT=$http_port WS_PORT=$ws_port \
  node dist/client.js &

  pids+=($!)
  ((http_port++))
  ((ws_port++))
done

# ─── Wait for everyone ────────────────────────────────────────────────────────
wait
echo "✅ All done."