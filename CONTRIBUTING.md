# Contributing

Report reproducible issues through [GitHub Issues](https://github.com/double-u-zw/Ecru/issues).
Include Ecru version/build (About Ecru), macOS version, chip, steps and expected
behavior. Use a synthetic PDF or a document you have permission to share;
remove private content from screenshots and logs.

Read [BUILDING.md](BUILDING.md) before making changes. Keep changes small and
focused. Run core tests, and run UI checks for window or interaction changes.
Explain what changed, why, how it was tested and any remaining limitations.

Preserve PDF compatibility identifiers, recovery data and authoritative saved
stroke outlines. The current `google-ink-daily-v5` engine is frozen for beta.2:
do not change input filters or brush parameters as incidental UI cleanup.
Dependency changes must identify the upstream revision and retain its licenses.

Contributions intentionally submitted for inclusion are licensed under
Apache-2.0 unless explicitly stated otherwise. Retain third-party copyright
and license notices. Derivative distributions are allowed by the project license;
use a distinct application identity/data directory for independently distributed
forks, and identify their origin and modifications clearly.
