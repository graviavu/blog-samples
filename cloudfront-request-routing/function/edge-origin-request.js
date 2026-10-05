'use strict';

// Placeholder route table. Lambda@Edge does not support environment variables,
// so the table lives in the code package or in a data source the function calls.
const ROUTES = {
  'route-a': 'origin-a.example.net',
  'route-b': 'origin-b.example.net',
};

// 'host' is the post's example; 'x-backend' works on the *.cloudfront.net domain.
// The attribute must be forwarded to the origin request event (cache key or origin request policy).
const ROUTE_ATTRIBUTE = 'x-backend';

exports.handler = (event, context, callback) => {
  const request = event.Records[0].cf.request;
  const attribute = request.headers[ROUTE_ATTRIBUTE];
  const key = attribute && attribute[0] ? attribute[0].value.toLowerCase().split(':')[0].replace(/\.$/, '') : '';
  const target = Object.prototype.hasOwnProperty.call(ROUTES, key) ? ROUTES[key] : undefined;

  if (!target) {
    // Unknown key: answer here, do not fall through to the default origin.
    callback(null, { status: '404', statusDescription: 'Not Found' });
    return;
  }
  if (request.origin.custom) {
    request.origin.custom.domainName = target;
    request.headers.host = [{ key: 'Host', value: target }];
  }
  callback(null, request);
};
