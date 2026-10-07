// Test-only function: answers with the Host value exactly as the function event shows it.
// It never routes anywhere and has no key value store.
function handler(event) {
  var host = event.request.headers.host;
  return {
    statusCode: 200,
    statusDescription: 'OK',
    headers: {
      'cache-control': { value: 'no-store' },
      'x-seen-host': { value: host ? host.value : '(none)' },
      'x-seen-multivalue': { value: host && host.multiValue ? JSON.stringify(host.multiValue) : '(none)' }
    }
  };
}
