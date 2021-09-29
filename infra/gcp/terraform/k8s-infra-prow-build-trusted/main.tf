/*
Copyright 2020 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

/*
This file defines:
- Google Project k8s-infra-prow-build-trusted to host the cluster
- GCP Service Account for prow-build-trusted
- GKE cluster configuration for prow-build-trusted
- GKE nodepool configuration for prow-build-trusted
*/

locals {
  project_id        = "k8s-infra-prow-build-trusted"
  cluster_name      = "prow-build-trusted" // The name of the cluster defined in this file
  cluster_location  = "us-central1"        // The GCP location (region or zone) where the cluster should be created
  bigquery_location = "US"                 // The bigquery specific location where the dataset should be created
  pod_namespace     = "test-pods"          // MUST match whatever prow is configured to use when it schedules to this cluster

  // Service Accounts in ${pod_namespace} (usable via Workload Identity)
  cluster_sa_name                     = "prow-build-trusted"          // Pods use this by default
  gcb_builder_sa_name                 = "gcb-builder"                 // Allowed to run GCB builds and push to GCS buckets
  prow_deployer_sa_name               = "prow-deployer"               // Allowed to deploy to prow build clusters
  k8s_metrics_sa_name                 = "k8s-metrics"                 // Allowed to write to gs://k8s-metrics
  k8s_triage_sa_name                  = "k8s-triage"                  // Allowed to write to gs://k8s-project-triage
  kubernetes_external_secrets_sa_name = "kubernetes-external-secrets" // Allowed to read from GSM in this and other projects
}

data "google_organization" "org" {
  domain = "kubernetes.io"
}

module "project" {
  source       = "../modules/gke-project"
  project_id   = local.project_id
  project_name = local.project_id
}

// Ensure k8s-infra-prow-oncall@kuberentes.io has owner access to this project
resource "google_project_iam_member" "k8s_infra_prow_oncall" {
  project = local.project_id
  role    = "roles/owner"
  member  = "group:k8s-infra-prow-oncall@kubernetes.io"
}

// TODO: consider moving the project role binding resources into the
//       workload-identity-service-account module
// 
// Some of the roles are assigned in bash or other terraform modules, so as
// to keep the permissions necessary to run this terraform module scoped to
// "roles/owner" for local.project_id

module "prow_build_cluster_sa" {
  source            = "../modules/workload-identity-service-account"
  project_id        = local.project_id
  name              = local.cluster_sa_name
  description       = "default service account for pods in ${local.cluster_name}"
  cluster_namespace = local.pod_namespace
}

module "gcb_builder_sa" {
  source            = "../modules/workload-identity-service-account"
  project_id        = local.project_id
  name              = local.gcb_builder_sa_name
  description       = "trigger GCB builds in all k8s-staging projects"
  cluster_namespace = local.pod_namespace
  // roles come from ensure-staging-storage.sh
}

module "prow_deployer_sa" {
  source            = "../modules/workload-identity-service-account"
  project_id        = local.project_id
  name              = local.prow_deployer_sa_name
  description       = "deploys k8s resources to k8s clusters"
  cluster_namespace = local.pod_namespace
  project_roles     = ["roles/container.admin"]
}
// roles: there are also some assigned in ensure-main-project.sh
resource "google_project_iam_member" "prow_deployer_for_prow_build" {
  project = "k8s-infra-prow-build"
  role    = "roles/container.admin"
  member  = "serviceAccount:${local.prow_deployer_sa_name}@${local.project_id}.iam.gserviceaccount.com"
}

module "k8s_metrics_sa" {
  source            = "../modules/workload-identity-service-account"
  project_id        = local.project_id
  name              = local.k8s_metrics_sa_name
  description       = "read bigquery and write to gs://k8s-metrics"
  cluster_namespace = local.pod_namespace
  project_roles     = ["roles/bigquery.user"]
}

module "k8s_triage_sa" {
  source            = "../modules/workload-identity-service-account"
  project_id        = local.project_id
  name              = local.k8s_triage_sa_name
  description       = "read bigquery and write to gs://k8s-triage"
  cluster_namespace = local.pod_namespace
  project_roles     = ["roles/bigquery.user"]
}

module "kubernetes_external_secrets_sa" {
  source            = "../modules/workload-identity-service-account"
  project_id        = local.project_id
  name              = local.kubernetes_external_secrets_sa_name
  description       = "sync K8s secrets from GSM in this and other projects"
  cluster_namespace = "kubernetes-external-secrets"
  project_roles     = ["roles/secretmanager.secretAccessor"]
}

// external (regional) ip addresses
resource "google_compute_address" "kubernetes_external_secrets_metrics_address" {
  name         = "kubernetes-external-secrets-metrics"
  description  = "to allow monitoring.k8s.prow.io to scrape kubernetes-external-secrets metrics"
  project      = local.project_id
  region       = local.cluster_location
  address_type = "EXTERNAL"
}

resource "google_compute_address" "ghproxy_metrics_address" {
  name         = "ghproxy-metrics"
  description  = "to allow monitoring.k8s.prow.io to scrape ghproxy metrics"
  project      = local.project_id
  region       = local.cluster_location
  address_type = "EXTERNAL"
}

locals {
  build_cluster_secrets = {
    k8s-infra-kops-e2e-tests-aws-ssh-key = {
      group  = "sig-cluster-lifecycle"
      owners = "k8s-infra-kops-maintainers@kubernetes.io"
    }
    k8s-triage-robot-github-token = {
      group  = "sig-contributor-experience"
      owners = "github@kubernetes.io"
    }
    cncf-ci-github-token = {
      group  = "sig-testing"
      owners = "k8s-infra-ii-coop@kubernetes.io"
    }
    snyk-token = {
      group  = "sig-architecture"
      owners = "k8s-infra-code-organization@kubernetes.io"
    }
  }
}

resource "google_secret_manager_secret" "build_cluster_secrets" {
  for_each  = local.build_cluster_secrets
  project   = local.project_id
  secret_id = each.key
  labels = {
    group = each.value.group
  }
  replication {
    automatic = true
  }
}

resource "google_secret_manager_secret_iam_binding" "build_cluster_secret_admins" {
  for_each  = local.build_cluster_secrets
  project   = google_secret_manager_secret.build_cluster_secrets[each.key].project
  secret_id = google_secret_manager_secret.build_cluster_secrets[each.key].id
  role      = "roles/secretmanager.admin"
  members = [
    "group:k8s-infra-prow-oncall@kubernetes.io",
    "group:${each.value.owners}"
  ]
}

module "prow_build_cluster" {
  source             = "../modules/gke-cluster"
  project_name       = local.project_id
  cluster_name       = local.cluster_name
  cluster_location   = local.cluster_location
  bigquery_location  = local.bigquery_location
  is_prod_cluster    = "true"
  release_channel    = "REGULAR"
  dns_cache_enabled  = "true"
  cloud_shell_access = false
}

module "prow_build_nodepool" {
  source        = "../modules/gke-nodepool"
  project_name  = local.project_id
  cluster_name  = module.prow_build_cluster.cluster.name
  location      = module.prow_build_cluster.cluster.location
  name          = "trusted-pool1"
  initial_count = 1
  min_count     = 1
  max_count     = 6
  # image/machine/disk match prow-build for consistency's sake
  image_type      = "UBUNTU_CONTAINERD"
  machine_type    = "n1-highmem-8"
  disk_size_gb    = 200
  disk_type       = "pd-ssd"
  service_account = module.prow_build_cluster.cluster_node_sa.email
}

