# A fresh "VPS" for the local lab: Ubuntu 24.04 with systemd as PID 1 and
# sshd accepting the root password, like a provider image before provisioning.
FROM ubuntu:24.04

ENV container=docker
ARG ROOT_PASSWORD=lab-root-password

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates iproute2 iptables kmod openssh-server python3 systemd systemd-sysv \
 && rm -rf /var/lib/apt/lists/* \
 && echo "root:${ROOT_PASSWORD}" | chpasswd \
 && printf 'PermitRootLogin yes\nPasswordAuthentication yes\n' > /etc/ssh/sshd_config.d/50-provider.conf \
 && systemctl enable ssh.socket \
 # These units act on the kernel, which a privileged container shares with the
 # host: masked so that installing auditd or AppArmor never touches the host.
 && systemctl mask auditd.service apparmor.service systemd-timesyncd.service \
      getty.target console-getty.service

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
