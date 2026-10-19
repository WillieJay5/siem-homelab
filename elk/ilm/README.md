# elk/ilm

Index lifecycle management policies.

Elastic's built-in `logs` and `metrics` policies roll over but **never delete**, so a 150 GB disk eventually fills and Elasticsearch stops writing at the 95% flood-stage watermark. These policies add deletion, and the `@custom` component templates apply them to every `logs-*-*` and `metrics-*-*` data stream (Fleet integrations included). Replicas are set to 0 because a single node can't place them (otherwise every index stays yellow).

Paste into Kibana → Dev Tools. New settings take effect on each data stream's next rollover.

```
PUT _ilm/policy/lab-logs
{
  "policy": {
    "phases": {
      "hot": { "actions": { "rollover": { "max_age": "7d", "max_primary_shard_size": "10gb" } } },
      "delete": { "min_age": "30d", "actions": { "delete": {} } }
    }
  }
}

PUT _ilm/policy/lab-metrics
{
  "policy": {
    "phases": {
      "hot": { "actions": { "rollover": { "max_age": "7d", "max_primary_shard_size": "10gb" } } },
      "delete": { "min_age": "14d", "actions": { "delete": {} } }
    }
  }
}

PUT _component_template/logs@custom
{
  "template": { "settings": { "index.lifecycle.name": "lab-logs", "index.number_of_replicas": 0 } }
}

PUT _component_template/metrics@custom
{
  "template": { "settings": { "index.lifecycle.name": "lab-metrics", "index.number_of_replicas": 0 } }
}
```

Retention (30 days logs, 14 days metrics) is a starting guess. Check disk use weekly with `GET _cat/allocation?v` and shorten if it passes ~60%.
