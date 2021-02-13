resource "lxd_profile" "kubenode" {
  name = "kubenode"

  config = {
    "limits.cpu" = 2
    "limits.memory.swap" = false
    "security.privileged"  = true
    "security.nesting"     = true
    "linux.kernel_modules" = "ip_tables,ip6_tables,nf_nat,overlay,br_netfilter"
    "raw.lxc"       = <<-EOT
      lxc.apparmor.profile=unconfined
      lxc.cap.drop=
      lxc.cgroup.devices.allow=a
      lxc.mount.auto=proc:rw sys:rw cgroup:rw
    EOT
    "user.user-data"       = <<-EOT
      #cloud-config
      ssh_authorized_keys:
        - ${file("~/.ssh/id_rsa.pub")}
      disable_root: false
      runcmd:
        - curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        - add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
        - apt-get update -y
        - apt-get install -y docker-ce docker-ce-cli containerd.io
        - mkdir -p /etc/systemd/system/docker.service.d/
        - printf "[Service]\nMountFlags=shared" > /etc/systemd/system/docker.service.d/mount_flags.conf
        - mount --make-rshared /
        - systemctl start docker
        - systemctl enable docker
    EOT
  }

  device {
    type = "unix-char"
    name = "kmsg"

    properties = {
      source = "/dev/kmsg"
      path = "/dev/kmsg"
    }
  }

  device {
    name = "eth0"
    type = "nic"

    properties = {
      network = "lxdbr0"
    }
  }

  device {
    type = "disk"
    name = "root"

    properties = {
      pool = "default"
      path = "/"
    }
  }
}

resource "lxd_container" "k8s" {
  count     = 1
  name      = "k8s${count.index}"
  image     = "ubuntu:20.04"
  ephemeral = false

  profiles = [lxd_profile.kubenode.name]
}

resource "time_sleep" "wait_cloud_init" {
  depends_on = [lxd_container.k8s]

  create_duration = "5m"
}

resource "rke_cluster" "cluster" {
  dynamic "nodes" {
    for_each = lxd_container.k8s

    content {
      address = nodes.value.ip_address
      user    = "root"
      role = [
        "controlplane",
        "etcd",
        "worker"
      ]
      ssh_key = file("~/.ssh/id_rsa")
    }
  }

  ingress {
    provider = "none"
  }

  ignore_docker_version = true

  depends_on = [time_sleep.wait_cloud_init]
}

resource "local_file" "kube_config_yaml" {
  filename = "${path.root}/kube_config.yaml"
  content  = rke_cluster.cluster.kube_config_yaml
}