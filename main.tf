terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }
}

provider "google" {
  project = "minecraft-server-iac" # <--- REPLACE THIS
  region  = "us-central1"
}

# --- 1. GKE Cluster (Control Plane) ---
resource "google_container_cluster" "primary" {
  name     = "learning-cluster"
  location = "us-central1-a" # Zonal cluster is cheaper than regional

  # We can't create a cluster with no node pool defined, but we want to only use
  # our separately managed node pool. So we create the smallest possible default
  # node pool and immediately delete it.
  remove_default_node_pool = true
  initial_node_count       = 1
}

# --- 2. Node Pool (Worker Nodes) ---
resource "google_container_node_pool" "primary_preemptible_nodes" {
  name       = "my-node-pool"
  cluster    = google_container_cluster.primary.id
  node_count = 2 # 2 nodes is good for redundancy, 1 is fine for absolute cheapest

  node_config {
    preemptible  = true # CHEAPER: Uses Spot VMs
    machine_type = "e2-medium"

    # Google recommends custom service accounts that have cloud-platform scope and permissions granted via IAM Roles.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
  }
}

# --- 3. Providers Configuration (Connects Terraform to the new Cluster) ---
# This data source grabs credentials from the cluster we just created
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.primary.endpoint}"
  token                  = data.google_client_config.default.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.primary.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.primary.master_auth[0].cluster_ca_certificate)
  }
}

# --- 4. Install Argo CD using Helm ---
resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "5.46.7" # Check for latest version if needed

  # Wait for the node pool to be ready before trying to install Argo CD
  depends_on = [google_container_node_pool.primary_preemptible_nodes]
}
