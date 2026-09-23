# The same service, built three times

One notes API — same routes, status codes, log shape, security headers, and the
same liveness/readiness split — on AWS, Azure and GCP. The app code differs only
in its data-access calls. **Everything else that changed is the cloud**, which is
what makes the diff worth reading.

| | AWS (`secure-container-pipeline`) | Azure (`azure-container-platform`) | GCP (this repo) |
|---|---|---|---|
| Compute | ECS Fargate | Container Apps | **Cloud Run** |
| Ingress | ALB + listener + target group + ACM cert + redirect rule | ingress block | **built in; URL and cert provisioned** |
| Data | DynamoDB on-demand | Cosmos DB serverless | **Firestore Native** |
| Registry | ECR | ACR Premium | **Artifact Registry** |
| Runtime identity | IAM task role | managed identity | **service account** |
| CI identity | IAM role + OIDC trust | federated credential | **workload identity pool** |
| Scale to zero | ✗ | ✓ | **✓, and CPU billed only in-request** |
| Autoscale signal | CPU target tracking | HTTP concurrency | **requests per instance** |
| Public by default | yes, once the ALB exists | yes | **no — 403 until `allUsers` is granted** |

## Four things that are genuinely different on GCP

### 1. A service account key is a permanent bearer credential

AWS keys rotate, Azure managed identities have no key at all, and a GCP service
account JSON key **never expires**. Leaking one is the worst credential incident
available on this cloud.

So federation matters more here, and the trap is specific: a workload identity
pool provider with **no `attribute_condition` trusts the GitHub OIDC issuer
globally** — every repository on GitHub could mint a token for your project.

Pinning `assertion.repository` is the usual advice and it is *not enough*: it
still admits every branch, tag and pull request of that repo, so a fork's PR
could run with deploy rights. This repo pins `assertion.sub`, which encodes repo
**and** ref together, and `terraform/tests.tftest.hcl` asserts the exact string.

### 2. Cloud Run is private until you say otherwise

An ALB serves the internet the moment it exists. A Container Apps ingress with
`external_enabled` does the same. Cloud Run returns **403 to everyone** until
`roles/run.invoker` is granted to `allUsers`. That line in `cloud_run.tf` is the
"this endpoint is public" switch, and its absence is the single most common
"why is my Cloud Run 403-ing" question.

### 3. Firestore's API disagrees with both others in two places

- Reading a missing document returns a snapshot with `.exists == False` rather
  than raising. DynamoDB returns an empty result; Cosmos raises.
- **Deleting a missing document succeeds.** Cosmos raises; DynamoDB needs a
  conditional expression to notice.

Both are why `get_note` and `delete_note` here carry explicit existence checks,
and why `tests/fake_firestore.py` reproduces those semantics rather than the
convenient ones.

### 4. Security rules are a concept with no AWS or Azure equivalent

Firestore rules govern access from **untrusted clients** — a browser or mobile
app talking to Firestore directly with no server in between. This service never
does that, so IAM is the control and rules are not in the path. Worth saying out
loud rather than leaving as an absence: the default rules on a new database allow
full access for 30 days and then deny everything, so a project that relies on
them silently breaks on day 31.

## And one thing that got easier

Ingress. AWS needs `aws_lb`, a target group, a listener, a second listener for
the HTTP→HTTPS redirect, and an ACM certificate. Cloud Run gives you a URL and a
managed certificate with no resources at all. Less to get wrong — and, exactly as
on Azure, less control: there is no WAF in the path without putting Cloud Armor
and a load balancer in front, which is a whole extra tier.

## What was the same

Almost all of the thinking. Least privilege split between a runtime identity and
a CI identity, keyless CI, liveness that does not touch the datastore, readiness
that does, immutable image tags, pinned dependencies, a reviewed scanner baseline
with written reasons, and scan gates that block the build.

Three clouds, three vocabularies, one set of engineering decisions. That is the
actual argument for hiring someone who has shipped on one of them.
