// Test origin (Lambda function URL). Returns {now, counter, nonce, path} and NO Cache-Control header,
// so the Lambda@Edge function alone decides. A repeated nonce means CloudFront answered from its cache.
// The counter counts invocations of this execution environment. A path starting with /err answers 500.
// CommonJS on purpose: this file is pasted inline into cfn/stack.yaml (inline code is saved as index.js).
let counter = 0;
const instance = Math.random().toString(36).slice(2, 8);
exports.handler = async (event) => {
  counter += 1;
  const path = (event && event.rawPath) || '/';
  const nonce = `${instance}-${counter}-${Math.random().toString(36).slice(2, 8)}`;
  const body = JSON.stringify({ now: new Date().toISOString(), counter, nonce, path });
  return {
    statusCode: path.startsWith('/err') ? 500 : 200,
    headers: { 'content-type': 'application/json' },
    body,
  };
};
