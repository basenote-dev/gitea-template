terraform {
  # Write-only arguments and ephemeral resources (secrets never reach state).
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.44"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.1" # ephemeral tls_private_key
    }
  }
}
