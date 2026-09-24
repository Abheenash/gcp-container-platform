# GCP Container Platform — the third build of the same service

> **Sep 2026 (v2):** the API test suite now also runs against **Google's own Firestore
> emulator**, alongside the hand-written fake — free, no GCP project, no credentials. The
> app needed no change: `google-cloud-firestore` honours `FIRESTORE_EMULATOR_HOST` and
> skips auth when it is set, so there is no test-only code path. Recorded honestly: the
> emulator found no divergence, so the claim is that the fake is now *verified* faithful
> rather than assumed to be. CI sets `REQUIRE_FIRESTORE=1` so an emulator that fails to
> start errors instead of skipping six tests behind a green tick.
>
> **Sep 2026:** first release — Cloud Run + Firestore + Artifact Registry, service-account identity end to end (no JSON key anywhere), keyless CI via workload identity federation pinned to `assertion.sub`, 14 checkov checks / 5 terraform tests / 15 unit tests green. Deliberately not applied.

The same notes API as [`secure-container-pipeline`](https://github.com/Abheenash/secure-container-pipeline)
(AWS) and [`azure-container-platform`](https://github.com/Abheenash/azure-container-platform)
(Azure) — **same routes, same probes, same log shape** — now on **Cloud Run,
Firestore and Artifact Registry**.

**The deliverable is the three-way diff, not the app.**
[**docs/three-clouds.md**](docs/three-clouds.md) is the thing worth reading: four
places GCP genuinely differs, one place it is simpler, and the large set of
decisions that turned out to be cloud-independent.

**Status:** `terraform validate` clean against google provider v8, checkov clean
against a reviewed baseline, 5 terraform tests and 15 unit tests green.
**Not applied** — Firestore and Cloud Run are near-free at this volume, but the
AWS original already carries the applied-and-measured evidence and standing this
up adds nothing but a bill.

## Why a third cloud

Reading 853 job requisitions across nineteen employers for my own search, **GCP
appeared 111 times** — behind Azure but ahead of most named tools. Two clouds
proves the ideas transfer; three proves it was not a coincidence.

## The one that would have bitten me

A GCP **service account key never expires**. Leaking one is the worst credential
incident this cloud offers, which makes federation the control that matters most.

The usual advice is to pin `assertion.repository` on the workload identity pool
provider. That is not enough — it still admits every branch, tag and pull request
of that repo, so a fork's PR could run with deploy rights. This repo pins
`assertion.sub`, which encodes repo **and** ref:

```
assertion.sub == 'repo:Abheenash/gcp-container-platform:ref:refs/heads/main'
```

I had written the weaker version first. checkov's `CKV_GCP_125` caught it, and
`terraform/tests.tftest.hcl` now asserts the exact string so it cannot regress.

## Architecture

```
GitHub Actions ──(OIDC → workload identity federation, no key)──► GCP
     │
     ├─ build ─► Artifact Registry (immutable tags, cleanup policy)
     │             │ pull via service account (artifactregistry.reader)
     ▼             ▼
  cosign + SLSA   Cloud Run ──► Firestore Native (PITR + delete protection)
  attestation      min 0 / max 4        ▲
                   service account ─────┘  roles/datastore.user — not admin
```

## The pipeline

Same gates as the other two, in the same order: **gitleaks → checkov + terraform
fmt/validate → pytest → trivy (CVEs, image secrets, non-root uid) + SBOM**, then
on `main`: federated login → push → cosign signature → **SLSA provenance
attestation** → `gcloud run deploy`.

`trivy` is pinned to **v0.69.3** and its installer fetched at that tag, not
`@main` — trivy's supply chain was compromised twice in March 2026
([CVE-2026-33634](https://github.com/advisories/GHSA-69fq-xp46-6x23)).

## Running it

```bash
cd terraform
terraform init
terraform apply -var project_id=<your-project>

# tests need no GCP project at all
pip install -r tests/requirements.txt -r app/requirements.txt
python -m pytest tests -q
terraform test        # mocked provider, no cloud calls
```

Then set the repo variables the deploy job reads: `WIF_PROVIDER`,
`WIF_SERVICE_ACCOUNT`, `ARTIFACT_REGISTRY`, `CLOUD_RUN_SERVICE`, `GCP_REGION`,
and `DEPLOY_ENABLED=true`. The first two come straight from `terraform output`.

## Cost

Cloud Run scales to zero and bills CPU only while a request is in flight;
Firestore bills per operation with a free daily quota. At demo volume this is
the cheapest of the three builds — which is why `min_instances = 0` is the
default and cold starts are accepted rather than paid away.

## Layout

```
app/          the ported FastAPI service (Firestore instead of DynamoDB/Cosmos)
terraform/    APIs, Firestore, Artifact Registry, both service accounts,
              workload identity federation, Cloud Run
tests/        15 tests against an in-memory fake that reproduces Firestore's
              actual semantics — including that deleting a missing document
              SUCCEEDS, which is why the handler checks existence first
docs/         the three-cloud comparison — the point of the repo
```

## Not affiliated with Google — a personal learning + portfolio project by
[Rajolu Abheenash](https://abheenash.com).
