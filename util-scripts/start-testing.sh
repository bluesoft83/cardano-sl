#!/usr/bin/env bash
stack exec -- cardano-node --system-start 1491770897 --explicit-initial --listen 127.0.0.1:12100 --log-config util-scripts/log-config-abc.yaml --logs-prefix "logs/abc" --db-path db-abc --peer 52.59.46.8:3000/zzQk9aJKJ9CGD3ATxO_RGUX_s7TTVS-_hw8mRkX6u9g= --wallet --wallet-db-path wdb-abc --kademlia-dump-path kademlia-abc.dump $@
