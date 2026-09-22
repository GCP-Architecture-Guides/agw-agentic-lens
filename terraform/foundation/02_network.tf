# ------------------------------------------------------------------------------
# 2. CORE INFRASTRUCTURE & NETWORKING
# ------------------------------------------------------------------------------
# VPC Network
resource "google_compute_network" "vpc" {
  name                    = "${var.prefix}-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.compute]
}

# Interface Subnet for Network Attachment
resource "google_compute_subnetwork" "intf_subnet" {
  name                     = "${var.prefix}-intf-subnet"
  ip_cidr_range            = "192.168.10.0/28"
  region                   = var.location
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}
# SGP Subnet for Network Attachment
resource "google_compute_subnetwork" "sgp_subnet" {
  name                     = "${var.prefix}-sgp-subnet"
  ip_cidr_range            = "10.10.10.0/24"
  region                   = var.location
  network                  = google_compute_network.vpc.id
  private_ip_google_access = true
}

# Network Attachment for Egress Gateway
resource "google_compute_network_attachment" "psc_network_attachment" {
  name                  = "${var.prefix}-psc-network-attachment"
  region                = var.location
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [google_compute_subnetwork.intf_subnet.id]
}

# Agent Gateway - Ingress
resource "google_network_services_agent_gateway" "ingress_gateway" {
  provider = google-beta
  name     = "${var.prefix}-ingress-gateway"
  location = var.location
  # protocols is deprecated (removed in a future provider major release);
  # governed_access_path already encodes the gateway direction.
  google_managed {
    governed_access_path = "CLIENT_TO_AGENT"
  }
  depends_on = [google_project_service.networkservices]
}

# Agent Gateway - Egress
resource "google_network_services_agent_gateway" "egress_gateway" {
  provider = google-beta
  name     = "${var.prefix}-egress-gateway"
  location = var.location
  # protocols is deprecated (removed in a future provider major release);
  # governed_access_path already encodes the gateway direction.
  google_managed {
    governed_access_path = "AGENT_TO_ANYWHERE"
  }
  depends_on = [google_project_service.networkservices]
  network_config {
    egress {
      network_attachment = google_compute_network_attachment.psc_network_attachment.id
    }
    dns_peering_config {
      target_project = var.project_id
      target_network = google_compute_network.vpc.id
      domains        = ["sgp.internal.gemini-corp."]
    }
  }
}

# =========================================================================
# SEMANTIC GOVERNANCE POLICY (SGP) — VPC CONNECTIVITY
# =========================================================================
# --- 1. SGP Network Attachment ---
resource "google_compute_network_attachment" "sgp_network_attachment" {
  name                  = "${var.prefix}-sgp-nw-attachment"
  region                = var.location
  description           = "Network attachment for SGP engine PSC connectivity"
  connection_preference = "ACCEPT_AUTOMATIC"
  subnetworks           = [google_compute_subnetwork.intf_subnet.id]

  depends_on = [google_project_service.compute]
}

# --- 2. Static Internal IP for PSC Endpoint ---
resource "google_compute_address" "sgp_psc_ip" {
  name         = "${var.prefix}-sgp-psc-ip"
  region       = var.location
  subnetwork   = google_compute_subnetwork.sgp_subnet.id
  address_type = "INTERNAL"
  description  = "Static internal IP for SGP PSC forwarding rule endpoint"

  depends_on = [google_project_service.compute]
}

# --- 3. PSC Forwarding Rule → SGP Engine Service Attachment ---
resource "google_compute_forwarding_rule" "sgp_psc_endpoint" {
  name                  = "${var.prefix}-sgp-psc-endpoint"
  region                = var.location
  network               = google_compute_network.vpc.id
  subnetwork            = google_compute_subnetwork.sgp_subnet.id
  ip_address            = google_compute_address.sgp_psc_ip.id
  load_balancing_scheme = ""
  target                = data.external.sgp_engine.result.psc_service_attachment
  description           = "PSC endpoint connecting our VPC to the automated SGP policy engine"

  depends_on = [
    google_compute_address.sgp_psc_ip,
    google_project_service.compute,
  ]
}

# --- 4. Private DNS Zone + A Record for SGP Hostname ---
# Note: Since the variable is removed, we just hardcode the local default
resource "google_dns_managed_zone" "sgp_dns_zone" {
  name        = "${var.prefix}-sgp-dns-zone"
  dns_name    = "sgp.internal.gemini-corp."
  description = "Private DNS zone for SGP engine hostname resolution"
  visibility  = "private"

  private_visibility_config {
    networks {
      network_url = google_compute_network.vpc.id
    }
  }

  depends_on = [google_project_service.dns]
}

resource "google_dns_record_set" "sgp_a_record" {
  name         = "sgp.internal.gemini-corp."
  managed_zone = google_dns_managed_zone.sgp_dns_zone.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_address.sgp_psc_ip.address]

  depends_on = [
    google_dns_managed_zone.sgp_dns_zone,
    google_compute_address.sgp_psc_ip,
  ]
}



