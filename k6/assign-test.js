// Controlled, increasing load against the module assignment path.
//
// This is the load test for Aufgabe 6: it proves that the module_service runs
// stably inside its CPU and memory limits under load, with one replica and no
// HPA (vertical scaling).
//
// Every iteration is one PUT on the backend, and the backend turns that into
// two calls on the module service: GET /api/v1/modules/{id} to check that the
// module is available, then PUT to assign it. So the module service sees twice
// the request rate shown in the k6 summary.
//
// The user is created once, in setup(), not per iteration. Registering is
// Argon2-bound (~0.22s of CPU) and would dominate the run, moving the load
// onto the backend and Postgres instead of onto the module service.
//
// Assigning the same module over and over is deliberate: the module service
// stores the assignment idempotently, so the work per iteration stays constant
// and users_modules does not grow. It is the request path being measured, not
// the number of rows.

import http from 'k6/http';
import { check, fail, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
// VUs at the peak. 9 is ~9 assignments/s, so ~18 requests/s on the module
// service; run.sh -p 25 raises it if the sizing needs a harder push.
const PEAK = Number(__ENV.PEAK_VUS || 9);
// "Cloud Architecture", seeded by module_service/schema.sql.
const MODULE_ID = 'c02f58f2-3aca-4f1e-8076-bacf6f1999e6';
const PASSWORD = 'k6-load-test-password';
const json = { headers: { 'Content-Type': 'application/json' } };

export const options = {
  // Applied to every metric, so one Grafana dashboard can isolate one run.
  tags: { testid: __ENV.TEST_ID || 'manual' },
  scenarios: {
    ramp: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '2m', target: Math.ceil(PEAK / 3) },   // warm up
        { duration: '3m', target: PEAK },  // the troughs have to stay above
        { duration: '3m', target: PEAK },  // the HPA target, not just the peaks
        { duration: '2m', target: 0 },   // release, then watch scale-down
      ],
      gracefulRampDown: '30s',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<2000'],
    checks: ['rate>0.95'],
  },
};

// Runs once before the ramp. Everything it returns is handed to every VU.
export function setup() {
  const email = `k6-modules-${Date.now()}@loadtest.local`;

  const registered = http.post(
    `${BASE_URL}/users/register`,
    JSON.stringify({ firstName: 'k6', lastName: 'Modules', email, password: PASSWORD }),
    { ...json, tags: { name: 'setup-register' } },
  );
  if (registered.status !== 201) {
    fail(`setup: register returned ${registered.status}, expected 201`);
  }

  const loggedIn = http.post(
    `${BASE_URL}/users/login`,
    JSON.stringify({ email, password: PASSWORD }),
    { ...json, tags: { name: 'setup-login' } },
  );
  // The JWT comes back in a header, not in the body. k6 canonicalises header
  // names, but accept either spelling rather than depend on that.
  const token = loggedIn.headers['Authorization'] || loggedIn.headers['authorization'];
  if (!token) {
    fail(`setup: login returned ${loggedIn.status} and no Authorization header`);
  }

  return { userId: registered.json('id'), token: token };
}

export default function (data) {
  const assigned = http.put(
    `${BASE_URL}/users/${data.userId}/modules/${MODULE_ID}`,
    null,
    { headers: { Authorization: data.token }, tags: { name: 'assign' } },
  );
  check(assigned, { 'assign -> 204': (r) => r.status === 204 });

  sleep(1);
}
