# 추가 작업 세션 — 역방향 존 / DHCP 옵션 정리 / Host Reservation

📅 작업일: 2026-07-19 (1차 세션 다음 날 이어서 진행)
🔗 이전 세션: [Rocky 10 DNS/DHCP 구축 실습 노트](./rocky10-dns-dhcp-lab-note.md)

> 이전 세션 종료 시점에 VirtualBox VM 이름 충돌 문제로 rocky-node1을 destroy 후 재생성함. 이번 세션은 그 복구 이후 진행한 3가지 TODO 완료 기록.

---

## 1. 역방향 존(Reverse Zone) 완성

### `/etc/named.conf`에 zone 선언 추가

```
zone "56.168.192.in-addr.arpa" IN {
    type master;
    file "56.168.192.rev";
    allow-update { none; };
};
```

### `/var/named/56.168.192.rev` 생성

```
$TTL 86400
@       IN  SOA     ns1.example.local. admin.example.local. (
                        2026071901  ; serial
                        3600        ; refresh
                        1800        ; retry
                        604800      ; expire
                        86400 )     ; minimum

        IN  NS      ns1.example.local.

10      IN  PTR     ns1.example.local.
```

### 권한/SELinux/검증

```bash
sudo chown root:named /var/named/56.168.192.rev
sudo chmod 640 /var/named/56.168.192.rev
sudo restorecon -v /var/named/56.168.192.rev
sudo named-checkzone 56.168.192.in-addr.arpa /var/named/56.168.192.rev
sudo systemctl restart named
```

### ✅ 결과 검증

```bash
dig @192.168.56.10 -x 192.168.56.10
```
```
;; ANSWER SECTION:
10.56.168.192.in-addr.arpa. 86400 IN PTR ns1.example.local.
```
`status: NOERROR`, `aa` 플래그 정상. 정방향(A) + 역방향(PTR) 모두 완비.

---

## 2. DHCP `domain-name` 옵션 수정

Kea 기본 템플릿의 잔재였던 전역 옵션을 실제 도메인에 맞게 수정.

```json
// 변경 전
{ "code": 15, "data": "example.org" }

// 변경 후
{ "code": 15, "data": "example.local" }
```

### ✅ 결과 검증 (node2에서)

```bash
sudo nmcli connection down "enp0s8"
sudo nmcli connection up "enp0s8"
nmcli device show enp0s8 | grep -i domain
```
```
IP4.DOMAIN[1]:    example.local
```

> 📝 참고: 같은 전역 `option-data`에 `domain-name-servers: "192.168.25.10, 192.0.2.2"`라는 오타/예제 잔재도 발견했으나, `subnet4` 레벨 옵션이 우선 적용되어 실제 클라이언트에는 영향 없음(`192.168.56.10`이 정상 전달). 우선순위: `host > subnet4 > class > global`. 유지보수 관점에서 추후 정리 권장 사항으로 남겨둠.

---

## 3. Kea Host Reservation — node2 MAC 고정 IP 할당

### `/etc/kea/kea-dhcp4.conf`의 `subnet4` 내부에 `reservations` 추가

```json
"subnet4": [
    {
        "id": 1,
        "subnet": "192.168.56.0/24",
        "interface": "enp0s8",
        "pools": [ { "pool": "192.168.56.100 - 192.168.56.200" } ],
        "option-data": [
            { "name": "routers", "data": "192.168.56.1" },
            { "name": "domain-name-servers", "data": "192.168.56.10" }
        ],
        "reservations": [
            {
                "hw-address": "08:00:27:a5:22:cf",
                "ip-address": "192.168.56.50",
                "hostname": "rocky-node2"
            }
        ]
    }
]
```

> reservation IP(`.50`)는 dynamic pool 범위(`.100–.200`) 밖으로 지정 — 정적/동적 할당을 명확히 구분하기 위한 관례.

### 검증 및 재시작

```bash
sudo kea-dhcp4 -t /etc/kea/kea-dhcp4.conf
sudo systemctl restart kea-dhcp4
```

### ✅ 결과 검증

node2:
```bash
sudo nmcli connection down "enp0s8"
sudo nmcli connection up "enp0s8"
ip -br a
```
```
enp0s8    UP    192.168.56.50/24
```

node1:
```bash
sudo cat /var/lib/kea/kea-leases4.csv
```
```
192.168.56.50,08:00:27:a5:22:cf,...,rocky-node2,0,,0
```

MAC `08:00:27:a5:22:cf`가 pool이 아닌 예약 IP `.50`을 정상적으로 받는 것 확인.

---

## 4. 이번 세션에서 겪은 트러블슈팅

| 증상 | 원인 | 해결 |
|---|---|---|
| `kea-dhcp4 -t` 통과 후에도 `reservations` 추가 시 문법 오류 재발 | `option-data` 배열을 닫는 `]` 뒤에 콤마(`,`) 누락 | 콤마 추가 |
| `got unexpected keyword "loggers" in subnet4 map` | `reservations` 배열만 닫고, 그걸 감싸는 서브넷 객체(`}`)와 `subnet4` 배열(`]`)을 안 닫음 — 괄호 깊이 불일치 | `]` 뒤에 `}`(서브넷 객체 닫기), `],`(subnet4 배열 닫기) 순서로 추가 |

> JSON 중첩 구조를 손으로 편집할 때는 **여는 괄호와 닫는 괄호의 "레벨"을 항상 짝 맞춰 확인**하는 습관이 필요함을 재확인. `option-data`, `reservations`, subnet 객체, `subnet4` 배열까지 4단계 중첩이라 실수하기 쉬웠음.

---

## 5. 남은 TODO

- [ ] Wazuh/ELK 로그 연동 — ⚠️ **이번 세션 시작 시점에 Wazuh 서버(호스트) 자체가 다운된 것 확인. 별도 복구 작업 필요, 다음 세션으로 이월.**
- [ ] kea-dhcp4.conf 전역 option-data의 오타/예제 잔재(`192.168.25.10, 192.0.2.2`) 정리
- [ ] 두 번째 DHCP reservation 예시(다른 클라이언트) 추가해보기
- [ ] named 로그 레벨을 default_debug에서 query 로그 전용 채널로 분리 (Wazuh 연동 전 사전 작업)

---

## 6. 업데이트된 설정 파일

이번 세션 반영본은 아래 파일 참고:
- `configs/named.conf` (역방향 존 추가)
- `configs/56.168.192.rev` (신규)
- `configs/kea-dhcp4.conf` (domain-name 수정 + reservations 추가)