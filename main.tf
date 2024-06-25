provider "google" {
  credentials = file(var.credentials_file)
  project     = var.project
  region      = var.region
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "4.9.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "4.0.5"
    }
  }
}

resource "google_project_service" "secretmanager" {
  service = "secretmanager.googleapis.com"
}

resource "tls_private_key" "kubernetes_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "google_secret_manager_secret" "kubernetes_key" {
  secret_id = "kubernetes-key"
  replication {
    automatic = true
  }
  depends_on = [google_project_service.secretmanager]
}

resource "google_secret_manager_secret_version" "kubernetes_key_version" {
  secret      = google_secret_manager_secret.kubernetes_key.id
  secret_data = tls_private_key.kubernetes_key.private_key_pem
}

resource "null_resource" "wait_for_secret_version" {
  depends_on = [google_secret_manager_secret_version.kubernetes_key_version]

  provisioner "local-exec" {
    command = "sleep 10"
  }
}

data "google_secret_manager_secret_version" "kubernetes_key_version_data" {
  depends_on = [null_resource.wait_for_secret_version]
  secret  = google_secret_manager_secret.kubernetes_key.id
  version = "latest"
}

output "kubernetes_key" {
  value     = data.google_secret_manager_secret_version.kubernetes_key_version_data.secret_data
  sensitive = true
}

resource "google_compute_instance" "k8s-master" {
  name         = "k8s-master"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = var.image
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata_startup_script = <<-EOF
  #!/bin/bash
  set -e
  exec > >(sudo tee /var/log/startup-script.log) 2>&1
  echo "Starting master node setup" | sudo tee -a /var/log/install.log
  sudo apt-get update | sudo tee -a /var/log/install.log

  # Adding Kubernetes APT repository and key
  sudo mkdir -p /etc/apt/keyrings | sudo tee -a /var/log/install.log
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.24/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg | sudo tee -a /var/log/install.log
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.24/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list | sudo tee -a /var/log/install.log

  sudo apt-get update | sudo tee -a /var/log/install.log
  sudo apt-get install -y apt-transport-https ca-certificates curl kubelet kubeadm kubectl docker.io | sudo tee -a /var/log/install.log
  sudo apt-mark hold kubelet kubeadm kubectl | sudo tee -a /var/log/install.log
  sudo systemctl enable docker | sudo tee -a /var/log/install.log
  sudo systemctl start docker | sudo tee -a /var/log/install.log

  echo "Initializing Kubernetes master" | sudo tee -a /var/log/install.log
  sudo kubeadm init --pod-network-cidr=10.244.0.0/16 | sudo tee -a /var/log/install.log

  # Set up kubeconfig for ubuntu user
  sudo mkdir -p /home/ubuntu/.kube | sudo tee -a /var/log/install.log
  sudo cp -i /etc/kubernetes/admin.conf /home/ubuntu/.kube/config | sudo tee -a /var/log/install.log
  sudo chown ubuntu:ubuntu /home/ubuntu/.kube/config | sudo tee -a /var/log/install.log

  # Ensure the kubeconfig is used
  echo "export KUBECONFIG=/home/ubuntu/.kube/config" | sudo tee -a /home/ubuntu/.bashrc
  export KUBECONFIG=/home/ubuntu/.kube/config

  # Ensure the necessary sysctl params are set
  sudo sysctl net.bridge.bridge-nf-call-iptables=1 | sudo tee -a /var/log/install.log

  # Apply the Flannel network
  echo "Applying Flannel network" | sudo tee -a /var/log/install.log
  kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml | sudo tee -a /var/log/install.log

  # Create and store the join token and hash in Secret Manager
  JOIN_CMD=$(sudo kubeadm token create --print-join-command)
  TOKEN=$(echo $JOIN_CMD | awk '{print $5}')
  DISCOVERY_HASH=$(echo $JOIN_CMD | awk '{print $7}')
  MASTER_INTERNAL_IP=$(hostname -I | awk '{print $1}')

  echo $TOKEN > /tmp/token.txt
  echo $DISCOVERY_HASH > /tmp/hash.txt
  echo $MASTER_INTERNAL_IP > /tmp/internal_ip.txt

  # Store the token, hash, and internal IP in Google Secret Manager
  if ! gcloud secrets describe kubernetes-token > /dev/null 2>&1; then
    gcloud secrets create kubernetes-token --data-file=/tmp/token.txt
  else
    gcloud secrets versions add kubernetes-token --data-file=/tmp/token.txt
  fi

  if ! gcloud secrets describe kubernetes-hash > /dev/null 2>&1; then
    gcloud secrets create kubernetes-hash --data-file=/tmp/hash.txt
  else
    gcloud secrets versions add kubernetes-hash --data-file=/tmp/hash.txt
  fi

  if ! gcloud secrets describe kubernetes-master-internal-ip > /dev/null 2>&1; then
    gcloud secrets create kubernetes-master-internal-ip --data-file=/tmp/internal_ip.txt
  else
    gcloud secrets versions add kubernetes-master-internal-ip --data-file=/tmp/internal_ip.txt
  fi
EOF

  tags = ["k8s", "master"]

  service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  metadata = {
    ssh-keys = "${var.username}:${tls_private_key.kubernetes_key.public_key_openssh}"
  }
}

