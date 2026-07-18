# Rocky Linux 10 — DNS(BIND) & DHCP(Kea) 서버 구축 실습

> Rocky Linux 10 기반 홈랩 환경에서 BIND(named)와 Kea DHCP 서버를 직접 구축하고 트러블슈팅한 기록입니다.

**실습일**: 2026-07-18
**환경**: VirtualBox + Vagrant / Rocky Linux 10 / Host-only Network `192.168.56.0/24`

---

## 목차

- [환경 구성](#환경-구성)
- [1. DNS 서버 구축 (BIND / named)](#1-dns-서버-구축-bind--named)
- [2. DHCP 서버 구축 (Kea)](#2-dhcp-서버-구축-kea)
- [3. 트러블슈팅 로그](#3-트러블슈팅-로그)
- [4. 핵심 학습 포인트](#4-핵심-학습-포인트)
- [5. TODO](#5-todo)

---

## 환경 구성

| 항목 | 값 |
|---|---|
| rocky-node1 (DNS+DHCP 서버) | `192.168.56.10` |
| rocky-node2 (클라이언트) | `192.168.56.20` (고정) → DHCP로 `192.168.56.101` 임대 |
| 인터페이스 | `enp0s3`(NAT), `enp0s8`(Host-only) |
| 관리 도구 | Vagrant, VirtualBox, PowerShell |

```ruby
# Vagrantfile 핵심 구조
VM_CONFIG = {
  "rocky-node1" => { networks: ["192.168.56.10"] },
  "rocky-node2" => { networks: ["192.168.56.20"] },
}
```

---

## 1. DNS 서버 구축 (BIND / named)

### 설치

```bash
sudo dnf install -y bind bind-utils
sudo systemctl enable --now named
sudo firewall-cmd --permanent --add-service=dns
sudo firewall-cmd --reload
```

### `/etc/named.conf`

```
listen-on port 53 { 127.0.0.1; 192.168.56.10; };
allow-query     { localhost; 192.168.56.0/24; };

zone "example.local" IN {
    type master;
    file "example.local.zone";
    allow-update { none; };
};
```

### `/var/named/example.local.zone`

```
$TTL 86400
@       IN  SOA     ns1.example.local. admin.example.local. (
                        2026071801  ; serial
                        3600        ; refresh
                        1800        ; retry
                        604800      ; expire
                        86400 )     ; minimum

        IN  NS      ns1.example.local.

ns1     IN  A       192.168.56.10
@       IN  A       192.168.56.10
www     IN  A       192.168.56.10
```

### 권한 / SELinux (필수)

```bash
sudo chown root:named /var/named/example.local.zone
sudo chmod 640 /var/named/example.local.zone
sudo restorecon -v /var/named/example.local.zone
```

### 검증

```bash
sudo named-checkconf
sudo named-checkzone example.local /var/named/example.local.zone
sudo systemctl restart named
dig @192.168.56.10 ns1.example.local
```

**결과**: 원격 클라이언트(node2)에서 `dig` 조회 시 `status: NOERROR`, `aa` flag 정상 확인.

> ⏸ **미완료**: 역방향 존(`56.168.192.in-addr.arpa`) — zone 선언 자체를 아직 안 함.

---

## 2. DHCP 서버 구축 (Kea)

> ⚠️ Rocky Linux 10부터 `dhcp-server`(ISC DHCP) 패키지가 저장소에서 제외됨. 후속 제품인 **Kea**로 대체.

### 설치

```bash
sudo dnf install -y kea
systemctl list-unit-files | grep kea   # Kea 3.x 서비스명은 kea-dhcp4 (구: kea-dhcp4-server 아님)
sudo systemctl enable --now kea-dhcp4
```

### `/etc/kea/kea-dhcp4.conf`

```json
{
  "Dhcp4": {
    "interfaces-config": {
      "interfaces": [ "enp0s8" ]
    },
    "subnet4": [
      {
        "id": 1,
        "subnet": "192.168.56.0/24",
        "interface": "enp0s8",
        "pools": [ { "pool": "192.168.56.100 - 192.168.56.200" } ],
        "option-data": [
          { "name": "routers", "data": "192.168.56.1" },
          { "name": "domain-name-servers", "data": "192.168.56.10" }
        ]
      }
    ]
  }
}
```

> 기본 템플릿의 `reservations` 예시 블록은 부분 주석 처리로 인한 JSON 파싱 오류의 주 원인이므로, 초기 실습에서는 통째로 삭제 권장.

### 검증 및 기동

```bash
sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
sudo systemctl restart kea-dhcp4
sudo firewall-cmd --permanent --add-service=dhcp
sudo firewall-cmd --reload
```

### 임대 확인

```bash
cat /var/lib/kea/kea-leases4.csv
sudo journalctl -u kea-dhcp4 -f
```

**최종 결과**:
```
192.168.56.101,08:00:27:7a:7b:dd,...,3600,...,rocky-node2,0,,0
```
node2가 `192.168.56.101`을 정상 임대받았고, DNS 옵션(`192.168.56.10`)도 함께 전달됨.

---

## 3. 트러블슈팅 로그

| 증상 | 원인 | 해결 |
|---|---|---|
| `option 'allow-update' is not allowed in 'hint' zone` | hint zone에 잘못된 옵션 혼입 | hint zone 블록에서 옵션 제거 |
| `could not configure root hints from 'name.ca'` | 파일명 오타(`named.ca`→`name.ca`) | 오타 수정 |
| `loading ... failed: permission denied` | 존 파일 소유권/권한 미설정 | `chown`, `chmod`, `restorecon` |
| `Unable to find a match: dhcp-server` | Rocky 10부터 ISC DHCP 폐지 | Kea로 대체 설치 |
| `Unit kea-dhcp4-server.service could not be found` | Kea 3.x 서비스명 변경 | `kea-dhcp4`로 정정 |
| `interface name eth0s8 ... not present` | 인터페이스명 오타 | `enp0s8`로 수정 |
| `reservation ... is not within the IPv4 subnet` | 예시 reservation IP가 실제 서브넷과 불일치 | reservation 예시 블록 삭제 |
| `got unexpected keyword "client-id" in subnet4 map` | 부분 주석 처리로 JSON 구조 파손 | reservations 블록 전체를 범위 삭제 |
| `nmcli connection modify` Permission denied | `.nmconnection` 파일 SELinux 컨텍스트가 `user_tmp_t` | `restorecon`으로 `NetworkManager_etc_rw_t` 복구 |
| node2가 `.101`을 받는데 Kea 임대 기록엔 없음 | **VirtualBox 내장 DHCP(host-only, IP `.100`)와 Kea가 경합** | `VBoxManage dhcpserver modify --disable`로 비활성화 |
| 비활성화 후에도 `.100`이 계속 응답 | `vagrant reload` 시 Vagrant가 host-only DHCP를 자동 재활성화 | 재차 `--disable` 실행 |

---

## 4. 핵심 학습 포인트

- BIND 존 파일 구조(SOA/NS/A), FQDN 표기 규칙(`.` 유무), Serial 값은 수정 시마다 증가 필수
- Rocky 10: ISC DHCP → **Kea** 전환, 설정 파일이 텍스트 → **JSON**
- SELinux: 파일 권한(rwx)이 맞아도 컨텍스트가 틀리면 서비스 접근 거부 → `restorecon`이 표준 해결
- **VirtualBox host-only 네트워크는 기본적으로 자체 DHCP 서버를 내장** → 커스텀 DHCP와 반드시 충돌 여부 확인
- `dig`의 QUESTION/ANSWER/AUTHORITY 섹션 해석, NOERROR vs NXDOMAIN
- `tcpdump`로 DORA(Discover-Offer-Request-Ack) 과정을 직접 캡처하는 것이 DHCP 트러블슈팅의 가장 확실한 방법

---

## 5. TODO

- [ ] 역방향 존(`56.168.192.in-addr.arpa`) 완성
- [ ] DHCP `domain-name` 옵션 `example.org` → `example.local` 수정
- [ ] Kea host reservation으로 node2 MAC 고정 IP 할당
- [ ] named/kea 로그를 Wazuh/ELK로 연동