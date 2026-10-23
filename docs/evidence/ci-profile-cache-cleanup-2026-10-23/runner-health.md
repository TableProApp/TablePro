# Runner health, October 23, 2026

Read-only SSH checks around 08:57 UTC found exec-a, exec-b and exec-c reachable with active forgejo-runner services. Each reported GTK 4.24.1, libadwaita 1.10.0 and GtkSourceView 5.22.0. Journals showed new task assignments on all three hosts without connection errors in the sampled tail.

Available root disk space was 26 GiB on exec-a (94% used), 34 GiB on exec-b (91%) and 27 GiB on exec-c (91%). This is limited headroom, not evidence of a current disk-full failure. No cache deletion or service restart was performed.

The supplied runner inventory screenshot showed Ubuntu registered only under ubuntu2604-canary and gnome50-host, so it cannot receive any-host work. exec-d and exec-e were offline. Their offline state was not independently probed in this check.

The API showed an old-head rerun of #922 and new run #923 during the sample. #922 retained guard and widget failures already traced to generated notices and the truncation assertion. Run #923 had guards, unit and sandbox active. Task status and run summary were not synchronized during reruns, so an Active badge alone does not establish CPU work or a stuck runner. No new gate was started by this diagnostic.