resource "null_resource" "master_ready" {
  depends_on = [google_compute_instance.k8s-master]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = var.username
      private_key = tls_private_key.kubernetes_key.private_key_pem
      host        = google_compute_instance.k8s-master.network_interface.0.access_config.0.nat_ip
    }

    inline = [
      "export KUBECONFIG=/home/ubuntu/.kube/config",
      "while ! kubectl get nodes | grep 'Ready' | grep 'control-plane'; do echo 'Waiting for Kubernetes master to be ready...' | sudo tee -a /var/log/install.log && sleep 10; done"
    ]
  }
}

resource "google_compute_instance" "k8s-worker" {
  count        = 2
  name         = "k8s-worker-${count.index}"
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = var.image
    }
  }

  network_interface {
    network = "default"
    access_config {}
  }

  metadata_startup_script = <<-EOF
  #!/bin/bash
  set -e
  exec > >(sudo tee /var/log/startup-script.log) 2>&1
  echo "Starting worker node setup" | sudo tee -a /var/log/install.log
  sudo apt-get update | sudo tee -a /var/log/install.log

  # Adding Kubernetes APT repository and key
  sudo mkdir -p /etc/apt/keyrings | sudo tee -a /var/log/install.log
  curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.24/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-archive-keyring.gpg | sudo tee -a /var/log/install.log
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-archive-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.24/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list | sudo tee -a /var/log/install.log

  sudo apt-get update | sudo tee -a /var/log/install.log
  sudo apt-get install -y apt-transport-https ca-certificates curl kubelet kubeadm kubectl docker.io | sudo tee -a /var/log/install.log
  sudo apt-mark hold kubelet kubeadm kubectl | sudo tee -a /var/log/install.log
  sudo systemctl enable docker | sudo tee -a /var/log/install.log
  sudo systemctl start docker | sudo tee -a /var/log/install.log

  # Ensure kubectl, kubeadm, and kubelet are in the PATH
  export PATH=$PATH:/usr/local/bin:/usr/bin:/bin

  # Retrieve the token, discovery hash, and master internal IP from Secret Manager
  TOKEN=$(sudo gcloud secrets versions access latest --secret=kubernetes-token)
  DISCOVERY_HASH=$(sudo gcloud secrets versions access latest --secret=kubernetes-hash)
  MASTER_INTERNAL_IP=$(sudo gcloud secrets versions access latest --secret=kubernetes-master-internal-ip)

  echo "Joining Kubernetes cluster with token $TOKEN and hash $DISCOVERY_HASH at master IP $MASTER_INTERNAL_IP" | sudo tee -a /var/log/install.log
  while ! sudo kubeadm join $MASTER_INTERNAL_IP:6443 --token $TOKEN --discovery-token-ca-cert-hash $DISCOVERY_HASH; do
    echo 'Waiting for master to be ready...' | sudo tee -a /var/log/install.log
    sleep 10
  done
EOF

tags = ["k8s", "worker"]

service_account {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
}

metadata = {
    ssh-keys = "${var.username}:${tls_private_key.kubernetes_key.public_key_openssh}"
}

depends_on = [
    null_resource.master_ready
]
}

resource "null_resource" "workers_ready" {
  depends_on = [google_compute_instance.k8s-worker]

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = var.username
      private_key = tls_private_key.kubernetes_key.private_key_pem
      host        = google_compute_instance.k8s-master.network_interface.0.access_config.0.nat_ip
    }

    inline = [
      "export KUBECONFIG=/home/ubuntu/.kube/config",
      "while [ $(kubectl get nodes | grep 'Ready' | grep -v 'control-plane' | wc -l) -ne ${count.index + 1} ]; do echo 'Waiting for all worker nodes to be ready...' && sleep 10; done"
    ]
  }

  count = length(google_compute_instance.k8s-worker)
}

resource "google_compute_firewall" "default" {
name    = "default-allow-ssh-${random_id.firewall_id.hex}"
network = "default"

allow {
    protocol = "tcp"
    ports    = ["22"]
}

source_ranges = ["0.0.0.0/0"]
target_tags   = ["k8s"]
}

resource "google_compute_firewall" "k8s" {
name    = "k8s-allow-internal"
network = "default"

allow {
    protocol = "tcp"
    ports    = ["0-65535"]
}

allow {
    protocol = "udp"
    ports    = ["0-65535"]
}

allow {
    protocol = "icmp"
}

source_ranges = ["10.128.0.0/9"]
target_tags   = ["k8s"]
}

resource "random_id" "firewall_id" {
byte_length = 8
}

output "master_ip" {
value = google_compute_instance.k8s-master.network_interface.0.access_config.0.nat_ip
}