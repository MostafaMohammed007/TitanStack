# TitanStack
Automated DevOps bootstrap stack that deploys a complete Kubernetes, CI/CD, GitOps, monitoring, and cloud automation environment on AWS EC2 or any vm builted from scratch.
# DevOps Kubernetes Bootstrap Project

This project is an automated DevOps environment installer for an Ubuntu EC2 instance.

The goal is to create a complete Kubernetes and DevOps lab using one Bash script.

The script installs and configures:

* Docker
* Kubernetes (kubeadm, kubelet, kubectl)
* Containerd
* Helm
* ArgoCD
* Jenkins
* Prometheus
* Grafana
* Loki
* Promtail
* SonarQube
* Trivy
* Terraform
* AWS CLI
* NGINX Ingress Controller
* Cert-manager

## How it works

The script prepares the Linux system, installs required packages, configures Docker and Kubernetes, then deploys DevOps tools using Helm charts.

Kubernetes is initialized as a single-node cluster with Calico networking.

Helm is used to manage applications and install DevOps services inside Kubernetes namespaces.

ArgoCD provides GitOps deployment.
Jenkins provides CI/CD automation.
Prometheus and Grafana provide monitoring and dashboards.
Loki and Promtail provide log collection.

## Usage

Clone the repository:

git clone <repository-url>

Give execution permission:

chmod +x install-devops-stack.sh

Run the installer:

./install-devops-stack.sh

## Requirements

* Ubuntu 22.04 / 24.04
* AWS EC2 instance
* Minimum 8GB RAM recommended
* Open required security group ports

After installation, use kubectl and Helm to manage the cluster.

This project creates a complete DevOps playground for learning Kubernetes, CI/CD, monitoring, and cloud automation.
