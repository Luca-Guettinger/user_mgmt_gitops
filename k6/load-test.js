// Controlled, increasing load against the user_mgmt_service.
//
// Each VU registers and logs in ONCE and then loops on the read endpoint:
//   POST /users/register + POST /users/login   (once per VU)
//   GET  /users/me                             (every iteration)
//
// Runs 1-4 logged in on every iteration. Argon2 (16 MiB, see Encoders.java)
// then ate the whole CPU limit, the container could not answer its probes in
// time and both replicas went NotReady during the scale-up - the opposite of
// what Aufgabe 2 asks for. Hashing once per VU still loads the HPA over its
// 70% target, but leaves the pod responsive.

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
const PASSWORD = 'k6-load-test-password';

// Per-VU state: k6 keeps module scope alive across the iterations of one VU.
let token = null;

export const options = {
  // Applied to every metric, so one Grafana dashboard can isolate one run.
  tags: { testid: __ENV.TEST_ID || 'manual' },
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: 4 },   // warm up
        { duration: '3m', target: 12 },  // read traffic is cheap, so it takes more VUs
        { duration: '3m', target: 12 },  // hold, so scale-up settles
        { duration: '2m', target: 0 },   // release, then watch scale-down
      ],
      gracefulRampDown: '30s',
    },
  },
  // The HPA needs 60s of sustained load before it adds a replica and 300s of
  // quiet before it removes one, so a shorter run proves nothing.
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<2000'],
    checks: ['rate>0.95'],
  },
};

// Returns the JWT, or null if the sign-up flow failed - then the next
// iteration tries again. That retry is what makes the alert demo work: with
// the database scaled to zero, every iteration produces a failing register.
function signUp() {
  const email = `k6-${__VU}-${Date.now()}@loadtest.local`;
  const json = { headers: { 'Content-Type': 'application/json' } };

  const registered = http.post(
    `${BASE_URL}/users/register`,
    JSON.stringify({ firstName: 'k6', lastName: 'Tester', email, password: PASSWORD }),
    { ...json, tags: { name: 'register' } },
  );
  check(registered, { 'register -> 201': (r) => r.status === 201 });
  if (registered.status !== 201) return null;

  const loggedIn = http.post(
    `${BASE_URL}/users/login`,
    JSON.stringify({ email, password: PASSWORD }),
    { ...json, tags: { name: 'login' } },
  );
  // The JWT comes back in the Authorization *response* header, not the body.
  const jwt = loggedIn.headers['Authorization'];
  check(loggedIn, {
    'login -> 200': (r) => r.status === 200,
    'login returns a token': () => !!jwt,
  });

  return jwt || null;
}

export default function () {
  if (!token) {
    token = signUp();
    if (!token) {
      // Back off. Registration hashes with Argon2 before it ever touches the
      // database, so retrying hard during an outage is itself a load test -
      // that is what pinned both pods at their CPU limit on 2026-09-18.
      sleep(5);
      return;
    }
  }

  const me = http.get(`${BASE_URL}/users/me`, {
    headers: { Authorization: token },
    tags: { name: 'me' },
  });
  check(me, { 'me -> 200': (r) => r.status === 200 });

  // A token outlives the run, so a 401 means the pod rejected it - start over.
  if (me.status === 401) token = null;

  sleep(0.5);
}
