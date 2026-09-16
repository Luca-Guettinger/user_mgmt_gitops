// Controlled, increasing load against the user_mgmt_service.
//
// One iteration walks the whole authentication flow:
//   POST /users/register  ->  POST /users/login  ->  GET /users/me
//
// login is the expensive call on purpose: the backend hashes with Argon2
// (16 MiB, see Encoders.java), so a handful of virtual users is enough to
// push a 500m-CPU container over the HPA's 70% target.

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
const PASSWORD = 'k6-load-test-password';

export const options = {
  // Applied to every metric, so one Grafana dashboard can isolate one run.
  tags: { testid: __ENV.TEST_ID || 'manual' },
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 4 },   // warm up
        { duration: '3m', target: 8 },   // climb past the HPA threshold
        { duration: '3m', target: 8 },   // hold, so scale-up settles
        { duration: '2m', target: 0 },   // release, then watch scale-down
      ],
      gracefulRampDown: '30s',
    },
  },
  // The HPA needs 60s of sustained load before it adds a replica and 300s of
  // quiet before it removes one, so a shorter run proves nothing.
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<5000'],
    checks: ['rate>0.95'],
  },
};

export default function () {
  // Unique per iteration: email is UNIQUE NOT NULL and a duplicate raises an
  // unhandled DataIntegrityViolationException, which would show up as a 500.
  const email = `k6-${__VU}-${__ITER}-${Date.now()}@loadtest.local`;
  const json = { headers: { 'Content-Type': 'application/json' } };

  const registered = http.post(
    `${BASE_URL}/users/register`,
    JSON.stringify({ firstName: 'k6', lastName: 'Tester', email, password: PASSWORD }),
    { ...json, tags: { name: 'register' } },
  );
  check(registered, { 'register -> 201': (r) => r.status === 201 });

  const loggedIn = http.post(
    `${BASE_URL}/users/login`,
    JSON.stringify({ email, password: PASSWORD }),
    { ...json, tags: { name: 'login' } },
  );
  // The JWT comes back in the Authorization *response* header, not the body.
  const token = loggedIn.headers['Authorization'];
  check(loggedIn, {
    'login -> 200': (r) => r.status === 200,
    'login returns a token': () => !!token,
  });

  if (token) {
    const me = http.get(`${BASE_URL}/users/me`, {
      headers: { Authorization: token },
      tags: { name: 'me' },
    });
    check(me, { 'me -> 200': (r) => r.status === 200 });
  }

  sleep(1);
}
