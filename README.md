# blog-samples
Deployable, tested code samples for the AR Logs blog (CloudFront, CDN, security, AI)

Each sample is a folder with its own README that opens with the problem it solves, what it deploys, the cost, the tests and the teardown.
Samples are for testing in a throwaway account. Read the safety notes in each README before you deploy.

| Sample | What it shows |
|---|---|
| [cloudfront-request-routing](cloudfront-request-routing/) | CloudFront as a reverse proxy for many backends: one catch-all behavior, a CloudFront Function and a KeyValueStore route table, no distribution change per route. CloudFormation, unit tests, a verify script and teardown. |
| [decision-model-eval](decision-model-eval/) | Rerun a side-by-side eval of your own decision model against an LLM baseline: one wrapper interface, email triage and routing harnesses, accuracy, urgent recall, injection, option-order and reversal checks, calibration, latency and a timeout-fallback test. One script with `--dry-run`, a typed confirmation and a spend guard before any paid call. Stub tests only, no network. |

License: [MIT](LICENSE).
