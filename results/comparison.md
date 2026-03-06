# Benchmark Comparison

Shared configurations compared between **Claude Code** (10 trials) and **Codex Exec** (3 trials).

Time ratios are directly comparable. Cost ratios are less apples-to-apples because they reflect each agent's published pricing, and the Codex run used the `fast` service tier.

| Language | Claude Code Time | Codex Exec Time | Time Ratio | Claude Code Cost | Codex Exec Cost | Cost Ratio | Rank Change |
|----------|----------------:|----------------:|----------------:|----------------:|----------------:|----------------:|------------:|
| Ruby | 73.1s | 86.9s | 1.19x | $0.36 | $1.27 | 3.53x | +0 |
| JavaScript | 81.1s | 91.8s | 1.13x | $0.39 | $1.35 | 3.48x | +1 |
| TypeScript | 133.0s | 105.8s | 0.80x | $0.62 | $1.61 | 2.61x | +8 |
| Python/mypy | 125.3s | 112.8s | 0.90x | $0.57 | $1.84 | 3.23x | +3 |
| Python | 74.6s | 113.3s | 1.52x | $0.38 | $1.49 | 3.91x | -3 |
| Go | 101.6s | 117.1s | 1.15x | $0.50 | $1.86 | 3.75x | -2 |
| Perl | 130.2s | 118.2s | 0.91x | $0.55 | $1.83 | 3.31x | +2 |
| OCaml | 128.1s | 133.7s | 1.04x | $0.58 | $1.73 | 2.98x | +0 |
| Lua | 143.6s | 136.1s | 0.95x | $0.58 | $1.71 | 2.92x | +3 |
| Rust | 113.7s | 138.5s | 1.22x | $0.54 | $1.75 | 3.25x | -5 |
| Haskell | 174.0s | 143.0s | 0.82x | $0.74 | $2.24 | 3.03x | +3 |
| Scheme | 130.6s | 149.2s | 1.14x | $0.60 | $2.08 | 3.45x | -2 |
| Java | 115.4s | 155.7s | 1.35x | $0.50 | $1.85 | 3.68x | -7 |
| C | 155.8s | 191.9s | 1.23x | $0.74 | $2.06 | 2.79x | -1 |
| Ruby/Steep | 186.6s | 197.0s | 1.06x | $0.84 | $4.07 | 4.85x | +0 |
