
locals {
  config_values = {
    4.4  = {
      type      = "openshift"
      type_code = "ocp4"
      version   = "4.4"
    }
    4.5  = {
      type      = "openshift"
      type_code = "ocp4"
      version   = "4.5"
    }
    4.6  = {
      type      = "openshift"
      type_code = "ocp4"
      version   = "4.6"
    }
    4.7  = {
      type      = "openshift"
      type_code = "ocp4"
      version   = "4.7"
    }
    4.8  = {
      type      = "openshift"
      type_code = "ocp4"
      version   = "4.8"
    }
  }
  name_prefix           = var.name_prefix != "" ? var.name_prefix : var.resource_group_name
  name_list             = [local.name_prefix, "cluster"]
  cluster_name          = var.name != "" ? var.name : join("-", local.name_list)
  server_url            = lookup(data.ibm_container_vpc_cluster.config, "public_service_endpoint_url", "")
  ingress_hostname      = lookup(data.ibm_container_vpc_cluster.config, "ingress_hostname", "")
  tls_secret            = lookup(data.ibm_container_vpc_cluster.config, "ingress_secret", "")
  openshift_versions    = {
  for version in lookup(data.ibm_container_cluster_versions.cluster_versions, "valid_openshift_versions", []):
  substr(version, 0, 3) => "${version}_openshift"
  }
  cluster_regex         = "(${join("|", keys(local.config_values))}|ocp4).*"
  cluster_type_cleaned  = regex(local.cluster_regex, var.ocp_version)[0] == "ocp4" ? "4.7" : regex(local.cluster_regex, var.ocp_version)[0]
  cluster_type          = lookup(local.config_values[local.cluster_type_cleaned], "type", "")
  # value should be ocp4, ocp3, or kubernetes
  cluster_type_code     = lookup(local.config_values[local.cluster_type_cleaned], "type_code", "")
  cluster_type_tag      = local.cluster_type == "kubernetes" ? "iks" : "ocp"
  cluster_version       = local.cluster_type == "openshift" ? "${var.ocp_version}_openshift" : ""
  vpc_subnet_count      = var.vpc_subnet_count
  total_workers         = var.worker_count * var.vpc_subnet_count
  vpc_id                = !var.exists ? data.ibm_is_vpc.vpc[0].id : ""
  vpc_subnets           = !var.exists ? var.vpc_subnets : []
  security_group_id     = !var.exists ? lookup(data.ibm_is_vpc.vpc[0], "default_security_group", "") : ""
  ipv4_cidr_blocks      = !var.exists ? data.ibm_is_subnet.vpc_subnet[*].ipv4_cidr_block : []
  kms_config            = var.kms_enabled ? [{
    instance_id      = var.kms_id
    crk_id           = var.kms_key_id
    private_endpoint = var.kms_private_endpoint
  }] : []
  policy_targets     = [
    "kms",
    "hs-crypto"
  ]
  login                 = var.login ? var.login : !var.disable_public_endpoint
  cluster_config        = local.login ? lookup(data.ibm_container_cluster_config.cluster[0], "config_file_path", "") : ""
  acl_rules             = [{
    name = "allow-all-ingress"
    action = "allow"
    direction = "inbound"
    source = "0.0.0.0/0"
    destination = "0.0.0.0/0"
  }, {
    name = "allow-all-egress"
    action = "allow"
    direction = "outbound"
    source = "0.0.0.0/0"
    destination = "0.0.0.0/0"
  }]
  workers = flatten([
    for i in range(local.total_workers) : {
      id = data.ibm_container_vpc_cluster_worker.workers[i].id
      zone = data.ibm_container_vpc_cluster_worker.workers[i].network_interfaces[0].subnet_id
    }
  ])
}

data external dirs {
  program = ["bash", "${path.module}/scripts/create-dirs.sh"]

  query = {
    tmp_dir = "${path.cwd}/.tmp"
    cluster_config_dir = "${path.cwd}/.kube"
    sync = var.sync
  }
}

resource null_resource print_resources {
  provisioner "local-exec" {
    command = "echo 'Resource group: ${var.resource_group_name}'"
  }
  provisioner "local-exec" {
    command = "echo 'Cos id: ${var.cos_id}'"
  }
  provisioner "local-exec" {
    command = "echo 'VPC name: ${var.vpc_name}'"
  }
}

# separated to prevent circular dependency
resource null_resource print_subnets {
  provisioner "local-exec" {
    command = "echo 'VPC subnet count: ${local.vpc_subnet_count}'"
  }
  provisioner "local-exec" {
    command = "echo 'VPC subnets: ${jsonencode(local.vpc_subnets)}'"
  }
}

