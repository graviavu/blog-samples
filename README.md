# blog-samples
Deployable, tested code samples for the AR Logs blog (CloudFront, CDN, security, AI)

Each sample is a folder with its own README that opens with the problem it solves, what it deploys, the cost, the tests and the teardown.
Samples are for testing in a throwaway account. Read the safety notes in each README before you deploy.

| Sample | What it shows |
|---|---|
| [cloudfront-request-routing](cloudfront-request-routing/) | CloudFront as a reverse proxy for many backends: one catch-all behavior, a CloudFront Function and a KeyValueStore route table, no distribution change per route. CloudFormation, unit tests, a verify script and teardown. |
| [cloudfront-business-hours-cache](cloudfront-business-hours-cache/) | No cache in business hours, long cache outside, with a Lambda@Edge origin-response function and one window in an S3 object. One script builds a temporary stack, measures it (Hit/Miss, Age, origin hits, the boundary-expiry limitation) and tears it down. |
| [cloudfront-folder-index](cloudfront-folder-index/) | Why a folder URL such as /posts/x/ returns 403 on a private S3 bucket behind CloudFront, and the rewrite function that fixes it. One script builds a temporary stack, checks four claims from the post (PASS or FAIL with status, X-Cache, Age) and tears it down. |

License: [MIT](LICENSE).
