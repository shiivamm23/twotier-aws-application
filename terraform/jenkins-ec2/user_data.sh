#!/bin/bash
# Runs once as root when the EC2 instance first boots
dnf update -y
dnf install -y docker git java-17-amazon-corretto-headless

systemctl enable --now docker

# Jenkins official repo + install
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins

# Let the jenkins user run docker commands
usermod -aG docker jenkins

systemctl enable --now jenkins
