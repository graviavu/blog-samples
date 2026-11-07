# blog-samples
Deployable, tested code samples for the AR Logs blog (CloudFront, CDN, security, AI)

Each sample is a folder with its own README that opens with the problem it solves, what it deploys, the cost, the tests and the teardown.
Samples are for testing in a throwaway account. Read the safety notes in each README before you deploy.

| Sample | What it shows |
|---|---|
| [cloudfront-request-routing](cloudfront-request-routing/) | CloudFront as a reverse proxy for many backends: one catch-all behavior, a CloudFront Function and a KeyValueStore route table, no distribution change per route. CloudFormation, unit tests, a verify script and teardown. |
| [cloudfront-business-hours-cache](cloudfront-business-hours-cache/) | No cache in business hours, long cache outside, with a Lambda@Edge origin-response function and one window in an S3 object. One script builds a temporary stack, measures it (Hit/Miss, Age, origin hits, the boundary-expiry limitation) and tears it down. |
| [message-threads-test](message-threads-test/) | One script that measures what a long agent loop saves from prompt caching, message threads and a cold reload, against a full resend with no cache: TTFT median and p90, cost per turn, the 404 replay path and the single-continue rule. Stub tests, dry run, typed confirmation and a spend cap. |

License: [MIT](LICENSE).
