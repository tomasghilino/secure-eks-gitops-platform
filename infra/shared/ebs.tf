# every new volume in the region is encrypted, including the ones the ebs csi driver creates for pvcs;
# its default storage class doesn't ask for encryption
resource "aws_ebs_encryption_by_default" "main" {
  enabled = true
}
