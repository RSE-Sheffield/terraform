# Management node instance
resource "google_compute_instance" "mgmt" {
  name         = "mgmt"
  machine_type = "${var.management_compute_instance_config["type"]}"
  tags = ["mgmt"]
  metadata_startup_script = "${data.template_file.bootstrap-script.rendered}"

  depends_on = [
    "module.filestore_shared_storage",
  ]

  # add an ssh key that ca be used to provisiont the instance once it's started  
  metadata = {
   ssh-keys = "provisioner:${data.local_file.ssh_public_key.content}"
 }

  boot_disk {
    initialize_params {
      image = "${var.management_compute_instance_config["image"]}"
    }
  }
  network_interface {
    subnetwork = "${google_compute_subnetwork.vpc_subnetwork.name}"

    # add an empty access_config block. We only need a public address which is a default part of this block
    access_config {}
  }

  # use the service account created to run the instance. This allows granular control over what the instance can access on GCP
  service_account {
    email = "${google_service_account.mgmt-sa.email}"
    scopes = ["compute-rw"]
  }
  
  # Ignore changes to the disk image, as if a family is specified it != the image name on the instance, and continually
  # rebuild when terraform is reapplied
  lifecycle {
    ignore_changes = ["boot_disk.0.initialize_params.0.image"]
  }

  # ssh connection information for provisioning
  connection {
    type          = "ssh"
    user          = "provisioner"
    private_key   = "${file("${var.private_key_path}")}"
    host          = "${google_compute_instance.mgmt.network_interface.0.access_config.0.nat_ip}"
  }

  provisioner "file" {
    destination = "/tmp/shapes.yaml"
    source = "${path.module}/files/shapes.yaml"
  }

  #TODO use file template?
  provisioner "file" {
    destination = "/tmp/startnode.yaml"
    content = <<EOF
compartment_id: ${var.project}
zone: ${var.zone}
subnet: regions/${google_compute_subnetwork.vpc_subnetwork.region}/subnetworks/${google_compute_subnetwork.vpc_subnetwork.name}
ansible_branch: ${var.management_compute_instance_config["ansible_branch"]}
EOF
  }

  provisioner "remote-exec" {
    when = "destroy"
    inline = [
      "echo Terminating any remaining compute nodes",
      "if systemctl status slurmctld >> /dev/null; then",
      "sudo -u slurm /usr/local/bin/stopnode \"$(sinfo --noheader --Format=nodelist:10000 | tr -d '[:space:]')\" || true",
      "fi",
      "sleep 5",
      "echo Node termination request completed",
    ]
  }
}
