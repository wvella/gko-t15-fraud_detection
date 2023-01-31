terraform {
    required_providers {
        confluent = {
            source = "confluentinc/confluent"
            version = "1.23.0"
        }
    }
}

provider "confluent" {
}

resource "random_id" "id" {
    byte_length = 4
}

resource "confluent_environment" "simple_env" {
    display_name = "${local.env_name}-${random_id.id.hex}"
    lifecycle {
        prevent_destroy = false
    }
}

# --------------------------------------------------------
# Schema Registry
# --------------------------------------------------------
data "confluent_schema_registry_region" "simple_sr_region" {
    cloud = "AWS"
    region = "us-east-2"
    package = "ESSENTIALS" 
}
resource "confluent_schema_registry_cluster" "simple_sr_cluster" {
    package = data.confluent_schema_registry_region.simple_sr_region.package
    environment {
        id = confluent_environment.simple_env.id 
    }
    region {
        id = data.confluent_schema_registry_region.simple_sr_region.id
    }
    lifecycle {
        prevent_destroy = false
    }
}

# --------------------------------------------------------
# Kafka Cluster
# --------------------------------------------------------
resource "confluent_kafka_cluster" "simple_cluster" {
    display_name = "${local.cluster_name}"
    availability = "SINGLE_ZONE"
    cloud = "AWS"
    region = "us-east-2"
    basic {}
    environment {
        id = confluent_environment.simple_env.id
    }
    lifecycle {
        prevent_destroy = false
    }
}

# --------------------------------------------------------
# Service Accounts
# --------------------------------------------------------
resource "confluent_service_account" "app_manager" {
    display_name = "app-manager-${random_id.id.hex}"
    description = "${local.description}"
}
resource "confluent_service_account" "sr" {
    display_name = "sr-${random_id.id.hex}"
    description = "${local.description}"
}
resource "confluent_service_account" "clients" {
    display_name = "client-${random_id.id.hex}"
    description = "${local.description}"
}
resource "confluent_service_account" "app-ksql" {
  display_name = "app-ksql"
  description  = "Service account to manage 'fraud detection' ksqlDB cluster"

  lifecycle {
    prevent_destroy = true
  }
}

# --------------------------------------------------------
# Role Bindings
# --------------------------------------------------------
resource "confluent_role_binding" "app_manager_environment_admin" {
    principal = "User:${confluent_service_account.app_manager.id}"
    role_name = "EnvironmentAdmin"
    crn_pattern = confluent_environment.simple_env.resource_name
}
resource "confluent_role_binding" "sr_environment_admin" {
    principal = "User:${confluent_service_account.sr.id}"
    role_name = "EnvironmentAdmin"
    crn_pattern = confluent_environment.simple_env.resource_name
}
resource "confluent_role_binding" "clients_cluster_admin" {
    principal = "User:${confluent_service_account.clients.id}"
    role_name = "CloudClusterAdmin"
    crn_pattern = confluent_kafka_cluster.simple_cluster.rbac_crn
}
resource "confluent_role_binding" "app-ksql-kafka-cluster-admin" {
  principal   = "User:${confluent_service_account.app-ksql.id}"
  role_name   = "CloudClusterAdmin"
  crn_pattern = confluent_kafka_cluster.simple_cluster.rbac_crn

  lifecycle {
    prevent_destroy = true
  }
}
# --------------------------------------------------------
# Credentials
# --------------------------------------------------------
resource "confluent_api_key" "app_manager_kafka_cluster_key" {
    display_name = "app-manager-${local.cluster_name}-key-${random_id.id.hex}"
    description = "${local.description}"
    owner {
        id = confluent_service_account.app_manager.id
        api_version = confluent_service_account.app_manager.api_version
        kind = confluent_service_account.app_manager.kind
    }
    managed_resource {
        id = confluent_kafka_cluster.simple_cluster.id
        api_version = confluent_kafka_cluster.simple_cluster.api_version
        kind = confluent_kafka_cluster.simple_cluster.kind
        environment {
            id = confluent_environment.simple_env.id
        }
    }
    depends_on = [
        confluent_role_binding.app_manager_environment_admin
    ]
}
resource "confluent_api_key" "sr_cluster_key" {
    display_name = "sr-${local.cluster_name}-key-${random_id.id.hex}"
    description = "${local.description}"
    owner {
        id = confluent_service_account.sr.id 
        api_version = confluent_service_account.sr.api_version
        kind = confluent_service_account.sr.kind
    }
    managed_resource {
        id = confluent_schema_registry_cluster.simple_sr_cluster.id
        api_version = confluent_schema_registry_cluster.simple_sr_cluster.api_version
        kind = confluent_schema_registry_cluster.simple_sr_cluster.kind 
        environment {
            id = confluent_environment.simple_env.id
        }
    }
    depends_on = [
      confluent_role_binding.sr_environment_admin
    ]
}
resource "confluent_api_key" "clients_kafka_cluster_key" {
    display_name = "clients-${local.cluster_name}-key-${random_id.id.hex}"
    description = "${local.description}"
    owner {
        id = confluent_service_account.clients.id
        api_version = confluent_service_account.clients.api_version
        kind = confluent_service_account.clients.kind
    }
    managed_resource {
        id = confluent_kafka_cluster.simple_cluster.id
        api_version = confluent_kafka_cluster.simple_cluster.api_version
        kind = confluent_kafka_cluster.simple_cluster.kind
        environment {
            id = confluent_environment.simple_env.id
        }
    }
    depends_on = [
        confluent_role_binding.clients_cluster_admin
    ]
}

