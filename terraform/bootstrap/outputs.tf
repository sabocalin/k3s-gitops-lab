output "state_bucket" {
  description = "Bucket for every stack's remote state (backend \"s3\" bucket)."
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}
