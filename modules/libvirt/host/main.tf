resource "libvirt_volume" "main_disk" {
  name = "terraform_${var.name}_${count.index}_disk"
  base_volume_id = "${var.image}"
  pool = "${var.libvirt_pool}"
  count = "${var.count}"
}

resource "libvirt_domain" "domain" {
  name = "${var.name}_${count.index}"
  memory = "${var.memory}"
  vcpu = "${var.vcpu}"
  running = "${var.running}"
  count = "${var.count}"

  disk {
    volume_id = "${element(libvirt_volume.main_disk.*.id, count.index)}"
  }

  network_interface {
    wait_for_lease = true
    // "terraform-network" if not bridged, "" if bridged
    network_name = "${element(list("terraform-network", ""), var.bridged)}"
    // "" if not bridged, ${var.bridge} if bridged
    bridge = "${element(list("", "${var.bridge}"), var.bridged)}"
  }

  connection {
    user = "root"
    password = "linux"
  }

  provisioner "file" {
    source = "salt"
    destination = "/srv"
  }

  provisioner "file" {
    content = <<EOF

hostname: ${var.name}${element(list("", "-${count.index  + 1}"), signum(var.count - 1))}
domain: ${var.domain}
use-avahi: True
package-mirror: ${var.package-mirror}
version: ${var.version}
database: ${var.database}
role: ${var.role}
cc_username: ${var.cc_username}
cc_password: ${var.cc_password}
server: ${var.server}
iss-master: ${var.iss-master}
iss-slave: ${var.iss-slave}
for-development-only: True

EOF

    destination = "/etc/salt/grains"
  }

  provisioner "remote-exec" {
    inline = [
      "salt-call --force-color --local state.sls terraform-resource",
      "salt-call --force-color --local state.highstate"
    ]
  }
}

output "hostname" {
    // HACK: this output artificially depends on the domain id
    // any resource using this output will have to wait until domain is fully up
    value = "${coalesce("${var.name}.${var.domain}", libvirt_domain.domain.id)}"
}
