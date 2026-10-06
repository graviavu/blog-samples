# blog-samples
Deployable, tested code samples for the AR Logs blog (CloudFront, CDN, security, AI)

Each sample is a folder with its own README that opens with the problem it solves, what it deploys, the cost, the tests and the teardown.
Samples are for testing in a throwaway account. Read the safety notes in each README before you deploy.

| Sample | What it shows |
|---|---|
| [cloudfront-time-window-caching](cloudfront-time-window-caching/) | Time-window caching on CloudFront without changing origins (a fixed window): short caching inside a known window and long caching outside it, decided at the edge. Cache policy TTL clamping, a CloudFront Function with a KeyValueStore window record that adds a time slot to the cache key, an optional Lambda@Edge variant. CloudFormation, unit tests, a time-driven verify script and teardown. |
