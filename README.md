# blog-samples
Deployable, tested code samples for the AR Logs blog (CloudFront, CDN, security, AI)

Each sample is a folder with its own README that opens with the problem it solves, what it deploys, the cost, the tests and the teardown.
Samples are for testing in a throwaway account. Read the safety notes in each README before you deploy.

| Sample | What it shows |
|---|---|
| [cloudfront-request-routing](cloudfront-request-routing/) | CloudFront as a reverse proxy for many backends: one catch-all behavior, a CloudFront Function and a KeyValueStore route table, no distribution change per route. CloudFormation, unit tests, a verify script and teardown. |

License: [MIT](LICENSE).
