// A git server over HTTP for the Forgejo tests: the bare repositories under <root>/<owner>/<name>.git, served by
// git http-backend, behind a login that is the token in <token file> given as the password of HTTP Basic with any
// username, which is how Forgejo takes an access token. A request without the token is answered 401, so git has
// to ask its credential helper; every request is logged to <log> as "<status> <METHOD> <path> user=<name>".
// Prints its port and runs until it is killed.
//
//   node tests/git-http-server.mjs <root> <token file> <log>
import http from 'node:http';
import fs from 'node:fs';
import { spawn } from 'node:child_process';

const [root, tokenFile, logFile] = process.argv.slice(2);
const server = http.createServer((req, res) => {
  const chunks = [];
  req.on('data', (c) => chunks.push(c));
  req.on('end', () => {
    const url = new URL(req.url, 'http://localhost');
    const auth = (req.headers.authorization || '').match(/^Basic (.*)$/);
    const [user, pass] = auth ? Buffer.from(auth[1], 'base64').toString().split(/:(.*)/s) : [];
    const log = (status) => fs.appendFileSync(logFile, `${status} ${req.method} ${url.pathname} user=${user || '-'}\n`);
    if (!auth || pass !== fs.readFileSync(tokenFile, 'utf8').trim()) {
      log(401); res.writeHead(401, { 'WWW-Authenticate': 'Basic realm="forge"' }); return res.end('login required');
    }
    const body = Buffer.concat(chunks);
    const env = { PATH: process.env.PATH, GIT_PROJECT_ROOT: root, GIT_HTTP_EXPORT_ALL: '1', REMOTE_USER: user, REMOTE_ADDR: '127.0.0.1',
      REQUEST_METHOD: req.method, PATH_INFO: url.pathname, QUERY_STRING: url.search.slice(1),
      CONTENT_TYPE: req.headers['content-type'] || '', CONTENT_LENGTH: String(body.length) };
    if (req.headers['content-encoding']) env.HTTP_CONTENT_ENCODING = req.headers['content-encoding'];
    if (req.headers['git-protocol']) env.HTTP_GIT_PROTOCOL = req.headers['git-protocol'];
    const cgi = spawn('git', ['http-backend'], { env });
    cgi.stdin.on('error', () => {});   // git may exit without reading the body; what it wrote is still the answer
    cgi.stdin.end(body);
    const out = [];
    cgi.stdout.on('data', (c) => out.push(c));
    cgi.on('close', () => {
      const all = Buffer.concat(out), cut = all.indexOf('\r\n\r\n');
      const head = (cut < 0 ? '' : all.subarray(0, cut).toString()).split('\r\n'), payload = cut < 0 ? all : all.subarray(cut + 4);
      let status = 200;
      const headers = {};
      for (const line of head) {
        const [k, ...v] = line.split(': ');
        if (k.toLowerCase() === 'status') status = parseInt(v.join(': '), 10); else if (k) headers[k] = v.join(': ');
      }
      log(status); res.writeHead(status, headers); res.end(payload);
    });
  });
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
