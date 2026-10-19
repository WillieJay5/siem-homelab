# elk

Elastic stack: docker-compose.yml and .env.example (never .env).

Single node on `elk01` (Servers VLAN): Elasticsearch `:9200`, Kibana `:5601`, Fleet Server `:8220`, all TLS with a self-signed CA made by the `certs` job. Needs Docker Engine 26+ (volume subpaths).

Hardening: the CA private key is only in the `ca` volume (mounted by the `certs` job alone); each service gets only the CA cert and its own key, read-only, with no world-readable files. Fleet Server authenticates with a service token created by `setup`, not the `elastic` superuser.

## Run

```bash
cp .env.example .env          # fill in passwords, ENCRYPTION_KEY, ELK_FQDN
docker compose config -q      # validate
docker compose up -d
docker compose logs -f setup  # wait for "Setup done."
```

Log in to `https://<ELK_FQDN>:5601` as `elastic`. To trust the CA in your browser and on agents:

```bash
docker compose cp es01:/usr/share/elasticsearch/config/certs/ca/ca.crt .
```

`kibana.yml` preconfigures the Fleet Server policy and the Fleet Server host (`https://<ELK_FQDN>:8220`).

## After first start (Kibana → Fleet → Settings)

- **Default output:** `https://<ELK_FQDN>:9200`, with the CA fingerprint from
  `openssl x509 -fingerprint -sha256 -noout -in ca.crt | cut -d= -f2 | tr -d :`

Until the output is changed from its `localhost` default, agents (Fleet Server included) can't ship data.