# --------------------------------------------------------
# Kafka Topics
# --------------------------------------------------------

resource "confluent_kafka_topic" "credit_cards" {
  kafka_cluster {
    id = confluent_kafka_cluster.simple_cluster.id
  }
  topic_name         = "credit_cards"
  partitions_count   = 6
  rest_endpoint      = confluent_kafka_cluster.simple_cluster.rest_endpoint
  # https://docs.confluent.io/cloud/current/clusters/broker-config.html#custom-topic-settings-for-all-cluster-types-supported-by-kafka-rest-api-and-terraform-provider
  config = {
    "cleanup.policy"                      = "delete"
    "delete.retention.ms"                 = "86400000"
    "max.compaction.lag.ms"               = "9223372036854775807"
    "max.message.bytes"                   = "2097164"
    "message.timestamp.difference.max.ms" = "9223372036854775807"
    "message.timestamp.type"              = "CreateTime"
    "min.compaction.lag.ms"               = "0"
    "min.insync.replicas"                 = "2"
    "retention.bytes"                     = "-1"
    "retention.ms"                        = "604800000"
    "segment.bytes"                       = "104857600"
    "segment.ms"                          = "604800000"
  }
  credentials {
    key    = confluent_api_key.app_manager_kafka_cluster_key.id
    secret = confluent_api_key.app_manager_kafka_cluster_key.secret
  }
}

resource "confluent_kafka_topic" "transactions" {
  kafka_cluster {
    id = confluent_kafka_cluster.simple_cluster.id
  }
  topic_name         = "transactions"
  partitions_count   = 6
  rest_endpoint      = confluent_kafka_cluster.simple_cluster.rest_endpoint
  # https://docs.confluent.io/cloud/current/clusters/broker-config.html#custom-topic-settings-for-all-cluster-types-supported-by-kafka-rest-api-and-terraform-provider
  config = {
    "cleanup.policy"                      = "delete"
    "delete.retention.ms"                 = "86400000"
    "max.compaction.lag.ms"               = "9223372036854775807"
    "max.message.bytes"                   = "2097164"
    "message.timestamp.difference.max.ms" = "9223372036854775807"
    "message.timestamp.type"              = "CreateTime"
    "min.compaction.lag.ms"               = "0"
    "min.insync.replicas"                 = "2"
    "retention.bytes"                     = "-1"
    "retention.ms"                        = "604800000"
    "segment.bytes"                       = "104857600"
    "segment.ms"                          = "604800000"
  }
  credentials {
    key    = confluent_api_key.app_manager_kafka_cluster_key.id
    secret = confluent_api_key.app_manager_kafka_cluster_key.secret
  }
}

