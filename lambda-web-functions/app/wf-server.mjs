// wf-server.mjs - the Lambda Web Function: a plain Node HTTP server, no handler and no adapter.
// UNVERIFIED (Web Functions are days old): how Lambda tells the server which port to listen on. This file listens on
// process.env.PORT if set, else 8080, on all interfaces. If the first deploy shows 502 Application.TimeoutListenError,
// check the Web Functions documentation for the port contract and set it here; nothing else depends on it.
import http from 'node:http';
import { route } from './core.mjs';

const port = parseInt(process.env.PORT || process.env.AWS_LAMBDA_WEB_PORT || '8080', 10);

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://local');
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) headers[k.toLowerCase()] = v;
  route(
    { kind: 'web-function', method: req.method, path: url.pathname, query: url.searchParams, headers },
    {
      start: (status, h) => res.writeHead(status, h),
      write: (c) => res.write(c),
      end: () => res.end(),
    },
  ).catch((err) => {
    console.error('handler error', err && err.message);
    if (!res.headersSent) res.writeHead(500, { 'content-type': 'application/json' });
    res.end('{"error":"internal"}');
  });
});
server.keepAliveTimeout = 65000;
server.listen(port, '0.0.0.0', () => console.log(`listening on ${port}`));
