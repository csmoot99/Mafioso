# Scout: Checkout latency & Ünïcode

## Findings

- The **payment gateway** retries three times before failing.
- [Grafana dashboard](https://grafana.example.com/d/abc) shows p99 at 2.4s.
- [ ] Follow up on the zebrafish cache eviction.

| metric | value |
|---|---|
| p50 | 180ms |
| p99 | 2400ms |

```
SELECT * FROM orders WHERE slow = true;
```

> A quote about <script>alert(1)</script> injection.