resource "confluent_kafka_topic" "users" {
  kafka_cluster {
    id = confluent_kafka_cluster.simple_cluster.id
  }
  topic_name         = "users"
  partitions_count   = 6
  rest_endpoint      = confluent_kafka_cluster.simple_cluster.rest_endpoint
  # https://docs.confluent.io/cloud/current/clusters/broker-config.html#custom-topic-settings-for-all-cluster-types-supported-by-kafka-rest-api-and-terraform-provider
  config = {
    "cleanup.policy"                      = "delete"
    "delete.retention.ms"                 = "86400000"
    "max.compaction.lag.ms"               = "9223372036854775807"
    "max.message.bytes"                   = "2097164"
    "message.timestamp.difference.max.ms" = "9223372036854775807"
    "message.timestamp.type"              = "CreateTime"
    "min.compaction.lag.ms"               = "0"
    "min.insync.replicas"                 = "2"
    "retention.bytes"                     = "-1"
    "retention.ms"                        = "604800000"
    "segment.bytes"                       = "104857600"
    "segment.ms"                          = "604800000"
  }
  credentials {
    key    = confluent_api_key.app_manager_kafka_cluster_key.id
    secret = confluent_api_key.app_manager_kafka_cluster_key.secret
  }
}

# --------------------------------------------------------
# ksqlDB Cluster
# --------------------------------------------------------

resource "confluent_ksql_cluster" "fraud-detection" {
  display_name = "fraud-detection"
  csu          = 1
  kafka_cluster {
    id = confluent_kafka_cluster.simple_cluster.id
  }
  credential_identity {
    id = confluent_service_account.app-ksql.id
  }
  environment {
    id = confluent_environment.simple_env.id
  }
  depends_on = [
    confluent_role_binding.app-ksql-kafka-cluster-admin,
    confluent_role_binding.sr_environment_admin,
    confluent_schema_registry_cluster.simple_sr_cluster
  ]

  lifecycle {
    prevent_destroy = true
  }
}

# --------------------------------------------------------
# Connectors
# --------------------------------------------------------

resource "confluent_connector" "credit_cards" {
  environment {
    id = confluent_environment.simple_env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.simple_cluster.id
  }

  config_sensitive = {}

  config_nonsensitive = {
    "connector.class"          = "DatagenSource"
    "name"                     = "DatagenSourceConnector_CreditCard"
    "kafka.auth.mode"          = "SERVICE_ACCOUNT"
    "kafka.service.account.id" = confluent_service_account.clients.id
    "kafka.topic"              = confluent_kafka_topic.credit_cards.topic_name
    "output.data.format"       = "JSON"
    "quickstart"               = "CREDIT_CARDS"
    "tasks.max"                = "1"
    "max.interval"             = "1000"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_connector" "transactions" {
  environment {
    id = confluent_environment.simple_env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.simple_cluster.id
  }

  config_sensitive = {}

  config_nonsensitive = {
    "connector.class"          = "DatagenSource"
    "name"                     = "DatagenSourceConnector_Transactions"
    "kafka.auth.mode"          = "SERVICE_ACCOUNT"
    "kafka.service.account.id" = confluent_service_account.clients.id
    "kafka.topic"              = confluent_kafka_topic.transactions.topic_name
    "output.data.format"       = "JSON"
    "quickstart"               = "TRANSACTIONS"
    "tasks.max"                = "1"
    "max.interval"             = "1000"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "confluent_connector" "users" {
  environment {
    id = confluent_environment.simple_env.id
  }
  kafka_cluster {
    id = confluent_kafka_cluster.simple_cluster.id
  }

  config_sensitive = {}

  config_nonsensitive = {
    "connector.class"          = "DatagenSource"
    "name"                     = "DatagenSourceConnector_Users"
    "kafka.auth.mode"          = "SERVICE_ACCOUNT"
    "kafka.service.account.id" = confluent_service_account.clients.id
    "kafka.topic"              = confluent_kafka_topic.users.topic_name
    "output.data.format"       = "JSON"
    "quickstart"               = "USERS"
    "tasks.max"                = "1"
    "max.interval"             = "1000"
  }

  lifecycle {
    prevent_destroy = true
  }
}