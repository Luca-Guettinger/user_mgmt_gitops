// Controlled, increasing load against the user_mgmt_service.
//
// Every iteration registers one user: the write path, CPU-bound through
// Argon2 (16 MiB, see Encoders.java), which is what moves the HPA.
//
// The rate is controlled by the sleep, not by piling up VUs. One register
// costs ~0.22s of CPU, so a core does ~4.5/s; the numbers below aim at
// roughly 2.7/s, comfortably past 80% of the 300m request and far below the
// 1000m limit.
//
// GET /users/me is deliberately NOT the load endpoint: on 2026-09-18 it took
// ~9s per call with no load at all and held a pool connection for that whole
// time, so 10 connections were gone and every request hit the 30s Hikari
// timeout. That is an application bug (it is also the portal's slow
// /api/me); until it is fixed, a read-driven test measures only the bug.
//
// With the database scaled to 0, every registration fails - that is the
// failing traffic the alert demo needs (runbook step 7).

import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE_URL = __ENV.BASE_URL;
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
        { duration: '2m', target: 3 },   // warm up
        { duration: '3m', target: 9 },   // ~4/s: the troughs have to stay above
        { duration: '3m', target: 9 },   // the 80% target, not just the peaks
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
