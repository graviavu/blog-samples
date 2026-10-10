// Tiny test origin (Lambda function URL). Returns {now, counter, nonce, path}. It sends NO Cache-Control header,
// so the Lambda@Edge function alone decides. The nonce is unique per invocation: a repeated nonce means CloudFront answered
// from its cache. The counter counts invocations of this execution environment (it restarts on a cold start).
// Any path starting with /err answers 500.
let counter = 0;
const instance = Math.random().toString(36).slice(2, 8);
export const handler = async (event) => {
  counter += 1;
  const path = (event && event.rawPath) || '/';
  const body = JSON.stringify({
    now: new Date().toISOString(),
    counter,
    nonce: `${instance}-${counter}-${Math.random().toString(36).slice(2, 8)}`,
    path,
  });
  return {
    statusCode: path.startsWith('/err') ? 500 : 200,
    headers: { 'content-type': 'application/json' },
    body,
  };
};
