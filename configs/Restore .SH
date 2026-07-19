#!/bin/bash
# ============================================================
# rocky-node1 DNS(named) + DHCP(kea) 설정 복원 스크립트
# 사용법: 이 스크립트와 같은 폴더의 named.conf, example.local.zone,
#         kea-dhcp4.conf 를 node1에 업로드한 뒤 root로 실행
#         sudo bash restore.sh
# ============================================================
set -e

echo "== 1. 패키지 확인 =="
command -v named >/dev/null 2>&1 || sudo dnf install -y bind bind-utils
command -v kea-dhcp4 >/dev/null 2>&1 || sudo dnf install -y kea

echo "== 2. named 설정 복원 =="
cp ./named.conf /etc/named.conf
cp ./example.local.zone /var/named/example.local.zone
cp ./56.168.192.rev /var/named/56.168.192.rev
chown root:named /var/named/example.local.zone /var/named/56.168.192.rev
chmod 640 /var/named/example.local.zone /var/named/56.168.192.rev
restorecon -v /var/named/example.local.zone /var/named/56.168.192.rev

echo "== 3. kea-dhcp4 설정 복원 =="
cp ./kea-dhcp4.conf /etc/kea/kea-dhcp4.conf

echo "== 4. 문법 검증 =="
named-checkconf
named-checkzone example.local /var/named/example.local.zone
named-checkzone 56.168.192.in-addr.arpa /var/named/56.168.192.rev
kea-dhcp4 -t /etc/kea/kea-dhcp4.conf

echo "== 5. 방화벽 =="
firewall-cmd --permanent --add-service=dns
firewall-cmd --permanent --add-service=dhcp
firewall-cmd --reload

echo "== 6. 서비스 재시작 =="
systemctl enable --now named
systemctl enable --now kea-dhcp4

echo "== 7. 상태 확인 =="
systemctl status named kea-dhcp4 --no-pager

echo "== 완료. 아래 명령으로 최종 검증하세요 =="
echo "  dig @192.168.56.10 ns1.example.local"
echo "  cat /var/lib/kea/kea-leases4.csv"

# ------------------------------------------------------------
# ⚠️ VirtualBox 내장 DHCP와 충돌 이력이 있었음. 호스트(PowerShell)에서
# 아래 명령으로 반드시 비활성화 상태인지 확인할 것:
#   VBoxManage list dhcpservers
#   VBoxManage dhcpserver modify --network="HostInterfaceNetworking-VirtualBox Host-Only Ethernet Adapter" --disable
# ------------------------------------------------------------