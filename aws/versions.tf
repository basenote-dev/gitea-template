terraform {
  # Ephemeral resources and write-only arguments (secrets never reach state or plan files).
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.44"
    }
  }
}
