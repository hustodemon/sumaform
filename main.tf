module "images" {
  source = "./libvirt_images"
}

module "suma21pg" {
  source = "./libvirt_host"
  name = "suma21pg"
  image = "${module.images.sles11sp3}"
  version = "2.1-nightly"
  database = "postgres"
  role = "suse-manager-server"
}

/*module "suma_openstack" {
  source = "./openstack_host"
  name = "suma21pg"
  image = "sumaform-sles11sp3"
  version = "2.1-nightly"
  database = "postgres"
  role = "suse-manager-server"
}*/
