import cf from 'cloudfront';

const kvsHandle = cf.kvs();

// Which request attribute names the route. 'host' is the post's worked example;
// 'x-backend' (a request header) lets the sample work on the *.cloudfront.net domain.
const ROUTE_ATTRIBUTE = 'x-backend';

// Allow-list for backend domains: a stored value must also end with this suffix, so a mistaken or
// malicious write to the store cannot send traffic to an arbitrary host. The default fits the sample's
// test origins (Lambda function URLs). Set it to your own domain suffix. '' disables the check.
const BACKEND_SUFFIX = '.lambda-url.us-east-1.on.aws';

// Region of the backend function URLs. It must match BACKEND_SUFFIX. The repo default (variant V2) sends it in
// originAccessControlConfig. The AWS parameter list for originAccessControlConfig shows no `region` field, and variant V4
// (without region) also worked in our run, for a us-east-1 backend. Other Regions are untested.
const OAC_REGION = 'us-east-1';

// Test variants. The template substitutes these two values from its RouteVariant parameter
// (see function/variants.json and variants.sh). The values in this file are the default variant V2.
//   SEND_HOST_HEADER: pass hostHeader to updateRequestOrigin(). Default false: in the observed run CloudFront rejected
//                     (502 FunctionValidationError) every call with hostHeader unless OAC was explicitly disabled,
//                     and the backend saw its own host name without it.
//   OAC_MODE: 'region'   originAccessControlConfig with region (default)
//             'noregion' originAccessControlConfig without region
//             'off'      originAccessControlConfig { enabled: false }
//             'none'     no originAccessControlConfig (the origin's own OAC settings are inherited)
const SEND_HOST_HEADER = false;
const OAC_MODE = 'region';

function oacConfig() {
  if (OAC_MODE === 'none') {
    return null;
  }
  if (OAC_MODE === 'off') {
    return { enabled: false };
  }
  // Sign the request to the backend (Lambda function URL with IAM auth) with CloudFront origin access control.
  const config = {
    enabled: true,
    signingBehavior: 'always',
    signingProtocol: 'sigv4',
    originType: 'lambda'
  };
  if (OAC_MODE === 'region') {
    config.region = OAC_REGION;
  }
  return config;
}

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

  const origin = { domainName: backend };
  if (SEND_HOST_HEADER) {
    origin.hostHeader = backend;   // variants only; see the note above
  }
  const oac = oacConfig();
  if (oac) {
    origin.originAccessControlConfig = oac;
  }
  cf.updateRequestOrigin(origin);
  return request;
}
