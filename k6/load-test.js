// Controlled, increasing load against the user_mgmt_service.
//
// Every iteration registers one user: the write path, CPU-bound through
// Argon2 (16 MiB, see Encoders.java), which is what moves the HPA.
//
// The rate is controlled by the sleep, not by piling up VUs. One register
// costs ~0.22s of CPU, so a core does ~4.5/s; the numbers below aim at
// roughly 2.6/s, which holds the backend near 110% of the 300m request and
// far below the 1000m limit.
//
// GET /users/me is not the load endpoint: it costs ~43ms server-side, so it
// takes far more VUs to move the HPA than the node has room for, and because
// spring.jpa.open-in-view holds a pool connection for the whole request, a
// read-driven ramp exhausts the 10 connections and everything hits the 30s
// Hikari timeout long before CPU becomes the limit.
//
// With the database scaled to 0, every registration fails - that is the
// failing traffic the alert demo needs (runbook step 7).

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
// VUs at the peak. 9 is the gentle HPA demo (~2.6/s); run.sh -p raises it
// for a stress test (25 is ~8/s, close to what two app nodes can hash).
const PEAK = Number(__ENV.PEAK_VUS || 9);
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
  // The HPA needs 60s of sustained load before it adds a replica and 300s of
  // quiet before it removes one, so a shorter run proves nothing.
  thresholds: {
    http_req_failed: ['rate<0.05'],
    http_req_duration: ['p(95)<2000'],
    checks: ['rate>0.95'],
  },
};

function register(email) {
  return http.post(
    `${BASE_URL}/users/register`,
    JSON.stringify({ firstName: 'k6', lastName: 'Tester', email, password: PASSWORD }),
    { ...json, tags: { name: 'register' } },
  );
}

export default function () {
  // Unique per iteration: email is UNIQUE NOT NULL, and a duplicate raises an
  // unhandled DataIntegrityViolationException, which would show up as a 500.
  const registered = register(`k6-${__VU}-${__ITER}-${Date.now()}@loadtest.local`);
  check(registered, { 'register -> 201': (r) => r.status === 201 });

  sleep(2);
}