data ibm_resource_group resource_group {
  depends_on = [null_resource.print_resources]

  name = var.resource_group_name
}

data ibm_container_cluster_versions cluster_versions {

  resource_group_id = data.ibm_resource_group.resource_group.id
}

module setup_clis {
  source = "github.com/cloud-native-toolkit/terraform-util-clis.git"

  clis = ["jq"]
}

data ibm_is_vpc vpc {
  count = !var.exists ? 1 : 0
  depends_on = [null_resource.print_resources]

  name  = var.vpc_name
}

data ibm_is_subnet vpc_subnet {
  count = !var.exists ? var.vpc_subnet_count : 0

  identifier = lookup(local.vpc_subnets[count.index], "id", "")
}

resource ibm_is_network_acl_rule rules {
  count = !var.exists && var.vpc_subnet_count > 0 ? length(local.acl_rules) : 0

  network_acl = data.ibm_is_subnet.vpc_subnet[0].network_acl
  name        = local.acl_rules[count.index].name
  action      = local.acl_rules[count.index].action
  source      = local.acl_rules[count.index].source
  destination = local.acl_rules[count.index].destination
  direction   = local.acl_rules[count.index].direction
}

# from https://cloud.ibm.com/docs/vpc?topic=vpc-service-endpoints-for-vpc
resource ibm_is_security_group_rule default_inbound_ping {
  count = !var.exists ? 1 : 0

  group     = local.security_group_id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  icmp {
    type = 8
  }
}

resource ibm_is_security_group_rule default_inbound_http {
  count = !var.exists ? 1 : 0

  group     = local.security_group_id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  tcp {
    port_min = 80
    port_max = 80
  }
}

resource ibm_is_security_group_rule default_inbound_https {
  count = !var.exists ? 1 : 0

  group     = local.security_group_id
  direction = "inbound"
  remote    = "0.0.0.0/0"

  tcp {
    port_min = 443
    port_max = 443
  }
}

resource ibm_container_vpc_cluster cluster {
  count = !var.exists ? 1 : 0
  depends_on = [null_resource.print_resources, ibm_is_network_acl_rule.rules]

  name              = local.cluster_name
  vpc_id            = local.vpc_id
  flavor            = var.flavor
  worker_count      = var.worker_count
  kube_version      = local.cluster_version
  entitlement       = var.ocp_entitlement
  cos_instance_crn  = var.cos_id
  resource_group_id = data.ibm_resource_group.resource_group.id
  disable_public_service_endpoint = var.disable_public_endpoint
  force_delete_storage = var.force_delete_storage
  wait_till         = "IngressReady"
  tags              = var.tags

  dynamic "zones" {
    for_each = local.vpc_subnets

    content {
      name = zones.value.zone
      subnet_id = zones.value.id
    }
  }

  dynamic "kms_config" {
    for_each = local.kms_config

    content {
      instance_id      = kms_config.value["instance_id"]
      crk_id           = kms_config.value["crk_id"]
      private_endpoint = kms_config.value["private_endpoint"]
    }
  }
}

resource ibm_is_security_group_rule rule_tcp_k8s {
  count     = !var.exists ? local.vpc_subnet_count : 0

  group     = local.security_group_id
  direction = "inbound"

  tcp {
    port_min = 30000
    port_max = 32767
  }
}

data ibm_container_vpc_cluster config {
  depends_on = [ibm_container_vpc_cluster.cluster, ibm_is_security_group_rule.rule_tcp_k8s]

  name              = local.cluster_name
  alb_type          = var.disable_public_endpoint ? "private" : "public"
  resource_group_id = data.ibm_resource_group.resource_group.id
}

data ibm_container_cluster_config cluster_admin {
  count = local.login ? 1 : 0
  depends_on        = [data.ibm_container_vpc_cluster.config]

  cluster_name_id   = local.cluster_name
  admin             = true
  resource_group_id = data.ibm_resource_group.resource_group.id
  config_dir        = data.external.dirs.result.cluster_config_dir
}

data ibm_container_cluster_config cluster {
  count = local.login ? 1 : 0
  depends_on        = [
    data.ibm_container_vpc_cluster.config,
    data.ibm_container_cluster_config.cluster_admin
  ]

  cluster_name_id   = local.cluster_name
  resource_group_id = data.ibm_resource_group.resource_group.id
  config_dir        = data.external.dirs.result.cluster_config_dir
}

data "ibm_container_vpc_cluster_worker" "workers" {
  depends_on        = [
    data.ibm_container_vpc_cluster.config
  ]
  count = var.worker_count * var.vpc_subnet_count
  worker_id       = data.ibm_container_vpc_cluster.config.workers[count.index]
  cluster_name_id = data.ibm_container_vpc_cluster.config.id
} 
