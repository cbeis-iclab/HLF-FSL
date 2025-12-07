#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Genera collections_config.json con endorsementPolicy:
- Global: TODOS los MSP en policy y endorsementPolicy.
- Por cliente: CLIENTE + TODOS los SERVIDORES en policy y endorsementPolicy.
No modifica nada más.
"""
import json
from typing import List

def msp(org:int)->str:
    return f"Org{org}MSP"

def member_expr(orgs:List[int])->str:
    inner = ",".join([f"'{msp(o)}.member'" for o in orgs])
    return f"OR({inner})"

def peer_expr(orgs:List[int])->str:
    inner = ",".join([f"'{msp(o)}.peer'" for o in orgs])
    return f"OR({inner})"

def ask_int(prompt:str, default:int)->int:
    raw = input(f"{prompt} [{default}]: ").strip()
    return default if raw == "" else int(raw)

def main():
    # ---- Inputs ----
    total_orgs      = ask_int("Total de organizaciones (incluye servidores y clientes)", 10)
    num_servers     = ask_int("Número de organizaciones servidor (comienzan desde Org1)", 1)
    clients_from    = ask_int("Org de inicio para clientes (si servidores son 1..S suele ser S+1)", num_servers+1)
    num_clients     = ask_int("Número de clientes", max(0, total_orgs - num_servers))

    # Knobs que quieres conservar (solo pedimos valor):
    requiredPeerCount = ask_int("requiredPeerCount", 0)
    maxPeerCount      = ask_int("maxPeerCount", 3)
    blockToLive       = ask_int("blockToLive", 1_000_000)
    memberOnlyRead    = True
    memberOnlyWrite   = True

    # ---- Conjuntos derivados ----
    servers = list(range(1, num_servers+1))
    clients = list(range(clients_from, clients_from+num_clients))

    # sane boundaries
    servers = [s for s in servers if 1 <= s <= total_orgs]
    clients = [c for c in clients if 1 <= c <= total_orgs and c not in servers]

    collections = []

    # ---- Por cliente: cliente + todos los servidores ----
    for c in clients:
        parties = [c] + servers
        # clientModelHashCollection
        collections.append({
            "name": f"clientModelHashCollection{msp(c)}",
            "policy": member_expr(parties),
            "requiredPeerCount": requiredPeerCount,
            "maxPeerCount": maxPeerCount,
            "blockToLive": blockToLive,
            "memberOnlyRead": memberOnlyRead,
            "memberOnlyWrite": memberOnlyWrite,
        })
        # intermediateDataHashCollection
        collections.append({
            "name": f"intermediateDataHashCollection{msp(c)}",
            "policy": member_expr(parties),
            "requiredPeerCount": requiredPeerCount,
            "maxPeerCount": maxPeerCount,
            "blockToLive": blockToLive,
            "memberOnlyRead": memberOnlyRead,
            "memberOnlyWrite": memberOnlyWrite,
        })

    # ---- Global: TODOS ----
    all_orgs = list(range(1, total_orgs+1))
    collections.append({
        "name": "globalModelHashCollection",
        "policy": member_expr(all_orgs),
        "requiredPeerCount": requiredPeerCount,
        "maxPeerCount": maxPeerCount,
        "blockToLive": blockToLive,
        "memberOnlyRead": memberOnlyRead,
        "memberOnlyWrite": memberOnlyWrite,
    })

    with open("collections_config.json", "w", encoding="utf-8") as f:
        json.dump(collections, f, indent=2, ensure_ascii=False)

    print(f"✅ Escrito collections_config.json con {len(collections)} colecciones.")
    print("Servidores:", servers)
    print("Clientes:", clients)

if __name__ == "__main__":
    main()
