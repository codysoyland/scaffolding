/**
 * Copyright 2022 The Sigstore Authors
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

// Private network
module "network" {
  source = "../network"

  region     = var.region
  project_id = var.project_id

  cluster_name = var.cluster_name

  requested_external_ipv4_address = var.static_external_ipv4_address
}

// Bastion
module "bastion" {
  source = "../bastion"

  project_id         = var.project_id
  region             = var.region
  zone               = var.bastion_zone
  network            = module.network.network_name
  subnetwork         = module.network.subnetwork_self_link
  tunnel_accessor_sa = var.tunnel_accessor_sa

  depends_on = [
    module.network
  ]
}

module "tuf" {
  source = "../tuf"

  region     = var.tuf_region == "" ? var.region : var.tuf_region
  project_id = var.project_id

  tuf_bucket         = var.tuf_bucket
  tuf_preprod_bucket = var.tuf_preprod_bucket
  storage_class      = var.tuf_storage_class
}

// Monitoring
module "monitoring" {
  source = "../monitoring"

  // Disable module entirely if monitoring
  // is disabled
  count = var.monitoring.enabled ? 1 : 0

  project_id               = var.project_id
  cluster_location         = var.project_id
  cluster_name             = var.cluster_name
  ca_pool_name             = var.ca_pool_name
  fulcio_url               = var.monitoring.fulcio_url
  rekor_url                = var.monitoring.rekor_url
  dex_url                  = var.monitoring.dex_url
  notification_channel_ids = var.monitoring.notification_channel_ids

  depends_on = [
    module.gke-cluster
  ]
}

resource "google_compute_firewall" "bastion-egress" {
  // Egress to Kubernetes API is the only allowed traffic
  name      = "bastion-egress"
  network   = module.network.network_name
  direction = "EGRESS"

  destination_ranges = ["${module.gke-cluster.cluster_endpoint}/32"]

  allow {
    protocol = "tcp"
    ports    = ["443"]
  }

  target_tags = ["bastion"]

  depends_on = [
    module.network,
    module.gke-cluster
  ]
}

# GKE cluster setup.
module "gke-cluster" {
  source = "../gke_cluster"

  region     = var.region
  project_id = var.project_id

  cluster_name = var.cluster_name

  network                       = module.network.network_self_link
  subnetwork                    = module.network.subnetwork_self_link
  cluster_secondary_range_name  = module.network.secondary_ip_range.0.range_name
  services_secondary_range_name = module.network.secondary_ip_range.1.range_name
  cluster_network_tag           = var.cluster_network_tag

  bastion_ip_address = module.bastion.ip_address

  depends_on = [
    module.network,
    module.bastion
  ]
}

// MYSQL
module "mysql" {
  source = "../mysql"

  region     = var.region
  project_id = var.project_id

  cluster_name      = var.cluster_name
  database_version  = var.mysql_db_version
  tier              = var.mysql_tier
  availability_type = var.mysql_availability_type

  replica_zones = var.mysql_replica_zones
  replica_tier  = var.mysql_replica_tier

  network = module.network.network_self_link

  instance_name = var.mysql_instance_name
  db_name       = var.mysql_db_name

  ipv4_enabled              = var.mysql_ipv4_enabled
  require_ssl               = var.mysql_require_ssl
  backup_enabled            = var.mysql_backup_enabled
  binary_log_backup_enabled = var.mysql_binary_log_backup_enabled


  depends_on = [
    module.network,
    module.gke-cluster
  ]
}

// Cluster policies setup.
module "policy_bindings" {
  source = "../policy_bindings"

  region     = var.region
  project_id = var.project_id

  cluster_name = var.cluster_name
  github_repo  = var.github_repo

  depends_on = [
    module.network
  ]
}


// Rekor
module "rekor" {
  source = "../rekor"

  region       = var.region
  project_id   = var.project_id
  cluster_name = var.cluster_name

  // Redis
  network = module.network.network_self_link

  // KMS
  rekor_keyring_name = var.rekor_keyring_name
  rekor_key_name     = var.rekor_key_name
  kms_location       = "global"

  // Storage
  attestation_bucket = var.attestation_bucket
  attestation_region = var.attestation_region == "" ? var.region : var.attestation_region
  storage_class      = var.attestation_storage_class

  dns_zone_name      = var.dns_zone_name
  dns_domain_name    = var.dns_domain_name
  load_balancer_ipv4 = module.network.external_ipv4_address

  depends_on = [
    module.network,
    module.gke-cluster
  ]
}

// Fulcio
module "fulcio" {
  source = "../fulcio"

  region       = var.region
  project_id   = var.project_id
  cluster_name = var.cluster_name

  // Certificate authority
  ca_pool_name = var.ca_pool_name
  ca_name      = var.ca_name

  // KMS
  fulcio_keyring_name = var.fulcio_keyring_name
  fulcio_key_name     = var.fulcio_intermediate_key_name

  dns_zone_name      = var.dns_zone_name
  dns_domain_name    = var.dns_domain_name
  load_balancer_ipv4 = module.network.external_ipv4_address

  depends_on = [
    module.gke-cluster,
    module.network
  ]
}

// Audit
module "audit" {
  source     = "../audit"
  project_id = var.project_id
}

// IAM project roles
module "project_roles" {
  source               = "../project_roles"
  project_id           = var.project_id
  iam_members_to_roles = var.iam_members_to_roles
}

// OSLogin configuration
module "oslogin" {
  source     = "../oslogin"
  project_id = var.project_id

  // Disable module entirely if oslogin is disabled
  count = var.oslogin.enabled ? 1 : 0

  oslogin = var.oslogin

  // Grant OSLogin access to the bastion instance to the GHA
  // SA for terraform access and to tunnel accessors.
  instance_os_login_members = {
    bastion = {
      instance_name = module.bastion.name
      zone          = module.bastion.zone
      members = [
        var.tunnel_accessor_sa,
        module.policy_bindings.gha_serviceaccount_member
      ]
    }
  }
  depends_on = [
    module.bastion,
    module.policy_bindings
  ]
}

// ctlog
module "ctlog" {
  source = "../ctlog"

  project_id = var.project_id

  dns_zone_name      = var.dns_zone_name
  dns_domain_name    = var.dns_domain_name
  load_balancer_ipv4 = module.network.external_ipv4_address

  depends_on = [
    module.gke-cluster,
    module.network
  ]
}

// dex
module "dex" {
  source = "../dex"

  project_id = var.project_id

  dns_zone_name      = var.dns_zone_name
  dns_domain_name    = var.dns_domain_name
  load_balancer_ipv4 = module.network.external_ipv4_address

  depends_on = [
    module.gke-cluster,
    module.network
  ]
}
