###############################################################################
# versions.tf
#
# Kept separate from providers.tf so tflint / pre-commit hooks can find the
# required_version block without parsing provider configuration.
###############################################################################

terraform {
  required_version = ">= 1.6.0, < 2.0.0"
}
