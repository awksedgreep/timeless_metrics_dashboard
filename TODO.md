# TimelessMetricsDashboard TODO

## Done
- [x] Project scaffold, mix.exs, deps
- [x] Reporter GenServer (ETS cache/buffer, lock-free handler, periodic flush)
- [x] DefaultMetrics (VM, Phoenix, Ecto, LiveView)
- [x] LiveDashboard Page (Overview, Metrics, Alerts, Storage tabs)
- [x] HEEx components (time picker, chart embed)
- [x] Compression ratio on Overview tab
- [x] Alert inline docs with ntfy.sh example
- [x] Flash message auto-dismiss (5s timeout + X button)
- [x] Backup download via DownloadPlug (tar.gz)
- [x] Backup path hint on Storage tab
- [x] Demo script (examples/demo.exs)
- [x] README
- [x] 20 tests passing, clean compile
- [x] Initial commit
- [x] Metric sidebar search/filter with prefix grouping
- [x] Time range vs data extent hint ("Showing 3h of 7d")
- [x] Human-readable data span on Overview tab ("12h, latest: live")
- [x] Auto-refresh chart on Metrics tab (already works via handle_refresh → load_tab_data)

## Next Up

### Git & Repo
- [ ] Push to github.com/awksedgreep/timeless_metrics_dashboard
- [ ] Add to timeless README as companion project

### Metrics Tab — Scale
- [ ] Pagination or virtual scroll if metric list gets huge
- [ ] Test with ddnet-scale data (10K devices x 100 metrics = 1M series)

### Metrics Tab — UX
- [ ] Multi-series overlay (select multiple metrics or label values to compare)
- [ ] Show latest value next to metric name in sidebar
- [ ] Label filter dropdown (e.g., pick a specific host/device)

### Overview Tab
- [ ] Overnight compression ratio results — update memory/README with real numbers
- [ ] Points/sec ingest rate (delta between refreshes)

### Alerts Tab
- [ ] Consider simple alert creation form (name, metric dropdown, condition, threshold)
- [ ] Alert history / state transitions log
- [ ] Test webhook delivery with ntfy.sh

### Storage Tab
- [ ] Backup deletion from UI
- [ ] Show per-shard DB sizes
- [ ] Scheduled backup support (or document cron approach)

### Integration
- [ ] Wire into ddnet as real-world test
- [ ] Verify with DHCP/DOCSIS metrics at scale
- [ ] Test with multiple Timeless stores (if ddnet uses more than one)
- [ ] Verify LiveDashboard auto-refresh (15s) works correctly with Page

### Hardening
- [ ] Error handling for store going down mid-session
- [ ] Handle very large query results gracefully (chart with 100K points)
- [ ] Rate-limit backup creation in UI
- [ ] DownloadPlug: streaming for large backups instead of in-memory tar
