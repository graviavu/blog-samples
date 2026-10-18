// fu-handler.mjs - the Event Function behind a Function URL (AWS_IAM, RESPONSE_STREAM). `awslambda` is a global in the
// Node.js Lambda runtimes.
import { route } from './core.mjs';

export const handler = awslambda.streamifyResponse(async (event, responseStream) => {
  const headers = {};
  for (const [k, v] of Object.entries(event.headers || {})) headers[k.toLowerCase()] = v;
  const query = new URLSearchParams(event.rawQueryString || '');
  let stream = responseStream;
  await route(
    {
      kind: 'function-url', method: (event.requestContext && event.requestContext.http && event.requestContext.http.method) || 'GET',
      path: event.rawPath || '/', query, headers,
    },
    {
      start: (status, h) => { stream = awslambda.HttpResponseStream.from(responseStream, { statusCode: status, headers: h }); },
      write: (c) => stream.write(c),
      end: () => stream.end(),
    },
  );
});
