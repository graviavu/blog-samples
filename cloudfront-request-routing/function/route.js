import cf from 'cloudfront';

const kvsHandle = cf.kvs();

// Which request attribute names the route. 'host' is the post's worked example;
// 'x-backend' (a request header) lets the sample work on the *.cloudfront.net domain.
const ROUTE_ATTRIBUTE = 'x-backend';

// Allow-list for backend domains: a stored value must also end with this suffix, so a mistaken or
// malicious write to the store cannot send traffic to an arbitrary host. The default fits the sample's
// test origins (Lambda function URLs). Set it to your own domain suffix. '' disables the check.
const BACKEND_SUFFIX = '.lambda-url.us-east-1.on.aws';

// updateRequestOrigin() rejects a domain name with a colon or an IP address.
const DOMAIN = /^(?!\d+(\.\d+){3}$)[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;

function reply(statusCode, statusDescription) {
  return { statusCode: statusCode, statusDescription: statusDescription };
}

async function handler(event) {
  const request = event.request;
  const attribute = request.headers[ROUTE_ATTRIBUTE];
  if (!attribute || !attribute.value) {
    return reply(404, 'Not Found');
  }
  // Normalize the route key: lowercase, no port, no trailing dot.
  const host = attribute.value.toLowerCase().split(':')[0].replace(/\.$/, '');

  // The key comes from the request; the value is a backend domain name from the store.
  if (!host || !(await kvsHandle.exists(host))) {
    return reply(404, 'Not Found');
  }
  const backend = await kvsHandle.get(host);
  if (!DOMAIN.test(backend) || !backend.endsWith(BACKEND_SUFFIX)) {
    return reply(500, 'Bad route');   // fail closed; never fall back to the default origin
  }

  cf.updateRequestOrigin({
    domainName: backend,
    hostHeader: backend   // the backend sees its own name, not the viewer's host
  });
  return request;
}
